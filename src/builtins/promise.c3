/// Promise constructor, Promise.prototype methods, and microtask integration.
module duktape::builtins;
import duktape::types;
import duktape::hstring;
import std::io;

import duktape::heap;
import duktape::hobject;
import duktape::env;
import duktape::bytecode;
import duktape::vm;

// ============================================================================
// Promise helpers (ES6 §25.4)
// ============================================================================

const uint PROMISE_PENDING   = 0;
const uint PROMISE_FULFILLED = 1;
const uint PROMISE_REJECTED  = 2;

/// Hidden property keys for Promise internals.
/// Leading \xFF makes them inaccessible to user code (no way to spell that
/// byte in ECMAScript string literals).
const char[] PROMISE_REACTION_NEXT_KEY = "\xFFpromise_reaction_next";

/// Initialize the HObjectPromise extra fields for a freshly-allocated
/// Promise object.  Called once on allocation (covers both user-facing
/// Promise instances and Promise.prototype itself).
fn void promise_init(HObject* promise) {
    if (promise == null) return;
    (*promise.extra_ptr()).promise.state = PROMISE_PENDING;
    (*promise.extra_ptr()).promise.result.set_undefined();
    (*promise.extra_ptr()).promise.reactions_head = null;
    (*promise.extra_ptr()).promise.reactions_tail = null;
}

/// Get the promise state from HObjectExtra.promise.state.
fn uint promise_get_state(HObject* promise, uint default_state) {
    if (promise == null) return default_state;
    return (*promise.extra_ptr()).promise.state;
}

/// Set the promise state.  Idempotent: only writes if currently pending
/// (a Promise can only be settled once).
fn void promise_set_state(HObject* promise, uint state) {
    if (promise == null) return;
    if ((*promise.extra_ptr()).promise.state != PROMISE_PENDING) return;
    (*promise.extra_ptr()).promise.state = state;
}

/// Settle a Promise in one shot: state + result + refcounting.
/// No-op if the promise is already settled.
fn void promise_settle(HObject* promise, uint state, TVal* val, Heap* heap) {
    if (promise == null) return;
    if ((*promise.extra_ptr()).promise.state != PROMISE_PENDING) return;
    heap.tval_copy_ref(&(*promise.extra_ptr()).promise.result, val);
    (*promise.extra_ptr()).promise.state = state;
}

/// Set the promise result.  Refcount-aware.
fn void promise_set_result(HObject* promise, TVal* val, Heap* heap) {
    if (promise == null) return;
    heap.tval_copy_ref(&(*promise.extra_ptr()).promise.result, val);
}

/// Get the promise's resolved value / rejection reason.
fn TVal promise_get_result(HObject* promise) {
    return (*promise.extra_ptr()).promise.result;
}

/// Get the "next" pointer in the reaction linked list.
fn HObject* reaction_get_next(HObject* reaction, Heap* heap) {
    if (reaction == null) return null;
    HString* key = builtin_intern_string(heap, PROMISE_REACTION_NEXT_KEY);
    if (key == null) return null;
    if (try nv = reaction.get_prop(key)) {
        if (nv.is_object() && nv.get_heapptr() != null) {
            return (HObject*)nv.get_heapptr();
        }
    }
    return null;
}

/// Set the "next" pointer in the reaction linked list.
fn void reaction_set_next(HObject* reaction, HObject* next, Heap* heap) {
    if (reaction == null) return;
    HString* key = builtin_intern_string(heap, PROMISE_REACTION_NEXT_KEY);
    if (key == null) return;
    TVal nv;
    if (next != null) {
        nv.set_object(next);
    } else {
        nv.set_undefined();
    }
    reaction.put_prop(key, nv, hobject::PROP_FLAGS_WEC);
}

/// Check that `this` is a Promise object.
fn HObject* check_promise(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.PROMISE) return obj;
    }
    builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Promise.prototype method called on incompatible value");
    return null;
}

/// Call a capability resolve or reject function with a single value.
/// Used for custom-constructor then() chains.
fn void promise_call_cap_fn(Heap* heap, void* vm, TVal cap_fn, TVal val) {
    if (heap.call_fn == null || vm == null) return;
    bool callable = cap_fn.is_lightfunc() ||
        (cap_fn.is_object() && cap_fn.get_heapptr() != null &&
         ((HObject*)cap_fn.get_heapptr()).is_callable());
    if (!callable) return;
    TVal arg = val;
    TVal undef; undef.set_undefined();
    heap.call_fn(vm, cap_fn, &arg, 1, undef);
    // Swallow any error from the cap function — the promise is already
    // committed to resolve/reject; errors here are non-recoverable.
    if (heap.has_error) promise_clear_error_channels(heap, vm);
}

/// Build a capability-wrapper object for use as the `downstream` slot of a
/// microtask queue entry.  The wrapper carries cap_resolve and cap_reject so
/// promise_microtask_after can call them instead of directly settling a PROMISE.
/// The plain `promise` field records the result-promise for reference.
fn HObject*? promise_make_cap_wrapper(Heap* heap, TVal cap_resolve, TVal cap_reject, TVal cap_promise) {
    HObject*? raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = raw) return null;
    HObject* w = raw;
    w.prototype = null;
    HString* r_key = builtin_intern_string(heap, "\xFFcap_resolve_tv");
    HString* j_key = builtin_intern_string(heap, "\xFFcap_reject_tv");
    HString* p_key = builtin_intern_string(heap, "\xFFcap_promise_tv");
    if (r_key != null) w.put_prop(r_key, cap_resolve, hobject::PROP_FLAGS_WEC);
    if (j_key != null) w.put_prop(j_key, cap_reject, hobject::PROP_FLAGS_WEC);
    if (p_key != null) w.put_prop(p_key, cap_promise, hobject::PROP_FLAGS_WEC);
    return w;
}

/// Trigger all pending reactions for a settled promise.  Reactions are
/// detached from the promise's linked list before invocation, so new
/// reactions added during a handler call don't re-trigger this promise.
fn void promise_trigger_reactions(HObject* promise, Heap* heap, void* vm) {
    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state == PROMISE_PENDING) return;

    // Snapshot and clear the reaction list before invoking.
    HObject* reaction = (*promise.extra_ptr()).promise.reactions_head;
    (*promise.extra_ptr()).promise.reactions_head = null;
    (*promise.extra_ptr()).promise.reactions_tail = null;

    TVal result = promise_get_result(promise);

    while (reaction != null) {
        HObject* next = reaction_get_next(reaction, heap);
        // Unlink before invoking so reactions added during invocation are
        // attached to whatever new promise the handler returns to.
        reaction_set_next(reaction, null, heap);

        // Get handler: onFulfilled for fulfilled, onRejected for rejected
        char[] handler_prop = (state == PROMISE_FULFILLED) ? "onFulfilled" : "onRejected";
        HString* handler_key = builtin_intern_string(heap, handler_prop);
        TVal? handler_opt = reaction.get_prop(handler_key);
        TVal handler;
        if (try h = handler_opt) {
            handler = h;
        } else {
            handler.set_undefined();
        }

        // Get the downstream promise to resolve/reject
        HString* downstream_key = builtin_intern_string(heap, "downstream");
        TVal downstream_val;
        downstream_val.set_undefined();
        HObject* downstream = null;
        if (try dv = reaction.get_prop(downstream_key)) {
            if (dv.is_object() && dv.get_heapptr() != null) {
                HObject* d = (HObject*)dv.get_heapptr();
                if (d.flags.obj_class == hobject::ObjClass.PROMISE) {
                    downstream = d;
                    downstream_val = dv;
                }
            }
        }

        // Check for capability resolve/reject stored on the reaction
        // (set when then() used a custom SpeciesConstructor via NewPromiseCapability).
        HString* cr_key = builtin_intern_string(heap, "\xFFcap_resolve_tv");
        HString* cj_key = builtin_intern_string(heap, "\xFFcap_reject_tv");
        TVal cap_resolve; cap_resolve.set_undefined();
        TVal cap_reject; cap_reject.set_undefined();
        bool has_cap = false;
        if (cr_key != null) {
            if (try crv = reaction.get_prop(cr_key)) {
                cap_resolve = crv;
                has_cap = true;
            }
        }
        if (cj_key != null) {
            if (try cjv = reaction.get_prop(cj_key)) {
                cap_reject = cjv;
            }
        }

        bool callable = handler.is_lightfunc() ||
            (handler.is_object() && handler.get_heapptr() != null &&
             ((HObject*)handler.get_heapptr()).is_callable());
        bool has_handler = !(handler.is_undefined() || !callable);

        // Per PromiseReactionJob (ES2015+ §27.2.2.1): a reaction is ALWAYS
        // run as a queued job, never inline — even with no handler, where
        // the spec substitutes the Identity (fulfilled) or Thrower
        // (rejected) abstract closure for `handler`. Using those same
        // lightfunc sentinels here lets the no-handler case share the
        // has-handler path's job-enqueue plumbing below instead of settling
        // the downstream synchronously.
        if (!has_handler) {
            handler = (state == PROMISE_FULFILLED)
                ? types::make_lightfunc((void*)(usz)Builtin.PROMISE_IDENTITY.ordinal)
                : types::make_lightfunc((void*)(usz)Builtin.PROMISE_THROWER.ordinal);
        }

        // Build the downstream TVal for the microtask queue: for custom
        // capabilities, wrap the cap resolve/reject in a wrapper object so
        // promise_microtask_after can call them.
        TVal microtask_downstream;
        if (has_cap) {
            // Build the capability wrapper (cap_promise may be undefined if default)
            HString* cp_key = builtin_intern_string(heap, "\xFFcap_promise_tv");
            TVal cap_promise; cap_promise.set_undefined();
            if (cp_key != null) {
                if (try cpv = reaction.get_prop(cp_key)) cap_promise = cpv;
            }
            HObject*? wrapper_opt = promise_make_cap_wrapper(heap, cap_resolve, cap_reject, cap_promise);
            if (try wrapper = wrapper_opt) {
                microtask_downstream.set_object(wrapper);
            } else {
                microtask_downstream = downstream_val;
            }
        } else {
            microtask_downstream = downstream_val;
        }
        heap.enqueue_microtask(handler, result, microtask_downstream);

        reaction = next;
    }
}

/// PromiseReactionJob's Identity closure — the substitute handler for a
/// fulfilled reaction with no onFulfilled: returns the argument unchanged,
/// so the downstream is fulfilled with the same value (ES2015+ §27.2.2.1).
fn void builtin_promise_identity(BuiltinContext* ctx) {
    TVal arg; arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    *ctx.result = arg;
}

/// PromiseReactionJob's Thrower closure — the substitute handler for a
/// rejected reaction with no onRejected: re-throws the argument, so
/// promise_microtask_after sees heap.has_error and rejects the downstream
/// with the same reason (ES2015+ §27.2.2.1).
fn void builtin_promise_thrower(BuiltinContext* ctx) {
    TVal arg; arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    ctx.should_throw = true;
    ctx.throw_value = arg;
}

/// Call a handler function with one argument.
fn TVal call_handler(TVal handler, TVal* arg, Heap* heap, void* vm) {
    if (heap.call_handler_fn != null && vm != null) {
        return heap.call_handler_fn(vm, handler, arg);
    }
    TVal result;
    result.set_undefined();
    return result;
}

/// Microtask completion callback — resolves the downstream promise with the
/// Make `downstream` adopt the state of native Promise `source` (Promise
/// Resolution Procedure for a native promise). If `source` is already settled,
/// settle `downstream` with the same state/result now. If still pending, attach
/// a handler-less pass-through reaction so `downstream` settles when `source`
/// does. Both promises must be ObjClass.PROMISE.
fn void promise_adopt_native(Heap* heap, void* vm, HObject* source, HObject* downstream) {
    if (source == null || downstream == null) return;
    if (promise_get_state(downstream, PROMISE_PENDING) != PROMISE_PENDING) return;

    uint sstate = promise_get_state(source, PROMISE_PENDING);
    if (sstate != PROMISE_PENDING) {
        TVal sresult = promise_get_result(source);
        promise_settle(downstream, sstate, &sresult, heap);
        promise_trigger_reactions(downstream, heap, vm);
        return;
    }

    // Pending: attach a handler-less reaction whose `downstream` is our target.
    // When `source` settles, promise_trigger_reactions takes the no-handler
    // pass-through path and settles `downstream` with the same state/value.
    HObject*? rxn_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = rxn_raw) return;
    HObject* rxn = rxn_raw;
    rxn.prototype = heap.object_proto;
    TVal undef; undef.set_undefined();
    HString* onf_key = builtin_intern_string(heap, "onFulfilled");
    HString* onr_key = builtin_intern_string(heap, "onRejected");
    HString* ds_key  = builtin_intern_string(heap, "downstream");
    if (onf_key != null) rxn.put_prop(onf_key, undef, hobject::PROP_FLAGS_WEC);
    if (onr_key != null) rxn.put_prop(onr_key, undef, hobject::PROP_FLAGS_WEC);
    if (ds_key != null) {
        TVal ds_tv; ds_tv.set_object(downstream);
        rxn.put_prop(ds_key, ds_tv, hobject::PROP_FLAGS_WEC);
    }
    promise_add_reaction(source, rxn, heap);
}

/// handler's return value.  Registered as heap.microtask_after_fn during init.
///
/// `downstream` is either:
///  - A PROMISE object (default path): directly settled.
///  - A capability wrapper OBJECT (custom-constructor path): has
///    \xFFcap_resolve_tv / \xFFcap_reject_tv — call them instead.
fn void promise_microtask_after(void* heap_raw, void* vm, TVal result, TVal downstream) {
    Heap* heap = (Heap*)heap_raw;
    if (!downstream.is_object() || downstream.get_heapptr() == null) return;
    HObject* ds = (HObject*)downstream.get_heapptr();

    // Check if this is a capability wrapper (custom constructor path).
    if (ds.flags.obj_class == hobject::ObjClass.OBJECT) {
        HString* cr_key = builtin_intern_string(heap, "\xFFcap_resolve_tv");
        HString* cj_key = builtin_intern_string(heap, "\xFFcap_reject_tv");
        if (cr_key != null && cj_key != null) {
            TVal? maybe_resolve = ds.get_prop(cr_key);
            if (try cap_resolve = maybe_resolve) {
                // This is a capability wrapper.
                TVal cap_reject; cap_reject.set_undefined();
                if (try cjv = ds.get_prop(cj_key)) cap_reject = cjv;

                if (heap.has_error) {
                    TVal err = heap.error_value;
                    promise_clear_error_channels(heap, vm);
                    promise_call_cap_fn(heap, vm, cap_reject, err);
                    return;
                }
                // If the result is a thenable, we must call cap_resolve(result)
                // and let the Promise Resolution Procedure do its work.
                // Per spec §27.2.2.1 step 8: if result is a thenable,
                // cap_resolve(result) chains to it.
                promise_call_cap_fn(heap, vm, cap_resolve, result);
                return;
            }
        }
    }

    if (ds.flags.obj_class != hobject::ObjClass.PROMISE) return;

    // Check if downstream is already settled (shouldn't be, but guard)
    uint state = promise_get_state(ds, PROMISE_PENDING);
    if (state != PROMISE_PENDING) return;

    // If the handler threw, reject the downstream with the error
    if (heap.has_error) {
        TVal err = heap.error_value;
        promise_clear_error_channels(heap, vm);
        promise_settle(ds, PROMISE_REJECTED, &err, heap);
        promise_trigger_reactions(ds, heap, vm);
        return;
    }

    // Per Promise Resolution Procedure (ES6 §25.4.1.3.2 steps 6-13, invoked
    // via FulfillPromise-equivalent handling of a handler's return value):
    // self-resolution check, native-Promise/thenable adoption, and plain
    // fulfillment are all handled uniformly by promise_resolve_with_value.
    promise_resolve_with_value(ds, result, heap, vm);
}

/// Resolve or reject a capability's downstream promise.
fn void call_capability(TVal resolve, TVal reject, TVal* val, Heap* heap, bool is_resolve, void* vm) {
    TVal callee = is_resolve ? resolve : reject;
    if (callee.is_undefined()) return;

    if (callee.is_object() && callee.get_heapptr() != null) {
        HObject* obj = (HObject*)callee.get_heapptr();
        // If it's a PROMISE directly, resolve/reject it
        if (obj.flags.obj_class == hobject::ObjClass.PROMISE) {
            promise_settle(obj, is_resolve ? PROMISE_FULFILLED : PROMISE_REJECTED, val, heap);
            promise_trigger_reactions(obj, heap, vm);
            return;
        }
        // If it's a capability object, look up the "promise" property
        HString* promise_key = builtin_intern_string(heap, "promise");
        if (try pv = obj.get_prop(promise_key)) {
            if (pv.is_object() && pv.get_heapptr() != null) {
                HObject* prom = (HObject*)pv.get_heapptr();
                if (prom.flags.obj_class == hobject::ObjClass.PROMISE) {
                    promise_settle(prom, is_resolve ? PROMISE_FULFILLED : PROMISE_REJECTED, val, heap);
                    promise_trigger_reactions(prom, heap, vm);
                }
            }
        }
    }
}

/// Resolve `promise` with `value` per the Promise Resolve Function's
/// [[Resolve]] procedure — ES6 §25.4.1.3.2 steps 7-13:
///   7. If SameValue(resolution, promise) → reject with a self-resolution
///      TypeError.
///   8. If Type(resolution) is not Object → fulfill with resolution.
///   9-12. Look up resolution.then; if that throw, reject with the error.
///   10. If not callable → fulfill with resolution.
///   12. Otherwise enqueue a resolve-thenable job that calls
///       then.call(resolution, resolve, reject).
/// Per spec, even a native Promise `resolution` goes through the generic
/// `.then` lookup (its `.then` may have been overridden by user code) rather
/// than being fast-path adopted.
fn void promise_resolve_with_value(HObject* promise, TVal value, Heap* heap, void* vm) {
    if (promise == null) return;
    // Guard: this reads/writes the HObjectExtra.promise union member, which is
    // only valid for ObjClass.PROMISE objects. Combinators call this with the
    // "outer" object from NewPromiseCapability(C), which for a custom C is
    // whatever C's constructor returned (this) — an ordinary OBJECT, not a
    // native Promise. In that case settlement happens exclusively via the
    // capability's [[Resolve]]/[[Reject]] functions (capability_invoke), and
    // this call must be a no-op rather than aliasing into unrelated fields.
    if (promise.flags.obj_class != hobject::ObjClass.PROMISE) return;
    if (promise_get_state(promise, PROMISE_PENDING) != PROMISE_PENDING) return;

    // Step 7: self-resolution error.
    if (value.is_object() && value.get_heapptr() == (void*)promise) {
        species_throw_typeerror(heap, "Chaining cycle detected for promise");
        TVal err = heap.error_value;
        heap.has_error = false;
        promise_settle(promise, PROMISE_REJECTED, &err, heap);
        promise_trigger_reactions(promise, heap, vm);
        return;
    }

    // Step 8: non-object resolution — fulfill directly.
    if (!value.is_object() || value.get_heapptr() == null) {
        promise_settle(promise, PROMISE_FULFILLED, &value, heap);
        promise_trigger_reactions(promise, heap, vm);
        return;
    }

    // Steps 9-12: resolve.then lookup, callable check, and (if thenable)
    // wrapper-promise creation + then(resolve, reject) invocation are all
    // handled by promise_coerce_thenable. It signals a poisoned `.then`
    // getter or a throwing then() call via heap.has_error; distinguish that
    // from "not a thenable" (returns null with no error).
    HObject*? wrapper_raw = promise_coerce_thenable(heap, value, vm);
    if (heap.has_error) {
        TVal err = heap.error_value;
        heap.has_error = false;
        promise_settle(promise, PROMISE_REJECTED, &err, heap);
        promise_trigger_reactions(promise, heap, vm);
        return;
    }
    if (catch err_c = wrapper_raw) {
        // Unexpected fault treated as non-thenable fulfillment.
        promise_settle(promise, PROMISE_FULFILLED, &value, heap);
        promise_trigger_reactions(promise, heap, vm);
        return;
    }
    if (wrapper_raw == null) {
        // Step 10: not callable (or not an object) — fulfill with resolution.
        promise_settle(promise, PROMISE_FULFILLED, &value, heap);
        promise_trigger_reactions(promise, heap, vm);
        return;
    }
    // Step 12: the wrapper adopts the thenable's eventual settlement; chain
    // that into `promise`.
    promise_adopt_native(heap, vm, wrapper_raw, promise);
}

fn void builtin_promise_resolve_callback(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    // Look up target promise from the function's hidden \xFFpromise prop.
    HObject* promise = null;
    HObject* cell = null;
    if (ctx.callee_obj != null) {
        HString* promise_key = builtin_intern_string(heap, "\xFFpromise");
        if (try pv = ctx.callee_obj.get_prop(promise_key)) {
            if (pv.is_object() && pv.get_heapptr() != null) {
                HObject* obj = (HObject*)pv.get_heapptr();
                if (obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                    promise = obj;
                }
            }
        }
        HString* cell_key = builtin_intern_string(heap, "\xFFcap_cell");
        if (try cv = ctx.callee_obj.get_prop(cell_key)) {
            if (cv.is_object() && cv.get_heapptr() != null) {
                cell = (HObject*)cv.get_heapptr();
            }
        }
    }
    if (promise == null) { ctx.result.set_undefined(); return; }

    // [[AlreadyCalled]] guard: executor (or combinator) calling resolve then
    // reject must leave the promise settled by the first call only.
    if (promise_already_called(cell, heap)) { ctx.result.set_undefined(); return; }
    promise_mark_already_called(cell, heap);

    TVal value;
    value.set_undefined();
    if (ctx.argc >= 1) value = ctx.regs[ctx.base_reg];

    promise_resolve_with_value(promise, value, heap, ctx.vm);
    // Per ES6 §25.4.1.3.2: Promise resolve functions return undefined.
    ctx.result.set_undefined();
}

fn void builtin_promise_reject_callback(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    HObject* promise = null;
    HObject* cell = null;
    if (ctx.callee_obj != null) {
        HString* promise_key = builtin_intern_string(heap, "\xFFpromise");
        if (try pv = ctx.callee_obj.get_prop(promise_key)) {
            if (pv.is_object() && pv.get_heapptr() != null) {
                HObject* obj = (HObject*)pv.get_heapptr();
                if (obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                    promise = obj;
                }
            }
        }
        HString* cell_key = builtin_intern_string(heap, "\xFFcap_cell");
        if (try cv = ctx.callee_obj.get_prop(cell_key)) {
            if (cv.is_object() && cv.get_heapptr() != null) {
                cell = (HObject*)cv.get_heapptr();
            }
        }
    }
    if (promise == null) { ctx.result.set_undefined(); return; }

    if (promise_already_called(cell, heap)) { ctx.result.set_undefined(); return; }
    promise_mark_already_called(cell, heap);

    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state != PROMISE_PENDING) { ctx.result.set_undefined(); return; }

    TVal reason;
    reason.set_undefined();
    if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];

    promise_settle(promise, PROMISE_REJECTED, &reason, heap);
    promise_trigger_reactions(promise, heap, ctx.vm);
    // Per ES6 §25.4.1.3.1: Promise reject functions return undefined.
    ctx.result.set_undefined();
}

// Shared [[AlreadyCalled]] flag is held in a per-capability "cell" object
// referenced from both resolve and reject via \xFFalreadyResolved.

struct PromiseCapability {
    HObject* resolve_func;
    HObject* reject_func;
    HObject* promise;
}

/// Allocate a tiny "cell" object used to share [[AlreadyCalled]] between
/// resolve and reject.  The cell carries one boolean property.
fn HObject* promise_new_already_cell(Heap* heap) {
    HObject*? cell_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = cell_raw) return null;
    HObject* cell = cell_raw;
    cell.prototype = heap.object_proto;
    HString* k = builtin_intern_string(heap, "\xFFalreadyResolved");
    TVal v;
    v.set_boolean(false);
    if (k != null) cell.put_prop(k, v, hobject::PROP_FLAGS_WEC);
    return cell;
}

/// Read the [[AlreadyCalled]] flag.
fn bool promise_already_called(HObject* cell, Heap* heap) {
    if (cell == null) return false;
    HString* k = builtin_intern_string(heap, "\xFFalreadyResolved");
    if (k == null) return false;
    if (try v = cell.get_prop(k)) {
        if (v.is_boolean()) return v.get_boolean();
    }
    return false;
}

/// Mark the capability as having been used — once any of resolve/reject
/// fires, subsequent calls must be ignored per ES6 §25.4.1.6.
fn void promise_mark_already_called(HObject* cell, Heap* heap) {
    if (cell == null) return;
    HString* k = builtin_intern_string(heap, "\xFFalreadyResolved");
    if (k == null) return;
    TVal v;
    v.set_boolean(true);
    cell.put_prop(k, v, hobject::PROP_FLAGS_WEC);
}

/// Build the resolve/reject callback pair for a freshly created Promise.
/// Per ES2015 §25.4.1.5 / §25.6.1.x: resolve and reject are JS functions
/// with length=1, name="", and an internal reference back to `promise` via
/// the hidden \xFFpromise property.  They share a single [[AlreadyCalled]]
/// flag so the executor calling resolve(x); reject(y) is a no-op per spec.
/// Returns null fields on allocation failure.
fn PromiseCapability promise_new_capability(Heap* heap, HObject* promise) {
    HObject* cell = promise_new_already_cell(heap);
    if (cell == null) {
        return { .resolve_func = null, .reject_func = null, .promise = null };
    }

    HObject*? resolve_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err_r = resolve_raw) {
        return { .resolve_func = null, .reject_func = null, .promise = null };
    }
    HObject* resolve_func = resolve_raw;
    HObject*? reject_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err_rj = reject_raw) {
        return { .resolve_func = null, .reject_func = null, .promise = null };
    }
    HObject* reject_func = reject_raw;
    resolve_func.flags.callable = true;
    resolve_func.flags.constructable = false;
    resolve_func.prototype = heap.function_proto;
    reject_func.flags.callable = true;
    reject_func.flags.constructable = false;
    reject_func.prototype = heap.function_proto;

    // Index must be assigned last so the function isn't callable-but-unbound
    // by anything that walks the partial object — alloc_object returns a
    // zero-initialised HObject so this field is -1 until set.
    (*resolve_func.extra_ptr()).func.builtin_fn_index = (int)Builtin.PROMISE_RESOLVE_CALLBACK.ordinal;
    (*reject_func.extra_ptr()).func.builtin_fn_index = (int)Builtin.PROMISE_REJECT_CALLBACK.ordinal;

    HString* len_key = builtin_intern_string(heap, "length");
    if (len_key != null) {
        TVal len_tv; len_tv.set_fastint(1);
        resolve_func.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
        reject_func.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* name_key = builtin_intern_string(heap, "name");
    if (name_key != null) {
        TVal name_tv; name_tv.set_string(builtin_intern_string(heap, ""));
        resolve_func.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
        reject_func.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* promise_key = builtin_intern_string(heap, "\xFFpromise");
    TVal promise_ref;
    promise_ref.set_object(promise);
    if (promise_key != null) {
        resolve_func.put_prop(promise_key, promise_ref, hobject::PROP_FLAGS_WEC);
        reject_func.put_prop(promise_key, promise_ref, hobject::PROP_FLAGS_WEC);
    }
    HString* cell_key = builtin_intern_string(heap, "\xFFcap_cell");
    if (cell_key != null) {
        TVal cell_tv; cell_tv.set_object(cell);
        resolve_func.put_prop(cell_key, cell_tv, hobject::PROP_FLAGS_WEC);
        reject_func.put_prop(cell_key, cell_tv, hobject::PROP_FLAGS_WEC);
    }

    return { .resolve_func = resolve_func, .reject_func = reject_func, .promise = promise };
}

/// Create a new pending Promise.
fn HObject*? promise_create(Heap* heap) {
    HObject*? prom_raw = heap.alloc_object(hobject::ObjClass.PROMISE);
    if (catch err = prom_raw) return null;
    HObject* prom = prom_raw;
    prom.prototype = heap.promise_proto;
    promise_init(prom);
    return prom;
}

/// Allocate a synthetic-executor function object.  The executor carries the
/// given `hole` object via its \xFFhole hidden prop.  When called as
/// `executor(resolve, reject)`, builtin_promise_synthetic_executor copies
/// resolve/reject into the hole under \xFFcap_resolve_tv / \xFFcap_reject_tv.
fn HObject*? promise_create_synthetic_executor(Heap* heap, HObject* hole) {
    HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = fn_raw) return null;
    HObject* fn_obj = fn_raw;
    (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.PROMISE_SYNTHETIC_EXECUTOR.ordinal;
    fn_obj.flags.callable = true;
    fn_obj.flags.constructable = false;
    fn_obj.prototype = heap.function_proto;

    HString* len_key = builtin_intern_string(heap, "length");
    if (len_key != null) {
        TVal len_tv; len_tv.set_fastint(2);
        fn_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* name_key = builtin_intern_string(heap, "name");
    if (name_key != null) {
        TVal name_tv; name_tv.set_string(builtin_intern_string(heap, ""));
        fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* hole_key = builtin_intern_string(heap, "\xFFhole");
    if (hole_key != null) {
        TVal hole_tv; hole_tv.set_object(hole);
        fn_obj.put_prop(hole_key, hole_tv, hobject::PROP_FLAGS_WEC);
    }
    return fn_obj;
}

/// NewPromiseCapability(C) — ES6 §25.4.1.6.  Returns {resolve_tv, reject_tv}
/// where resolve_tv is the resolve function passed to `new C(executor)`.  When
/// C is the default Promise or construct_fn is unavailable we fall back to
/// builtin resolve/reject.  Hole is mutated to receive cap_resolve_tv and
/// cap_reject_tv after the construct call.  Returns false if any step fails.
fn bool promise_new_capability_full(Heap* heap, void* vm, TVal c_tv, HObject* hole) {
    TVal undef; undef.set_undefined();
    // Default Promise constructor: build internal capability.
    if (c_tv.is_object() && c_tv.get_heapptr() != null &&
        (HObject*)c_tv.get_heapptr() == heap.promise_ctor) {
        HObject*? prom_raw = promise_create(heap);
        if (catch err = prom_raw) return false;
        HObject* outer = prom_raw;
        PromiseCapability cap = promise_new_capability(heap, outer);
        if (cap.resolve_func == null) return false;
        TVal cap_r; cap_r.set_object(cap.resolve_func);
        TVal cap_j; cap_j.set_object(cap.reject_func);
        HString* r_key = builtin_intern_string(heap, "\xFFcap_resolve_tv");
        HString* j_key = builtin_intern_string(heap, "\xFFcap_reject_tv");
        HString* p_key = builtin_intern_string(heap, "\xFFcap_promise_tv");
        if (r_key != null && j_key != null && hole != null) {
            hole.put_prop(r_key, cap_r, hobject::PROP_FLAGS_WEC);
            hole.put_prop(j_key, cap_j, hobject::PROP_FLAGS_WEC);
        }
        if (p_key != null && hole != null) {
            TVal outer_tv; outer_tv.set_object(outer);
            hole.put_prop(p_key, outer_tv, hobject::PROP_FLAGS_WEC);
        }
        return true;
    }
    // Custom constructor: call Construct(C, [executor]) per ES6 §25.4.1.6.
    if (heap.construct_fn == null || vm == null) return false;
    HObject*? exec_raw = promise_create_synthetic_executor(heap, hole);
    if (catch err = exec_raw) return false;
    HObject* exec_obj = exec_raw;
    TVal exec_tv; exec_tv.set_object(exec_obj);
    TVal result_tv = heap.construct_fn(vm, c_tv, &exec_tv, 1, c_tv);
    if (heap.has_error) {
        // The user's constructor threw — per ES6 §25.4.1.5 step 7
        // "ReturnIfAbrupt(promise)", the error must propagate, NOT be
        // converted to a generic TypeError. Stash the original error on
        // the hole so callers can re-throw it.
        HString* err_key = builtin_intern_string(heap, "\xFFcap_aborterror");
        if (err_key != null && hole != null) {
            hole.put_prop(err_key, heap.error_value, hobject::PROP_FLAGS_WEC);
        }
        heap.has_error = false;
        return false;
    }
    // If construct_fn returned without an object, the constructor threw or
    // was not a valid constructor — fall back to the builtin pair.
    if (!result_tv.is_object() || result_tv.get_heapptr() == null) return false;
    // Per ES6 §25.4.1.5 step 7/8: if [[Resolve]] / [[Reject]] are still
    // undefined (executor never called, or threw), the capability is invalid
    // and the outer site must throw a TypeError. Detect this here so callers
    // like Promise.resolve / Promise.reject see the failure.
    HString* r_key = builtin_intern_string(heap, "\xFFcap_resolve_tv");
    HString* j_key = builtin_intern_string(heap, "\xFFcap_reject_tv");
    HString* p_key = builtin_intern_string(heap, "\xFFcap_promise_tv");
    bool resolve_set = false;
    bool reject_set = false;
    if (r_key != null && hole != null) {
        if (try rv = hole.get_prop(r_key)) {
            resolve_set = rv.is_lightfunc() || (rv.is_object() && rv.get_heapptr() != null
                && ((HObject*)rv.get_heapptr()).is_callable());
        }
    }
    if (j_key != null && hole != null) {
        if (try jv = hole.get_prop(j_key)) {
            reject_set = jv.is_lightfunc() || (jv.is_object() && jv.get_heapptr() != null
                && ((HObject*)jv.get_heapptr()).is_callable());
        }
    }
    if (!resolve_set || !reject_set) {
        // Capability is incomplete — wipe back to undefined and report failure.
        TVal undef2; undef2.set_undefined();
        if (r_key != null && hole != null) {
            hole.put_prop(r_key, undef2, hobject::PROP_FLAGS_WEC);
        }
        if (j_key != null && hole != null) {
            hole.put_prop(j_key, undef2, hobject::PROP_FLAGS_WEC);
        }
        return false;
    }
    // Store the constructed promise on the hole so combinators can return it.
    if (p_key != null && hole != null) {
        hole.put_prop(p_key, result_tv, hobject::PROP_FLAGS_WEC);
    }
    return true;
}

/// Read back the promise TVal stored by NewPromiseCapability (the object
/// returned by Construct(C, [executor]) or by promise_create for default C).
fn TVal promise_hole_get_promise(Heap* heap, HObject* hole) {
    TVal p; p.set_undefined();
    if (hole == null) return p;
    HString* k = builtin_intern_string(heap, "\xFFcap_promise_tv");
    if (k == null) return p;
    if (try v = hole.get_prop(k)) return v;
    return p;
}

/// Read back the resolve TVal stored by NewPromiseCapability.
fn TVal promise_hole_get_resolve(Heap* heap, HObject* hole) {
    TVal r; r.set_undefined();
    if (hole == null) return r;
    HString* k = builtin_intern_string(heap, "\xFFcap_resolve_tv");
    if (k == null) return r;
    if (try v = hole.get_prop(k)) return v;
    return r;
}

/// Read back the reject TVal stored by NewPromiseCapability.
fn TVal promise_hole_get_reject(Heap* heap, HObject* hole) {
    TVal j; j.set_undefined();
    if (hole == null) return j;
    HString* k = builtin_intern_string(heap, "\xFFcap_reject_tv");
    if (k == null) return j;
    if (try v = hole.get_prop(k)) return v;
    return j;
}

/// Throw a TypeError into a builtin's ctx for an incomplete PromiseCapability.
/// Used by combinators (Promise.all, Promise.race, Promise.any, …
/// Promise.allSettled) when NewPromiseCapability fails — per ES6 §25.4.4.x
/// the algorithm returns IfAbrupt (TypeError) when the capability is invalid.
fn void promise_capability_incomplete_throw(BuiltinContext* ctx) {
    builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Promise capability not initialized by constructor");
}

/// Re-throw an abrupt error stashed on a PromiseCapability hole from
/// `promise_new_capability_full`'s Construct() path. Used by combinator-style
/// call sites (Promise.resolve.call, etc.) that need to surface the user's
/// actual exception instead of a generic TypeError.
fn bool promise_rethrow_stored_abort(BuiltinContext* ctx, HObject* hole) {
    if (hole == null) return false;
    HString* err_key = builtin_intern_string(ctx.heap, "\xFFcap_aborterror");
    if (err_key == null) return false;
    if (catch err_get = hole.get_prop(err_key)) return false;
    TVal? err_tv = hole.get_prop(err_key);
    TVal abort_err;
    if (try et = err_tv) abort_err = et;
    if (!abort_err.is_object() || abort_err.get_heapptr() == null) return false;
    ctx.should_throw = true;
    ctx.throw_value = abort_err;
    return true;
}

/// Throw the right error for an incomplete PromiseCapability — prefer the
/// user's actual exception (stashed on the hole by `promise_new_capability_full`)
/// over the generic TypeError. Returns true once the throw flag is set.
fn bool promise_throw_capability_failure(BuiltinContext* ctx, HObject* hole) {
    if (promise_rethrow_stored_abort(ctx, hole)) return true;
    promise_capability_incomplete_throw(ctx);
    return true;
}

/// Create a resolve/reject capability object (internal).
fn HObject*? promise_create_capability(Heap* heap, HObject* promise) {
    HObject*? cap_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = cap_raw) return null;
    HObject* cap = cap_raw;

    HString* promise_key = builtin_intern_string(heap, "promise");
    TVal promise_val;
    promise_val.set_object(promise);
    cap.put_prop(promise_key, promise_val, hobject::PROP_FLAGS_WEC);

    return cap;
}

/// Append a reaction HObject to the promise's reaction linked list.
fn void promise_add_reaction(HObject* promise, HObject* reaction, Heap* heap) {
    if (promise == null || reaction == null) return;
    reaction_set_next(reaction, null, heap);
    if ((*promise.extra_ptr()).promise.reactions_tail == null) {
        (*promise.extra_ptr()).promise.reactions_head = reaction;
    } else {
        reaction_set_next((HObject*)(*promise.extra_ptr()).promise.reactions_tail, reaction, heap);
    }
    (*promise.extra_ptr()).promise.reactions_tail = reaction;
}

/// Get the resolved value of a Promise-like object (Promise, thenable, etc).
/// Reads from the HObjectPromise extra slot.  Only valid for ObjClass.PROMISE.
fn TVal promise_try_get_value(HObject* obj) {
    if (obj == null || obj.flags.obj_class != hobject::ObjClass.PROMISE) {
        TVal undef; undef.set_undefined(); return undef;
    }
    return promise_get_result(obj);
}

// ============================================================================
// Promise constructor (ES6 §25.4.3.1)
// ============================================================================

fn void builtin_promise(BuiltinContext* ctx) {
    // ES6 §25.4.3.1 step 1: If NewTarget is undefined, throw a TypeError exception.
    if (!ctx.is_constructor) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err_e = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Promise cannot be called without 'new'");
        if (msg_key != null && msg_str != null) {
            TVal msg_tv; msg_tv.set_string(msg_str);
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;
    // ES2015 §25.4.3.1 step 3: OrdinaryCreateFromConstructor(NewTarget, "%PromisePrototype%")
    promise.prototype = builtin_proto_from_new_target(ctx, ctx.heap.promise_proto);

    // ES2015 §25.6.3.1 step 2: throw TypeError if IsCallable(executor) is
    // false — including when no argument was passed at all (executor is
    // then undefined, which is not callable).
    TVal executor;
    if (ctx.argc < 1) {
        executor.set_undefined();
    } else {
        executor = ctx.regs[ctx.base_reg];
    }
    // An executor is callable iff it's an object with is_callable() or a lightfunc.
    bool exec_callable = executor.is_lightfunc();
    HObject* exec_func = null;
    if (executor.is_object() && executor.get_heapptr() != null) {
        exec_func = (HObject*)executor.get_heapptr();
        exec_callable = exec_func.is_callable();
    }
    if (!exec_callable) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err_e = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Promise resolver undefined is not a function");
        if (msg_key != null && msg_str != null) {
            TVal msg_tv; msg_tv.set_string(msg_str);
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }

    if (exec_func != null && (*exec_func.extra_ptr()).func.comp_func == null && (*exec_func.extra_ptr()).func.builtin_fn_index < 0) {
        ctx.result.set_object(promise);
        return;
    }

    // Build capability using the shared helper so the executor's resolve/reject
    // share one [[AlreadyCalled]] flag and the combinators can reuse the same
    // pair by calling promise_new_capability themselves.
    Heap* heap = ctx.heap;
    PromiseCapability cap = promise_new_capability(heap, promise);
    if (cap.resolve_func == null || cap.reject_func == null) {
        ctx.result.set_object(promise);
        return;
    }
    HObject* resolve_func = cap.resolve_func;
    HObject* reject_func = cap.reject_func;

    TVal resolve_tv;
    resolve_tv.set_object(resolve_func);
    TVal reject_tv;
    reject_tv.set_object(reject_func);

    // Call executor(resolve, reject) via the VM
    TVal[2] exec_args;
    exec_args[0] = resolve_tv;
    exec_args[1] = reject_tv;
    if (heap.call_fn != null && ctx.vm != null) {
        heap.call_fn(ctx.vm, executor, &exec_args[0], 2, ctx.this_val);
        if (ctx.heap.has_error) {
            // ES6 §25.4.3.1 step 10: abrupt completion → call reject
            TVal err_val = ctx.heap.error_value;
            ctx.heap.has_error = false;
            TVal undef_this; undef_this.set_undefined();
            heap.call_fn(ctx.vm, reject_tv, &err_val, 1, undef_this);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
                return;
            }
        }
    }

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise[Symbol.species] getter — ES6 §27.2.4.6
// ============================================================================

/// Promise[Symbol.species] getter: returns `this` (the constructor).
fn void builtin_promise_species_getter(BuiltinContext* ctx) {
    *ctx.result = ctx.regs[ctx.base_reg - 1];
}

// ============================================================================
// Promise.prototype.then(onFulfilled, onRejected) — ES6 §25.4.5.3
// ============================================================================

/// Set heap.has_error to a new TypeError with the given message.
/// Used by SpeciesConstructor to signal abrupt completions.
fn void species_throw_typeerror(Heap* heap, char[] msg) {
    HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = heap.type_err_proto;
        HString* msg_str = builtin_intern_string(heap, msg);
        if (msg_str != null) {
            TVal msg_tv; msg_tv.set_string(msg_str);
            HString* msg_key = builtin_intern_string(heap, "message");
            if (msg_key != null) err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        }
        heap.has_error = true;
        heap.error_value.set_object(err);
    }
}

/// SpeciesConstructor helper — ES6 §7.3.22
/// Returns the constructor to use when creating derived objects.
/// On TypeError (steps 5, 10), sets heap.has_error and returns null.
/// On normal fallback-to-default, returns fallback_ctor without error.
fn HObject*? species_constructor(Heap* heap, void* vm, TVal o, HObject* fallback_ctor, HObject* fallback_proto) {
    // 1. Assert: Type(O) is Object.
    // 2. Let C = O.[[Get]]("constructor") — full Get semantics: an accessor
    //    "constructor" property (e.g. via Object.defineProperty) must have
    //    its getter invoked, and a throwing getter must propagate as an
    //    abrupt completion here, not be silently misread as a data property.
    HString* ctor_key = builtin_intern_string(heap, "constructor");
    if (ctor_key == null) return fallback_ctor;
    HObject* obj = (HObject*)o.get_heapptr();
    if (obj == null) return fallback_ctor;
    TVal ctor_val = promise_get_prop_thru_accessor(heap, vm, obj, ctor_key);
    if (heap.has_error) return null;
    // 3. ReturnIfAbrupt(C).
    // 4. If C is undefined, return defaultConstructor.
    if (ctor_val.is_undefined()) {
        return fallback_ctor;
    }
    // 5. If Type(C) is not Object, throw TypeError.
    if (!ctor_val.is_object() || ctor_val.get_heapptr() == null) {
        species_throw_typeerror(heap, "constructor is not an object");
        return null;  // heap.has_error = true
    }
    // 6. Let S = Get(C, @@species).
    // Use full Get semantics so the accessor getter is invoked (e.g.
    // Function.prototype[Symbol.species] is a getter returning `this`).
    HString* species_sym = ensure_species_symbol(heap);
    if (species_sym == null) return fallback_ctor;
    HObject* ctor_obj = (HObject*)ctor_val.get_heapptr();
    TVal species_val;
    if (!promise_object_get(heap, vm, ctor_obj, species_sym, &species_val)) {
        // getter threw — heap.has_error may be set.
        return null;
    }
    // 7. ReturnIfAbrupt(S).
    // 8. If S is undefined or null, return defaultConstructor.
    if (species_val.is_undefined() || species_val.is_null()) {
        return fallback_ctor;
    }
    // 9. If IsConstructor(S) is true, return S.
    if (species_val.is_object() && species_val.get_heapptr() != null) {
        HObject* s_obj = (HObject*)species_val.get_heapptr();
        if (s_obj.flags.constructable) return s_obj;
    }
    // 10. Throw TypeError.
    species_throw_typeerror(heap, "SpeciesConstructor result is not a constructor");
    return null;  // heap.has_error = true
}

/// Synthetic executor used by NewPromiseCapability(C) when C is a custom
/// constructor.  The combinator passes a state HObject via the function's
/// \xFFhole hidden prop; we copy resolve/reject (the args) into that state
/// so the combinator can read them via cap_resolve/cap_reject later.  Per
/// ES6 §25.4.1.6 the executor may call resolve/reject at any time, even
/// after the function returns — we don't synchronously invoke anything here.
///
/// Implements ES6 §25.4.1.5.1 GetCapabilitiesExecutor Functions:
///   1. If promiseCapability.[[Resolve]] is not undefined → throw TypeError.
///   2. If promiseCapability.[[Reject]] is not undefined → throw TypeError.
///   3. If resolve/reject non-callable → throw TypeError.
///   4. Otherwise copy resolve/reject into the hole and return.
fn bool is_callable_tval(TVal v) {
    if (v.is_lightfunc()) return true;
    if (v.is_object() && v.get_heapptr() != null) {
        HObject* o = (HObject*)v.get_heapptr();
        return o.is_callable();
    }
    return false;
}

fn void promise_throw_typeerror(BuiltinContext* ctx, String msg) {
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (catch err_e = err_raw) return;
    HObject* err = err_raw;
    err.prototype = ctx.heap.type_err_proto;
    HString* msg_str = builtin_intern_string(ctx.heap, msg);
    if (msg_str != null) {
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_tv, hobject::PROP_FLAGS_WC);
    }
    ctx.should_throw = true;
    ctx.throw_value.set_object(err);
}

fn void builtin_promise_synthetic_executor(BuiltinContext* ctx) {
    if (ctx.callee_obj == null) return;
    HString* hole_key = builtin_intern_string(ctx.heap, "\xFFhole");
    if (hole_key == null) return;
    TVal? hole_opt = ctx.callee_obj.get_prop(hole_key);
    HObject* hole = null;
    if (try hv = hole_opt) {
        if (hv.is_object() && hv.get_heapptr() != null) hole = (HObject*)hv.get_heapptr();
    }
    if (hole == null) return;

    // ES6 §25.4.1.5.1 steps 1–2: AlreadyCalled guards (any prior resolve/reject
    // captured in the hole triggers a TypeError).
    HString* r_already_key = builtin_intern_string(ctx.heap, "\xFFcap_resolve_tv");
    HString* j_already_key = builtin_intern_string(ctx.heap, "\xFFcap_reject_tv");
    if (r_already_key != null) {
        if (try pv = hole.get_prop(r_already_key)) {
            if (!pv.is_undefined()) {
                promise_throw_typeerror(ctx, "executor already called with non-undefined values");
                return;
            }
        }
    }
    if (j_already_key != null) {
        if (try pv = hole.get_prop(j_already_key)) {
            if (!pv.is_undefined()) {
                promise_throw_typeerror(ctx, "executor already called with non-undefined values");
                return;
            }
        }
    }

    // ES6 §25.4.1.5.1 steps 5–6: resolve/reject may be non-callable.
    // Per the spec the executor itself never throws for non-callable resolve/
    // reject — it's NewPromiseCapability step 8/9 that throws TypeError after
    // Construct returns. So we set the slot to whatever the user passed and
    // let the post-Construct check (in promise_new_capability_full) throw if
    // it's non-callable.
    if (ctx.argc >= 1) {
        TVal resolve_tv = ctx.regs[ctx.base_reg];
        if (r_already_key != null) hole.put_prop(r_already_key, resolve_tv, hobject::PROP_FLAGS_WEC);
    }
    if (ctx.argc >= 2) {
        TVal reject_tv = ctx.regs[ctx.base_reg + 1];
        if (j_already_key != null) hole.put_prop(j_already_key, reject_tv, hobject::PROP_FLAGS_WEC);
    }
}

fn void builtin_promise_proto_then(BuiltinContext* ctx) {
    HObject* promise = check_promise(ctx);
    if (promise == null) return;

    TVal on_fulfilled;
    on_fulfilled.set_undefined();
    TVal on_rejected;
    on_rejected.set_undefined();
    if (ctx.argc >= 1) on_fulfilled = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) on_rejected  = ctx.regs[ctx.base_reg + 1];

    // Determine the constructor via SpeciesConstructor (ES6 §25.4.5.3 step 2)
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* default_ctor = ctx.heap.promise_ctor;
    HObject*? sc_opt = species_constructor(ctx.heap, ctx.vm, this_val, default_ctor, ctx.heap.promise_proto);
    HObject* ctor;
    // species_constructor sets heap.has_error on TypeError (steps 5/10).
    if (ctx.heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
        return;
    }
    if (catch err_sc = sc_opt) {
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            return;
        }
        ctor = default_ctor;
    } else if (sc_opt != null) {
        ctor = sc_opt;
    } else {
        ctor = default_ctor;
    }

    // Create a new promise for the chain via NewPromiseCapability(C) so that
    // custom constructors (SpeciesConstructor) are invoked per ES6 §27.2.5.4.
    HObject* new_promise = null;
    TVal cap_resolve_tv; cap_resolve_tv.set_undefined();
    TVal cap_reject_tv; cap_reject_tv.set_undefined();
    bool use_capability = false;

    if (ctor == default_ctor) {
        // Fast path: allocate a plain promise without calling the constructor.
        HObject*? new_prom_raw = promise_create(ctx.heap);
        if (catch err = new_prom_raw) {
            ctx.result.set_undefined();
            return;
        }
        new_promise = new_prom_raw;
    } else {
        // Custom SpeciesConstructor — call NewPromiseCapability(C).
        TVal ctor_tv; ctor_tv.set_object(ctor);
        HObject*? hole_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = hole_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* hole = hole_raw;
        hole.prototype = ctx.heap.object_proto;
        if (!promise_new_capability_full(ctx.heap, ctx.vm, ctor_tv, hole)) {
            promise_throw_capability_failure(ctx, hole);
            return;
        }
        // Extract the result promise and resolve/reject from the hole.
        TVal cap_p = promise_hole_get_promise(ctx.heap, hole);
        cap_resolve_tv = promise_hole_get_resolve(ctx.heap, hole);
        cap_reject_tv  = promise_hole_get_reject(ctx.heap, hole);
        use_capability = true;
        // new_promise for the return value — may not be a PROMISE obj_class.
        // We record it as null to skip downstream-settle; use cap fn instead.
        new_promise = null;
        // Store cap_p so we can set ctx.result at the end.
        // Use a local TVal rather than HObject* since it may not be PROMISE class.
        *ctx.result = cap_p;  // tentatively set; overwritten below if we return early
        // We still need to build the reaction; carry cap_p for the return value.
        // Fall through with use_capability = true.
    }

    // Build reaction object
    HObject*? reaction_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = reaction_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* reaction = reaction_raw;

    HString* onf_key = builtin_intern_string(ctx.heap, "onFulfilled");
    reaction.put_prop(onf_key, on_fulfilled, hobject::PROP_FLAGS_WEC);

    HString* onr_key = builtin_intern_string(ctx.heap, "onRejected");
    reaction.put_prop(onr_key, on_rejected, hobject::PROP_FLAGS_WEC);

    HString* downstream_key = builtin_intern_string(ctx.heap, "downstream");
    TVal downstream_val;
    if (use_capability || new_promise == null) {
        downstream_val.set_undefined();
    } else {
        downstream_val.set_object(new_promise);
    }
    reaction.put_prop(downstream_key, downstream_val, hobject::PROP_FLAGS_WEC);

    // For custom capabilities, store cap_resolve and cap_reject on the reaction.
    if (use_capability) {
        HString* cr_key = builtin_intern_string(ctx.heap, "\xFFcap_resolve_tv");
        HString* cj_key = builtin_intern_string(ctx.heap, "\xFFcap_reject_tv");
        HString* cp_key = builtin_intern_string(ctx.heap, "\xFFcap_promise_tv");
        if (cr_key != null) reaction.put_prop(cr_key, cap_resolve_tv, hobject::PROP_FLAGS_WEC);
        if (cj_key != null) reaction.put_prop(cj_key, cap_reject_tv, hobject::PROP_FLAGS_WEC);
        if (cp_key != null) {
            // Store the cap_promise ref (already set in *ctx.result above).
            TVal cp_tv = *ctx.result;
            reaction.put_prop(cp_key, cp_tv, hobject::PROP_FLAGS_WEC);
        }
    }

    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state == PROMISE_PENDING) {
        promise_add_reaction(promise, reaction, ctx.heap);
    } else {
        // Promise already settled — trigger reactions now.  Adding the
        // reaction first then triggering ensures the linked-list walk sees
        // it (trigger clears the list before iterating, but our snapshot
        // already includes the just-added reaction).
        promise_add_reaction(promise, reaction, ctx.heap);
        promise_trigger_reactions(promise, ctx.heap, ctx.vm);
    }

    // Return the result promise.  For custom constructors (use_capability),
    // ctx.result was already set to cap_p above.  For the default path,
    // set it now.
    if (!use_capability) {
        ctx.result.set_object(new_promise);
    }
    // (use_capability case: ctx.result already holds cap_p)
}

// ============================================================================
// Promise.prototype.catch(onRejected) — ES6 §25.4.5.1
// ============================================================================

fn void builtin_promise_proto_catch(BuiltinContext* ctx) {
    // ES2021 §27.2.5.1: Let promise be the this value.
    // Return ? Invoke(promise, "then", « undefined, onRejected »).
    // Invoke calls the "then" method on the this value itself — no IsPromise check.
    Heap* heap = ctx.heap;
    TVal promise_val = ctx.regs[ctx.base_reg - 1];
    TVal on_rejected;
    on_rejected.set_undefined();
    if (ctx.argc >= 1) on_rejected = ctx.regs[ctx.base_reg];

    // Invoke uses GetV(promise, "then") which ToObject-coerces primitives.
    // Reject only null/undefined per spec.
    if (promise_val.is_null() || promise_val.is_undefined()) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "Promise.prototype.catch called on null or undefined");
        return;
    }
    // ToObject(promise_val) — get the wrapper object to look up "then" on.
    // GetV calls with the original value (not the wrapper).
    HObject* promise_obj = null;
    if (promise_val.is_object() && promise_val.get_heapptr() != null) {
        promise_obj = (HObject*)promise_val.get_heapptr();
    } else {
        // Primitive — wrap it so we can walk the prototype chain to find "then".
        // Boolean → Boolean.prototype, Number → Number.prototype, etc.
        HObject* proto = null;
        if (promise_val.is_boolean()) { proto = heap.bool_proto; }
        else if (promise_val.is_number() || promise_val.is_fastint()) { proto = heap.number_proto; }
        else if (promise_val.is_string()) {
            HString* pstr = (HString*)promise_val.get_heapptr();
            if (pstr != null && pstr.is_symbol()) { proto = heap.symbol_proto; }
            else { proto = heap.string_proto; }
        }
        // Walk the prototype to find "then".
        // We can't call promise_object_get on a primitive directly — use its proto.
        promise_obj = proto;
        if (promise_obj == null) { ctx.result.set_undefined(); return; }
    }
    HString* then_key = builtin_intern_string(heap, "then");
    if (then_key == null) { ctx.result.set_undefined(); return; }

    // GetV(promise, "then") — look up on the (possibly wrapped) object.
    TVal then_fn;
    if (!promise_object_get(heap, ctx.vm, promise_obj, then_key, &then_fn)) {
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
        }
        return;
    }

    // Call(then, promise, [undefined, onRejected])
    if (heap.call_fn == null || ctx.vm == null) { ctx.result.set_undefined(); return; }
    bool then_callable = then_fn.is_lightfunc() ||
        (then_fn.is_object() && then_fn.get_heapptr() != null &&
         ((HObject*)then_fn.get_heapptr()).is_callable());
    if (!then_callable) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "then is not callable");
        return;
    }
    TVal undef_tv; undef_tv.set_undefined();
    TVal[2] call_args;
    call_args[0] = undef_tv;
    call_args[1] = on_rejected;
    TVal ret = heap.call_fn(ctx.vm, then_fn, &call_args[0], 2, promise_val);
    if (heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = heap.error_value;
        heap.has_error = false;
        return;
    }
    *ctx.result = ret;
}

// ============================================================================
// Promise.prototype.finally(onFinally) — ES2018 §25.4.5.3
// ============================================================================

/// Build a ThenFinally or CatchFinally wrapper function (ES2018 §27.2.5.3
/// steps 4.a/4.b). Stores onFinally and the SpeciesConstructor C as hidden
/// props so the wrapper handler can call onFinally() and, once its result
/// settles, pass the original fulfillment value / rejection reason through.
fn HObject*? promise_make_finally_wrapper(Heap* heap, uint builtin_index, TVal on_finally, HObject* ctor) {
    HObject*? wrap_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = wrap_raw) return null;
    HObject* wrap_fn = wrap_raw;
    wrap_fn.flags.callable = true;
    wrap_fn.flags.constructable = false;
    wrap_fn.prototype = heap.function_proto;
    (*wrap_fn.extra_ptr()).func.builtin_fn_index = (int)builtin_index;
    HString* len_key = builtin_intern_string(heap, "length");
    if (len_key != null) {
        TVal len_tv; len_tv.set_fastint(1);
        wrap_fn.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* of_key = builtin_intern_string(heap, "\xFFon_finally");
    if (of_key != null) wrap_fn.put_prop(of_key, on_finally, hobject::PROP_FLAGS_WEC);
    HString* ctor_key = builtin_intern_string(heap, "\xFFfinally_ctor");
    if (ctor_key != null && ctor != null) {
        TVal ctor_tv; ctor_tv.set_object(ctor);
        wrap_fn.put_prop(ctor_key, ctor_tv, hobject::PROP_FLAGS_WEC);
    }
    return wrap_fn;
}

/// Shared body for ThenFinally/CatchFinally (ES2018 §27.2.5.3 steps 4.a.i-4.a.vii):
/// call onFinally() with no args; if it throws, propagate that throw as the
/// wrapper's own completion. Otherwise Promise.resolve(C, result), and
/// .then() a passthrough handler that returns `passthrough_value` (for
/// ThenFinally) or re-throws it (for CatchFinally, is_reject=true).
fn void promise_finally_wrapper_body(BuiltinContext* ctx, bool is_reject) {
    Heap* heap = ctx.heap;
    ctx.result.set_undefined();
    if (ctx.callee_obj == null) return;

    TVal passthrough;
    passthrough.set_undefined();
    if (ctx.argc >= 1) passthrough = ctx.regs[ctx.base_reg];

    HString* of_key = builtin_intern_string(heap, "\xFFon_finally");
    TVal on_finally; on_finally.set_undefined();
    if (of_key != null) {
        if (try ov = ctx.callee_obj.get_prop(of_key)) on_finally = ov;
    }
    HString* ctor_key = builtin_intern_string(heap, "\xFFfinally_ctor");
    HObject* ctor = heap.promise_ctor;
    if (ctor_key != null) {
        if (try cv = ctx.callee_obj.get_prop(ctor_key)) {
            if (cv.is_object() && cv.get_heapptr() != null) ctor = (HObject*)cv.get_heapptr();
        }
    }

    if (heap.call_fn == null || ctx.vm == null) return;
    TVal undef; undef.set_undefined();
    TVal result = heap.call_fn(ctx.vm, on_finally, null, 0, undef);
    if (heap.has_error) {
        // onFinally itself threw — propagate as this wrapper's own throw.
        ctx.should_throw = true;
        ctx.throw_value = heap.error_value;
        heap.has_error = false;
        return;
    }

    // Promise.resolve(C, result) — call C.resolve(result) if available,
    // else fall back to the builtin resolve procedure.
    TVal resolved_promise;
    resolved_promise.set_undefined();
    HString* resolve_key = builtin_intern_string(heap, "resolve");
    TVal resolve_fn; resolve_fn.set_undefined();
    bool have_resolve_fn = false;
    if (resolve_key != null && ctor != null) {
        if (promise_object_get(heap, ctx.vm, ctor, resolve_key, &resolve_fn)) {
            have_resolve_fn = resolve_fn.is_lightfunc() ||
                (resolve_fn.is_object() && resolve_fn.get_heapptr() != null &&
                 ((HObject*)resolve_fn.get_heapptr()).is_callable());
        } else if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            return;
        }
    }
    if (have_resolve_fn) {
        TVal ctor_tv; ctor_tv.set_object(ctor);
        TVal[1] r_args; r_args[0] = result;
        resolved_promise = heap.call_fn(ctx.vm, resolve_fn, &r_args[0], 1, ctor_tv);
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            return;
        }
    } else {
        HObject*? prom_raw = promise_create(heap);
        if (catch err = prom_raw) return;
        HObject* prom = prom_raw;
        promise_settle(prom, PROMISE_FULFILLED, &result, heap);
        resolved_promise.set_object(prom);
    }

    // valueThunk / thrower passthrough handler: a tiny builtin closure
    // carrying `passthrough` so .then(valueThunk) returns it unchanged (or,
    // for CatchFinally, re-throws it).
    HObject*? thunk_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = thunk_raw) return;
    HObject* thunk = thunk_raw;
    thunk.flags.callable = true;
    thunk.flags.constructable = false;
    thunk.prototype = heap.function_proto;
    (*thunk.extra_ptr()).func.builtin_fn_index =
        is_reject ? (int)Builtin.PROMISE_CATCH_FINALLY.ordinal : (int)Builtin.PROMISE_THEN_FINALLY.ordinal;
    // Reuse \xFFon_finally as the storage slot for the passthrough value,
    // and mark \xFFfinally_ctor absent so promise_finally_wrapper_body's
    // caller (this same function, recursively) instead takes the "leaf"
    // path below via a dedicated flag.
    HString* pv_key = builtin_intern_string(heap, "\xFFfinally_passthrough");
    if (pv_key != null) thunk.put_prop(pv_key, passthrough, hobject::PROP_FLAGS_WEC);
    HString* leaf_key = builtin_intern_string(heap, "\xFFfinally_leaf");
    TVal leaf_true; leaf_true.set_boolean(true);
    if (leaf_key != null) thunk.put_prop(leaf_key, leaf_true, hobject::PROP_FLAGS_WEC);

    // ES2018 §27.2.5.3 step 4.a.vi/4.b.vi: Return ? Invoke(promise, "then",
    // « valueThunk ») [ThenFinally] / « thrower » [CatchFinally] — the thunk
    // is always passed as the single onFulfilled argument (promise, wrapping
    // onFinally()'s return value via PromiseResolve, is virtually always
    // fulfilled); the thunk itself decides passthrough vs rethrow based on
    // `is_reject` baked into its own builtin_fn_index. onRejected is left
    // undefined so a rejected `promise` (onFinally() returned/threw via a
    // rejected thenable) propagates that new rejection instead.
    TVal undef_fulfill; undef_fulfill.set_undefined();
    TVal thunk_tv; thunk_tv.set_object(thunk);
    TVal invoke_result;
    if (!promise_invoke_then(heap, ctx.vm, resolved_promise, thunk_tv, undef_fulfill, &invoke_result)) {
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
        }
        return;
    }
    *ctx.result = invoke_result;
}

fn void builtin_promise_then_finally(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    // Leaf thunk (passthrough value/reason holder) vs the outer wrapper
    // (holds \xFFon_finally) are distinguished by \xFFfinally_leaf.
    HString* leaf_key = builtin_intern_string(heap, "\xFFfinally_leaf");
    bool is_leaf = false;
    if (ctx.callee_obj != null && leaf_key != null) {
        if (try lv = ctx.callee_obj.get_prop(leaf_key)) {
            if (lv.is_boolean() && lv.get_boolean()) is_leaf = true;
        }
    }
    if (is_leaf) {
        HString* pv_key = builtin_intern_string(heap, "\xFFfinally_passthrough");
        TVal pv; pv.set_undefined();
        if (pv_key != null && ctx.callee_obj != null) {
            if (try v = ctx.callee_obj.get_prop(pv_key)) pv = v;
        }
        *ctx.result = pv;
        return;
    }
    promise_finally_wrapper_body(ctx, false);
}

fn void builtin_promise_catch_finally(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    HString* leaf_key = builtin_intern_string(heap, "\xFFfinally_leaf");
    bool is_leaf = false;
    if (ctx.callee_obj != null && leaf_key != null) {
        if (try lv = ctx.callee_obj.get_prop(leaf_key)) {
            if (lv.is_boolean() && lv.get_boolean()) is_leaf = true;
        }
    }
    if (is_leaf) {
        HString* pv_key = builtin_intern_string(heap, "\xFFfinally_passthrough");
        TVal pv; pv.set_undefined();
        if (pv_key != null && ctx.callee_obj != null) {
            if (try v = ctx.callee_obj.get_prop(pv_key)) pv = v;
        }
        ctx.should_throw = true;
        ctx.throw_value = pv;
        return;
    }
    promise_finally_wrapper_body(ctx, true);
}

fn void builtin_promise_proto_finally(BuiltinContext* ctx) {
    // ES2018 §27.2.5.3: `this` is used directly (no IsPromise check) —
    // finally() is generic like then()/catch(). Invoke(promise, "then", ...)
    // per steps 5-6 handles poisoned/overridden `.then` and non-Promise
    // `this` (e.g. custom thenables) correctly, since we never call our own
    // PerformPromiseThen implementation directly.
    Heap* heap = ctx.heap;
    TVal promise_val = ctx.regs[ctx.base_reg - 1];

    TVal on_finally;
    on_finally.set_undefined();
    if (ctx.argc >= 1) on_finally = ctx.regs[ctx.base_reg];

    if (promise_val.is_null() || promise_val.is_undefined()) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "Promise.prototype.finally called on null or undefined");
        return;
    }

    bool on_finally_callable = on_finally.is_lightfunc() ||
        (on_finally.is_object() && on_finally.get_heapptr() != null &&
         ((HObject*)on_finally.get_heapptr()).is_callable());

    TVal then_fulfill = on_finally;
    TVal then_reject = on_finally;

    if (on_finally_callable) {
        // Step 4: build the wrapper handlers. SpeciesConstructor uses
        // %Promise% as the default and fallback_proto (only relevant when
        // `this` actually is a Promise instance; for a non-Promise `this`
        // species_constructor's Get("constructor") + @@species chain still
        // applies per spec — it's not gated on IsPromise).
        HObject* ctor = heap.promise_ctor;
        if (promise_val.is_object() && promise_val.get_heapptr() != null) {
            HObject*? sc_opt = species_constructor(heap, ctx.vm, promise_val, heap.promise_ctor, heap.promise_proto);
            if (heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = heap.error_value;
                heap.has_error = false;
                return;
            }
            if (catch err_sc = sc_opt) {
                ctor = heap.promise_ctor;
            } else if (sc_opt != null) {
                ctor = sc_opt;
            }
        }
        HObject*? then_wrap_raw = promise_make_finally_wrapper(heap, (uint)Builtin.PROMISE_THEN_FINALLY.ordinal, on_finally, ctor);
        HObject*? catch_wrap_raw = promise_make_finally_wrapper(heap, (uint)Builtin.PROMISE_CATCH_FINALLY.ordinal, on_finally, ctor);
        if (catch err1 = then_wrap_raw) { ctx.result.set_undefined(); return; }
        if (catch err2 = catch_wrap_raw) { ctx.result.set_undefined(); return; }
        then_fulfill.set_object(then_wrap_raw);
        then_reject.set_object(catch_wrap_raw);
    }

    // Step 5-6: Return ? Invoke(promise, "then", « thenFinally, catchFinally »).
    HObject* promise_obj = null;
    if (promise_val.is_object() && promise_val.get_heapptr() != null) {
        promise_obj = (HObject*)promise_val.get_heapptr();
    } else {
        HObject* proto = null;
        if (promise_val.is_boolean()) { proto = heap.bool_proto; }
        else if (promise_val.is_number() || promise_val.is_fastint()) { proto = heap.number_proto; }
        else if (promise_val.is_string()) {
            HString* pstr = (HString*)promise_val.get_heapptr();
            if (pstr != null && pstr.is_symbol()) { proto = heap.symbol_proto; }
            else { proto = heap.string_proto; }
        }
        promise_obj = proto;
        if (promise_obj == null) { ctx.result.set_undefined(); return; }
    }
    HString* then_key = builtin_intern_string(heap, "then");
    if (then_key == null) { ctx.result.set_undefined(); return; }
    TVal then_fn;
    if (!promise_object_get(heap, ctx.vm, promise_obj, then_key, &then_fn)) {
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
        }
        return;
    }
    bool then_callable = then_fn.is_lightfunc() ||
        (then_fn.is_object() && then_fn.get_heapptr() != null &&
         ((HObject*)then_fn.get_heapptr()).is_callable());
    if (!then_callable) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "then is not callable");
        return;
    }
    if (heap.call_fn == null || ctx.vm == null) { ctx.result.set_undefined(); return; }
    TVal[2] call_args;
    call_args[0] = then_fulfill;
    call_args[1] = then_reject;
    TVal ret = heap.call_fn(ctx.vm, then_fn, &call_args[0], 2, promise_val);
    if (heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = heap.error_value;
        heap.has_error = false;
        return;
    }
    *ctx.result = ret;
}

// ============================================================================
// Promise.resolve(x) — ES6 §25.4.4.5
// ============================================================================

fn void builtin_promise_resolve(BuiltinContext* ctx) {
    TVal val;
    val.set_undefined();
    if (ctx.argc >= 1) val = ctx.regs[ctx.base_reg];

    // Determine the constructor C = this value (ES6 §25.4.4.5 step 1).
    // The fast path applies only when C is the default Promise. For a custom
    // constructor we must run NewPromiseCapability(C) so the resulting Promise
    // is owned by C and so things like Promise.resolve.call(fn) trigger fn().
    TVal this_ctor_val = ctx.regs[ctx.base_reg - 1];
    bool is_default_promise = this_ctor_val.is_object()
        && this_ctor_val.get_heapptr() != null
        && (HObject*)this_ctor_val.get_heapptr() == ctx.heap.promise_ctor;
    if (!is_default_promise) {
        // If C is the species Promise itself but we got here somehow, fall
        // through; else create a capability and use it.
        HObject*? cap_hole_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try cap_hole = cap_hole_raw) {
            cap_hole.prototype = ctx.heap.object_proto;
            if (promise_new_capability_full(ctx.heap, ctx.vm, this_ctor_val, cap_hole)) {
                // Per ES6 §25.4.4.5 step 3: if x is already a Promise AND
                // SameValue(x.constructor, C), return it unchanged. Reading
                // x.constructor may run user code / throw (poisoned getter).
                if (val.is_object() && val.get_heapptr() != null) {
                    HObject* obj = (HObject*)val.get_heapptr();
                    if (obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                        HString* ctor_key = builtin_intern_string(ctx.heap, "constructor");
                        TVal xctor;
                        xctor.set_undefined();
                        if (ctor_key != null) {
                            xctor = promise_get_prop_thru_accessor(ctx.heap, ctx.vm, obj, ctor_key);
                            if (ctx.heap.has_error) {
                                ctx.should_throw = true;
                                ctx.throw_value = ctx.heap.error_value;
                                ctx.heap.has_error = false;
                                return;
                            }
                        }
                        bool same_ctor = xctor.is_object() && xctor.get_heapptr() != null &&
                            xctor.get_heapptr() == this_ctor_val.get_heapptr();
                        if (same_ctor) {
                            *ctx.result = val;
                            return;
                        }
                    }
                }
                // Per ES6 §27.2.4.5 step 4: Call(promiseCapability.[[Resolve]], undefined, « x »).
                // Return promiseCapability.[[Promise]].
                TVal cap_resolve = promise_hole_get_resolve(ctx.heap, cap_hole);
                TVal cap_p_tv = promise_hole_get_promise(ctx.heap, cap_hole);
                TVal r_args = val;
                TVal undef2; undef2.set_undefined();
                if (ctx.heap.call_fn != null && ctx.vm != null) {
                    ctx.heap.call_fn(ctx.vm, cap_resolve, &r_args, 1, undef2);
                    if (ctx.heap.has_error) {
                        ctx.should_throw = true;
                        ctx.throw_value = ctx.heap.error_value;
                        ctx.heap.has_error = false;
                        return;
                    }
                }
                *ctx.result = cap_p_tv;
                return;
            } else {
                // ES6 §25.4.1.5 step 7/8: capability is incomplete or
                // Construct() threw. Use the rethrow-stored-abort helper so
                // the user's actual exception (if any) takes precedence over
                // the generic TypeError.
                promise_throw_capability_failure(ctx, cap_hole);
                return;
            }
        }
    }

    // Per ES6 §25.4.4.5 step 3: if x is already a Promise AND
    // SameValue(x.constructor, C) — here C is %Promise% — return it
    // unchanged. A Promise whose "constructor" was overridden must still go
    // through NewPromiseCapability + resolve.
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.PROMISE) {
            HString* ctor_key = builtin_intern_string(ctx.heap, "constructor");
            TVal xctor;
            xctor.set_undefined();
            if (ctor_key != null) {
                xctor = promise_get_prop_thru_accessor(ctx.heap, ctx.vm, obj, ctor_key);
                if (ctx.heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = ctx.heap.error_value;
                    ctx.heap.has_error = false;
                    return;
                }
            }
            bool same_ctor = xctor.is_object() && xctor.get_heapptr() != null &&
                (HObject*)xctor.get_heapptr() == ctx.heap.promise_ctor;
            if (same_ctor) {
                *ctx.result = val;
                return;
            }
        }
    }

    // Otherwise: NewPromiseCapability(%Promise%) + Call(resolve, undefined, «x»).
    // Reuse the full Promise Resolve Function procedure (self-resolution N/A
    // here since `promise` is freshly created; thenable coercion/poisoned
    // `.then` propagation are shared with the executor's resolve callback).
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;
    promise_resolve_with_value(promise, val, ctx.heap, ctx.vm);

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise.reject(r) — ES6 §25.4.4.4
// ============================================================================

fn void builtin_promise_reject(BuiltinContext* ctx) {
    TVal reason;
    reason.set_undefined();
    if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];

    // ES6 §25.4.4.4 step 1 — for custom C, run NewPromiseCapability(C).
    TVal this_ctor_val = ctx.regs[ctx.base_reg - 1];
    bool is_default_promise = this_ctor_val.is_object()
        && this_ctor_val.get_heapptr() != null
        && (HObject*)this_ctor_val.get_heapptr() == ctx.heap.promise_ctor;
    if (!is_default_promise) {
        HObject*? cap_hole_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try cap_hole = cap_hole_raw) {
            cap_hole.prototype = ctx.heap.object_proto;
            if (promise_new_capability_full(ctx.heap, ctx.vm, this_ctor_val, cap_hole)) {
                // Per ES6 §25.4.4.4 step 4: invoke the capability's [[Reject]]
                // with `reason` and `this=undefined`. The returned Promise from
                // the constructor is ignored; the outer spec value is from the
                // call's resolve/reject path. We must surface any throw from
                // the user-supplied reject so test262 capability-invocation-error
                // passes.
                // Per ES6 §27.2.4.4 step 4: Call(promiseCapability.[[Reject]], undefined, « r »).
                // Return promiseCapability.[[Promise]].
                TVal cap_reject = promise_hole_get_reject(ctx.heap, cap_hole);
                TVal cap_p_tv = promise_hole_get_promise(ctx.heap, cap_hole);
                TVal r_args = reason;
                TVal undef; undef.set_undefined();
                if (ctx.heap.call_fn != null && ctx.vm != null) {
                    ctx.heap.call_fn(ctx.vm, cap_reject, &r_args, 1, undef);
                    if (ctx.heap.has_error) {
                        ctx.should_throw = true;
                        ctx.throw_value = ctx.heap.error_value;
                        ctx.heap.has_error = false;
                        return;
                    }
                }
                *ctx.result = cap_p_tv;
                return;
            } else {
                // ES6 §25.4.1.5 step 7/8: capability is incomplete or
                // Construct() threw. Use the rethrow-stored-abort helper so
                // the user's actual exception (if any) takes precedence over
                // the generic TypeError.
                promise_throw_capability_failure(ctx, cap_hole);
                return;
            }
        }
    }

    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;
    promise_settle(promise, PROMISE_REJECTED, &reason, ctx.heap);

    ctx.result.set_object(promise);
}

// ============================================================================
// Thenable coercion — ES6 Promise Resolution Procedure
// ============================================================================

/// Read `key` off `obj`, invoking an accessor getter (via heap.call_fn) if
/// the property is one. Sets heap.has_error/heap.error_value and returns
/// undefined if the getter throws — callers must check heap.has_error after
/// calling this. Mirrors the pattern in object.c3's desc_get.
fn TVal promise_get_prop_thru_accessor(Heap* heap, void* vm, HObject* obj, HString* key) {
    TVal out;
    out.set_undefined();
    if (obj == null || key == null) return out;
    hobject::PropLookupResult res = obj.get_prop_or_accessor_proto(key, true);
    if (res.kind == hobject::PropLookupKind.PROP_NOT_FOUND) return out;
    if (res.kind == hobject::PropLookupKind.PROP_DATA) {
        return res.data_val;
    }
    // PROP_ACCESSOR
    TVal getter = res.acc.accessor_fn;
    if (getter.is_undefined() || getter.is_null()) return out;
    if (heap.call_fn == null || vm == null) return out;
    TVal this_tv;
    this_tv.set_object(obj);
    return heap.call_fn(vm, getter, null, 0, this_tv);
}

/// If `val` is a non-Promise object with a callable `.then` method, create a
/// new Promise, call `thenable.then(resolve, reject)`, and return the wrapper
/// Promise. Returns `null` for non-thenables, in which case the caller should
/// await the original value as a non-thenable (no-op). If reading `.then`
/// throws (poisoned accessor), heap.has_error is set and `null` is returned;
/// callers must check heap.has_error to distinguish this from "not thenable".
fn HObject*? promise_coerce_thenable(Heap* heap, TVal val, void* vm) {
    if (!val.is_object() || val.get_heapptr() == null) return null;
    HObject* obj = (HObject*)val.get_heapptr();

    // Get .then property (through accessors — a poisoned `then` getter must
    // propagate its throw, not be silently swallowed).
    HString* then_key = builtin_intern_string(heap, "then");
    if (then_key == null) return null;
    TVal then_method = promise_get_prop_thru_accessor(heap, vm, obj, then_key);
    if (heap.has_error) return null;

    bool then_callable = then_method.is_lightfunc() ||
        (then_method.is_object() && then_method.get_heapptr() != null &&
         ((HObject*)then_method.get_heapptr()).is_callable());
    if (!then_callable) return null;

    // Create wrapper Promise
    HObject*? wrapper_raw = promise_create(heap);
    if (catch err = wrapper_raw) return null;
    HObject* wrapper = wrapper_raw;

    // Hidden property key used by resolve/reject callbacks
    HString* promise_key = builtin_intern_string(heap, "\xFFpromise");
    HString* cell_key = builtin_intern_string(heap, "\xFFcap_cell");

    // Shared [[AlreadyResolved]] cell (ES6 §25.4.1.3 CreateResolvingFunctions
    // step 2): must be marked true synchronously the moment EITHER resolve
    // or reject is first called, even though resolving a thenable value
    // defers the actual settlement to a queued job. Without this, a
    // thenable.then() that calls resolve(anotherThenable) and then throws
    // synchronously would incorrectly reject the wrapper via the throw,
    // since the wrapper's promise state is still PENDING (the nested
    // thenable's own job hasn't run yet) — see
    // exception-after-resolve-in-thenable-job.js.
    HObject* already_cell = promise_new_already_cell(heap);

    // Create resolve callback
    HObject*? resolve_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = resolve_raw) return null;
    HObject* resolve_fn = resolve_raw;
    resolve_fn.flags.callable = true;
    resolve_fn.flags.constructable = false;
    resolve_fn.prototype = heap.function_proto;
    (*resolve_fn.extra_ptr()).func.builtin_fn_index = (int)Builtin.PROMISE_RESOLVE_CALLBACK.ordinal;
    // Set length=1, name="" per ES2015 §25.4.1.3.2 (PromiseCapability records)
    HString* len_key = builtin_intern_string(heap, "length");
    if (len_key != null) {
        TVal len_tv; len_tv.set_fastint(1);
        resolve_fn.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* name_key = builtin_intern_string(heap, "name");
    if (name_key != null) {
        TVal name_tv; name_tv.set_string(builtin_intern_string(heap, ""));
        resolve_fn.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
    }
    if (promise_key != null) {
        TVal wrapper_tv; wrapper_tv.set_object(wrapper);
        resolve_fn.put_prop(promise_key, wrapper_tv, hobject::PROP_FLAGS_WEC);
    }
    if (cell_key != null && already_cell != null) {
        TVal cell_tv; cell_tv.set_object(already_cell);
        resolve_fn.put_prop(cell_key, cell_tv, hobject::PROP_FLAGS_WEC);
    }
    TVal resolve_tv; resolve_tv.set_object(resolve_fn);

    // Create reject callback
    HObject*? reject_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = reject_raw) return null;
    HObject* reject_fn = reject_raw;
    reject_fn.flags.callable = true;
    reject_fn.flags.constructable = false;
    reject_fn.prototype = heap.function_proto;
    (*reject_fn.extra_ptr()).func.builtin_fn_index = (int)Builtin.PROMISE_REJECT_CALLBACK.ordinal;
    if (len_key != null) {
        TVal len_tv; len_tv.set_fastint(1);
        reject_fn.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
    }
    if (name_key != null) {
        TVal name_tv; name_tv.set_string(builtin_intern_string(heap, ""));
        reject_fn.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
    }
    if (promise_key != null) {
        TVal wrapper_tv; wrapper_tv.set_object(wrapper);
        reject_fn.put_prop(promise_key, wrapper_tv, hobject::PROP_FLAGS_WEC);
    }
    if (cell_key != null && already_cell != null) {
        TVal cell_tv2; cell_tv2.set_object(already_cell);
        reject_fn.put_prop(cell_key, cell_tv2, hobject::PROP_FLAGS_WEC);
    }
    TVal reject_tv; reject_tv.set_object(reject_fn);

    // Per ES6 §25.4.1.3.2 step 12 / §25.4.2.2 PromiseResolveThenableJob: the
    // `then.call(resolution, resolve, reject)` call must run as a queued job,
    // not synchronously inline with whatever code triggered the resolution
    // (executor, resolve callback, etc.) — otherwise thenable.then() would
    // observably run before the resolving call returns.
    HObject*? job_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = job_raw) return null;
    HObject* job = job_raw;
    job.flags.callable = true;
    job.flags.constructable = false;
    job.prototype = heap.function_proto;
    (*job.extra_ptr()).func.builtin_fn_index = (int)Builtin.PROMISE_RESOLVE_THENABLE_JOB.ordinal;
    HString* then_hidden_key = builtin_intern_string(heap, "\xFFthen");
    HString* resolution_key  = builtin_intern_string(heap, "\xFFresolution");
    HString* resolve_key     = builtin_intern_string(heap, "\xFFjob_resolve");
    HString* reject_hkey     = builtin_intern_string(heap, "\xFFjob_reject");
    if (then_hidden_key != null) job.put_prop(then_hidden_key, then_method, hobject::PROP_FLAGS_WEC);
    if (resolution_key != null)  job.put_prop(resolution_key, val, hobject::PROP_FLAGS_WEC);
    if (resolve_key != null)     job.put_prop(resolve_key, resolve_tv, hobject::PROP_FLAGS_WEC);
    if (reject_hkey != null)     job.put_prop(reject_hkey, reject_tv, hobject::PROP_FLAGS_WEC);

    TVal job_tv; job_tv.set_object(job);
    TVal undef_arg; undef_arg.set_undefined();
    TVal undef_downstream; undef_downstream.set_undefined();
    heap.enqueue_microtask(job_tv, undef_arg, undef_downstream);

    return wrapper;
}

/// Microtask handler for PromiseResolveThenableJob (ES6 §25.4.2.2). Reads
/// the deferred then/resolution/resolve/reject off ctx.callee_obj's hidden
/// slots and performs `then.call(resolution, resolve, reject)`. If that call
/// throws, invokes `reject(error)` (per spec step, unless already settled —
/// the resolve/reject callbacks themselves enforce [[AlreadyResolved]] via
/// the target promise's PENDING check, since no capability cell is used
/// here, so a direct settle-if-pending on the wrapper is sufficient).
fn void builtin_promise_resolve_thenable_job(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    ctx.result.set_undefined();
    if (ctx.callee_obj == null) return;

    HString* then_hidden_key = builtin_intern_string(heap, "\xFFthen");
    HString* resolution_key  = builtin_intern_string(heap, "\xFFresolution");
    HString* resolve_key     = builtin_intern_string(heap, "\xFFjob_resolve");
    HString* reject_hkey     = builtin_intern_string(heap, "\xFFjob_reject");

    TVal then_method; then_method.set_undefined();
    TVal resolution; resolution.set_undefined();
    TVal resolve_tv; resolve_tv.set_undefined();
    TVal reject_tv; reject_tv.set_undefined();
    if (then_hidden_key != null) {
        if (try tv = ctx.callee_obj.get_prop(then_hidden_key)) then_method = tv;
    }
    if (resolution_key != null) {
        if (try rv = ctx.callee_obj.get_prop(resolution_key)) resolution = rv;
    }
    if (resolve_key != null) {
        if (try rsv = ctx.callee_obj.get_prop(resolve_key)) resolve_tv = rsv;
    }
    if (reject_hkey != null) {
        if (try rjv = ctx.callee_obj.get_prop(reject_hkey)) reject_tv = rjv;
    }

    if (heap.call_fn == null) return;
    TVal[2] arg_arr = { resolve_tv, reject_tv };
    heap.call_fn(ctx.vm, then_method, &arg_arr, 2, resolution);
    if (heap.has_error) {
        TVal err = heap.error_value;
        heap.has_error = false;
        TVal err_args = err;
        TVal undef; undef.set_undefined();
        heap.call_fn(ctx.vm, reject_tv, &err_args, 1, undef);
        if (heap.has_error) heap.has_error = false;
    }
}

// ============================================================================
// Promise.all/race element-tracking helpers (ES6 §25.4.4.1, §25.4.4.3)
//
// Both algorithms need to attach per-element callbacks to pending input
// promises and update shared state (remaining count for all, first-settler
// for race) when each input settles.  These helpers create the shared
// "state" object and the per-element callbacks.  The state is referenced
// from each callback's hidden properties so they can find each other.
//
// Hidden state schema on the outer promise:
//   \xFFstate — state HObject carrying remaining count, result array,
//               rejected flag, and outer promise reference.
// Hidden props on each element callback:
//   \xFFouter   — outer promise (so we can settle it)
//   \xFFstate   — shared state object (so callbacks share remaining count)
//   \xFFidx     — index in the result array (for all)
// ============================================================================

/// Create the shared state object for Promise.all / Promise.race tracking.
/// `cap_resolve` and `cap_reject` are the capability's resolve/reject TVals;

/// Invoke the capability's resolve or reject via call_fn if it is callable.
/// Used by per-element callbacks after settling the outer promise to meet
/// the spec's promiseCapability.[[Resolve]](valuesArray) requirement.
fn void capability_invoke(Heap* heap, void* vm, HObject* state, TVal* val, bool is_resolve, TVal this_val) {
    if (state == null || heap.call_fn == null || vm == null) return;
    char[] key_name = is_resolve ? "\xFFcap_resolve" : "\xFFcap_reject";
    HString* key = builtin_intern_string(heap, key_name);
    if (key == null) return;
    TVal? cap_opt = state.get_prop(key);
    TVal capr;
    capr.set_undefined();
    if (try cv = cap_opt) capr = cv;
    // Only invoke if callable (user-defined function or lightfunc).
    if (capr.is_lightfunc() ||
        (capr.is_object() && capr.get_heapptr() != null &&
         ((HObject*)capr.get_heapptr()).is_callable())) {
        TVal[1] cap_args;
        cap_args[0] = *val;
        TVal cap_ret = heap.call_fn(vm, capr, &cap_args[0], 1, this_val);
        if (heap.has_error) {
            TVal err_val = heap.error_value;
            promise_clear_error_channels(heap, vm);
            if (is_resolve) {
                // Per IfAbruptRejectPromise (ES6 §25.4.1.1.1): a throw from
                // Call(resultCapability.[[Resolve]], ...) must reject the
                // capability's promise with the thrown value, not be
                // silently swallowed.
                HString* rj_key = builtin_intern_string(heap, "\xFFcap_reject");
                if (rj_key != null) {
                    TVal? rj_opt = state.get_prop(rj_key);
                    TVal rejr; rejr.set_undefined();
                    if (try rv = rj_opt) rejr = rv;
                    promise_combinator_reject(heap, vm, rejr, &err_val);
                }
            }
        }
    }
}

/// Create the shared state object for Promise.all / Promise.race tracking.
/// `cap_resolve` and `cap_reject` are the capability's resolve/reject TVals;
/// they are stored on the state so element callbacks can invoke the spec's
/// promiseCapability.[[Resolve]](valuesArray) step when the outer promise
/// settles.  Either may be the JS undefined when no constructor's resolve
/// was looked up — in that case element callbacks just settle the outer
/// directly without going through a callable.
fn HObject*? promise_create_all_state(Heap* heap, HObject* outer_promise, HObject* arr, usz initial_remaining,
                                      TVal cap_resolve, TVal cap_reject) {
    HObject*? state_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = state_raw) return null;
    HObject* state = state_raw;
    state.prototype = heap.object_proto;

    HString* outer_key = builtin_intern_string(heap, "\xFFouter");
    HString* arr_key = builtin_intern_string(heap, "\xFFarr");
    HString* remaining_key = builtin_intern_string(heap, "\xFFremaining");
    HString* rejected_key = builtin_intern_string(heap, "\xFFrejected");
    HString* cap_r_key = builtin_intern_string(heap, "\xFFcap_resolve");
    HString* cap_j_key = builtin_intern_string(heap, "\xFFcap_reject");

    if (outer_key != null) {
        TVal outer_tv; outer_tv.set_object(outer_promise);
        state.put_prop(outer_key, outer_tv, hobject::PROP_FLAGS_WEC);
    }
    if (arr_key != null) {
        TVal arr_tv; arr_tv.set_object(arr);
        state.put_prop(arr_key, arr_tv, hobject::PROP_FLAGS_WEC);
    }
    if (remaining_key != null) {
        TVal rem_tv; rem_tv.set_fastint((long)initial_remaining);
        state.put_prop(remaining_key, rem_tv, hobject::PROP_FLAGS_WEC);
    }
    if (rejected_key != null) {
        TVal rej_tv; rej_tv.set_boolean(false);
        state.put_prop(rejected_key, rej_tv, hobject::PROP_FLAGS_WEC);
    }
    if (cap_r_key != null) {
        state.put_prop(cap_r_key, cap_resolve, hobject::PROP_FLAGS_WEC);
    }
    if (cap_j_key != null) {
        state.put_prop(cap_j_key, cap_reject, hobject::PROP_FLAGS_WEC);
    }
    return state;
}

/// Create a per-element fulfill/reject callback function.  Carries the shared
/// state and index via hidden properties.
fn HObject*? promise_create_element_callback(Heap* heap, uint builtin_index, HObject* state, usz idx) {
    HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = fn_raw) return null;
    HObject* cb = fn_raw;
    (*cb.extra_ptr()).func.builtin_fn_index = (int)builtin_index;
    cb.flags.callable = true;
    cb.flags.constructable = false;
    cb.prototype = heap.function_proto;

    HString* len_key = builtin_intern_string(heap, "length");
    if (len_key != null) {
        TVal len_tv; len_tv.set_fastint(1);
        cb.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* name_key = builtin_intern_string(heap, "name");
    if (name_key != null) {
        TVal name_tv; name_tv.set_string(builtin_intern_string(heap, ""));
        cb.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* state_key = builtin_intern_string(heap, "\xFFstate");
    if (state_key != null) {
        TVal state_tv; state_tv.set_object(state);
        cb.put_prop(state_key, state_tv, hobject::PROP_FLAGS_WEC);
    }
    HString* idx_key = builtin_intern_string(heap, "\xFFidx");
    if (idx_key != null) {
        TVal idx_tv; idx_tv.set_fastint((long)idx);
        cb.put_prop(idx_key, idx_tv, hobject::PROP_FLAGS_WEC);
    }
    return cb;
}

/// Promise.all per-element fulfill handler (called via microtask).
/// Stores the value at result[idx] and decrements the remaining counter;
/// when it reaches zero, fulfills the outer promise with the result array.
fn void builtin_promise_all_resolve_element(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    if (ctx.callee_obj == null) return;

    // Per spec §27.2.4.1.2 step 1-3: alreadyCalled guard.
    HString* ac_key = builtin_intern_string(heap, "\xFFalreadyCalled");
    if (ac_key != null) {
        if (try acv = ctx.callee_obj.get_prop(ac_key)) {
            if (acv.is_boolean() && acv.get_boolean()) { ctx.result.set_undefined(); return; }
        }
        TVal ac_true; ac_true.set_boolean(true);
        ctx.callee_obj.put_prop(ac_key, ac_true, hobject::PROP_FLAGS_WEC);
    }

    // Read state and idx from hidden properties on this callback function.
    HString* state_key = builtin_intern_string(heap, "\xFFstate");
    HString* idx_key = builtin_intern_string(heap, "\xFFidx");
    HString* arr_key = builtin_intern_string(heap, "\xFFarr");
    HString* remaining_key = builtin_intern_string(heap, "\xFFremaining");
    HString* outer_key = builtin_intern_string(heap, "\xFFouter");
    if (state_key == null || idx_key == null) return;

    TVal? state_opt = ctx.callee_obj.get_prop(state_key);
    HObject* state = null;
    if (try sv = state_opt) {
        if (sv.is_object() && sv.get_heapptr() != null) state = (HObject*)sv.get_heapptr();
    }
    if (state == null) return;

    TVal? idx_opt = ctx.callee_obj.get_prop(idx_key);
    usz idx = 0;
    if (try iv = idx_opt) {
        if (iv.is_fastint()) idx = (usz)iv.get_fastint();
    }

    TVal value;
    value.set_undefined();
    if (ctx.argc >= 1) value = ctx.regs[ctx.base_reg];

    // Store value at result[idx] (state.arr)
    if (arr_key != null) {
        TVal? arr_opt = state.get_prop(arr_key);
        HObject* arr = null;
        if (try av = arr_opt) {
            if (av.is_object() && av.get_heapptr() != null) arr = (HObject*)av.get_heapptr();
        }
        if (arr != null) {
            arr.set_array_idx((uint)idx, value);
            // Update array length so user code can read arr.length.
            // (set_array_idx updates array_used but not the cached length /
            // named "length" property.)
            if ((uint)idx + 1 > *arr.array_len_ptr()) {
                array_set_length(arr, (uint)idx + 1, heap);
            }
        }
    }

    // Decrement remaining; settle outer if it reaches zero.
    if (remaining_key != null) {
        TVal? rem_opt = state.get_prop(remaining_key);
        long remaining = 0;
        if (try rv = rem_opt) {
            if (rv.is_fastint()) remaining = rv.get_fastint();
        }
        remaining -= 1;
        TVal new_rem; new_rem.set_fastint(remaining);
        state.put_prop(remaining_key, new_rem, hobject::PROP_FLAGS_WEC);

        if (remaining == 0 && outer_key != null) {
            TVal? outer_opt = state.get_prop(outer_key);
            HObject* outer = null;
            if (try ov = outer_opt) {
                if (ov.is_object() && ov.get_heapptr() != null) outer = (HObject*)ov.get_heapptr();
            }
            // Read current rejected flag — if already rejected, don't overwrite.
            HString* rej_key = builtin_intern_string(heap, "\xFFrejected");
            bool already_rejected = false;
            if (rej_key != null) {
                TVal? rej_opt = state.get_prop(rej_key);
                if (try rj = rej_opt) {
                    if (rj.is_boolean() && rj.get_boolean()) already_rejected = true;
                }
            }
            if (outer != null && !already_rejected) {
                // Settle outer with the result array.
                TVal arr_val;
                if (arr_key != null) {
                    TVal? arr_opt2 = state.get_prop(arr_key);
                    if (try av2 = arr_opt2) {
                        arr_val = av2;
                    } else {
                        arr_val.set_undefined();
                    }
                } else {
                    arr_val.set_undefined();
                }
                // Settlement for the default path is handled by capability_invoke
                // below (cap_resolve IS builtin_promise_resolve_callback for the
                // default constructor, which internally runs the full Promise
                // Resolve Function procedure). Calling promise_resolve_with_value
                // here too would double-settle when C is a custom constructor
                // whose resolve/reject are independent of `outer`.
                capability_invoke(heap, ctx.vm, state, &arr_val, true, ctx.this_val);
                if (!heap.microtask_draining) {
                    heap.drain_microtasks(ctx.vm);
                }
            }
        }
    }
}

/// Promise.all per-element reject handler (called via microtask).
/// Rejects the outer promise on the first rejection (subsequent rejections
/// are ignored per ES6 §25.4.4.1).
fn void builtin_promise_all_reject_element(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    if (ctx.callee_obj == null) return;

    HString* state_key = builtin_intern_string(heap, "\xFFstate");
    HString* outer_key = builtin_intern_string(heap, "\xFFouter");
    HString* rej_key = builtin_intern_string(heap, "\xFFrejected");
    if (state_key == null) return;

    TVal? state_opt = ctx.callee_obj.get_prop(state_key);
    HObject* state = null;
    if (try sv = state_opt) {
        if (sv.is_object() && sv.get_heapptr() != null) state = (HObject*)sv.get_heapptr();
    }
    if (state == null) return;

    TVal reason;
    reason.set_undefined();
    if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];

    // Check if already rejected
    bool already_rejected = false;
    if (rej_key != null) {
        TVal? rej_opt = state.get_prop(rej_key);
        if (try rj = rej_opt) {
            if (rj.is_boolean() && rj.get_boolean()) already_rejected = true;
        }
    }
    if (already_rejected) return;

    // Mark rejected
    if (rej_key != null) {
        TVal rej_tv; rej_tv.set_boolean(true);
        state.put_prop(rej_key, rej_tv, hobject::PROP_FLAGS_WEC);
    }

    // Reject the outer promise
    if (outer_key != null) {
        TVal? outer_opt = state.get_prop(outer_key);
        HObject* outer = null;
        if (try ov = outer_opt) {
            if (ov.is_object() && ov.get_heapptr() != null) outer = (HObject*)ov.get_heapptr();
        }
        if (outer != null) {
            promise_settle(outer, PROMISE_REJECTED, &reason, heap);
            promise_trigger_reactions(outer, heap, ctx.vm);
            capability_invoke(heap, ctx.vm, state, &reason, false, ctx.this_val);
        }
    }
}

/// Attach fulfill/reject element callbacks to a pending promise.  Used by
/// Promise.all / Promise.race.  If the promise is already settled, fire
/// the appropriate callback immediately.
fn void promise_attach_element_callbacks(HObject* promise, HObject* fulfill_fn, HObject* reject_fn, Heap* heap, void* vm) {
    if (promise == null) return;

    HString* onf_key = builtin_intern_string(heap, "onFulfilled");
    HString* onr_key = builtin_intern_string(heap, "onRejected");
    HString* ds_key = builtin_intern_string(heap, "downstream");

    // Build reactions for both fulfill and reject.  We use a non-PROMISE
    // downstream so promise_microtask_after returns early (the callbacks
    // do their own work via the shared state object).
    HObject*? fulfill_reaction_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (try fr = fulfill_reaction_raw) {
        TVal ff_tv; ff_tv.set_object(fulfill_fn);
        if (onf_key != null) fr.put_prop(onf_key, ff_tv, hobject::PROP_FLAGS_WEC);
        if (ds_key != null) {
            TVal undef_tv; undef_tv.set_undefined();
            fr.put_prop(ds_key, undef_tv, hobject::PROP_FLAGS_WEC);
        }
        promise_add_reaction(promise, fr, heap);
    }

    HObject*? reject_reaction_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (try rr = reject_reaction_raw) {
        TVal rf_tv; rf_tv.set_object(reject_fn);
        if (onr_key != null) rr.put_prop(onr_key, rf_tv, hobject::PROP_FLAGS_WEC);
        if (ds_key != null) {
            TVal undef_tv; undef_tv.set_undefined();
            rr.put_prop(ds_key, undef_tv, hobject::PROP_FLAGS_WEC);
        }
        promise_add_reaction(promise, rr, heap);
    }

    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state != PROMISE_PENDING) {
        promise_trigger_reactions(promise, heap, vm);
    }
}

// ============================================================================
// Helper: handle a resolved-thenable synchronously for the combinator loop.
//
// When `C.resolve(elem)` returns a thenable (not a Promise), the spec requires
// us to call `.then` on it. If the thenable's `then` is synchronous, the
// wrapper Promise is settled before we can attach reactions — so the
// attached reactions are queued as microtasks. That breaks tests that
// assert synchronous behavior after the combinator call returns.
//
// This helper handles BOTH paths:
//   - Synchronous: extract result/reason from the wrapper, call the
//     element callback directly. This matches reference engines that
//     drain microtasks inline.
//   - Asynchronous (still pending): attach reactions for later draining.
//
// Returns true if the wrapper is already settled and the callback was
// invoked synchronously. The caller should `continue` to the next element
// in that case.
// ============================================================================
fn bool promise_attach_thenable_element_callbacks(
    Heap* heap, void* vm, TVal resolved, HObject* fulfill_fn, HObject* reject_fn
) {
    if (!resolved.is_object() || resolved.get_heapptr() == null) return false;
    HObject* wrapper = (HObject*)resolved.get_heapptr();

    // If the wrapper is already settled, run the callback directly via a
    // synthetic call. This handles synchronously-settled thenables.
    uint state = promise_get_state(wrapper, PROMISE_PENDING);
    if (state != PROMISE_PENDING) {
        TVal result = promise_get_result(wrapper);
        HObject* cb = (state == PROMISE_FULFILLED) ? fulfill_fn : reject_fn;

        // Build a synthetic context so we can dispatch_builtin directly.
        // Layout: [callee, this, arg0, padding]
        TVal[4] temp;
        temp[0].set_object((void*)cb);
        temp[1].set_undefined();
        temp[2] = result;
        temp[3].set_undefined();
        BuiltinContext cb_ctx;
        cb_ctx.vm = vm;
        cb_ctx.heap = heap;
        cb_ctx.regs = &temp;
        cb_ctx.base_reg = 2;
        cb_ctx.argc = 1;
        cb_ctx.result = &temp[0];
        cb_ctx.this_val.set_undefined();
        cb_ctx.is_constructor = false;
        cb_ctx.needs_re_dispatch = false;
        cb_ctx.re_nargs = 0;
        cb_ctx.global_env = null;
        cb_ctx.should_throw = false;
        cb_ctx.callee_obj = cb;
        dispatch_builtin(
            (uint)(*cb.extra_ptr()).func.builtin_fn_index,
            &cb_ctx
        );
        return true;
    }

    // Pending: attach reactions for async settling.
    promise_attach_element_callbacks(wrapper, fulfill_fn, reject_fn, heap, vm);
    return true;
}

// ============================================================================
// Promise.allSettled element-tracking helpers (ES2020 §25.6.4.5)
//
// Like Promise.all but tracks BOTH fulfill and reject for each element.
// The shared state holds the result array (indexed by element position) and
// a remaining count. When remaining hits zero, settle outer with the array.
//
// Hidden props on each element callback:
//   \xFFstate   — shared state object
//   \xFFidx     — index in the result array
// ============================================================================

/// Promise.allSettled per-element fulfill handler.
/// Creates {status: "fulfilled", value: x} at result[idx], decrements
/// remaining, settles outer with the full array when remaining reaches 0.
fn void builtin_promise_allsettled_resolve_element(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    if (ctx.callee_obj == null) return;

    // Per spec §27.2.4.4.2 step 1-3: alreadyCalled guard.
    HString* ac_key = builtin_intern_string(heap, "\xFFalreadyCalled");
    if (ac_key != null) {
        if (try acv = ctx.callee_obj.get_prop(ac_key)) {
            if (acv.is_boolean() && acv.get_boolean()) { ctx.result.set_undefined(); return; }
        }
        TVal ac_true; ac_true.set_boolean(true);
        ctx.callee_obj.put_prop(ac_key, ac_true, hobject::PROP_FLAGS_WEC);
    }

    HString* state_key = builtin_intern_string(heap, "\xFFstate");
    HString* idx_key = builtin_intern_string(heap, "\xFFidx");
    HString* arr_key = builtin_intern_string(heap, "\xFFarr");
    HString* remaining_key = builtin_intern_string(heap, "\xFFremaining");
    HString* outer_key = builtin_intern_string(heap, "\xFFouter");
    if (state_key == null || idx_key == null) return;

    TVal? state_opt = ctx.callee_obj.get_prop(state_key);
    HObject* state = null;
    if (try sv = state_opt) {
        if (sv.is_object() && sv.get_heapptr() != null) state = (HObject*)sv.get_heapptr();
    }
    if (state == null) return;

    TVal? idx_opt = ctx.callee_obj.get_prop(idx_key);
    usz idx = 0;
    if (try iv = idx_opt) {
        if (iv.is_fastint()) idx = (usz)iv.get_fastint();
    }

    TVal value;
    value.set_undefined();
    if (ctx.argc >= 1) value = ctx.regs[ctx.base_reg];

    // Build {status: "fulfilled", value: x}
    HObject*? result_obj_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (try result_obj = result_obj_raw) {
        result_obj.prototype = heap.object_proto;
        HString* status_key = builtin_intern_string(heap, "status");
        HString* value_key = builtin_intern_string(heap, "value");
        TVal fulfilled_status;
        fulfilled_status.set_string(builtin_intern_string(heap, "fulfilled"));
        if (status_key != null) result_obj.put_prop(status_key, fulfilled_status, hobject::PROP_FLAGS_WEC);
        if (value_key != null) result_obj.put_prop(value_key, value, hobject::PROP_FLAGS_WEC);
        TVal result_tv;
        result_tv.set_object(result_obj);

        // Store into result array at idx
        if (arr_key != null) {
            TVal? arr_opt = state.get_prop(arr_key);
            HObject* arr = null;
            if (try av = arr_opt) {
                if (av.is_object() && av.get_heapptr() != null) arr = (HObject*)av.get_heapptr();
            }
            if (arr != null) {
                arr.set_array_idx((uint)idx, result_tv);
                if ((uint)idx + 1 > *arr.array_len_ptr()) {
                    array_set_length(arr, (uint)idx + 1, heap);
                }
            }
        }
    }

    // Decrement remaining
    if (remaining_key != null) {
        TVal? rem_opt = state.get_prop(remaining_key);
        long remaining = 0;
        if (try rv = rem_opt) {
            if (rv.is_fastint()) remaining = rv.get_fastint();
        }
        remaining -= 1;
        TVal new_rem; new_rem.set_fastint(remaining);
        state.put_prop(remaining_key, new_rem, hobject::PROP_FLAGS_WEC);

        if (remaining == 0 && outer_key != null) {
            TVal? outer_opt = state.get_prop(outer_key);
            HObject* outer = null;
            if (try ov = outer_opt) {
                if (ov.is_object() && ov.get_heapptr() != null) outer = (HObject*)ov.get_heapptr();
            }
            if (outer != null && arr_key != null) {
                TVal arr_val;
                TVal? arr_opt2 = state.get_prop(arr_key);
                if (try av2 = arr_opt2) {
                    arr_val = av2;
                } else {
                    arr_val.set_undefined();
                }
                // Per spec: Call(resultCapability.[[Resolve]], «valuesArray»).
                // Settlement is handled by capability_invoke below — see
                // the detailed comment in builtin_promise_race_resolve_element.
                capability_invoke(heap, ctx.vm, state, &arr_val, true, ctx.this_val);
                // Drain microtasks inline so combinator-result checks
                // (e.g. test262 "call-resolve-element") see the outer
                // settled and any executor callback fired.
                if (!heap.microtask_draining) {
                    heap.drain_microtasks(ctx.vm);
                }
            }
        }
    }
}

/// Promise.allSettled per-element reject handler.
/// Creates {status: "rejected", reason: x} at result[idx], decrements
/// remaining, settles outer when remaining reaches 0.
fn void builtin_promise_allsettled_reject_element(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    if (ctx.callee_obj == null) return;

    // Per spec §27.2.4.4.3 step 1-3: alreadyCalled guard.
    HString* ac_key = builtin_intern_string(heap, "\xFFalreadyCalled");
    if (ac_key != null) {
        if (try acv = ctx.callee_obj.get_prop(ac_key)) {
            if (acv.is_boolean() && acv.get_boolean()) { ctx.result.set_undefined(); return; }
        }
        TVal ac_true; ac_true.set_boolean(true);
        ctx.callee_obj.put_prop(ac_key, ac_true, hobject::PROP_FLAGS_WEC);
    }

    HString* state_key = builtin_intern_string(heap, "\xFFstate");
    HString* idx_key = builtin_intern_string(heap, "\xFFidx");
    HString* arr_key = builtin_intern_string(heap, "\xFFarr");
    HString* remaining_key = builtin_intern_string(heap, "\xFFremaining");
    HString* outer_key = builtin_intern_string(heap, "\xFFouter");
    if (state_key == null || idx_key == null) return;

    TVal? state_opt = ctx.callee_obj.get_prop(state_key);
    HObject* state = null;
    if (try sv = state_opt) {
        if (sv.is_object() && sv.get_heapptr() != null) state = (HObject*)sv.get_heapptr();
    }
    if (state == null) return;

    TVal? idx_opt = ctx.callee_obj.get_prop(idx_key);
    usz idx = 0;
    if (try iv = idx_opt) {
        if (iv.is_fastint()) idx = (usz)iv.get_fastint();
    }

    TVal reason;
    reason.set_undefined();
    if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];

    HObject*? result_obj_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (try result_obj = result_obj_raw) {
        result_obj.prototype = heap.object_proto;
        HString* status_key = builtin_intern_string(heap, "status");
        HString* reason_key = builtin_intern_string(heap, "reason");
        TVal rejected_status;
        rejected_status.set_string(builtin_intern_string(heap, "rejected"));
        if (status_key != null) result_obj.put_prop(status_key, rejected_status, hobject::PROP_FLAGS_WEC);
        if (reason_key != null) result_obj.put_prop(reason_key, reason, hobject::PROP_FLAGS_WEC);
        TVal result_tv;
        result_tv.set_object(result_obj);

        if (arr_key != null) {
            TVal? arr_opt = state.get_prop(arr_key);
            HObject* arr = null;
            if (try av = arr_opt) {
                if (av.is_object() && av.get_heapptr() != null) arr = (HObject*)av.get_heapptr();
            }
            if (arr != null) {
                arr.set_array_idx((uint)idx, result_tv);
                if ((uint)idx + 1 > *arr.array_len_ptr()) {
                    array_set_length(arr, (uint)idx + 1, heap);
                }
            }
        }
    }

    if (remaining_key != null) {
        TVal? rem_opt = state.get_prop(remaining_key);
        long remaining = 0;
        if (try rv = rem_opt) {
            if (rv.is_fastint()) remaining = rv.get_fastint();
        }
        remaining -= 1;
        TVal new_rem; new_rem.set_fastint(remaining);
        state.put_prop(remaining_key, new_rem, hobject::PROP_FLAGS_WEC);

        if (remaining == 0 && outer_key != null) {
            TVal? outer_opt = state.get_prop(outer_key);
            HObject* outer = null;
            if (try ov = outer_opt) {
                if (ov.is_object() && ov.get_heapptr() != null) outer = (HObject*)ov.get_heapptr();
            }
            if (outer != null && arr_key != null) {
                TVal arr_val;
                TVal? arr_opt2 = state.get_prop(arr_key);
                if (try av2 = arr_opt2) {
                    arr_val = av2;
                } else {
                    arr_val.set_undefined();
                }
                // Per spec: Call(resultCapability.[[Resolve]], «valuesArray»).
                // Settlement is handled by capability_invoke below — see
                // the detailed comment in builtin_promise_race_resolve_element.
                capability_invoke(heap, ctx.vm, state, &arr_val, true, ctx.this_val);
                if (!heap.microtask_draining) {
                    heap.drain_microtasks(ctx.vm);
                }
            }
        }
    }
}

// ============================================================================
// Promise.any element-tracking helpers (ES2021 §25.6.4.3)
//
// First-fulfill-wins: when an element fulfills, settle outer with the value
// immediately. When an element rejects, store the reason. If all elements
// reject, settle outer with an AggregateError holding the reasons.
//
// Shared state:
//   \xFFouter       — outer promise
//   \xFFerrors      — errors array (rejection reasons in iteration order)
//   \xFFremaining   — pending count (decremented on reject; if 0, all rejected)
//   \xFFrejected    — "settled" flag (any fulfill wins immediately)
// ============================================================================

/// Promise.any per-element fulfill handler (first-fulfill-wins).
/// Settles the outer promise with the value, ignoring subsequent events.
fn void builtin_promise_any_resolve_element(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    if (ctx.callee_obj == null) return;

    // Per §27.2.4.3.1: unlike Promise.all/race, Promise.any's resolve
    // element functions have NO [[AlreadyCalled]] guard — they forward
    // directly to resultCapability.[[Resolve]] on every invocation. A
    // thenable is free to call its resolver multiple times; each call
    // re-invokes the (idempotent, since the promise settles once) outer
    // resolve. See resolve-from-same-thenable.js.
    HString* state_key = builtin_intern_string(heap, "\xFFstate");
    HString* outer_key = builtin_intern_string(heap, "\xFFouter");
    if (state_key == null) return;

    TVal? state_opt = ctx.callee_obj.get_prop(state_key);
    HObject* state = null;
    if (try sv = state_opt) {
        if (sv.is_object() && sv.get_heapptr() != null) state = (HObject*)sv.get_heapptr();
    }
    if (state == null) return;

    TVal value;
    value.set_undefined();
    if (ctx.argc >= 1) value = ctx.regs[ctx.base_reg];

    if (outer_key != null) {
        TVal? outer_opt = state.get_prop(outer_key);
        HObject* outer = null;
        if (try ov = outer_opt) {
            if (ov.is_object() && ov.get_heapptr() != null) outer = (HObject*)ov.get_heapptr();
        }
        if (outer != null) {
            // Settlement is handled by capability_invoke below (cap_resolve
            // IS builtin_promise_resolve_callback for the default constructor,
            // which runs the full Promise Resolve Function procedure). Calling
            // promise_resolve_with_value here too would double-settle when C
            // is a custom constructor whose resolve/reject are independent of
            // `outer` (e.g. the constructor explicitly returns a different
            // Promise object) — the direct settle would race the custom
            // resolve function and could pre-empt it (including swallowing
            // its own throw, which must instead reject via the capability).
            capability_invoke(heap, ctx.vm, state, &value, true, ctx.this_val);
            if (!heap.microtask_draining) {
                heap.drain_microtasks(ctx.vm);
            }
        }
    }
}

/// Promise.any per-element reject handler.
/// Stores reason in errors[idx], decrements remaining. If remaining hits 0,
/// settle outer with an AggregateError(errors).
fn void builtin_promise_any_reject_element(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    if (ctx.callee_obj == null) return;

    // Per spec §27.2.4.2.2 step 1-3: alreadyCalled guard.
    HString* ac_key = builtin_intern_string(heap, "\xFFalreadyCalled");
    if (ac_key != null) {
        if (try acv = ctx.callee_obj.get_prop(ac_key)) {
            if (acv.is_boolean() && acv.get_boolean()) { ctx.result.set_undefined(); return; }
        }
        TVal ac_true; ac_true.set_boolean(true);
        ctx.callee_obj.put_prop(ac_key, ac_true, hobject::PROP_FLAGS_WEC);
    }

    HString* state_key = builtin_intern_string(heap, "\xFFstate");
    HString* idx_key = builtin_intern_string(heap, "\xFFidx");
    HString* errors_key = builtin_intern_string(heap, "\xFFerrors");
    HString* remaining_key = builtin_intern_string(heap, "\xFFremaining");
    HString* outer_key = builtin_intern_string(heap, "\xFFouter");
    HString* rej_key = builtin_intern_string(heap, "\xFFrejected");
    if (state_key == null || idx_key == null) return;

    TVal? state_opt = ctx.callee_obj.get_prop(state_key);
    HObject* state = null;
    if (try sv = state_opt) {
        if (sv.is_object() && sv.get_heapptr() != null) state = (HObject*)sv.get_heapptr();
    }
    if (state == null) return;

    // If a fulfill has already settled the outer, ignore late rejections
    bool already_settled = false;
    if (rej_key != null) {
        TVal? rej_opt = state.get_prop(rej_key);
        if (try rj = rej_opt) {
            if (rj.is_boolean() && rj.get_boolean()) already_settled = true;
        }
    }
    if (already_settled) return;

    TVal? idx_opt = ctx.callee_obj.get_prop(idx_key);
    usz idx = 0;
    if (try iv = idx_opt) {
        if (iv.is_fastint()) idx = (usz)iv.get_fastint();
    }

    TVal reason;
    reason.set_undefined();
    if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];

    // Store reason at errors[idx]
    if (errors_key != null) {
        TVal? errors_opt = state.get_prop(errors_key);
        HObject* errors_arr = null;
        if (try ev = errors_opt) {
            if (ev.is_object() && ev.get_heapptr() != null) errors_arr = (HObject*)ev.get_heapptr();
        }
        if (errors_arr != null) {
            errors_arr.set_array_idx((uint)idx, reason);
            if ((uint)idx + 1 > *errors_arr.array_len_ptr()) {
                array_set_length(errors_arr, (uint)idx + 1, heap);
            }
        }
    }

    // Decrement remaining
    if (remaining_key != null) {
        TVal? rem_opt = state.get_prop(remaining_key);
        long remaining = 0;
        if (try rv = rem_opt) {
            if (rv.is_fastint()) remaining = rv.get_fastint();
        }
        remaining -= 1;
        TVal new_rem; new_rem.set_fastint(remaining);
        state.put_prop(remaining_key, new_rem, hobject::PROP_FLAGS_WEC);

        if (remaining == 0 && outer_key != null) {
            // All rejected — settle outer with AggregateError
            TVal? outer_opt = state.get_prop(outer_key);
            HObject* outer = null;
            if (try ov = outer_opt) {
                if (ov.is_object() && ov.get_heapptr() != null) outer = (HObject*)ov.get_heapptr();
            }
            if (outer != null) {
                TVal errors_val;
                if (errors_key != null) {
                    TVal? ev_opt = state.get_prop(errors_key);
                    if (try ev2 = ev_opt) {
                        errors_val = ev2;
                    } else {
                        errors_val.set_undefined();
                    }
                } else {
                    errors_val.set_undefined();
                }

                HString* msg = builtin_intern_string(heap, "All promises were rejected");
                TVal msg_tv;
                msg_tv.set_string(msg);

                HObject*? agg_raw = heap.alloc_object(hobject::ObjClass.ERROR);
                TVal agg_tv;
                agg_tv.set_undefined();
                if (try agg = agg_raw) {
                    agg.prototype = heap.aggregate_err_proto;
                    HString* errors_prop_key = builtin_intern_string(heap, "errors");
                    if (errors_prop_key != null) {
                        agg.put_prop(errors_prop_key, errors_val, hobject::PROP_FLAGS_WEC);
                    }
                    HString* msg_key = builtin_intern_string(heap, "message");
                    if (msg_key != null) {
                        agg.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                    }
                    agg_tv.set_object(agg);
                }
                promise_settle(outer, PROMISE_REJECTED, &agg_tv, heap);
                promise_trigger_reactions(outer, heap, ctx.vm);
                capability_invoke(heap, ctx.vm, state, &agg_tv, false, ctx.this_val);
                if (!heap.microtask_draining) {
                    heap.drain_microtasks(ctx.vm);
                }
            }
        }
    }
}

// ============================================================================
// Shared iterator helpers for Promise combinators (ES2021 §27.2.4.x)
//
// GetIterator(iterable): call iterable[Symbol.iterator]() → iterator object.
// IteratorNext(iterator): call iterator.next() → {done, value} record.
// IteratorClose(iterator): call iterator.return() swallowing its result.
//
// These helpers set heap.has_error / ctx.should_throw on failure so callers
// can propagate abrupt completions and close the iterator as required.
// ============================================================================

/// ES2021 §10.1.8 OrdinaryGet — Get(O, P) with full accessor-getter invocation.
/// On success: *out is the property value and the function returns true.
/// On failure (getter throws, allocation error): heap.has_error is set and
/// the function returns false.  If the property does not exist, *out is set
/// to undefined and the function returns true.
fn bool promise_object_get(Heap* heap, void* vm, HObject* obj, HString* key, TVal* out) {
    out.set_undefined();
    if (obj == null || key == null) return true;
    hobject::PropLookupResult res = obj.get_prop_or_accessor_proto(key, true);
    if (res.kind == hobject::PropLookupKind.PROP_DATA) {
        *out = res.data_val;
        return true;
    }
    if (res.kind == hobject::PropLookupKind.PROP_NOT_FOUND) {
        return true;
    }
    // PROP_ACCESSOR — call the getter with `this` = obj.
    TVal getter_fn = res.acc.accessor_fn;
    if (getter_fn.is_undefined() || getter_fn.is_null()) {
        // Accessor with no getter: return undefined.
        return true;
    }
    bool getter_callable = getter_fn.is_lightfunc() ||
        (getter_fn.is_object() && getter_fn.get_heapptr() != null &&
         ((HObject*)getter_fn.get_heapptr()).is_callable());
    if (!getter_callable) return true;
    if (heap.call_fn == null || vm == null) return true;
    TVal this_tv; this_tv.set_object(obj);
    TVal result = heap.call_fn(vm, getter_fn, null, 0, this_tv);
    if (heap.has_error) return false;
    *out = result;
    return true;
}

/// Call iterable[Symbol.iterator]() and return the resulting iterator object.
/// On success *out_iter is the iterator and the function returns true.
/// On failure heap.has_error is set and the function returns false.
fn bool promise_get_iterator(Heap* heap, void* vm, TVal iterable, TVal* out_iter) {
    HString* iter_sym = ensure_iterator_symbol(heap);
    if (iter_sym == null) return false;

    TVal iter_method;
    iter_method.set_undefined();
    bool found = false;
    if (iterable.is_object() && iterable.get_heapptr() != null) {
        HObject* iterable_obj = (HObject*)iterable.get_heapptr();
        hobject::PropLookupResult res = iterable_obj.get_prop_or_accessor_proto(iter_sym, true);
        if (res.kind == hobject::PropLookupKind.PROP_DATA) {
            iter_method = res.data_val;
            found = true;
        } else if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
            TVal getter = res.acc.accessor_fn;
            if (!getter.is_undefined() && !getter.is_null()) {
                if (heap.call_fn == null || vm == null) return false;
                iter_method = heap.call_fn(vm, getter, null, 0, iterable);
                if (heap.has_error) return false;
                found = true;
            }
        }
    } else if (iterable.is_string() && iterable.get_heapptr() != null
               && ((HString*)iterable.get_heapptr()).is_symbol() && heap.symbol_proto != null) {
        // Symbols share the STRING tag internally — Symbol.prototype has no
        // @@iterator, so GetIterator must fail (found stays false) rather
        // than falling through to String.prototype's iterator below.
        hobject::PropLookupResult res = heap.symbol_proto.get_prop_or_accessor_proto(iter_sym, true);
        if (res.kind == hobject::PropLookupKind.PROP_DATA) {
            iter_method = res.data_val;
            found = true;
        } else if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
            TVal getter = res.acc.accessor_fn;
            if (!getter.is_undefined() && !getter.is_null()) {
                if (heap.call_fn == null || vm == null) return false;
                iter_method = heap.call_fn(vm, getter, null, 0, iterable);
                if (heap.has_error) return false;
                found = true;
            }
        }
    } else if (iterable.is_string() && heap.string_proto != null) {
        hobject::PropLookupResult res = heap.string_proto.get_prop_or_accessor_proto(iter_sym, true);
        if (res.kind == hobject::PropLookupKind.PROP_DATA) {
            iter_method = res.data_val;
            found = true;
        } else if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
            TVal getter = res.acc.accessor_fn;
            if (!getter.is_undefined() && !getter.is_null()) {
                if (heap.call_fn == null || vm == null) return false;
                iter_method = heap.call_fn(vm, getter, null, 0, iterable);
                if (heap.has_error) return false;
                found = true;
            }
        }
    } else if (iterable.is_boolean() && heap.bool_proto != null) {
        if (try bm = heap.bool_proto.get_prop(iter_sym)) { iter_method = bm; found = true; }
    } else if ((iterable.is_number() || iterable.is_fastint()) && heap.number_proto != null) {
        if (try nm = heap.number_proto.get_prop(iter_sym)) { iter_method = nm; found = true; }
    }

    bool iter_callable = found && (iter_method.is_lightfunc() ||
        (iter_method.is_object() && iter_method.get_heapptr() != null &&
         ((HObject*)iter_method.get_heapptr()).is_callable()));
    if (!iter_callable) {
        // ES2022 §7.4.2 GetIterator: if method is undefined/missing/not
        // callable, throw a TypeError ("is not iterable") rather than
        // silently signaling failure with no error value — callers reject
        // the combinator's capability with heap.error_value on failure.
        species_throw_typeerror(heap, "is not iterable");
        return false;
    }

    if (heap.call_fn == null || vm == null) return false;
    TVal result = heap.call_fn(vm, iter_method, null, 0, iterable);
    if (heap.has_error) return false;
    if (!result.is_object() || result.get_heapptr() == null) {
        species_throw_typeerror(heap, "Result of the Symbol.iterator method is not an object");
        return false;
    }
    *out_iter = result;
    return true;
}

/// Clear all error-propagation channels after a caller has captured
/// `heap.error_value` into its own local completion. `heap.call_fn`
/// propagates a callee's uncaught throw on three channels simultaneously
/// (heap.has_error/heap.error_value, vm.throw_pending/vm.throw_value, and
/// vm.has_error — see vm_call_fn_impl); clearing only some of them leaves
/// the others to resurface as a spurious exception (e.g. the CALL opcode
/// checking vm.has_error) the next time the interpreter or another
/// reentrant heap.call_fn call runs after this builtin returns.
fn void promise_clear_error_channels(Heap* heap, void* vm) {
    heap.has_error = false;
    Vm* v = (Vm*)vm;
    if (v != null) {
        v.throw_pending = false;
        v.has_error = false;
    }
}

/// Call iterator.next() and return the result record.
/// On success *out_result is the {done,value} object and the function returns true.
/// On failure heap.has_error is set and the function returns false.
fn bool promise_iterator_step(Heap* heap, void* vm, TVal iterator, TVal* out_result) {
    if (!iterator.is_object() || iterator.get_heapptr() == null) return false;
    HObject* iter_obj = (HObject*)iterator.get_heapptr();
    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key == null) return false;
    TVal? next_opt = iter_obj.get_prop_proto(next_key);
    TVal next_method;
    if (try nm = next_opt) { next_method = nm; } else { return false; }
    bool next_callable = next_method.is_lightfunc() ||
        (next_method.is_object() && next_method.get_heapptr() != null &&
         ((HObject*)next_method.get_heapptr()).is_callable());
    if (!next_callable) return false;

    if (heap.call_fn == null || vm == null) return false;
    TVal step = heap.call_fn(vm, next_method, null, 0, iterator);
    if (heap.has_error) return false;
    if (!step.is_object() || step.get_heapptr() == null) return false;
    *out_result = step;
    return true;
}

/// Call iterator.return() if present, swallowing any error (IteratorClose).
/// The completion passed as argument is the abrupt completion to eventually
/// surface — the iterator.return() result is ignored per spec.
/// IteratorClose(iteratorRecord, completion) — ES2022 §7.4.11.
/// `completion` is the in-flight abrupt completion that triggered the close;
/// when non-null it is updated in place if GetMethod(iterator, "return")
/// itself throws (step 3/5: "if innerResult is a throw completion, return ?
/// innerResult" — replacing, not just accompanying, the original completion).
/// A successful or non-existent return() leaves `completion` untouched and
/// its own result/error is otherwise discarded, per spec.
fn void promise_iterator_close(Heap* heap, void* vm, TVal iterator, TVal* completion = null) {
    if (!iterator.is_object() || iterator.get_heapptr() == null) return;
    HObject* iter_obj = (HObject*)iterator.get_heapptr();
    HString* return_key = builtin_intern_string(heap, "return");
    if (return_key == null) return;
    TVal? return_opt = iter_obj.get_prop_proto(return_key);
    if (catch err = return_opt) return;
    TVal return_method = return_opt;
    if (return_method.is_undefined() || return_method.is_null()) return;
    bool callable = return_method.is_lightfunc() ||
        (return_method.is_object() && return_method.get_heapptr() != null &&
         ((HObject*)return_method.get_heapptr()).is_callable());
    if (!callable) {
        if (completion != null) {
            species_throw_typeerror(heap, "'return' method is not a function");
            if (heap.has_error) {
                *completion = heap.error_value;
                promise_clear_error_channels(heap, vm);
            }
        }
        return;
    }
    if (heap.call_fn == null || vm == null) return;
    heap.call_fn(vm, return_method, null, 0, iterator);
    // Per spec, swallow the error from return() itself.
    promise_clear_error_channels(heap, vm);
}

/// Reject the promise capability identified by `cap_reject_tv` with `reason`.
/// Used by combinators to handle IfAbruptRejectPromise.
fn void promise_combinator_reject(Heap* heap, void* vm, TVal cap_reject_tv, TVal* reason) {
    if (cap_reject_tv.is_undefined()) return;
    bool callable = cap_reject_tv.is_lightfunc() ||
        (cap_reject_tv.is_object() && cap_reject_tv.get_heapptr() != null &&
         ((HObject*)cap_reject_tv.get_heapptr()).is_callable());
    if (!callable) return;
    if (heap.call_fn == null || vm == null) return;
    TVal undef; undef.set_undefined();
    heap.call_fn(vm, cap_reject_tv, reason, 1, undef);
    promise_clear_error_channels(heap, vm);
}

/// Invoke nextPromise.then(onFulfilled, onRejected) per spec step.
/// Returns true on success; on failure sets heap.has_error. When `out_result`
/// is non-null, receives the value returned by the `.then()` call itself
/// (the newly created downstream promise) — needed by callers whose own
/// return value must be that promise (e.g. ThenFinally/CatchFinallyFunctions
/// returning `? Invoke(promise, "then", « valueThunk »)` verbatim), as
/// opposed to combinator callers that only care about success/failure.
fn bool promise_invoke_then(Heap* heap, void* vm, TVal next_promise,
                             TVal on_fulfilled, TVal on_rejected, TVal* out_result = null) {
    if (!next_promise.is_object() || next_promise.get_heapptr() == null) return false;
    HObject* np_obj = (HObject*)next_promise.get_heapptr();
    HString* then_key = builtin_intern_string(heap, "then");
    if (then_key == null) return false;

    // Get(nextPromise, "then") — full accessor-getter invocation, may throw
    TVal then_method;
    if (!promise_object_get(heap, vm, np_obj, then_key, &then_method)) {
        // heap.has_error was set by the getter throw
        return false;
    }

    // Call(then, nextPromise, [onFulfilled, onRejected]) — may throw
    bool then_callable = then_method.is_lightfunc() ||
        (then_method.is_object() && then_method.get_heapptr() != null &&
         ((HObject*)then_method.get_heapptr()).is_callable());
    if (!then_callable) return true; // non-callable then: no-op per spec (non-thenable)

    if (heap.call_fn == null || vm == null) return true;
    TVal[2] then_args;
    then_args[0] = on_fulfilled;
    then_args[1] = on_rejected;
    TVal then_ret = heap.call_fn(vm, then_method, &then_args[0], 2, next_promise);
    if (heap.has_error) return false;
    if (out_result != null) *out_result = then_ret;
    return true;
}

// ============================================================================
// Shared combinator body — GetIterator + loop.
//
// All four combinators share the same outer algorithm:
//   1. C = this; NewPromiseCapability(C) → [cap_promise, cap_resolve, cap_reject]
//   2. promiseResolve = Get(C, "resolve"); check callable once.
//   3. GetIterator(iterable) → iterator; if abrupt → reject capability, return cap.
//   4. Loop IteratorNext:
//      a. If done: for all/allSettled check remaining; for race/any cap_reject.
//      b. nextPromise = Call(promiseResolve, C, [value]); abrupt → close+reject.
//      c. Invoke(nextPromise, "then", [onFulfilled, cap_reject]); abrupt → close+reject.
//   5. Return cap_promise.
//
// Each combinator provides its own element callbacks and post-loop empty handling.
// ============================================================================

// ============================================================================
// Promise.all(iterable) — ES6 §25.4.4.1
// ============================================================================

fn void builtin_promise_all(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal iterable;
    iterable.set_undefined();
    if (ctx.argc >= 1) iterable = ctx.regs[ctx.base_reg];

    // Step 1: C = this value
    TVal this_ctor_val = ctx.regs[ctx.base_reg - 1];
    if (!this_ctor_val.is_object() || this_ctor_val.get_heapptr() == null) {
        promise_throw_typeerror(ctx, "Promise.all called on non-object");
        return;
    }

    // Step 2: NewPromiseCapability(C)
    HObject*? hole_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err_h = hole_raw) { ctx.result.set_undefined(); return; }
    HObject* hole = hole_raw;
    hole.prototype = heap.object_proto;
    if (!promise_new_capability_full(heap, ctx.vm, this_ctor_val, hole)) {
        promise_throw_capability_failure(ctx, hole);
        return;
    }
    TVal cap_resolve_tv = promise_hole_get_resolve(heap, hole);
    TVal cap_reject_tv  = promise_hole_get_reject(heap, hole);
    TVal cap_promise_tv = promise_hole_get_promise(heap, hole);
    HObject* promise    = null;
    if (cap_promise_tv.is_object() && cap_promise_tv.get_heapptr() != null) {
        promise = (HObject*)cap_promise_tv.get_heapptr();
    }

    // Step 3: promiseResolve = Get(C, "resolve") — once before iteration
    HString* resolve_key = builtin_intern_string(heap, "resolve");
    TVal resolve_fn; resolve_fn.set_undefined();
    if (resolve_key != null && this_ctor_val.is_object()) {
        HObject* ctor_obj = (HObject*)this_ctor_val.get_heapptr();
        // Use full Get semantics so accessor getters on C.resolve are invoked.
        // On getter throw, heap.has_error is set — checked below.
        promise_object_get(heap, ctx.vm, ctor_obj, resolve_key, &resolve_fn);
    }
    if (heap.has_error) {
        TVal err_val = heap.error_value;
        heap.has_error = false;
        promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
        if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); }
        return;
    }
    bool resolve_callable = is_callable_tval(resolve_fn);
    if (!resolve_callable) {
        // TypeError: C.resolve is not callable
        HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
        TVal err_tv; err_tv.set_undefined();
        if (try err_obj = err_raw) {
            err_obj.prototype = heap.type_err_proto;
            HString* msg_key = builtin_intern_string(heap, "message");
            HString* msg_str = builtin_intern_string(heap, "Promise.resolve is not a function");
            if (msg_key != null && msg_str != null) {
                TVal msg_tv; msg_tv.set_string(msg_str);
                err_obj.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            }
            err_tv.set_object(err_obj);
        }
        promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_tv);
        if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); }
        return;
    }

    // Step 4: GetIterator
    TVal iterator; iterator.set_undefined();
    bool have_iter = promise_get_iterator(heap, ctx.vm, iterable, &iterator);
    if (!have_iter) {
        TVal err_val; err_val.set_undefined();
        if (heap.has_error) { err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm); }
        promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
        if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); }
        return;
    }

    // Allocate result array and shared state
    HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err_arr = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    arr.prototype = heap.array_proto;

    // remaining starts at 1 (the "extra +1" trick so the loop body can do
    // remaining-- without worrying about premature settle on the first element).
    // We decrement once after the loop.
    usz remaining = 1;
    usz idx = 0;

    HObject*? state_raw = promise_create_all_state(heap, promise, arr, remaining,
                                                    cap_resolve_tv, cap_reject_tv);
    if (catch err_s = state_raw) { ctx.result.set_undefined(); return; }
    HObject* state = state_raw;

    HString* remaining_key = builtin_intern_string(heap, "\xFFremaining");

    bool iter_done = false;
    while (!iter_done) {
        // IteratorStep
        TVal step_result; step_result.set_undefined();
        if (!promise_iterator_step(heap, ctx.vm, iterator, &step_result)) {
            // IteratorStep abrupt: per spec, iteratorRecord.[[done]] is set to true
            // and ReturnIfAbrupt is applied WITHOUT calling IteratorClose first.
            if (heap.has_error) {
                TVal err_val = heap.error_value;
                promise_clear_error_channels(heap, ctx.vm);
                promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
            }
            if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); }
            return;
        }
        HObject* step_obj = (HObject*)step_result.get_heapptr();
        HString* done_key = builtin_intern_string(heap, "done");
        HString* value_key = builtin_intern_string(heap, "value");
        // IteratorComplete: Get(result, "done") — full Get with accessor invocation.
        bool done = false;
        if (done_key != null) {
            TVal dv_done; dv_done.set_undefined();
            if (!promise_object_get(heap, ctx.vm, step_obj, done_key, &dv_done)) {
                // IteratorComplete abrupt: iteratorRecord.[[done]] = true, no IteratorClose.
                TVal err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm);
                promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
                if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); }
                return;
            }
            done = builtin_to_boolean(&dv_done);
        }
        if (done) { iter_done = true; break; }

        // IteratorValue: Get(result, "value") — full Get with accessor invocation.
        TVal next_value; next_value.set_undefined();
        if (value_key != null) {
            if (!promise_object_get(heap, ctx.vm, step_obj, value_key, &next_value)) {
                // IteratorValue abrupt: iteratorRecord.[[done]] = true, no IteratorClose.
                TVal err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm);
                promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
                if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); }
                return;
            }
        }

        // Call promiseResolve(value) → nextPromise
        TVal[1] res_args;
        res_args[0] = next_value;
        TVal next_promise = heap.call_fn(ctx.vm, resolve_fn, &res_args[0], 1, this_ctor_val);
        if (heap.has_error) {
            TVal err_val = heap.error_value;
            heap.has_error = false;
            promise_iterator_close(heap, ctx.vm, iterator, &err_val);
            promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
            if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); }
            return;
        }

        // Create element callbacks
        HObject*? fulfill_raw = promise_create_element_callback(heap, Builtin.PROMISE_ALL_RESOLVE_ELEMENT.ordinal, state, idx);
        HObject*? reject_raw  = promise_create_element_callback(heap, Builtin.PROMISE_ALL_REJECT_ELEMENT.ordinal, state, idx);
        if (catch ef = fulfill_raw) {
            promise_iterator_close(heap, ctx.vm, iterator);
            if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
        }
        if (catch er = reject_raw) {
            promise_iterator_close(heap, ctx.vm, iterator);
            if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
        }
        HObject* fulfill_fn = fulfill_raw;
        HObject* reject_fn  = reject_raw;

        TVal fulfill_tv; fulfill_tv.set_object(fulfill_fn);
        TVal reject_tv;  reject_tv.set_object(reject_fn);

        // Per ES2020 §27.2.4.1.1 PerformPromiseAll step 6.d.xi/xii: the
        // remainingElementsCount increment happens BEFORE Invoke(nextPromise,
        // "then", ...) — not after. A thenable whose .then() calls its
        // onFulfilled synchronously (like a same-tick resolve) must observe
        // the incremented count so its decrement doesn't race against this
        // iteration's own bookkeeping.
        //
        // Read-modify-write `state`'s live copy directly (not a local
        // counter written back at the end): a prior element's .then() may
        // have already fired synchronously and decremented state's copy
        // during an earlier iteration of this same loop, so a stale local
        // increment-then-overwrite would clobber that decrement.
        idx += 1;
        if (remaining_key != null) {
            long live_remaining = (long)remaining;
            if (try rv3 = state.get_prop(remaining_key)) {
                if (rv3.is_fastint()) live_remaining = rv3.get_fastint();
            }
            live_remaining += 1;
            TVal rem_tv; rem_tv.set_fastint(live_remaining);
            state.put_prop(remaining_key, rem_tv, hobject::PROP_FLAGS_WEC);
            remaining = (usz)live_remaining;
        } else {
            remaining += 1;
        }

        // Invoke nextPromise.then(fulfill, cap_reject)
        if (!promise_invoke_then(heap, ctx.vm, next_promise, fulfill_tv, cap_reject_tv)) {
            TVal err_val; err_val.set_undefined();
            if (heap.has_error) { err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm); }
            promise_iterator_close(heap, ctx.vm, iterator, &err_val);
            promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
            if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); }
            return;
        }
    }

    // Decrement the initial +1; if remaining reaches 0 here, iterable was empty
    // OR every element already resolved synchronously during the loop above
    // (each such resolution decremented state's live \xFFremaining via
    // builtin_promise_all_resolve_element). Re-read the current value from
    // `state` rather than using this function's local `remaining` — the local
    // only tracks the loop's own increments and goes stale the moment any
    // element callback fires synchronously and decrements state's copy.
    if (remaining_key != null) {
        long live_remaining = (long)remaining;
        if (try rv2 = state.get_prop(remaining_key)) {
            if (rv2.is_fastint()) live_remaining = rv2.get_fastint();
        }
        live_remaining -= 1;
        TVal rem_tv; rem_tv.set_fastint(live_remaining);
        state.put_prop(remaining_key, rem_tv, hobject::PROP_FLAGS_WEC);
        remaining = (usz)live_remaining;
    } else {
        remaining -= 1;
    }
    if (remaining == 0) {
        // Settle with empty array. Per ES6 §27.2.4.5 step 4 / PerformPromiseAll
        // step 6.d.iii.2: this is a Call(resultCapability.[[Resolve]], «valuesArray»),
        // i.e. the full Promise Resolve Function procedure — not a direct
        // FulfillPromise. For the default (non-custom) constructor path,
        // route through promise_resolve_with_value so self-resolution / a
        // poisoned/overridden Array.prototype.then on the values array is
        // honored, same as the custom-capability path already gets via
        // capability_invoke below.
        TVal arr_tv; arr_tv.set_object(arr);
        // Settlement is handled by capability_invoke below — see the
        // detailed comment in builtin_promise_race_resolve_element.
        capability_invoke(heap, ctx.vm, state, &arr_tv, true, ctx.this_val);
        if (!heap.microtask_draining) heap.drain_microtasks(ctx.vm);
    }

    if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); }
}

// ============================================================================
// Promise.allSettled(iterable) — ES2020 §25.6.4.5
// ============================================================================

fn void builtin_promise_allsettled(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal iterable;
    iterable.set_undefined();
    if (ctx.argc >= 1) iterable = ctx.regs[ctx.base_reg];

    TVal this_ctor_val = ctx.regs[ctx.base_reg - 1];
    if (!this_ctor_val.is_object() || this_ctor_val.get_heapptr() == null) {
        promise_throw_typeerror(ctx, "Promise.allSettled called on non-object");
        return;
    }

    HObject*? hole_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err_h = hole_raw) { ctx.result.set_undefined(); return; }
    HObject* hole = hole_raw;
    hole.prototype = heap.object_proto;
    if (!promise_new_capability_full(heap, ctx.vm, this_ctor_val, hole)) {
        promise_throw_capability_failure(ctx, hole);
        return;
    }
    TVal cap_resolve_tv = promise_hole_get_resolve(heap, hole);
    TVal cap_reject_tv  = promise_hole_get_reject(heap, hole);
    TVal cap_promise_tv = promise_hole_get_promise(heap, hole);
    HObject* promise    = null;
    if (cap_promise_tv.is_object() && cap_promise_tv.get_heapptr() != null) {
        promise = (HObject*)cap_promise_tv.get_heapptr();
    }

    HString* resolve_key = builtin_intern_string(heap, "resolve");
    TVal resolve_fn; resolve_fn.set_undefined();
    if (resolve_key != null && this_ctor_val.is_object()) {
        HObject* ctor_obj = (HObject*)this_ctor_val.get_heapptr();
        // Use full Get semantics so accessor getters on C.resolve are invoked.
        // On getter throw, heap.has_error is set — checked below.
        promise_object_get(heap, ctx.vm, ctor_obj, resolve_key, &resolve_fn);
    }
    if (heap.has_error) {
        TVal err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm);
        promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
        if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
    }
    if (!is_callable_tval(resolve_fn)) {
        HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
        TVal err_tv; err_tv.set_undefined();
        if (try err_obj = err_raw) {
            err_obj.prototype = heap.type_err_proto;
            HString* msg_key = builtin_intern_string(heap, "message");
            HString* msg_str = builtin_intern_string(heap, "Promise.resolve is not a function");
            if (msg_key != null && msg_str != null) {
                TVal mt; mt.set_string(msg_str); err_obj.put_prop(msg_key, mt, hobject::PROP_FLAGS_WC);
            }
            err_tv.set_object(err_obj);
        }
        promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_tv);
        if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
    }

    TVal iterator; iterator.set_undefined();
    if (!promise_get_iterator(heap, ctx.vm, iterable, &iterator)) {
        TVal err_val; err_val.set_undefined();
        if (heap.has_error) { err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm); }
        promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
        if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
    }

    HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err_arr = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    arr.prototype = heap.array_proto;

    usz remaining = 1;
    usz idx = 0;

    HObject*? state_raw = promise_create_all_state(heap, promise, arr, remaining,
                                                    cap_resolve_tv, cap_reject_tv);
    if (catch err_s = state_raw) { ctx.result.set_undefined(); return; }
    HObject* state = state_raw;
    HString* remaining_key = builtin_intern_string(heap, "\xFFremaining");

    bool iter_done = false;
    while (!iter_done) {
        TVal step_result; step_result.set_undefined();
        if (!promise_iterator_step(heap, ctx.vm, iterator, &step_result)) {
            // IteratorStep abrupt: per spec, iteratorRecord.[[done]] is set to
            // true and ReturnIfAbrupt is applied WITHOUT calling IteratorClose
            // first (the failure came from next() itself, not from processing
            // its result — ES2022 §7.4.7 IteratorStep step 3).
            if (heap.has_error) {
                TVal err_val = heap.error_value;
                promise_clear_error_channels(heap, ctx.vm);
                promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
            }
            if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
        }
        HObject* step_obj = (HObject*)step_result.get_heapptr();
        HString* done_key = builtin_intern_string(heap, "done");
        HString* value_key = builtin_intern_string(heap, "value");
        // IteratorComplete: Get(result, "done") — full Get with accessor invocation.
        bool done = false;
        if (done_key != null) {
            TVal dv_done; dv_done.set_undefined();
            if (!promise_object_get(heap, ctx.vm, step_obj, done_key, &dv_done)) {
                // IteratorComplete abrupt: iteratorRecord.[[done]] = true, no IteratorClose.
                TVal err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm);
                promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
                if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); }
                return;
            }
            done = builtin_to_boolean(&dv_done);
        }
        if (done) { iter_done = true; break; }

        // IteratorValue: Get(result, "value") — full Get with accessor invocation.
        TVal next_value; next_value.set_undefined();
        if (value_key != null) {
            if (!promise_object_get(heap, ctx.vm, step_obj, value_key, &next_value)) {
                // IteratorValue abrupt: iteratorRecord.[[done]] = true, no IteratorClose.
                TVal err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm);
                promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
                if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); }
                return;
            }
        }

        TVal[1] res_args;
        res_args[0] = next_value;
        TVal next_promise = heap.call_fn(ctx.vm, resolve_fn, &res_args[0], 1, this_ctor_val);
        if (heap.has_error) {
            TVal err_val = heap.error_value;
            promise_clear_error_channels(heap, ctx.vm);
            promise_iterator_close(heap, ctx.vm, iterator, &err_val);
            promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
            if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
        }

        HObject*? fulfill_raw = promise_create_element_callback(heap, Builtin.PROMISE_ALLSETTLED_RESOLVE_ELEMENT.ordinal, state, idx);
        HObject*? reject_raw  = promise_create_element_callback(heap, Builtin.PROMISE_ALLSETTLED_REJECT_ELEMENT.ordinal, state, idx);
        if (catch ef = fulfill_raw) {
            promise_iterator_close(heap, ctx.vm, iterator);
            if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
        }
        if (catch er = reject_raw) {
            promise_iterator_close(heap, ctx.vm, iterator);
            if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
        }
        HObject* fulfill_fn = fulfill_raw;
        HObject* reject_fn  = reject_raw;
        TVal fulfill_tv; fulfill_tv.set_object(fulfill_fn);
        TVal reject_tv;  reject_tv.set_object(reject_fn);

        // Increment before Invoke(nextPromise, "then", ...) — see the
        // matching comment in builtin_promise_all. Read-modify-write state's
        // live copy (not a stale local) since a prior element's .then() may
        // have already fired synchronously during this same loop.
        idx += 1;
        if (remaining_key != null) {
            long live_remaining = (long)remaining;
            if (try rv3 = state.get_prop(remaining_key)) {
                if (rv3.is_fastint()) live_remaining = rv3.get_fastint();
            }
            live_remaining += 1;
            TVal rem_tv; rem_tv.set_fastint(live_remaining);
            state.put_prop(remaining_key, rem_tv, hobject::PROP_FLAGS_WEC);
            remaining = (usz)live_remaining;
        } else {
            remaining += 1;
        }

        if (!promise_invoke_then(heap, ctx.vm, next_promise, fulfill_tv, reject_tv)) {
            TVal err_val; err_val.set_undefined();
            if (heap.has_error) { err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm); }
            promise_iterator_close(heap, ctx.vm, iterator, &err_val);
            promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
            if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
        }
    }

    // Re-read the current value from `state` rather than trusting this
    // function's local `remaining` — see the matching comment in
    // builtin_promise_all for why (synchronous element resolutions during
    // the loop decrement state's live copy, leaving the local stale).
    if (remaining_key != null) {
        long live_remaining = (long)remaining;
        if (try rv2 = state.get_prop(remaining_key)) {
            if (rv2.is_fastint()) live_remaining = rv2.get_fastint();
        }
        live_remaining -= 1;
        TVal rem_tv; rem_tv.set_fastint(live_remaining);
        state.put_prop(remaining_key, rem_tv, hobject::PROP_FLAGS_WEC);
        remaining = (usz)live_remaining;
    } else {
        remaining -= 1;
    }
    if (remaining == 0) {
        // See the matching comment in builtin_promise_all — this is a
        // Call(resultCapability.[[Resolve]], «valuesArray»), so route through
        // the full Promise Resolve Function procedure for the default path.
        TVal arr_tv; arr_tv.set_object(arr);
        // Settlement is handled by capability_invoke below — see the
        // detailed comment in builtin_promise_race_resolve_element.
        capability_invoke(heap, ctx.vm, state, &arr_tv, true, ctx.this_val);
        if (!heap.microtask_draining) heap.drain_microtasks(ctx.vm);
    }

    if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); }
}

// ============================================================================
// Promise.any(iterable) — ES2021 §25.6.4.3
// ============================================================================

fn void builtin_promise_any(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal iterable;
    iterable.set_undefined();
    if (ctx.argc >= 1) iterable = ctx.regs[ctx.base_reg];

    TVal this_ctor_val = ctx.regs[ctx.base_reg - 1];
    if (!this_ctor_val.is_object() || this_ctor_val.get_heapptr() == null) {
        promise_throw_typeerror(ctx, "Promise.any called on non-object");
        return;
    }

    HObject*? hole_raw_any = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err_h = hole_raw_any) { ctx.result.set_undefined(); return; }
    HObject* hole_any = hole_raw_any;
    hole_any.prototype = heap.object_proto;
    if (!promise_new_capability_full(heap, ctx.vm, this_ctor_val, hole_any)) {
        promise_throw_capability_failure(ctx, hole_any);
        return;
    }
    TVal cap_resolve_tv = promise_hole_get_resolve(heap, hole_any);
    TVal cap_reject_tv  = promise_hole_get_reject(heap, hole_any);
    TVal cap_promise_tv = promise_hole_get_promise(heap, hole_any);
    HObject* promise    = null;
    if (cap_promise_tv.is_object() && cap_promise_tv.get_heapptr() != null) {
        promise = (HObject*)cap_promise_tv.get_heapptr();
    }

    HString* resolve_key = builtin_intern_string(heap, "resolve");
    TVal resolve_fn; resolve_fn.set_undefined();
    if (resolve_key != null && this_ctor_val.is_object()) {
        HObject* ctor_obj = (HObject*)this_ctor_val.get_heapptr();
        // Use full Get semantics so accessor getters on C.resolve are invoked.
        // On getter throw, heap.has_error is set — checked below.
        promise_object_get(heap, ctx.vm, ctor_obj, resolve_key, &resolve_fn);
    }
    if (heap.has_error) {
        TVal err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm);
        promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
        if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
    }
    if (!is_callable_tval(resolve_fn)) {
        HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
        TVal err_tv; err_tv.set_undefined();
        if (try err_obj = err_raw) {
            err_obj.prototype = heap.type_err_proto;
            HString* msg_key = builtin_intern_string(heap, "message");
            HString* msg_str = builtin_intern_string(heap, "Promise.resolve is not a function");
            if (msg_key != null && msg_str != null) {
                TVal mt; mt.set_string(msg_str); err_obj.put_prop(msg_key, mt, hobject::PROP_FLAGS_WC);
            }
            err_tv.set_object(err_obj);
        }
        promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_tv);
        if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
    }

    TVal iterator; iterator.set_undefined();
    if (!promise_get_iterator(heap, ctx.vm, iterable, &iterator)) {
        TVal err_val; err_val.set_undefined();
        if (heap.has_error) { err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm); }
        promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
        if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
    }

    // Pre-allocate errors array and shared state for any.
    HObject*? errors_arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    HObject* errors_arr = null;
    if (try arr = errors_arr_raw) {
        arr.prototype = heap.array_proto;
        errors_arr = arr;
    }

    HObject*? state_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    HObject* state = null;
    if (try sr = state_raw) {
        sr.prototype = heap.object_proto;
        HString* outer_key    = builtin_intern_string(heap, "\xFFouter");
        HString* errors_key   = builtin_intern_string(heap, "\xFFerrors");
        HString* remaining_key = builtin_intern_string(heap, "\xFFremaining");
        HString* rejected_key = builtin_intern_string(heap, "\xFFrejected");
        HString* cap_r_key    = builtin_intern_string(heap, "\xFFcap_resolve");
        HString* cap_j_key    = builtin_intern_string(heap, "\xFFcap_reject");
        if (outer_key != null && promise != null) {
            TVal outer_tv; outer_tv.set_object(promise);
            sr.put_prop(outer_key, outer_tv, hobject::PROP_FLAGS_WEC);
        }
        if (errors_key != null && errors_arr != null) {
            TVal errors_tv; errors_tv.set_object(errors_arr);
            sr.put_prop(errors_key, errors_tv, hobject::PROP_FLAGS_WEC);
        }
        // remaining starts at 1 (decremented after loop)
        if (remaining_key != null) {
            TVal rem_tv; rem_tv.set_fastint(1);
            sr.put_prop(remaining_key, rem_tv, hobject::PROP_FLAGS_WEC);
        }
        if (rejected_key != null) {
            TVal rej_tv; rej_tv.set_boolean(false);
            sr.put_prop(rejected_key, rej_tv, hobject::PROP_FLAGS_WEC);
        }
        if (cap_r_key != null) sr.put_prop(cap_r_key, cap_resolve_tv, hobject::PROP_FLAGS_WEC);
        if (cap_j_key != null) sr.put_prop(cap_j_key, cap_reject_tv, hobject::PROP_FLAGS_WEC);
        state = sr;
    }
    if (state == null) { ctx.result.set_undefined(); return; }

    HString* remaining_key = builtin_intern_string(heap, "\xFFremaining");
    usz remaining = 1;
    usz idx = 0;

    bool iter_done = false;
    while (!iter_done) {
        TVal step_result; step_result.set_undefined();
        if (!promise_iterator_step(heap, ctx.vm, iterator, &step_result)) {
            // IteratorStep abrupt: per spec, iteratorRecord.[[done]] is set to
            // true and ReturnIfAbrupt is applied WITHOUT calling IteratorClose
            // first (the failure came from next() itself, not from processing
            // its result — ES2022 §7.4.7 IteratorStep step 3).
            if (heap.has_error) {
                TVal err_val = heap.error_value;
                promise_clear_error_channels(heap, ctx.vm);
                promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
            }
            if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
        }
        HObject* step_obj = (HObject*)step_result.get_heapptr();
        HString* done_key = builtin_intern_string(heap, "done");
        HString* value_key = builtin_intern_string(heap, "value");
        // IteratorComplete: Get(result, "done") — full Get with accessor invocation.
        bool done = false;
        if (done_key != null) {
            TVal dv_done; dv_done.set_undefined();
            if (!promise_object_get(heap, ctx.vm, step_obj, done_key, &dv_done)) {
                // IteratorComplete abrupt: iteratorRecord.[[done]] = true, no IteratorClose.
                TVal err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm);
                promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
                if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); }
                return;
            }
            done = builtin_to_boolean(&dv_done);
        }
        if (done) { iter_done = true; break; }

        // IteratorValue: Get(result, "value") — full Get with accessor invocation.
        TVal next_value; next_value.set_undefined();
        if (value_key != null) {
            if (!promise_object_get(heap, ctx.vm, step_obj, value_key, &next_value)) {
                // IteratorValue abrupt: iteratorRecord.[[done]] = true, no IteratorClose.
                TVal err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm);
                promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
                if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); }
                return;
            }
        }

        TVal[1] res_args;
        res_args[0] = next_value;
        TVal next_promise = heap.call_fn(ctx.vm, resolve_fn, &res_args[0], 1, this_ctor_val);
        if (heap.has_error) {
            TVal err_val = heap.error_value;
            promise_clear_error_channels(heap, ctx.vm);
            promise_iterator_close(heap, ctx.vm, iterator, &err_val);
            promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
            if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
        }

        HObject*? fulfill_raw = promise_create_element_callback(heap, Builtin.PROMISE_ANY_RESOLVE_ELEMENT.ordinal, state, idx);
        HObject*? reject_raw  = promise_create_element_callback(heap, Builtin.PROMISE_ANY_REJECT_ELEMENT.ordinal, state, idx);
        if (catch ef = fulfill_raw) {
            promise_iterator_close(heap, ctx.vm, iterator);
            if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
        }
        if (catch er = reject_raw) {
            promise_iterator_close(heap, ctx.vm, iterator);
            if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
        }
        HObject* fulfill_fn = fulfill_raw;
        HObject* reject_fn  = reject_raw;
        TVal fulfill_tv; fulfill_tv.set_object(fulfill_fn);
        TVal reject_tv2;  reject_tv2.set_object(reject_fn);

        // Increment before Invoke(nextPromise, "then", ...) — see the
        // matching comment in builtin_promise_all. Read-modify-write state's
        // live copy (not a stale local) since a prior element's .then() may
        // have already fired synchronously during this same loop.
        idx += 1;
        if (remaining_key != null) {
            long live_remaining = (long)remaining;
            if (try rv3 = state.get_prop(remaining_key)) {
                if (rv3.is_fastint()) live_remaining = rv3.get_fastint();
            }
            live_remaining += 1;
            TVal rem_tv; rem_tv.set_fastint(live_remaining);
            state.put_prop(remaining_key, rem_tv, hobject::PROP_FLAGS_WEC);
            remaining = (usz)live_remaining;
        } else {
            remaining += 1;
        }

        if (!promise_invoke_then(heap, ctx.vm, next_promise, fulfill_tv, reject_tv2)) {
            TVal err_val; err_val.set_undefined();
            if (heap.has_error) { err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm); }
            promise_iterator_close(heap, ctx.vm, iterator, &err_val);
            promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
            if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
        }
    }

    // Decrement the +1 sentinel. Re-read the current value from `state`
    // rather than trusting this function's local `remaining` — see the
    // matching comment in builtin_promise_all (synchronous element
    // rejections during the loop decrement state's live copy, leaving the
    // local stale).
    if (remaining_key != null) {
        long live_remaining = (long)remaining;
        if (try rv2 = state.get_prop(remaining_key)) {
            if (rv2.is_fastint()) live_remaining = rv2.get_fastint();
        }
        live_remaining -= 1;
        TVal rem_tv; rem_tv.set_fastint(live_remaining);
        state.put_prop(remaining_key, rem_tv, hobject::PROP_FLAGS_WEC);
        remaining = (usz)live_remaining;
    } else {
        remaining -= 1;
    }

    if (remaining == 0) {
        // All rejected (empty iterable): settle outer with AggregateError([])
        HString* msg = builtin_intern_string(heap, "All promises were rejected");
        TVal msg_tv; msg_tv.set_string(msg);
        HObject*? agg_raw = heap.alloc_object(hobject::ObjClass.ERROR);
        TVal agg_tv; agg_tv.set_undefined();
        if (try agg = agg_raw) {
            agg.prototype = heap.aggregate_err_proto;
            HString* errors_prop_key = builtin_intern_string(heap, "errors");
            TVal errors_tv; errors_tv.set_undefined();
            if (errors_arr != null) errors_tv.set_object(errors_arr);
            if (errors_prop_key != null) agg.put_prop(errors_prop_key, errors_tv, hobject::PROP_FLAGS_WEC);
            HString* msg_key = builtin_intern_string(heap, "message");
            if (msg_key != null) agg.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            agg_tv.set_object(agg);
        }
        if (promise != null) {
            promise_settle(promise, PROMISE_REJECTED, &agg_tv, heap);
            promise_trigger_reactions(promise, heap, ctx.vm);
        }
        capability_invoke(heap, ctx.vm, state, &agg_tv, false, ctx.this_val);
        if (!heap.microtask_draining) heap.drain_microtasks(ctx.vm);
    }

    if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); }
}

// ============================================================================
// Promise.race(iterable) — ES6 §25.4.4.3
// ============================================================================

fn void builtin_promise_race(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal iterable;
    iterable.set_undefined();
    if (ctx.argc >= 1) iterable = ctx.regs[ctx.base_reg];

    TVal this_ctor_val = ctx.regs[ctx.base_reg - 1];
    if (!this_ctor_val.is_object() || this_ctor_val.get_heapptr() == null) {
        promise_throw_typeerror(ctx, "Promise.race called on non-object");
        return;
    }

    HObject*? hole_raw_race = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err_h = hole_raw_race) { ctx.result.set_undefined(); return; }
    HObject* hole_race = hole_raw_race;
    hole_race.prototype = heap.object_proto;
    if (!promise_new_capability_full(heap, ctx.vm, this_ctor_val, hole_race)) {
        promise_throw_capability_failure(ctx, hole_race);
        return;
    }
    TVal cap_resolve_tv = promise_hole_get_resolve(heap, hole_race);
    TVal cap_reject_tv  = promise_hole_get_reject(heap, hole_race);
    TVal cap_promise_tv = promise_hole_get_promise(heap, hole_race);
    HObject* promise    = null;
    if (cap_promise_tv.is_object() && cap_promise_tv.get_heapptr() != null) {
        promise = (HObject*)cap_promise_tv.get_heapptr();
    }

    HString* resolve_key = builtin_intern_string(heap, "resolve");
    TVal resolve_fn; resolve_fn.set_undefined();
    if (resolve_key != null && this_ctor_val.is_object()) {
        HObject* ctor_obj = (HObject*)this_ctor_val.get_heapptr();
        // Use full Get semantics so accessor getters on C.resolve are invoked.
        // On getter throw, heap.has_error is set — checked below.
        promise_object_get(heap, ctx.vm, ctor_obj, resolve_key, &resolve_fn);
    }
    if (heap.has_error) {
        TVal err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm);
        promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
        if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
    }
    if (!is_callable_tval(resolve_fn)) {
        HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
        TVal err_tv; err_tv.set_undefined();
        if (try err_obj = err_raw) {
            err_obj.prototype = heap.type_err_proto;
            HString* msg_key = builtin_intern_string(heap, "message");
            HString* msg_str = builtin_intern_string(heap, "Promise.resolve is not a function");
            if (msg_key != null && msg_str != null) {
                TVal mt; mt.set_string(msg_str); err_obj.put_prop(msg_key, mt, hobject::PROP_FLAGS_WC);
            }
            err_tv.set_object(err_obj);
        }
        promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_tv);
        if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
    }

    TVal iterator; iterator.set_undefined();
    if (!promise_get_iterator(heap, ctx.vm, iterable, &iterator)) {
        TVal err_val; err_val.set_undefined();
        if (heap.has_error) { err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm); }
        promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
        if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
    }

    // Shared state for race (uses rejected flag as "settled" flag).
    HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    HObject* arr = null;
    if (try a = arr_raw) { a.prototype = heap.array_proto; arr = a; }

    HObject*? state_raw = promise_create_all_state(heap, promise, arr, 0,
                                                    cap_resolve_tv, cap_reject_tv);
    if (catch err_s = state_raw) { ctx.result.set_undefined(); return; }
    HObject* state = state_raw;

    bool iter_done = false;
    while (!iter_done) {
        TVal step_result; step_result.set_undefined();
        if (!promise_iterator_step(heap, ctx.vm, iterator, &step_result)) {
            // IteratorStep abrupt: per spec, iteratorRecord.[[done]] is set to
            // true and ReturnIfAbrupt is applied WITHOUT calling IteratorClose
            // first (the failure came from next() itself, not from processing
            // its result — ES2022 §7.4.7 IteratorStep step 3).
            if (heap.has_error) {
                TVal err_val = heap.error_value;
                promise_clear_error_channels(heap, ctx.vm);
                promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
            }
            if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
        }
        HObject* step_obj = (HObject*)step_result.get_heapptr();
        HString* done_key = builtin_intern_string(heap, "done");
        HString* value_key = builtin_intern_string(heap, "value");
        // IteratorComplete: Get(result, "done") — full Get with accessor invocation.
        bool done = false;
        if (done_key != null) {
            TVal dv_done; dv_done.set_undefined();
            if (!promise_object_get(heap, ctx.vm, step_obj, done_key, &dv_done)) {
                // IteratorComplete abrupt: iteratorRecord.[[done]] = true, no IteratorClose.
                TVal err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm);
                promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
                if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); }
                return;
            }
            done = builtin_to_boolean(&dv_done);
        }
        if (done) { iter_done = true; break; }

        // IteratorValue: Get(result, "value") — full Get with accessor invocation.
        TVal next_value; next_value.set_undefined();
        if (value_key != null) {
            if (!promise_object_get(heap, ctx.vm, step_obj, value_key, &next_value)) {
                // IteratorValue abrupt: iteratorRecord.[[done]] = true, no IteratorClose.
                TVal err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm);
                promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
                if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); }
                return;
            }
        }

        TVal[1] res_args;
        res_args[0] = next_value;
        TVal next_promise = heap.call_fn(ctx.vm, resolve_fn, &res_args[0], 1, this_ctor_val);
        if (heap.has_error) {
            TVal err_val = heap.error_value;
            promise_clear_error_channels(heap, ctx.vm);
            promise_iterator_close(heap, ctx.vm, iterator, &err_val);
            promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
            if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
        }

        // For race, onFulfilled = cap_resolve, onRejected = cap_reject
        if (!promise_invoke_then(heap, ctx.vm, next_promise, cap_resolve_tv, cap_reject_tv)) {
            TVal err_val; err_val.set_undefined();
            if (heap.has_error) { err_val = heap.error_value; promise_clear_error_channels(heap, ctx.vm); }
            promise_iterator_close(heap, ctx.vm, iterator, &err_val);
            promise_combinator_reject(heap, ctx.vm, cap_reject_tv, &err_val);
            if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); } return;
        }
    }

    // Race with empty iterable: cap_promise stays pending forever (per spec).
    if (cap_promise_tv.is_object()) { *ctx.result = cap_promise_tv; } else { ctx.result.set_undefined(); }
}

// ============================================================================
// Promise constructor registration
// ============================================================================

fn bool register_promise_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Promise.prototype. Per ES6 §25.4.5 the prototype is an
    // ordinary object (ObjClass.OBJECT) — it must NOT carry the
    // [[PromiseState]] internal slot that Promise instances have, or
    // Promise.prototype.then would pass the IsPromise check.
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    heap.promise_proto = proto;

    if (!register_string_proto_method(proto, heap, "then",    Builtin.PROMISE_PROTO_THEN.ordinal))    return false;
    if (!register_string_proto_method(proto, heap, "catch",   Builtin.PROMISE_PROTO_CATCH.ordinal))   return false;
    if (!register_string_proto_method(proto, heap, "finally", Builtin.PROMISE_PROTO_FINALLY.ordinal)) return false;

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Promise"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.PROMISE.ordinal;
    heap.promise_ctor = ctor;

    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // Per ECMA-262 §17 "built-in function objects" Set order: "length", "name".
    // We must add length+name BEFORE the static methods (resolve, reject, all,
    // race, allSettled, any) so Object.getOwnPropertyNames() returns them
    // first, satisfying the property-order test family.
    {
        HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        TVal length_tv2;
        length_tv2.set_fastint(1);
        ctor.put_prop(length_key, length_tv2, hobject::PROP_FLAGS_NWC);

        HString* name_key = builtin_intern_string(heap, "name");
        HString* name_hstr = builtin_intern_string(heap, "Promise");
        TVal name_tv; name_tv.set_string(name_hstr);
        ctor.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
    }

    // Promise[Symbol.species] accessor — ES6 §27.2.4.6: getter returns `this`.
    {
        HString* species_sym = ensure_species_symbol(heap);
        if (species_sym != null) {
            HObject*? getter_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (try getter = getter_raw) {
                getter.flags.callable = true;
                getter.flags.constructable = false;
                getter.prototype = heap.function_proto;
                (*getter.extra_ptr()).func.builtin_fn_index = (int)Builtin.PROMISE_SPECIES_GETTER.ordinal;
                HString* getter_name_key = builtin_intern_string(heap, "name");
                if (getter_name_key != null) {
                    HString* getter_name_str = builtin_intern_string(heap, "get [Symbol.species]");
                    if (getter_name_str != null) {
                        TVal gn_tv; gn_tv.set_string(getter_name_str);
                        getter.put_prop(getter_name_key, gn_tv, hobject::PROP_FLAGS_NWC);
                    }
                }
                HString* getter_len_key = builtin_intern_string(heap, "length");
                if (getter_len_key != null) {
                    TVal gl_tv; gl_tv.set_fastint(0);
                    getter.put_prop(getter_len_key, gl_tv, hobject::PROP_FLAGS_NWC);
                }
                TVal getter_tv; getter_tv.set_object(getter);
                TVal undef_tv; undef_tv.set_undefined();
                PropFlags acc_flags;
                acc_flags.writable = false;
                acc_flags.enumerable = false;
                acc_flags.configurable = true;
                acc_flags.is_accessor = true;
                ctor.put_prop(species_sym, hobject::hobject_create_accessors(heap, getter_tv, undef_tv), acc_flags);
            }
        }
    }

    HString* resolve_key = builtin_intern_string(heap, "resolve");
    TVal resolve_tv;
    resolve_tv.set_lightfunc((void*)(usz)Builtin.PROMISE_RESOLVE.ordinal);
    ctor.put_prop(resolve_key, resolve_tv, hobject::PROP_FLAGS_WC);

    HString* reject_key = builtin_intern_string(heap, "reject");
    TVal reject_tv;
    reject_tv.set_lightfunc((void*)(usz)Builtin.PROMISE_REJECT.ordinal);
    ctor.put_prop(reject_key, reject_tv, hobject::PROP_FLAGS_WC);

    HString* all_key = builtin_intern_string(heap, "all");
    TVal all_tv;
    all_tv.set_lightfunc((void*)(usz)Builtin.PROMISE_ALL.ordinal);
    ctor.put_prop(all_key, all_tv, hobject::PROP_FLAGS_WC);

    HString* race_key = builtin_intern_string(heap, "race");
    TVal race_tv;
    race_tv.set_lightfunc((void*)(usz)Builtin.PROMISE_RACE.ordinal);
    ctor.put_prop(race_key, race_tv, hobject::PROP_FLAGS_WC);

    HString* allsettled_key = builtin_intern_string(heap, "allSettled");
    TVal allsettled_tv;
    allsettled_tv.set_lightfunc((void*)(usz)Builtin.PROMISE_ALLSETTLED.ordinal);
    ctor.put_prop(allsettled_key, allsettled_tv, hobject::PROP_FLAGS_WC);

    HString* any_key = builtin_intern_string(heap, "any");
    TVal any_tv;
    any_tv.set_lightfunc((void*)(usz)Builtin.PROMISE_ANY.ordinal);
    ctor.put_prop(any_key, any_tv, hobject::PROP_FLAGS_WC);

    uint hash = heap.hash_string("Promise");
    HString* existing = heap.str_table_lookup("Promise", hash);
    HString* promise_key;
    if (existing != null) {
        promise_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Promise", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        promise_key = new_key;
    }
    TVal promise_val;
    promise_val.set_object(ctor);
    env::env_declare_nonenum(global_env, promise_key, promise_val);

    return true;
}

// ============================================================================
// Async/await resume and reject callbacks
// ============================================================================

/// Resume callback for async/await. Called as a microtask when a pending
/// Promise settles with a fulfilled value.  Re-enters the suspended async
/// function at the AWAIT point via the generator resume mechanism.
fn void builtin_async_resume(BuiltinContext* ctx) {
    // The GeneratorState was stashed in the function object's var_env field
    // by the AWAIT opcode handler.
    GeneratorState* gs = (GeneratorState*)(*ctx.callee_obj.extra_ptr()).func.var_env;
    if (gs == null) { ctx.result.set_undefined(); return; }

    // Set the resume value from the settled Promise result
    if (ctx.argc >= 1) {
        gs.resume_value = ctx.regs[ctx.base_reg];
    } else {
        gs.resume_value.set_undefined();
    }
    gs.resume_kind = NEXT;

    // Signal the VM to resume from the saved state
    ctx.heap.resume_gen = gs;

    // Build a callable TVal for the compiled function and invoke it directly.
    // vm_call_fn_impl Case 3 checks resume_gen and restores the saved PC/regs.
    HObject*? func_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) {
        ctx.heap.resume_gen = null;
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_raw;
    func_obj.flags.callable = true;
    (*func_obj.extra_ptr()).func.comp_func = (CompiledFunction*)gs.func;
    (*func_obj.extra_ptr()).func.var_env = (EnvRecord*)gs.var_env;
    (*func_obj.extra_ptr()).func.lex_env = (EnvRecord*)gs.lex_env;

    TVal func_tv;
    func_tv.set_object(func_obj);

    // Call the compiled function directly — vm_call_fn_impl will detect
    // resume_gen and restore the saved PC + registers.
    TVal resume_arg;
    resume_arg = gs.resume_value;
    TVal result = ctx.heap.call_fn(ctx.vm, func_tv, &resume_arg, 1, gs.this_binding);

    ctx.heap.resume_gen = null;

    // If the function completed (returned a value), store it in ctx.result
    // so the downstream promise gets settled.
    *ctx.result = result;
}

/// Reject callback for async/await. Called when a pending Promise rejects.
/// Injects the rejection reason as an exception into the suspended async function.
fn void builtin_async_reject(BuiltinContext* ctx) {
    GeneratorState* gs = (GeneratorState*)(*ctx.callee_obj.extra_ptr()).func.var_env;
    if (gs == null) { ctx.result.set_undefined(); return; }

    // Set the throw value from the rejection reason
    if (ctx.argc >= 1) {
        gs.throw_value = ctx.regs[ctx.base_reg];
    } else {
        gs.throw_value.set_undefined();
    }
    gs.resume_kind = THROW;

    // Signal the VM to resume from the saved state
    ctx.heap.resume_gen = gs;

    // Build a callable TVal for the compiled function and invoke it directly.
    // vm_call_fn_impl Case 3 checks resume_gen and restores the saved PC/regs.
    // LOAD_RESUME will inject the throw via vm_throw_value.
    HObject*? func_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) {
        ctx.heap.resume_gen = null;
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_raw;
    func_obj.flags.callable = true;
    (*func_obj.extra_ptr()).func.comp_func = (CompiledFunction*)gs.func;
    (*func_obj.extra_ptr()).func.var_env = (EnvRecord*)gs.var_env;
    (*func_obj.extra_ptr()).func.lex_env = (EnvRecord*)gs.lex_env;

    TVal func_tv;
    func_tv.set_object(func_obj);

    // Call the compiled function directly — vm_call_fn_impl will detect
    // resume_gen and restore the saved PC + registers.
    TVal throw_arg;
    throw_arg = gs.throw_value;
    TVal result = ctx.heap.call_fn(ctx.vm, func_tv, &throw_arg, 1, gs.this_binding);

    ctx.heap.resume_gen = null;

    // If the function completed (returned a value — e.g. catch handled the
    // rejection), store it in ctx.result so the downstream promise gets settled.
    *ctx.result = result;
}

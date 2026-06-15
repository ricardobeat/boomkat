/// Promise constructor, Promise.prototype methods, and microtask integration.
module tinyduck::builtins;
import tinyduck::types;
import libc;
import tinyduck::hstring;

import tinyduck::heap;
import tinyduck::hobject;
import tinyduck::env;

// ============================================================================
// Promise helpers (ES6 §25.4)
// ============================================================================

const uint PROMISE_PENDING   = 0;
const uint PROMISE_FULFILLED = 1;
const uint PROMISE_REJECTED  = 2;

/// Get the promise state from the HObject's array_part[0].
fn uint promise_get_state(HObject* promise, uint default_state) {
    if (promise.array_part() != null && promise.array_size >= 2) {
        return (uint)promise.array_part()[0].get_fastint();
    }
    return default_state;
}

/// Set the promise state in array_part.
/// Layout: array[0]=state, array[1]=result, array[2+]=reactions.
/// We must ensure array_used >= 2 so that reactions start at index 2.
/// set_array_idx's undefined-based tracking only counts index 0 (state)
/// as used, leaving index 1 (result=undef) uncounted. Without the fix,
/// promise_add_reaction writes to index 1, clobbering the result slot,
/// and promise_trigger_reactions finds zero reactions.
fn void promise_set_state(HObject* promise, uint state) {
    TVal state_tv;
    state_tv.set_fastint((long)state);
    promise.set_array_idx(0, state_tv);
    TVal undef;
    undef.set_undefined();
    promise.set_array_idx(1, undef);
    if (promise.array_used < 2) {
        promise.array_used = 2;
    }
}

/// Set the promise result in array_part.
/// Writes directly to array_part[1] — the slot is already accounted for in
/// array_used by promise_set_state, so using set_array_idx would incorrectly
/// increment array_used when transitioning from undefined to non-undefined.
fn void promise_set_result(HObject* promise, TVal* val) {
    if (promise.array_part() != null && promise.array_size > 1) {
        promise.array_part()[1] = *val;
    }
}

/// Check that `this` is a Promise object.
fn HObject* check_promise(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.PROMISE) return obj;
    }
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        HString* msg_str = builtin_intern_string(ctx.heap,
            "Promise.prototype method called on incompatible value");
        if (msg_str != null) {
            TVal msg_tv;
            msg_tv.set_string(msg_str);
            err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_tv, hobject::PROP_FLAGS_WEC);
        }
        ctx.throw_value.set_object(err);
    } else {
        ctx.throw_value.set_undefined();
    }
    ctx.should_throw = true;
    return null;
}

/// Trigger all pending reactions for a settled promise.
fn void promise_trigger_reactions(HObject* promise, Heap* heap, void* vm) {
    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state == PROMISE_PENDING) return;

    TVal result = promise.array_part()[1];

    // Iterate reactions stored in array_part starting at index 2
    // Each reaction occupies one slot (an OBJECT with handler/downstream props)
    uint num_reactions = 0;
    if (promise.array_used > 2) {
        num_reactions = promise.array_used - 2;
    }

    for (uint i = 0; i < num_reactions; i++) {
        TVal reaction_val = promise.array_part()[2 + i];
        if (!reaction_val.is_object() || reaction_val.get_heapptr() == null) continue;
        HObject* reaction = (HObject*)reaction_val.get_heapptr();

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

        if (state == PROMISE_FULFILLED) {
            if (handler.is_undefined()) {
                // No onFulfilled — pass through to downstream
                if (downstream != null) {
                    promise_set_state(downstream, PROMISE_FULFILLED);
                    promise_set_result(downstream, &result);
                    promise_trigger_reactions(downstream, heap, vm);
                }
            } else {
                // Enqueue microtask — handler will be called asynchronously,
                // downstream will be resolved with handler's return value by drain
                heap.enqueue_microtask(handler, result, downstream_val);
            }
        } else {
            if (handler.is_undefined()) {
                // No onRejected — pass through rejection to downstream
                if (downstream != null) {
                    promise_set_state(downstream, PROMISE_REJECTED);
                    promise_set_result(downstream, &result);
                    promise_trigger_reactions(downstream, heap, vm);
                }
            } else {
                // Enqueue microtask — handler will be called asynchronously,
                // downstream will be resolved with handler's return value by drain
                heap.enqueue_microtask(handler, result, downstream_val);
            }
        }
    }
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
/// handler's return value.  Registered as heap.microtask_after_fn during init.
fn void promise_microtask_after(void* heap_raw, void* vm, TVal result, TVal downstream) {
    Heap* heap = (Heap*)heap_raw;
    if (!downstream.is_object() || downstream.get_heapptr() == null) return;
    HObject* ds = (HObject*)downstream.get_heapptr();
    if (ds.flags.obj_class != hobject::ObjClass.PROMISE) return;

    // Check if downstream is already settled (shouldn't be, but guard)
    uint state = promise_get_state(ds, PROMISE_PENDING);
    if (state != PROMISE_PENDING) return;

    // Resolve the downstream promise with the handler's return value.
    // If the result is a thenable, we should follow it (Promise Resolution
    // Function).  For now, do a simple resolve.
    promise_set_state(ds, PROMISE_FULFILLED);
    promise_set_result(ds, &result);
    promise_trigger_reactions(ds, heap, vm);
}

/// Resolve or reject a capability's downstream promise.
fn void call_capability(TVal resolve, TVal reject, TVal* val, Heap* heap, bool is_resolve, void* vm) {
    TVal callee = is_resolve ? resolve : reject;
    if (callee.is_undefined()) return;

    if (callee.is_object() && callee.get_heapptr() != null) {
        HObject* obj = (HObject*)callee.get_heapptr();
        // If it's a PROMISE directly, resolve/reject it
        if (obj.flags.obj_class == hobject::ObjClass.PROMISE) {
            promise_set_state(obj, is_resolve ? PROMISE_FULFILLED : PROMISE_REJECTED);
            promise_set_result(obj, val);
            promise_trigger_reactions(obj, heap, vm);
            return;
        }
        // If it's a capability object, look up the "promise" property
        HString* promise_key = builtin_intern_string(heap, "promise");
        if (try pv = obj.get_prop(promise_key)) {
            if (pv.is_object() && pv.get_heapptr() != null) {
                HObject* prom = (HObject*)pv.get_heapptr();
                if (prom.flags.obj_class == hobject::ObjClass.PROMISE) {
                    promise_set_state(prom, is_resolve ? PROMISE_FULFILLED : PROMISE_REJECTED);
                    promise_set_result(prom, val);
                    promise_trigger_reactions(prom, heap, vm);
                }
            }
        }
    }
}

fn void builtin_promise_resolve_callback(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    // Try to get promise from the function object's stored property
    HObject* promise = null;
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
    }
    // Fallback to promise_resolve_stack
    if (promise == null && heap.promise_resolve_top > 0 && heap.promise_resolve_stack != null) {
        promise = heap.promise_resolve_stack[heap.promise_resolve_top - 1];
    }
    if (promise == null) return;

    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state != PROMISE_PENDING) return;

    TVal value;
    value.set_undefined();
    if (ctx.argc >= 1) value = ctx.regs[ctx.base_reg];

    promise_set_state(promise, PROMISE_FULFILLED);
    promise_set_result(promise, &value);
    promise_trigger_reactions(promise, heap, ctx.vm);
}

fn void builtin_promise_reject_callback(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    HObject* promise = null;
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
    }
    if (promise == null && heap.promise_resolve_top > 0 && heap.promise_resolve_stack != null) {
        promise = heap.promise_resolve_stack[heap.promise_resolve_top - 1];
    }
    if (promise == null) return;

    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state != PROMISE_PENDING) return;

    TVal reason;
    reason.set_undefined();
    if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];

    promise_set_state(promise, PROMISE_REJECTED);
    promise_set_result(promise, &reason);
    promise_trigger_reactions(promise, heap, ctx.vm);
}

/// Create a new Promise with the given internal structure.
fn HObject*? promise_create(Heap* heap) {
    HObject*? prom_raw = heap.alloc_object(hobject::ObjClass.PROMISE);
    if (catch err = prom_raw) return null;
    HObject* prom = prom_raw;
    promise_set_state(prom, PROMISE_PENDING);
    return prom;
}

/// Create a resolve/reject capability object (internal).
/// Returns a pair of functions as properties on a capability HObject.
fn HObject*? promise_create_capability(Heap* heap, HObject* promise) {
    HObject*? cap_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = cap_raw) return null;
    HObject* cap = cap_raw;

    // Store a reference to the promise this capability controls
    HString* promise_key = builtin_intern_string(heap, "promise");
    TVal promise_val;
    promise_val.set_object(promise);
    cap.put_prop(promise_key, promise_val, hobject::PROP_FLAGS_WEC);

    return cap;
}

/// Add a reaction to a pending promise.
fn void promise_add_reaction(HObject* promise, TVal reaction_val) {
    uint idx = promise.array_used;
    promise.set_array_idx(idx, reaction_val);
}

// ============================================================================
// Promise constructor (ES6 §25.4.3.1)
// ============================================================================

fn void builtin_promise(BuiltinContext* ctx) {
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;

    // Set prototype

    if (ctx.argc < 1) {
        // No executor — return pending promise
        ctx.result.set_object(promise);
        return;
    }

    TVal executor = ctx.regs[ctx.base_reg];
    if (!executor.is_object() || executor.get_heapptr() == null) {
        ctx.result.set_object(promise);
        return;
    }

    HObject* exec_func = (HObject*)executor.get_heapptr();
    if ((*exec_func.extra_ptr()).func.comp_func == null && (*exec_func.extra_ptr()).func.builtin_fn_index < 0) {
        ctx.result.set_object(promise);
        return;
    }

    // Push promise onto resolve stack so resolve/reject callbacks can find it
    Heap* heap = ctx.heap;
    if (heap.promise_resolve_top >= heap.promise_resolve_cap) {
        uint new_cap = heap.promise_resolve_cap == 0 ? 16 : heap.promise_resolve_cap * 2;
        void*? new_raw = heap.alloc((usz)(HObject*::size * new_cap));
        HObject** new_stack;
        if (try p = new_raw) {
            new_stack = (HObject**)p;
        } else {
            ctx.result.set_object(promise);
            return;
        }
        if (heap.promise_resolve_stack != null) {
            libc::memcpy(new_stack, heap.promise_resolve_stack, (usz)(HObject*::size * heap.promise_resolve_top));
            heap.free(heap.promise_resolve_stack);
        } else {
            libc::memset(new_stack, 0, (usz)(HObject*::size * new_cap));
        }
        heap.promise_resolve_stack = new_stack;
        heap.promise_resolve_cap = new_cap;
    }
    if (heap.promise_resolve_stack != null) {
        heap.promise_resolve_stack[heap.promise_resolve_top] = promise;
        heap.promise_resolve_top++;
    }

    // Create resolve/reject function objects that carry the promise reference
    HObject*? resolve_func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = resolve_func_raw) {
        ctx.result.set_object(promise);
        return;
    }
    HObject* resolve_func = resolve_func_raw;
    (*resolve_func.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_PROMISE_RESOLVE_CALLBACK;
    resolve_func.flags.callable = true;
    // Store promise reference on the function object
    HString* promise_key = builtin_intern_string(heap, "\xFFpromise");
    TVal promise_ref;
    promise_ref.set_object(promise);
    resolve_func.put_prop(promise_key, promise_ref, hobject::PROP_FLAGS_WEC);

    HObject*? reject_func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = reject_func_raw) {
        ctx.result.set_object(promise);
        return;
    }
    HObject* reject_func = reject_func_raw;
    (*reject_func.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_PROMISE_REJECT_CALLBACK;
    reject_func.flags.callable = true;
    reject_func.put_prop(promise_key, promise_ref, hobject::PROP_FLAGS_WEC);

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
    }

    // Pop from resolve stack
    if (heap.promise_resolve_top > 0) {
        heap.promise_resolve_top--;
    }

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise.prototype.then(onFulfilled, onRejected) — ES6 §25.4.5.3
// ============================================================================

fn void builtin_promise_proto_then(BuiltinContext* ctx) {
    HObject* promise = check_promise(ctx);
    if (promise == null) return;

    TVal on_fulfilled;
    on_fulfilled.set_undefined();
    TVal on_rejected;
    on_rejected.set_undefined();
    if (ctx.argc >= 1) on_fulfilled = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) on_rejected  = ctx.regs[ctx.base_reg + 1];

    // Create a new promise for the chain
    HObject*? new_prom_raw = promise_create(ctx.heap);
    if (catch err = new_prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* new_promise = new_prom_raw;

    // Build reaction object
    HObject*? reaction_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = reaction_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* reaction = reaction_raw;

    // Store handlers
    HString* onf_key = builtin_intern_string(ctx.heap, "onFulfilled");
    reaction.put_prop(onf_key, on_fulfilled, hobject::PROP_FLAGS_WEC);

    HString* onr_key = builtin_intern_string(ctx.heap, "onRejected");
    reaction.put_prop(onr_key, on_rejected, hobject::PROP_FLAGS_WEC);

    // Store the downstream promise directly on the reaction
    HString* downstream_key = builtin_intern_string(ctx.heap, "downstream");
    TVal downstream_val;
    downstream_val.set_object(new_promise);
    reaction.put_prop(downstream_key, downstream_val, hobject::PROP_FLAGS_WEC);

    // Add reaction to the original promise
    TVal reaction_val;
    reaction_val.set_object(reaction);

    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state == PROMISE_PENDING) {
        promise_add_reaction(promise, reaction_val);
    } else {
        // Promise already settled — trigger reaction immediately
        promise_add_reaction(promise, reaction_val);
        promise_trigger_reactions(promise, ctx.heap, ctx.vm);
    }

    ctx.result.set_object(new_promise);
}

// ============================================================================
// Promise.prototype.catch(onRejected) — ES6 §25.4.5.1
// ============================================================================

fn void builtin_promise_proto_catch(BuiltinContext* ctx) {
    // catch(onRejected) is equivalent to then(undefined, onRejected)
    TVal on_rejected;
    on_rejected.set_undefined();
    if (ctx.argc >= 1) on_rejected = ctx.regs[ctx.base_reg];

    // Set up: then(undefined, on_rejected)
    ctx.regs[ctx.base_reg].set_undefined();     // onFulfilled = undefined
    ctx.regs[ctx.base_reg + 1] = on_rejected;   // onRejected = original arg
    ctx.argc = 2;
    builtin_promise_proto_then(ctx);
}

// ============================================================================
// Promise.prototype.finally(onFinally) — ES2018 §25.4.5.3
// ============================================================================

fn void builtin_promise_proto_finally(BuiltinContext* ctx) {
    HObject* promise = check_promise(ctx);
    if (promise == null) return;

    TVal on_finally;
    on_finally.set_undefined();
    if (ctx.argc >= 1) on_finally = ctx.regs[ctx.base_reg];

    // If onFinally is not callable, just pass through: then(onFinally, onFinally)
    if (!on_finally.is_object() || on_finally.get_heapptr() == null ||
        !((HObject*)on_finally.get_heapptr()).is_callable()) {
        ctx.regs[ctx.base_reg + 1] = on_finally;
        builtin_promise_proto_then(ctx);
        return;
    }

    // ES2018 §25.4.5.3: wrap onFinally in handlers that call it with no args
    // and preserve the original fulfillment value / rejection reason.
    // For now, use onFinally as a passthrough handler (slightly wrong: receives
    // value as arg) — but the downstream promise at least gets a value.
    ctx.regs[ctx.base_reg + 1] = on_finally;  // Set both onFulfilled and onRejected
    builtin_promise_proto_then(ctx);
}

// ============================================================================
// Promise.resolve(x) — ES6 §25.4.4.5
// ============================================================================

fn void builtin_promise_resolve(BuiltinContext* ctx) {
    TVal val;
    val.set_undefined();
    if (ctx.argc >= 1) val = ctx.regs[ctx.base_reg];

    // If already a Promise, return it
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.PROMISE) {
            *ctx.result = val;
            return;
        }
    }

    // Create a new fulfilled promise
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;
    promise_set_state(promise, PROMISE_FULFILLED);
    promise_set_result(promise, &val);

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise.reject(r) — ES6 §25.4.4.4
// ============================================================================

fn void builtin_promise_reject(BuiltinContext* ctx) {
    TVal reason;
    reason.set_undefined();
    if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];

    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;
    promise_set_state(promise, PROMISE_REJECTED);
    promise_set_result(promise, &reason);

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise.all(iterable) — ES6 §25.4.4.1
// ============================================================================

fn void builtin_promise_all(BuiltinContext* ctx) {
    // Get the iterable argument
    TVal iterable;
    iterable.set_undefined();
    if (ctx.argc >= 1) iterable = ctx.regs[ctx.base_reg];

    // Create the result promise
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;

    // Helper: resolve result promise with empty array
    usz len = 0;
    bool has_len = false;
    HObject* obj = null;

    if (iterable.is_object() && iterable.get_heapptr() != null) {
        obj = (HObject*)iterable.get_heapptr();
        HString* length_key = builtin_intern_string(ctx.heap, "length");
        if (try len_tv = obj.get_prop(length_key)) {
            if (len_tv.is_fastint() && len_tv.get_fastint() >= 0) {
                len = (usz)len_tv.get_fastint();
                has_len = true;
            }
        }
    }

    // Zero-length or non-iterable — resolve with [] immediately
    if (!has_len || len == 0) {
        HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        TVal arr_val;
        arr_val.set_undefined();
        if (try arr = arr_raw) {
            arr_val.set_object(arr);
        }
        promise_set_state(promise, PROMISE_FULFILLED);
        promise_set_result(promise, &arr_val);
        ctx.result.set_object(promise);
        return;
    }

    // Allocate results array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_object(promise);
        return;
    }
    HObject* arr = arr_raw;

    usz remaining = len;
    bool rejected = false;

    for (usz i = 0; i < len; i++) {
        if (rejected) break;

        TVal idx_tv;
        idx_tv.set_fastint((long)i);

        TVal elem;
        if (try e = obj.get_prop(&idx_tv)) {
            elem = e;
        } else {
            elem.set_undefined();
        }

        // Check if element is a Promise
        if (elem.is_object() && elem.get_heapptr() != null) {
            HObject* elem_obj = (HObject*)elem.get_heapptr();
            if (elem_obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                uint state = promise_get_state(elem_obj, PROMISE_PENDING);
                if (state == PROMISE_FULFILLED) {
                    arr.set_array_idx((uint)i, elem_obj.array_part()[1]);
                    remaining--;
                } else if (state == PROMISE_REJECTED) {
                    promise_set_state(promise, PROMISE_REJECTED);
                    promise_set_result(promise, &elem_obj.array_part()[1]);
                    promise_trigger_reactions(promise, ctx.heap, ctx.vm);
                    rejected = true;
                    break;
                } else {
                    // Pending promise — skip (no async support yet)
                    remaining--;
                }
                continue;
            }
        }

        // Not a promise — store as value
        arr.set_array_idx((uint)i, elem);
        remaining--;
    }

    if (!rejected && remaining == 0) {
        TVal arr_val;
        arr_val.set_object(arr);
        promise_set_state(promise, PROMISE_FULFILLED);
        promise_set_result(promise, &arr_val);
        promise_trigger_reactions(promise, ctx.heap, ctx.vm);
    }

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise.allSettled(iterable) — ES2020 §25.6.4.5
// ============================================================================

fn void builtin_promise_allsettled(BuiltinContext* ctx) {
    // Get the iterable argument
    TVal iterable;
    iterable.set_undefined();
    if (ctx.argc >= 1) iterable = ctx.regs[ctx.base_reg];

    // Create the result promise
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;

    // Get .length from iterable
    usz len = 0;
    bool has_len = false;
    HObject* obj = null;

    if (iterable.is_object() && iterable.get_heapptr() != null) {
        obj = (HObject*)iterable.get_heapptr();
        HString* length_key = builtin_intern_string(ctx.heap, "length");
        if (try len_tv = obj.get_prop(length_key)) {
            if (len_tv.is_fastint() && len_tv.get_fastint() >= 0) {
                len = (usz)len_tv.get_fastint();
                has_len = true;
            }
        }
    }

    // Zero-length or non-iterable — resolve with [] immediately
    if (!has_len || len == 0) {
        HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        TVal arr_val;
        arr_val.set_undefined();
        if (try arr = arr_raw) {
            arr_val.set_object(arr);
        }
        promise_set_state(promise, PROMISE_FULFILLED);
        promise_set_result(promise, &arr_val);
        ctx.result.set_object(promise);
        return;
    }

    // Allocate results array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_object(promise);
        return;
    }
    HObject* arr = arr_raw;

    usz remaining = len;
    HString* status_key = builtin_intern_string(ctx.heap, "status");
    HString* value_key = builtin_intern_string(ctx.heap, "value");
    HString* reason_key = builtin_intern_string(ctx.heap, "reason");
    TVal fulfilled_status;
    fulfilled_status.set_string(builtin_intern_string(ctx.heap, "fulfilled"));
    TVal rejected_status;
    rejected_status.set_string(builtin_intern_string(ctx.heap, "rejected"));

    for (usz i = 0; i < len; i++) {
        TVal idx_tv;
        idx_tv.set_fastint((long)i);

        TVal elem;
        if (try e = obj.get_prop(&idx_tv)) {
            elem = e;
        } else {
            elem.set_undefined();
        }

        // Check if element is a Promise
        if (elem.is_object() && elem.get_heapptr() != null) {
            HObject* elem_obj = (HObject*)elem.get_heapptr();
            if (elem_obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                uint state = promise_get_state(elem_obj, PROMISE_PENDING);

                // Create result object
                HObject*? result_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (try result_obj = result_obj_raw) {

                    if (state == PROMISE_FULFILLED) {
                        result_obj.put_prop(status_key, fulfilled_status, hobject::PROP_FLAGS_WEC);
                        result_obj.put_prop(value_key, elem_obj.array_part()[1], hobject::PROP_FLAGS_WEC);
                    } else if (state == PROMISE_REJECTED) {
                        result_obj.put_prop(status_key, rejected_status, hobject::PROP_FLAGS_WEC);
                        result_obj.put_prop(reason_key, elem_obj.array_part()[1], hobject::PROP_FLAGS_WEC);
                    } else {
                        // Pending — use "fulfilled" with undefined value (no async yet)
                        result_obj.put_prop(status_key, fulfilled_status, hobject::PROP_FLAGS_WEC);
                        TVal undef;
                        undef.set_undefined();
                        result_obj.put_prop(value_key, undef, hobject::PROP_FLAGS_WEC);
                    }
                    TVal result_tv;
                    result_tv.set_object(result_obj);
                    arr.set_array_idx((uint)i, result_tv);
                }
                remaining--;
                continue;
            }
        }

        // Not a promise — store as fulfilled
        HObject*? result_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try result_obj = result_obj_raw) {
            result_obj.put_prop(status_key, fulfilled_status, hobject::PROP_FLAGS_WEC);
            result_obj.put_prop(value_key, elem, hobject::PROP_FLAGS_WEC);
            TVal result_tv;
            result_tv.set_object(result_obj);
            arr.set_array_idx((uint)i, result_tv);
        }
        remaining--;
    }

    if (remaining == 0) {
        TVal arr_val;
        arr_val.set_object(arr);
        promise_set_state(promise, PROMISE_FULFILLED);
        promise_set_result(promise, &arr_val);
        promise_trigger_reactions(promise, ctx.heap, ctx.vm);
    }

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise.any(iterable) — ES2021 §25.6.4.3
// ============================================================================

fn void builtin_promise_any(BuiltinContext* ctx) {
    // Get the iterable argument
    TVal iterable;
    iterable.set_undefined();
    if (ctx.argc >= 1) iterable = ctx.regs[ctx.base_reg];

    // Create the result promise
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;

    // Get .length from iterable
    usz len = 0;
    bool has_len = false;
    HObject* obj = null;

    if (iterable.is_object() && iterable.get_heapptr() != null) {
        obj = (HObject*)iterable.get_heapptr();
        HString* length_key = builtin_intern_string(ctx.heap, "length");
        if (try len_tv = obj.get_prop(length_key)) {
            if (len_tv.is_fastint() && len_tv.get_fastint() >= 0) {
                len = (usz)len_tv.get_fastint();
                has_len = true;
            }
        }
    }

    // Empty iterable or non-iterable — reject with AggregateError
    if (!has_len || len == 0) {
        TVal errors_tv;
        errors_tv.set_undefined();
        HString* msg = builtin_intern_string(ctx.heap, "All promises were rejected");
        TVal msg_tv;
        msg_tv.set_string(msg);

        // Create AggregateError with empty errors array
        HObject*? agg_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try agg = agg_raw) {
            HString* errors_key = builtin_intern_string(ctx.heap, "errors");
            HObject*? empty_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (try arr = empty_arr) {
                TVal arr_tv;
                arr_tv.set_object(arr);
                agg.put_prop(errors_key, arr_tv, hobject::PROP_FLAGS_WEC);
            }
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            agg.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        }

        TVal agg_tv;
        agg_tv.set_undefined();
        if (try agg2 = agg_raw) {
            agg_tv.set_object(agg2);
        }
        promise_set_state(promise, PROMISE_REJECTED);
        promise_set_result(promise, &agg_tv);
        ctx.result.set_object(promise);
        return;
    }

    usz remaining = len;
    usz rejected_count = 0;
    HObject*? errors_arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    HObject* errors_arr = null;
    if (try arr = errors_arr_raw) {
        errors_arr = arr;
    }

    for (usz i = 0; i < len; i++) {
        TVal idx_tv;
        idx_tv.set_fastint((long)i);

        TVal elem;
        if (try e = obj.get_prop(&idx_tv)) {
            elem = e;
        } else {
            elem.set_undefined();
        }

        // Check if element is a Promise
        if (elem.is_object() && elem.get_heapptr() != null) {
            HObject* elem_obj = (HObject*)elem.get_heapptr();
            if (elem_obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                uint state = promise_get_state(elem_obj, PROMISE_PENDING);
                if (state == PROMISE_FULFILLED) {
                    // Fulfilled — resolve with value
                    promise_set_state(promise, PROMISE_FULFILLED);
                    promise_set_result(promise, &elem_obj.array_part()[1]);
                    promise_trigger_reactions(promise, ctx.heap, ctx.vm);
                    ctx.result.set_object(promise);
                    return;
                } else if (state == PROMISE_REJECTED) {
                    // Track rejection reason
                    if (errors_arr != null) {
                        errors_arr.set_array_idx((uint)(rejected_count), elem_obj.array_part()[1]);
                    }
                    rejected_count++;
                } else {
                    // Pending — accumulate as rejected with undefined reason
                    if (errors_arr != null) {
                        TVal undef;
                        undef.set_undefined();
                        errors_arr.set_array_idx((uint)(rejected_count), undef);
                    }
                    rejected_count++;
                }
                remaining--;
                continue;
            }
        }

        // Not a promise — resolve with this value immediately
        promise_set_state(promise, PROMISE_FULFILLED);
        promise_set_result(promise, &elem);
        promise_trigger_reactions(promise, ctx.heap, ctx.vm);
        ctx.result.set_object(promise);
        return;
    }

    // All rejected — create AggregateError
    if (remaining == 0) {
        TVal errors_val;
        if (errors_arr != null) {
            errors_val.set_object(errors_arr);
        } else {
            errors_val.set_undefined();
        }

        HObject*? agg_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        TVal agg_tv;
        agg_tv.set_undefined();
        if (try agg = agg_raw) {
            HString* errors_key = builtin_intern_string(ctx.heap, "errors");
            agg.put_prop(errors_key, errors_val, hobject::PROP_FLAGS_WEC);
            HString* msg = builtin_intern_string(ctx.heap, "All promises were rejected");
            TVal msg_tv;
            msg_tv.set_string(msg);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            agg.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            agg_tv.set_object(agg);
        }
        promise_set_state(promise, PROMISE_REJECTED);
        promise_set_result(promise, &agg_tv);
        promise_trigger_reactions(promise, ctx.heap, ctx.vm);
    }

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise.race(iterable) — ES6 §25.4.4.3
// ============================================================================

fn void builtin_promise_race(BuiltinContext* ctx) {
    TVal iterable;
    iterable.set_undefined();
    if (ctx.argc >= 1) iterable = ctx.regs[ctx.base_reg];

    // Create the result promise
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;

    if (!iterable.is_object() || iterable.get_heapptr() == null) {
        ctx.result.set_object(promise);
        return;
    }

    HObject* obj = (HObject*)iterable.get_heapptr();
    HString* length_key = builtin_intern_string(ctx.heap, "length");
    usz len = 0;
    bool has_len = false;
    if (try len_tv = obj.get_prop(length_key)) {
        if (len_tv.is_fastint() && len_tv.get_fastint() >= 0) {
            len = (usz)len_tv.get_fastint();
            has_len = true;
        }
    }

    if (!has_len) {
        ctx.result.set_object(promise);
        return;
    }

    bool settled = false;

    for (usz i = 0; i < len && !settled; i++) {
        TVal idx_tv;
        idx_tv.set_fastint((long)i);

        TVal elem;
        if (try e = obj.get_prop(&idx_tv)) {
            elem = e;
        } else {
            elem.set_undefined();
        }

        // If element is a Promise, check its state
        if (elem.is_object() && elem.get_heapptr() != null) {
            HObject* elem_obj = (HObject*)elem.get_heapptr();
            if (elem_obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                uint state = promise_get_state(elem_obj, PROMISE_PENDING);
                if (state == PROMISE_FULFILLED) {
                    promise_set_state(promise, PROMISE_FULFILLED);
                    promise_set_result(promise, &elem_obj.array_part()[1]);
                    promise_trigger_reactions(promise, ctx.heap, ctx.vm);
                    settled = true;
                    break;
                } else if (state == PROMISE_REJECTED) {
                    promise_set_state(promise, PROMISE_REJECTED);
                    promise_set_result(promise, &elem_obj.array_part()[1]);
                    promise_trigger_reactions(promise, ctx.heap, ctx.vm);
                    settled = true;
                    break;
                }
                // Pending: continue (no async support yet)
                continue;
            }
        }

        // Non-promise value — immediate resolution
        promise_set_state(promise, PROMISE_FULFILLED);
        promise_set_result(promise, &elem);
        promise_trigger_reactions(promise, ctx.heap, ctx.vm);
        settled = true;
        break;
    }

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise constructor registration
// ============================================================================

fn bool register_promise_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Promise.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.PROMISE);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    heap.promise_proto = proto;

    // Register prototype methods
    if (!register_string_proto_method(proto, heap, "then",    BUILTIN_PROMISE_PROTO_THEN))    return false;
    if (!register_string_proto_method(proto, heap, "catch",   BUILTIN_PROMISE_PROTO_CATCH))   return false;
    if (!register_string_proto_method(proto, heap, "finally", BUILTIN_PROMISE_PROTO_FINALLY)) return false;

    // Create Promise function object
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_PROMISE;

    // Wire prototype.constructor → ctor
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    // Wire ctor.prototype → proto (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // Promise.length = 1
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(1);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WEC);

    // Register static methods on Promise
    HString* resolve_key = builtin_intern_string(heap, "resolve");
    TVal resolve_tv;
    resolve_tv.set_lightfunc((void*)(usz)BUILTIN_PROMISE_RESOLVE);
    ctor.put_prop(resolve_key, resolve_tv, hobject::PROP_FLAGS_WEC);

    HString* reject_key = builtin_intern_string(heap, "reject");
    TVal reject_tv;
    reject_tv.set_lightfunc((void*)(usz)BUILTIN_PROMISE_REJECT);
    ctor.put_prop(reject_key, reject_tv, hobject::PROP_FLAGS_WEC);

    HString* all_key = builtin_intern_string(heap, "all");
    TVal all_tv;
    all_tv.set_lightfunc((void*)(usz)BUILTIN_PROMISE_ALL);
    ctor.put_prop(all_key, all_tv, hobject::PROP_FLAGS_WEC);

    HString* race_key = builtin_intern_string(heap, "race");
    TVal race_tv;
    race_tv.set_lightfunc((void*)(usz)BUILTIN_PROMISE_RACE);
    ctor.put_prop(race_key, race_tv, hobject::PROP_FLAGS_WEC);

    HString* allsettled_key = builtin_intern_string(heap, "allSettled");
    TVal allsettled_tv;
    allsettled_tv.set_lightfunc((void*)(usz)BUILTIN_PROMISE_ALLSETTLED);
    ctor.put_prop(allsettled_key, allsettled_tv, hobject::PROP_FLAGS_WEC);

    HString* any_key = builtin_intern_string(heap, "any");
    TVal any_tv;
    any_tv.set_lightfunc((void*)(usz)BUILTIN_PROMISE_ANY);
    ctor.put_prop(any_key, any_tv, hobject::PROP_FLAGS_WEC);

    // Register "Promise" in global environment
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
    set_func_ctor_name_length(ctor, heap, "Promise", 1);
    env::env_declare_nonenum(global_env, promise_key, promise_val);

    return true;
}

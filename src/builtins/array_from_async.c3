/// Array.fromAsync ( asyncItems [ , mapfn [ , thisArg ] ] ), from
/// proposal-array-from-async, ratified for ES2026.
///
/// Returns a Promise that fulfills with a new array. Because this engine has
/// no async generator functions (deferred, plan 060), the spec's async-function
/// driver loop is implemented here as a *native promise state machine*: the
/// synchronous prologue (validate mapfn, obtain the iterator, construct the
/// result array) runs in `builtin_array_from_async`, which then kicks off the
/// loop and returns the outer promise immediately. Every `Await` in the spec
/// becomes a `PromiseResolve` + a pair of native reaction closures
/// (`..._step_fulfill` / `..._map_fulfill` on fulfillment, `..._reject` on
/// rejection) attached via `promise_attach_element_callbacks`. All loop state
/// lives on a hidden "state" object referenced from each closure.
///
/// Two source shapes share one driver:
///   * iterator path , @@asyncIterator, or @@iterator wrapped with
///     CreateAsyncFromSyncIterator (the AsyncFromSync adapter already
///     await-unwraps the value half, so the driver awaits only the next()
///     result and the mapped value, never the raw value).
///   * array-like path, per-index Get + Await of the element, then optional
///     mapfn + Await, then CreateDataPropertyOrThrow.
module duktape::builtins;
import duktape::types;
import duktape::hstring;
import duktape::heap;
import duktape::hobject;

// Hidden-prop keys carrying the driver state (mirrors promise.c3 / async_from_
// sync.c3 "\xFF..." unspellable-key convention). All live on one state object.
const char[] AFA_STATE_SLOT     = "\xFFafa_state";     // on each closure: -> state obj
const char[] AFA_ARR_SLOT       = "\xFFafa_arr";       // result array A
const char[] AFA_MAPFN_SLOT     = "\xFFafa_mapfn";     // mapfn (or undefined)
const char[] AFA_THISARG_SLOT   = "\xFFafa_thisArg";   // thisArg
const char[] AFA_ITER_SLOT      = "\xFFafa_iter";      // iterator object (iterator path)
const char[] AFA_NEXT_SLOT      = "\xFFafa_next";      // iterator.next method
const char[] AFA_ARRAYLIKE_SLOT = "\xFFafa_arraylike"; // array-like object
const char[] AFA_K_SLOT         = "\xFFafa_k";         // current index k
const char[] AFA_LEN_SLOT       = "\xFFafa_len";       // length (array-like path)
const char[] AFA_OUTER_SLOT     = "\xFFafa_outer";     // outer result promise
const char[] AFA_ISASYNC_SLOT   = "\xFFafa_isAsync";   // true=iterator path, false=array-like
const char[] AFA_SOURCE_SLOT    = "\xFFafa_source";    // pins asyncItems for the driver's lifetime

// ---------------------------------------------------------------------------
// State object helpers
// ---------------------------------------------------------------------------

fn void afa_put_obj(HObject* state, Heap* heap, char[] key, HObject* val) {
    HString* k = builtin_intern_string(heap, key);
    if (k == null) return;
    TVal tv;
    if (val != null) { tv.set_object(val); } else { tv.set_undefined(); }
    state.put_prop(k, tv, hobject::PROP_FLAGS_WEC, heap);
}

fn void afa_put_tval(HObject* state, Heap* heap, char[] key, TVal val) {
    HString* k = builtin_intern_string(heap, key);
    if (k == null) return;
    state.put_prop(k, val, hobject::PROP_FLAGS_WEC, heap);
}

fn void afa_put_bool(HObject* state, Heap* heap, char[] key, bool val) {
    TVal tv; tv.set_boolean(val);
    afa_put_tval(state, heap, key, tv);
}

fn void afa_put_int(HObject* state, Heap* heap, char[] key, long val) {
    TVal tv; tv.set_fastint(val);
    afa_put_tval(state, heap, key, tv);
}

fn HObject* afa_get_obj(HObject* state, Heap* heap, char[] key) {
    HString* k = builtin_intern_string(heap, key);
    if (k == null) return null;
    if (try v = state.get_prop(k, heap)) {
        if (v.is_object() && v.get_heapptr() != null) return (HObject*)v.get_heapptr();
    }
    return null;
}

fn TVal afa_get_tval(HObject* state, Heap* heap, char[] key) {
    TVal out; out.set_undefined();
    HString* k = builtin_intern_string(heap, key);
    if (k == null) return out;
    if (try v = state.get_prop(k, heap)) return v;
    return out;
}

fn bool afa_get_bool(HObject* state, Heap* heap, char[] key) {
    TVal v = afa_get_tval(state, heap, key);
    if (v.is_boolean()) return v.get_boolean();
    return false;
}

fn long afa_get_int(HObject* state, Heap* heap, char[] key) {
    TVal v = afa_get_tval(state, heap, key);
    if (v.is_fastint()) return v.get_fastint();
    if (v.is_number()) return (long)v.get_number();
    return 0;
}

/// Read the driver state object off a reaction closure's callee.
fn HObject* afa_state_of(BuiltinContext* ctx) {
    if (ctx.callee_obj == null) return null;
    return afa_get_obj(ctx.callee_obj, ctx.heap, AFA_STATE_SLOT);
}

/// Clear any stale error channels on entry to a reaction closure.
///
/// These closures are attached in fulfill/reject pairs via
/// promise_attach_element_callbacks. When the awaited promise is already
/// *rejected*, promise_trigger_reactions still enqueues the fulfill reaction
/// with the PROMISE_THROWER substitute handler; that thrower runs (as a
/// microtask with an undefined downstream, so promise_microtask_after never
/// consumes its abrupt completion) immediately before our reject reaction and
/// leaves heap.has_error / vm.throw_pending set. Left uncleared, that stale
/// channel resurfaces inside the *next* user handler drained from the queue
/// (e.g. the caller's .then rejection handler), which then spuriously throws
/// the reason. Clearing all three channels here absorbs the thrower's leak;
/// our reactions communicate outcomes solely through the outer promise.
fn void afa_clear_stale_error(BuiltinContext* ctx) {
    promise_clear_error_channels(ctx.heap, ctx.vm);
}

// ---------------------------------------------------------------------------
// Closure construction
// ---------------------------------------------------------------------------

/// Allocate a native FUNCTION closure for builtin `idx`, carrying `state`.
fn HObject* afa_make_closure(Heap* heap, uint idx, HObject* state) {
    HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = fn_raw) return null;
    HObject* cb = fn_raw;
    (*cb.extra_ptr()).func.builtin_fn_index = (int)idx;
    cb.flags.callable = true;
    cb.flags.constructable = false;
    cb.prototype = heap.function_proto;
    afa_put_obj(cb, heap, AFA_STATE_SLOT, state);
    return cb;
}

/// Await(value): PromiseResolve(%Promise%, value) then attach the given
/// fulfill/reject reaction closures. Models one spec `Await` step.
/// On allocation failure, rejects the outer promise with a generic error.
fn void afa_await(Heap* heap, void* vm, HObject* state, TVal value, uint fulfill_idx) {
    HObject* fulfill = afa_make_closure(heap, fulfill_idx, state);
    HObject* reject  = afa_make_closure(heap, Builtin.ARRAY_FROM_ASYNC_REJECT.ordinal, state);
    if (fulfill == null || reject == null) { afa_reject_outer_alloc(heap, vm, state); return; }

    HObject*? vp_raw = promise_resolve_default_ctor(heap, vm, value);
    if (heap.has_error) {
        TVal reason = heap.error_value;
        heap.has_error = false;
        afa_reject_outer(heap, vm, state, reason);
        return;
    }
    if (catch err = vp_raw) { afa_reject_outer_alloc(heap, vm, state); return; }
    HObject* value_promise = vp_raw;
    promise_attach_element_callbacks(value_promise, fulfill, reject, heap, vm);
}

// ---------------------------------------------------------------------------
// Outer-promise settlement
// ---------------------------------------------------------------------------

fn void afa_resolve_outer(Heap* heap, void* vm, HObject* state, TVal value) {
    HObject* outer = afa_get_obj(state, heap, AFA_OUTER_SLOT);
    if (outer == null) return;
    // The array A is a fully-built ordinary array, never a thenable, so a
    // plain fulfill is correct (and matches Array.from's non-Promise return).
    promise_settle(outer, PROMISE_FULFILLED, &value, heap);
    promise_trigger_reactions(outer, heap, vm);
}

fn void afa_reject_outer(Heap* heap, void* vm, HObject* state, TVal reason) {
    HObject* outer = afa_get_obj(state, heap, AFA_OUTER_SLOT);
    if (outer == null) return;
    promise_settle(outer, PROMISE_REJECTED, &reason, heap);
    promise_trigger_reactions(outer, heap, vm);
}

fn void afa_reject_outer_alloc(Heap* heap, void* vm, HObject* state) {
    TVal te = async_from_sync_type_error(heap, "Array.fromAsync internal allocation failure");
    afa_reject_outer(heap, vm, state, te);
}

/// Build a RangeError value (without touching heap.has_error) for use as a
/// rejection reason. Mirrors async_from_sync_type_error but for RangeError.
fn TVal afa_range_error(Heap* heap, char[] msg) {
    TVal out; out.set_undefined();
    HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = heap.range_err_proto;
        HString* msg_str = builtin_intern_string(heap, msg);
        if (msg_str != null) {
            TVal msg_tv; msg_tv.set_string(msg_str);
            HString* msg_key = heap.str(heap::BuiltinStr.MESSAGE);
            if (msg_key != null) err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC, heap);
        }
        out.set_object(err);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Iterator close (on abrupt completion)
// ---------------------------------------------------------------------------

/// Best-effort IteratorClose / AsyncIteratorClose: call iterator.return() and
/// discard its result. For the async path the adapter's return() yields a
/// promise; we don't await it (the original rejection reason is what the outer
/// promise settles with, and swallowing return()'s own errors matches the
/// pragmatic behaviour of the sync close helper).
fn void afa_close_iterator(Heap* heap, void* vm, HObject* state) {
    HObject* iter = afa_get_obj(state, heap, AFA_ITER_SLOT);
    if (iter == null) return;
    if (heap.call_fn == null || vm == null) return;
    HString* return_key = builtin_intern_string(heap, "return");
    if (return_key == null) return;
    TVal? rm_opt = iter.get_prop_proto(return_key, heap);
    if (try rm = rm_opt) {
        if (rm.is_undefined() || rm.is_null()) return;
        bool callable = rm.is_lightfunc() ||
            (rm.is_object() && rm.get_heapptr() != null && ((HObject*)rm.get_heapptr()).is_callable());
        if (!callable) return;
        TVal iter_tv; iter_tv.set_object(iter);
        heap.call_fn(vm, rm, null, 0, iter_tv);
        // Swallow errors from return(), the original completion takes priority.
        if (heap.has_error) heap.has_error = false;
    }
}

// ---------------------------------------------------------------------------
// Main entry, Array.fromAsync
// ---------------------------------------------------------------------------

fn void builtin_array_from_async(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    ctx.result.set_undefined();

    // Step 1: Let C be the this value.
    TVal c_val = ctx.this_val;

    // Create the outer result promise up front so every error path can reject
    // it and return a rejected promise (fromAsync never throws synchronously
    // except for a bad mapfn, actually even that rejects per spec §3.i).
    HObject*? outer_raw = promise_create(heap);
    if (catch err = outer_raw) { return; }
    HObject* outer = outer_raw;
    outer.prototype = heap.promise_proto;
    ctx.result.set_object(outer);

    // Build the shared state object.
    HObject*? state_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = state_raw) {
        TVal te = async_from_sync_type_error(heap, "Array.fromAsync internal allocation failure");
        promise_settle(outer, PROMISE_REJECTED, &te, heap);
        promise_trigger_reactions(outer, heap, ctx.vm);
        return;
    }
    HObject* state = state_raw;
    state.prototype = null;
    afa_put_obj(state, heap, AFA_OUTER_SLOT, outer);
    afa_put_int(state, heap, AFA_K_SLOT, 0);

    // Step 2: asyncItems (arg 0).
    TVal async_items;
    if (ctx.argc > 0) { async_items = ctx.regs[ctx.base_reg]; } else { async_items.set_undefined(); }

    // Step 3: mapfn (arg 1). If not undefined, must be callable, else reject.
    TVal mapfn; mapfn.set_undefined();
    bool mapping = false;
    TVal this_arg; this_arg.set_undefined();
    if (ctx.argc > 1) {
        mapfn = ctx.regs[ctx.base_reg + 1];
        if (!mapfn.is_undefined()) {
            if (!arr_from_is_callable(mapfn)) {
                TVal te = async_from_sync_type_error(heap, "Array.fromAsync mapfn is not callable");
                promise_settle(outer, PROMISE_REJECTED, &te, heap);
                promise_trigger_reactions(outer, heap, ctx.vm);
                return;
            }
            mapping = true;
            if (ctx.argc > 2) this_arg = ctx.regs[ctx.base_reg + 2];
        }
    }
    afa_put_tval(state, heap, AFA_MAPFN_SLOT, mapfn);
    afa_put_bool(state, heap, "\xFFafa_mapping", mapping);
    afa_put_tval(state, heap, AFA_THISARG_SLOT, this_arg);

    // Steps 4-8: obtain an iterator. GetMethod(asyncItems, @@asyncIterator),
    // then GetMethod(asyncItems, @@iterator) wrapped via CreateAsyncFromSync.
    // Wrap primitives in a temporary object for the property lookup (ToObject).
    HObject* items_obj = null;
    if (async_items.is_object() && async_items.get_heapptr() != null) {
        items_obj = (HObject*)async_items.get_heapptr();
    } else if (!async_items.is_undefined() && !async_items.is_null()) {
        HObject*? wrapped = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try w = wrapped) {
            items_obj = w;
            HObject* wrap_proto = heap.string_proto;
            if (async_items.is_string()) {
                // Symbols share the STRING tag: a Symbol primitive must wrap
                // to an ordinary object with Symbol.prototype, NOT a string
                // exotic (which would find String.prototype[@@iterator] and
                // throw trying to stringify the symbol).
                HString* hs = (HString*)async_items.get_heapptr();
                if (hs != null && hs.is_symbol()) {
                    wrap_proto = heap.symbol_proto;
                } else {
                    (*items_obj.extra_ptr()).prim.primitive_value = async_items;
                }
            } else if (async_items.is_fastint() || async_items.is_number()) {
                wrap_proto = heap.number_proto;
            } else if (async_items.is_boolean()) {
                wrap_proto = heap.bool_proto;
            } else if (async_items.is_bigint()) {
                wrap_proto = heap.bigint_proto;
            }
            items_obj.prototype = wrap_proto;
        }
    }

    TVal iter_method; iter_method.set_undefined();
    bool have_iter = false;
    bool wrap_sync = false;

    if (items_obj != null) {
        // @@asyncIterator first.
        HString* async_sym = ensure_asynciterator_symbol(heap);
        if (async_sym != null) {
            TVal? m_opt = builtins_generic_get(items_obj, async_sym, ctx);
            if (ctx.should_throw) { afa_flush_prologue_throw(ctx, outer); return; }
            if (try m = m_opt) {
                if (!m.is_undefined() && !m.is_null()) { iter_method = m; have_iter = true; }
            }
        }
        // Fall back to @@iterator (sync) if no @@asyncIterator.
        if (!have_iter) {
            HString* iter_sym = ensure_iterator_symbol(heap);
            if (iter_sym != null) {
                TVal? m_opt = builtins_generic_get(items_obj, iter_sym, ctx);
                if (ctx.should_throw) { afa_flush_prologue_throw(ctx, outer); return; }
                if (try m = m_opt) {
                    if (!m.is_undefined() && !m.is_null()) {
                        iter_method = m; have_iter = true; wrap_sync = true;
                    }
                }
            }
        }
    }

    if (have_iter) {
        if (!arr_from_is_callable(iter_method)) {
            TVal te = async_from_sync_type_error(heap, "Array.fromAsync iterator method is not callable");
            promise_settle(outer, PROMISE_REJECTED, &te, heap);
            promise_trigger_reactions(outer, heap, ctx.vm);
            return;
        }

        // Construct A (IsConstructor(C) ? Construct(C) : ArrayCreate(0)) BEFORE
        // GetIterator, per spec order.
        HObject* arr = afa_construct_result(ctx, c_val, false, 0);
        if (ctx.should_throw) { afa_flush_prologue_throw(ctx, outer); return; }
        if (arr == null) { afa_reject_outer_alloc(heap, ctx.vm, state); return; }
        afa_put_obj(state, heap, AFA_ARR_SLOT, arr);

        // GetIterator: iterator = Call(iter_method, asyncItems).
        TVal iterator = heap.call_fn(ctx.vm, iter_method, null, 0, async_items);
        if (heap.has_error) {
            TVal reason = heap.error_value; heap.has_error = false;
            promise_settle(outer, PROMISE_REJECTED, &reason, heap);
            promise_trigger_reactions(outer, heap, ctx.vm);
            return;
        }
        if (!iterator.is_object() || iterator.get_heapptr() == null) {
            TVal te = async_from_sync_type_error(heap, "Array.fromAsync iterator is not an object");
            promise_settle(outer, PROMISE_REJECTED, &te, heap);
            promise_trigger_reactions(outer, heap, ctx.vm);
            return;
        }
        HObject* sync_or_async_iter = (HObject*)iterator.get_heapptr();

        // Pin asyncItems for the driver's lifetime. The built-in array iterator
        // holds only a *borrowed* GC pointer to its target (see
        // create_array_iterator: iter.target = iterable, no incref); when
        // fromAsync is reached via Function.prototype.call the source's only
        // other strong reference can be released as intervening frames unwind,
        // letting the source be freed and its heap slot reused (observed as the
        // source array turning into our state object mid-iteration). Holding a
        // strong reference on state keeps the iterator's target alive.
        afa_put_tval(state, heap, AFA_SOURCE_SLOT, async_items);

        // For a sync iterable, wrap with CreateAsyncFromSyncIterator so the
        // driver can uniformly await the next() result (the adapter unwraps the
        // value half itself).
        HObject* iter_obj = sync_or_async_iter;
        if (wrap_sync) {
            HObject*? adapter = async_from_sync_iterator(heap, sync_or_async_iter, ctx.vm);
            if (heap.has_error) {
                // The sync `next` getter threw while caching [[NextMethod]],
                // reject the fromAsync promise with the thrown value.
                TVal thrown = heap.error_value; heap.has_error = false;
                afa_reject_outer(heap, ctx.vm, state, thrown);
                return;
            }
            if (catch err = adapter) { afa_reject_outer_alloc(heap, ctx.vm, state); return; }
            iter_obj = adapter;
        }
        afa_put_obj(state, heap, AFA_ITER_SLOT, iter_obj);
        afa_put_bool(state, heap, AFA_ISASYNC_SLOT, true);

        // GetMethod(iterator, "next") once (§ IteratorRecord [[NextMethod]]).
        HString* next_key = builtin_intern_string(heap, "next");
        TVal? next_opt = builtins_generic_get(iter_obj, next_key, ctx);
        if (ctx.should_throw) { afa_flush_prologue_throw(ctx, outer); return; }
        TVal next_method; next_method.set_undefined();
        if (try nm = next_opt) next_method = nm;
        afa_put_tval(state, heap, AFA_NEXT_SLOT, next_method);

        // Kick off the loop: call next() and await its result.
        afa_iterator_step(heap, ctx.vm, state);
        return;
    }

    // Steps 9-10: array-like path. asyncItems must not be null/undefined.
    if (async_items.is_undefined() || async_items.is_null()) {
        TVal te = async_from_sync_type_error(heap, "Array.fromAsync: cannot convert undefined or null to object");
        promise_settle(outer, PROMISE_REJECTED, &te, heap);
        promise_trigger_reactions(outer, heap, ctx.vm);
        return;
    }

    // items_obj is already the ToObject result (built above for primitives).
    HObject* array_like = items_obj;
    if (array_like == null) { afa_reject_outer_alloc(heap, ctx.vm, state); return; }
    afa_put_obj(state, heap, AFA_ARRAYLIKE_SLOT, array_like);
    afa_put_bool(state, heap, AFA_ISASYNC_SLOT, false);

    // LengthOfArrayLike(arrayLike).
    HString* len_key = heap.str(heap::BuiltinStr.LENGTH);
    ulong len = 0;
    if (len_key != null) {
        TVal? len_opt = builtins_generic_get(array_like, len_key, ctx);
        if (ctx.should_throw) { afa_flush_prologue_throw(ctx, outer); return; }
        if (try lv = len_opt) {
            // ToLength via ToNumber with ToPrimitive: an object-valued
            // length (observable valueOf) must be coerced, not NaN'd.
            double len_d = builtin_to_number_vm(ctx, &lv);
            if (ctx.should_throw) { afa_flush_prologue_throw(ctx, outer); return; }
            len = arr_to_length(len_d);
        }
    }
    afa_put_int(state, heap, AFA_LEN_SLOT, (long)len);

    // When C is not a constructor, A = ArrayCreate(len), which throws a
    // RangeError for len > 2^32 - 1 (ES2024 ArrayCreate step 1). A constructor
    // path delegates the range decision to Construct(C, «len»).
    bool c_is_ctor = c_val.is_object() && c_val.get_heapptr() != null && arr_from_is_callable(c_val);
    if (!c_is_ctor && len > 0xFFFFFFFF) {
        TVal re = afa_range_error(heap, "Array.fromAsync: invalid array length");
        promise_settle(outer, PROMISE_REJECTED, &re, heap);
        promise_trigger_reactions(outer, heap, ctx.vm);
        return;
    }

    // Construct A (IsConstructor(C) ? Construct(C, «len») : ArrayCreate(len)).
    HObject* arr = afa_construct_result(ctx, c_val, true, len);
    if (ctx.should_throw) { afa_flush_prologue_throw(ctx, outer); return; }
    if (arr == null) { afa_reject_outer_alloc(heap, ctx.vm, state); return; }
    afa_put_obj(state, heap, AFA_ARR_SLOT, arr);

    // Kick off the array-like loop.
    afa_arraylike_step(heap, ctx.vm, state);
}

/// Move a ctx-recorded abrupt completion (ctx.should_throw/throw_value) onto
/// the outer promise as a rejection. Used by the synchronous prologue.
fn void afa_flush_ctx_throw_to_outer(BuiltinContext* ctx, HObject* outer) {
    TVal reason = ctx.throw_value;
    ctx.should_throw = false;
    if (ctx.heap.has_error) ctx.heap.has_error = false;
    promise_settle(outer, PROMISE_REJECTED, &reason, ctx.heap);
    promise_trigger_reactions(outer, ctx.heap, ctx.vm);
}

/// Prologue variant: builtin_throw (which set should_throw) also clobbered
/// ctx.result to undefined, restore the outer promise so fromAsync still
/// RETURNS the (now rejected) promise instead of undefined. Only valid for
/// the real fromAsync BuiltinContext, not the driver's stack-local lctx.
fn void afa_flush_prologue_throw(BuiltinContext* ctx, HObject* outer) {
    afa_flush_ctx_throw_to_outer(ctx, outer);
    ctx.result.set_object(outer);
}

/// Construct the result array A. When `with_len`, IsConstructor(C) receives
/// «len». Returns null on allocation failure; sets ctx.should_throw if the
/// constructor threw.
fn HObject* afa_construct_result(BuiltinContext* ctx, TVal c_val, bool with_len, ulong len) {
    Heap* heap = ctx.heap;
    HObject* arr = null;
    if (c_val.is_object() && c_val.get_heapptr() != null && arr_from_is_callable(c_val)) {
        TVal ctor_result;
        if (with_len) {
            TVal len_arg;
            if (len <= 0x7FFFFFFF) { len_arg.set_fastint((long)len); } else { len_arg.set_number((double)len); }
            ctor_result = heap.construct_fn(ctx.vm, c_val, &len_arg, 1, c_val);
        } else {
            ctor_result = heap.construct_fn(ctx.vm, c_val, null, 0, c_val);
        }
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            return null;
        }
        if (ctor_result.is_object() && ctor_result.get_heapptr() != null) {
            arr = (HObject*)ctor_result.get_heapptr();
        }
    }
    if (arr == null) {
        HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
        if (catch err = arr_raw) return null;
        arr = arr_raw;
        arr.prototype = heap.array_proto;
    }
    return arr;
}

// ---------------------------------------------------------------------------
// Iterator-path driver
// ---------------------------------------------------------------------------

/// Call iterator.next() and Await its result (which lands in
/// builtin_array_from_async_step_fulfill). On a synchronous throw from next(),
/// reject the outer promise directly (no iterator to close, the step failed).
fn void afa_iterator_step(Heap* heap, void* vm, HObject* state) {
    HObject* iter = afa_get_obj(state, heap, AFA_ITER_SLOT);
    TVal next_method = afa_get_tval(state, heap, AFA_NEXT_SLOT);
    if (iter == null) { afa_reject_outer_alloc(heap, vm, state); return; }

    bool callable = next_method.is_lightfunc() ||
        (next_method.is_object() && next_method.get_heapptr() != null &&
         ((HObject*)next_method.get_heapptr()).is_callable());
    if (!callable) {
        TVal te = async_from_sync_type_error(heap, "Array.fromAsync: iterator.next is not callable");
        afa_reject_outer(heap, vm, state, te);
        return;
    }

    TVal iter_tv; iter_tv.set_object(iter);
    TVal step_result = heap.call_fn(vm, next_method, null, 0, iter_tv);
    if (heap.has_error) {
        TVal reason = heap.error_value; heap.has_error = false;
        afa_reject_outer(heap, vm, state, reason);
        return;
    }
    // Await(step_result): the next() result is a promise for {value,done}.
    afa_await(heap, vm, state, step_result, Builtin.ARRAY_FROM_ASYNC_STEP_FULFILL.ordinal);
}

/// Fulfill reaction for an awaited iterator step. The argument is the resolved
/// iterator result object {value, done}. Reads done/value; if done, finalize
/// (set length, resolve outer); else await the value's mapping/storage.
fn void builtin_array_from_async_step_fulfill(BuiltinContext* ctx) {
    ctx.result.set_undefined();
    afa_clear_stale_error(ctx);
    Heap* heap = ctx.heap;
    HObject* state = afa_state_of(ctx);
    if (state == null) return;

    bool is_async = afa_get_bool(state, heap, AFA_ISASYNC_SLOT);
    if (!is_async) {
        // Array-like path uses this same fulfill for the awaited element value.
        afa_arraylike_value_ready(ctx, state);
        return;
    }

    TVal step_result; step_result.set_undefined();
    if (ctx.argc >= 1) step_result = ctx.regs[ctx.base_reg];
    if (!step_result.is_object() || step_result.get_heapptr() == null) {
        TVal te = async_from_sync_type_error(heap, "Array.fromAsync: iterator result is not an object");
        afa_reject_outer(heap, ctx.vm, state, te);
        return;
    }
    HObject* result_obj = (HObject*)step_result.get_heapptr();

    // IteratorComplete: Get(result, "done") -> ToBoolean.
    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal? done_opt = builtins_generic_get(result_obj, done_key, ctx);
    if (ctx.should_throw) { afa_close_and_reject_ctx(ctx, state); return; }
    bool done = false;
    if (try dv = done_opt) done = builtin_to_boolean(&dv);

    if (done) {
        afa_finalize(heap, ctx.vm, state);
        return;
    }

    // IteratorValue: Get(result, "value").
    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    TVal? value_opt = builtins_generic_get(result_obj, value_key, ctx);
    if (ctx.should_throw) { afa_close_and_reject_ctx(ctx, state); return; }
    TVal value; value.set_undefined();
    if (try vv = value_opt) value = vv;

    // NOTE: unlike the array-like path, the iterator path does NOT await the
    // raw value (only the mapped value). The AsyncFromSync adapter already
    // await-unwrapped the sync case; native async iterators resolve their own
    // values.
    afa_process_value(ctx, state, value);
}

/// Given a (already-awaited, for the iterator path) value: apply mapfn if
/// mapping (and await the mapped result), else store directly and advance.
fn void afa_process_value(BuiltinContext* ctx, HObject* state, TVal value) {
    Heap* heap = ctx.heap;
    bool mapping = afa_get_bool(state, heap, "\xFFafa_mapping");
    long k = afa_get_int(state, heap, AFA_K_SLOT);

    if (mapping) {
        TVal mapfn = afa_get_tval(state, heap, AFA_MAPFN_SLOT);
        TVal this_arg = afa_get_tval(state, heap, AFA_THISARG_SLOT);
        TVal[2] args;
        args[0] = value;
        args[1].set_fastint(k);
        TVal mapped = heap.call_fn(ctx.vm, mapfn, &args[0], 2, this_arg);
        if (heap.has_error) {
            TVal reason = heap.error_value; heap.has_error = false;
            afa_close_and_reject(heap, ctx.vm, state, reason);
            return;
        }
        // Await(mappedValue) -> map_fulfill stores it.
        afa_await(heap, ctx.vm, state, mapped, Builtin.ARRAY_FROM_ASYNC_MAP_FULFILL.ordinal);
        return;
    }

    // No mapping: store value directly, advance, loop.
    if (!afa_store_and_advance(ctx, state, value)) return;
    bool is_async = afa_get_bool(state, heap, AFA_ISASYNC_SLOT);
    if (is_async) {
        afa_iterator_step(heap, ctx.vm, state);
    } else {
        afa_arraylike_step(heap, ctx.vm, state);
    }
}

/// Fulfill reaction for an awaited mapped value. Store it, advance, loop.
fn void builtin_array_from_async_map_fulfill(BuiltinContext* ctx) {
    ctx.result.set_undefined();
    afa_clear_stale_error(ctx);
    Heap* heap = ctx.heap;
    HObject* state = afa_state_of(ctx);
    if (state == null) return;

    TVal mapped; mapped.set_undefined();
    if (ctx.argc >= 1) mapped = ctx.regs[ctx.base_reg];

    if (!afa_store_and_advance(ctx, state, mapped)) return;
    bool is_async = afa_get_bool(state, heap, AFA_ISASYNC_SLOT);
    if (is_async) {
        afa_iterator_step(heap, ctx.vm, state);
    } else {
        afa_arraylike_step(heap, ctx.vm, state);
    }
}

/// CreateDataPropertyOrThrow(A, k, value); k++. Returns false (and rejects the
/// outer promise, closing the iterator when async) on a store failure.
fn bool afa_store_and_advance(BuiltinContext* ctx, HObject* state, TVal value) {
    Heap* heap = ctx.heap;
    HObject* arr = afa_get_obj(state, heap, AFA_ARR_SLOT);
    long k = afa_get_int(state, heap, AFA_K_SLOT);
    if (arr == null) { afa_reject_outer_alloc(heap, ctx.vm, state); return false; }

    HString* pk = heap.int_to_hstring(k);
    if (pk != null) {
        if (!afa_create_data_property(ctx, heap, state, arr, pk, value)) return false;
    }
    afa_put_int(state, heap, AFA_K_SLOT, k + 1);
    return true;
}

/// CreateDataPropertyOrThrow(arr, key, value), ES2022 §7.3.5.
///
/// Routes through the full [[DefineOwnProperty]] MOP (object_define_own): a
/// Proxy result fires its `defineProperty` trap (order-of-operations tests
/// observe this) and any ordinary result gets correct ValidateAndApply
/// semantics, so redefining a pre-existing non-configurable own index (e.g. a
/// custom constructor whose instances predefine a read-only element) yields
/// res=false → a rejecting TypeError, which the simpler put_prop-only path
/// misses. On failure closes the iterator (async path) and rejects outer.
fn bool afa_create_data_property(BuiltinContext* ctx, Heap* heap, HObject* state, HObject* arr, HString* key, TVal value) {
    ProxyDesc nd = {};
    nd.found = true;
    nd.has_value = true; nd.value = value;
    nd.has_writable = true; nd.writable = true;
    nd.has_enumerable = true; nd.enumerable = true;
    nd.has_configurable = true; nd.configurable = true;
    bool res = false;
    if (!object_define_own(ctx.vm, heap, arr, key, &nd, &res)) {
        TVal reason;
        if (heap.has_error) { reason = heap.error_value; heap.has_error = false; }
        else { reason = async_from_sync_type_error(heap, "Array.fromAsync: CreateDataProperty failed"); }
        afa_close_and_reject(heap, ctx.vm, state, reason);
        return false;
    }
    if (!res) {
        TVal te = async_from_sync_type_error(heap, "Array.fromAsync: cannot define array element");
        afa_close_and_reject(heap, ctx.vm, state, te);
        return false;
    }
    return true;
}

/// Finalize the iterator path: Set(A, "length", k) then resolve outer with A.
fn void afa_finalize(Heap* heap, void* vm, HObject* state) {
    HObject* arr = afa_get_obj(state, heap, AFA_ARR_SLOT);
    if (arr == null) { afa_reject_outer_alloc(heap, vm, state); return; }
    long k = afa_get_int(state, heap, AFA_K_SLOT);

    BuiltinContext lctx;
    lctx.vm = vm;
    lctx.heap = heap;
    lctx.should_throw = false;
    HString* len_key = heap.str(heap::BuiltinStr.LENGTH);
    if (len_key != null) {
        if (!arr_set_length_or_throw(&lctx, arr, len_key, (ulong)k)) {
            afa_close_and_reject_ctx(&lctx, state);
            return;
        }
    }
    TVal arr_tv; arr_tv.set_object(arr);
    afa_resolve_outer(heap, vm, state, arr_tv);
}

// ---------------------------------------------------------------------------
// Array-like driver
// ---------------------------------------------------------------------------

/// One array-like iteration: if k >= len finalize; else Get(arrayLike, k) and
/// Await it (landing in the shared step_fulfill, which routes to
/// afa_arraylike_value_ready for the non-async path).
fn void afa_arraylike_step(Heap* heap, void* vm, HObject* state) {
    long k = afa_get_int(state, heap, AFA_K_SLOT);
    long len = afa_get_int(state, heap, AFA_LEN_SLOT);
    if (k >= len) {
        // Set(A, "length", len) then resolve.
        HObject* arr = afa_get_obj(state, heap, AFA_ARR_SLOT);
        if (arr == null) { afa_reject_outer_alloc(heap, vm, state); return; }
        BuiltinContext lctx;
        lctx.vm = vm; lctx.heap = heap; lctx.should_throw = false;
        HString* len_key = heap.str(heap::BuiltinStr.LENGTH);
        if (len_key != null) {
            if (!arr_set_length_or_throw(&lctx, arr, len_key, (ulong)len)) {
                afa_flush_ctx_throw_to_outer(&lctx, afa_get_obj(state, heap, AFA_OUTER_SLOT));
                return;
            }
        }
        TVal arr_tv; arr_tv.set_object(arr);
        afa_resolve_outer(heap, vm, state, arr_tv);
        return;
    }

    HObject* array_like = afa_get_obj(state, heap, AFA_ARRAYLIKE_SLOT);
    if (array_like == null) { afa_reject_outer_alloc(heap, vm, state); return; }

    BuiltinContext lctx;
    lctx.vm = vm; lctx.heap = heap; lctx.should_throw = false;
    HString* pk = heap.int_to_hstring(k);
    TVal kvalue; kvalue.set_undefined();
    if (pk != null) {
        TVal? elem_opt = builtins_generic_get(array_like, pk, &lctx);
        if (lctx.should_throw) {
            afa_flush_ctx_throw_to_outer(&lctx, afa_get_obj(state, heap, AFA_OUTER_SLOT));
            return;
        }
        if (try e = elem_opt) kvalue = e;
    }
    // Await(kValue) -> step_fulfill -> afa_arraylike_value_ready.
    afa_await(heap, vm, state, kvalue, Builtin.ARRAY_FROM_ASYNC_STEP_FULFILL.ordinal);
}

/// Array-like path: the awaited element value is ready. Apply mapfn (+await) or
/// store directly, then advance.
fn void afa_arraylike_value_ready(BuiltinContext* ctx, HObject* state) {
    TVal value; value.set_undefined();
    if (ctx.argc >= 1) value = ctx.regs[ctx.base_reg];
    afa_process_value(ctx, state, value);
}

// ---------------------------------------------------------------------------
// Rejection reaction + close helpers
// ---------------------------------------------------------------------------

/// Generic reject reaction: an awaited value/next-result/mapped-value rejected.
/// Close the iterator (if any) and reject the outer promise with the reason.
fn void builtin_array_from_async_reject(BuiltinContext* ctx) {
    ctx.result.set_undefined();
    // Capture the reason BEFORE clearing channels, the reject reason lives in
    // ctx.regs, but a stale sibling-thrower error must not leak to the caller's
    // handler drained after us.
    TVal reason; reason.set_undefined();
    if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];
    afa_clear_stale_error(ctx);
    Heap* heap = ctx.heap;
    HObject* state = afa_state_of(ctx);
    if (state == null) return;
    afa_close_and_reject(heap, ctx.vm, state, reason);
}

/// Close the iterator (if async path) and reject outer with `reason`.
/// The reason may be a borrowed reference from a caller's register/microtask
/// slot; closing the iterator can run arbitrary JS (iterator.return) that
/// triggers GC and would free a solely-borrowed reason string before we settle
/// with it. Anchor a strong reference across the close, then release it.
fn void afa_close_and_reject(Heap* heap, void* vm, HObject* state, TVal reason) {
    bool is_async = afa_get_bool(state, heap, AFA_ISASYNC_SLOT);
    if (is_async) afa_close_iterator(heap, vm, state);
    afa_reject_outer(heap, vm, state, reason);
}

/// Same, taking the reason from ctx.throw_value (after a ctx-recorded throw).
fn void afa_close_and_reject_ctx(BuiltinContext* ctx, HObject* state) {
    TVal reason = ctx.throw_value;
    ctx.should_throw = false;
    if (ctx.heap.has_error) ctx.heap.has_error = false;
    afa_close_and_reject(ctx.heap, ctx.vm, state, reason);
}

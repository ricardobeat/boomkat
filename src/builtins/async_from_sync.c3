/// %AsyncFromSyncIteratorPrototype% — ES2018 §27.1.4.
///
/// Wraps a synchronous iterator so `for await` can drive it: `next`/`return`/
/// `throw` all return Promises, and per §27.1.4.4 AsyncFromSyncIteratorContinuation
/// the *value* half of the sync `{value, done}` result is itself Promise-resolved
/// (awaited) before the caller sees it, so a synchronously-thenable value
/// still gets unwrapped like it would from a real async iterator.
module duktape::builtins;
import duktape::types;
import duktape::hstring;
import duktape::heap;
import duktape::hobject;

/// Internal-slot key holding the wrapped [[SyncIteratorRecord]]'s iterator
/// object. There is no dedicated ObjClass/HObjectExtra member for this
/// adapter (it would need a new union member + GC-mark case for a single
/// TVal), so — following the same convention as Promise capability state
/// and Promise.all element callbacks (see promise.c3's "\xFFcap_*" /
/// "\xFFstate" hidden props) — the sync iterator is stashed as a TVal behind
/// a hidden, unprintable-prefixed property key that user code cannot spell.
const char[] ASYNC_FROM_SYNC_ITERATOR_SLOT = "\xFFsyncIterator";

/// Hidden-prop keys on the native value-unwrap/reject-forward reaction
/// closures (mirrors promise.c3's promise_create_element_callback pattern).
const char[] ASYNC_FROM_SYNC_DONE_SLOT  = "\xFFdone";
const char[] ASYNC_FROM_SYNC_OUTER_SLOT = "\xFFouter";

/// Slots on the reject-forward closure carrying the sync iterator to close and
/// a flag marking whether it should be closed (§27.1.4.4 step 13: the onRejected
/// reaction closes the iterator when the yielded "value" is a rejected promise
/// and `done` is false).
const char[] ASYNC_FROM_SYNC_CLOSEITER_SLOT = "\xFFcloseIter";

/// Create %AsyncFromSyncIteratorPrototype% (ES2018 §27.1.4): a plain object
/// (inherits directly from %ObjectPrototype%, not %IteratorPrototype%) with
/// next/return/throw methods.
fn bool register_async_from_sync_iterator_prototype(Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    heap.async_from_sync_iter_proto = proto;

    if (!register_string_proto_method(proto, heap, "next",   Builtin.ASYNC_FROM_SYNC_NEXT.ordinal))   return false;
    if (!register_string_proto_method(proto, heap, "return", Builtin.ASYNC_FROM_SYNC_RETURN.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "throw",  Builtin.ASYNC_FROM_SYNC_THROW.ordinal))  return false;

    return true;
}

/// Allocate an %AsyncFromSyncIteratorPrototype% instance wrapping `syncIter`
/// (ES2018 §27.1.4.1 CreateAsyncFromSyncIterator). Called from the
/// GET_ITER_ASYNC opcode handler once it has obtained a sync iterator via
/// @@iterator.
fn HObject*? async_from_sync_iterator(Heap* heap, HObject* syncIter, void* vm) {
    HObject*? adapter_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = adapter_raw) return null;
    HObject* adapter = adapter_raw;
    adapter.prototype = heap.async_from_sync_iter_proto;

    HString* slot_key = builtin_intern_string(heap, ASYNC_FROM_SYNC_ITERATOR_SLOT);
    if (slot_key == null) return null;
    TVal sync_tv;
    sync_tv.set_object(syncIter);
    adapter.put_prop(slot_key, sync_tv, hobject::PROP_FLAGS_WEC);

    return adapter;
}

/// Read the wrapped sync iterator off an adapter object, or null if `this`
/// isn't one (guards against `AsyncFromSyncIteratorPrototype.next.call(x)`).
fn HObject* async_from_sync_get_wrapped(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object()) return null;
    HObject* adapter = (HObject*)ctx.this_val.get_heapptr();
    if (adapter == null) return null;
    HString* slot_key = builtin_intern_string(ctx.heap, ASYNC_FROM_SYNC_ITERATOR_SLOT);
    if (slot_key == null) return null;
    TVal? sync_opt = adapter.get_prop(slot_key);
    if (try sv = sync_opt) {
        if (sv.is_object() && sv.get_heapptr() != null) return (HObject*)sv.get_heapptr();
    }
    return null;
}

/// Build the promise-fulfill / promise-reject pair of native reaction
/// closures used to finish AsyncFromSyncIteratorContinuation, and attach
/// them to `value_promise`. `done` is baked into the fulfill closure so it
/// can build `{value, done}` once the (possibly-thenable) value settles.
/// Returns the outer promise the caller should hand back to `for await`.
fn HObject*? async_from_sync_continuation(Heap* heap, void* vm, HObject* sync_iter, TVal result_value, bool done, bool close_on_rejection) {
    HObject*? outer_raw = promise_create(heap);
    if (catch err = outer_raw) return null;
    HObject* outer = outer_raw;

    // ES2018 §27.1.4.4 step: "Let valueWrapper be PromiseResolve(%Promise%,
    // value)" — the full PromiseResolve abstract operation, which performs an
    // observable `Get(value, "constructor")` lookup when value is already a
    // Promise (returning it unchanged when the constructor is %Promise%)
    // before falling back to the internal [[Resolve]] procedure (thenable
    // coercion / plain fulfillment) for every other case.
    HObject*? value_promise_raw = promise_resolve_default_ctor(heap, vm, result_value);
    if (heap.has_error) {
        // §27.1.4.4 step 6: "If valueWrapper is an abrupt completion, done is
        // false, and closeOnRejection is true, then set valueWrapper to
        // IteratorClose(syncIteratorRecord, valueWrapper)." A close that throws
        // replaces the rejection reason; otherwise the original reason stands.
        TVal ctor_err = heap.error_value;
        heap.has_error = false;
        if (!done && close_on_rejection && sync_iter != null) {
            AsyncFromSyncCloseResult cr = async_from_sync_iterator_close_normal(heap, vm, sync_iter);
            if (cr.threw) ctor_err = cr.error;
        }
        promise_settle(outer, PROMISE_REJECTED, &ctor_err, heap);
        promise_trigger_reactions(outer, heap, vm);
        return outer;
    }
    if (catch err = value_promise_raw) return null;
    HObject* value_promise = value_promise_raw;

    HObject*? fulfill_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = fulfill_raw) return null;
    HObject* fulfill_fn = fulfill_raw;
    (*fulfill_fn.extra_ptr()).func.builtin_fn_index = (int)Builtin.ASYNC_FROM_SYNC_VALUE_UNWRAP.ordinal;
    fulfill_fn.flags.callable = true;
    fulfill_fn.flags.constructable = false;
    fulfill_fn.prototype = heap.function_proto;

    HObject*? reject_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = reject_raw) return null;
    HObject* reject_fn = reject_raw;
    (*reject_fn.extra_ptr()).func.builtin_fn_index = (int)Builtin.ASYNC_FROM_SYNC_REJECT_FORWARD.ordinal;
    reject_fn.flags.callable = true;
    reject_fn.flags.constructable = false;
    reject_fn.prototype = heap.function_proto;

    HString* done_key  = builtin_intern_string(heap, ASYNC_FROM_SYNC_DONE_SLOT);
    HString* outer_key = builtin_intern_string(heap, ASYNC_FROM_SYNC_OUTER_SLOT);
    if (done_key == null || outer_key == null) return null;

    TVal done_tv; done_tv.set_boolean(done);
    fulfill_fn.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);
    TVal outer_tv; outer_tv.set_object(outer);
    fulfill_fn.put_prop(outer_key, outer_tv, hobject::PROP_FLAGS_WEC);
    reject_fn.put_prop(outer_key, outer_tv, hobject::PROP_FLAGS_WEC);

    // §27.1.4.4 step 13: when done is false and closeOnRejection is true, the
    // onRejected reaction must close the sync iterator (with a throw completion
    // carrying the rejection reason) before forwarding it to the outer promise.
    if (!done && close_on_rejection && sync_iter != null) {
        HString* closeiter_key = builtin_intern_string(heap, ASYNC_FROM_SYNC_CLOSEITER_SLOT);
        if (closeiter_key != null) {
            TVal si_tv; si_tv.set_object(sync_iter);
            reject_fn.put_prop(closeiter_key, si_tv, hobject::PROP_FLAGS_WEC);
        }
    }

    promise_attach_element_callbacks(value_promise, fulfill_fn, reject_fn, heap, vm);

    return outer;
}

/// Native fulfill reaction for the internal value-promise: builds
/// `{value, done}` and fulfills the outer (returned) promise with it
/// (ES2018 §27.1.4.4 steps 9-11, "onFulfilled" closure).
fn void builtin_async_from_sync_value_unwrap(BuiltinContext* ctx) {
    ctx.result.set_undefined();
    if (ctx.callee_obj == null) return;
    Heap* heap = ctx.heap;

    HString* done_key  = builtin_intern_string(heap, ASYNC_FROM_SYNC_DONE_SLOT);
    HString* outer_key = builtin_intern_string(heap, ASYNC_FROM_SYNC_OUTER_SLOT);
    if (done_key == null || outer_key == null) return;

    bool done = false;
    if (try dv = ctx.callee_obj.get_prop(done_key)) {
        if (dv.is_boolean()) done = dv.get_boolean();
    }
    HObject* outer = null;
    if (try ov = ctx.callee_obj.get_prop(outer_key)) {
        if (ov.is_object() && ov.get_heapptr() != null) outer = (HObject*)ov.get_heapptr();
    }
    if (outer == null) return;

    TVal value;
    value.set_undefined();
    if (ctx.argc >= 1) value = ctx.regs[ctx.base_reg];

    HObject*? iter_result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = iter_result_raw) {
        TVal err_tv = heap.error_value;
        heap.has_error = false;
        promise_settle(outer, PROMISE_REJECTED, &err_tv, heap);
        promise_trigger_reactions(outer, heap, ctx.vm);
        return;
    }
    HObject* iter_result = iter_result_raw;
    iter_result.prototype = heap.object_proto;

    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    iter_result.put_prop(value_key, value, hobject::PROP_FLAGS_WEC);
    HString* done_out_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv; done_tv.set_boolean(done);
    iter_result.put_prop(done_out_key, done_tv, hobject::PROP_FLAGS_WEC);

    TVal iter_result_tv;
    iter_result_tv.set_object(iter_result);
    promise_settle(outer, PROMISE_FULFILLED, &iter_result_tv, heap);
    promise_trigger_reactions(outer, heap, ctx.vm);
}

/// Native reject reaction for the internal value-promise: forwards the
/// rejection reason straight to the outer promise (ES2018 §27.1.4.4 step 9,
/// "onRejected" is `promiseCapability.[[Reject]]`).
fn void builtin_async_from_sync_reject_forward(BuiltinContext* ctx) {
    ctx.result.set_undefined();
    if (ctx.callee_obj == null) return;
    Heap* heap = ctx.heap;

    HString* outer_key = builtin_intern_string(heap, ASYNC_FROM_SYNC_OUTER_SLOT);
    if (outer_key == null) return;
    HObject* outer = null;
    if (try ov = ctx.callee_obj.get_prop(outer_key)) {
        if (ov.is_object() && ov.get_heapptr() != null) outer = (HObject*)ov.get_heapptr();
    }
    if (outer == null) return;

    TVal reason;
    reason.set_undefined();
    if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];

    // §27.1.4.4 step 13 onRejected: if a sync iterator was captured (done was
    // false and closeOnRejection true), close it with a throw completion. Since
    // the completion is already a throw, IteratorClose keeps the original reason
    // unless closing itself throws — in which case that error becomes the reason.
    HString* closeiter_key = builtin_intern_string(heap, ASYNC_FROM_SYNC_CLOSEITER_SLOT);
    if (closeiter_key != null) {
        if (try si = ctx.callee_obj.get_prop(closeiter_key)) {
            if (si.is_object() && si.get_heapptr() != null) {
                HObject* sync_iter = (HObject*)si.get_heapptr();
                AsyncFromSyncCloseResult cr = async_from_sync_iterator_close_normal(heap, ctx.vm, sync_iter);
                if (cr.threw) reason = cr.error;
            }
        }
    }

    promise_settle(outer, PROMISE_REJECTED, &reason, heap);
    promise_trigger_reactions(outer, heap, ctx.vm);
}

/// Build a TypeError value (without touching heap.has_error) for use as a
/// promise rejection reason — e.g. "Iterator result is not an object".
fn TVal async_from_sync_type_error(Heap* heap, char[] msg) {
    TVal out;
    out.set_undefined();
    HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = heap.type_err_proto;
        HString* msg_str = builtin_intern_string(heap, msg);
        if (msg_str != null) {
            TVal msg_tv; msg_tv.set_string(msg_str);
            HString* msg_key = builtin_intern_string(heap, "message");
            if (msg_key != null) err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        }
        out.set_object(err);
    }
    return out;
}

/// Reject a freshly-created promise with `reason` and return it. Shared by
/// next/return/throw's early-exit error paths (e.g. sync method threw, or
/// its result wasn't an object).
fn HObject*? async_from_sync_rejected_promise(Heap* heap, void* vm, TVal reason) {
    HObject*? p_raw = promise_create(heap);
    if (catch err = p_raw) return null;
    HObject* p = p_raw;
    promise_settle(p, PROMISE_REJECTED, &reason, heap);
    promise_trigger_reactions(p, heap, vm);
    return p;
}

/// Result of running IteratorClose on the wrapped sync iterator.
struct AsyncFromSyncCloseResult {
    bool threw;   // the close operation produced an abrupt (throw) completion
    TVal error;   // the thrown value, valid only when `threw` is true
}

/// IteratorClose(syncIteratorRecord, NormalCompletion) — used when the sync
/// iterator lacks a `throw` method (§27.1.4.5 step 7c) so it gets a chance to
/// clean up before we reject. Gets the `return` method; a throwing getter or a
/// throwing/`return`-non-object result yields an abrupt completion whose value
/// is reported back so the caller can reject with it. A missing/nullish
/// `return`, or a normal object result, yields a normal completion (threw =
/// false); the result value is ignored per spec.
fn AsyncFromSyncCloseResult async_from_sync_iterator_close_normal(Heap* heap, void* vm, HObject* sync_iter) {
    AsyncFromSyncCloseResult out;
    out.threw = false;
    out.error.set_undefined();

    HString* return_key = builtin_intern_string(heap, "return");
    if (return_key == null) return out;

    // GetMethod(iterator, "return") — a throwing getter propagates.
    hobject::PropLookupResult res = sync_iter.get_prop_or_accessor_proto((void*)return_key, true);
    TVal return_method;
    return_method.set_undefined();
    if (res.kind == hobject::PropLookupKind.PROP_DATA) {
        return_method = res.data_val;
    } else if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
        TVal getter_this; getter_this.set_object(res.acc.this_obj);
        return_method = heap.call_fn(vm, res.acc.accessor_fn, null, 0, getter_this);
        if (heap.has_error) {
            out.threw = true;
            out.error = heap.error_value;
            heap.has_error = false;
            return out;
        }
    }

    // §7.4.8 IteratorClose step 4: if `return` is undefined, return normally.
    if (return_method.is_nullish()) return out;
    if (!return_method.is_object() || !((HObject*)return_method.get_heapptr()).is_callable()) {
        // GetMethod would have thrown a TypeError for a non-callable, non-nullish
        // value; surface that as the close error.
        out.threw = true;
        out.error = async_from_sync_type_error(heap, "iterator.return is not a function");
        return out;
    }

    TVal sync_this; sync_this.set_object(sync_iter);
    TVal ret = heap.call_fn(vm, return_method, null, 0, sync_this);
    if (heap.has_error) {
        out.threw = true;
        out.error = heap.error_value;
        heap.has_error = false;
        return out;
    }
    // Completion is normal here, so IteratorClose ignores the return value
    // (it does not enforce object-ness). Normal completion.
    return out;
}

/// Shared tail of next/return/throw once the sync method has returned an object
/// `result_obj`: run AsyncFromSyncIteratorContinuation (§27.1.4.4). Extracts
/// `done` (IteratorComplete) and `value` (IteratorValue); a poisoned getter on
/// either rejects the returned promise (IfAbruptRejectPromise) rather than
/// throwing synchronously. `close_on_rejection` is true for next/throw and
/// false for return.
fn void async_from_sync_finish_continuation(BuiltinContext* ctx, HObject* sync_iter, HObject* result_obj, bool close_on_rejection) {
    Heap* heap = ctx.heap;

    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal? done_opt = builtins_generic_get(result_obj, done_key, ctx);
    if (ctx.should_throw) {
        ctx.should_throw = false;
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, ctx.throw_value);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }
    bool done = false;
    if (try dv = done_opt) { done = builtin_to_boolean(&dv); }

    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    TVal? value_opt = builtins_generic_get(result_obj, value_key, ctx);
    if (ctx.should_throw) {
        ctx.should_throw = false;
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, ctx.throw_value);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }
    TVal value;
    value.set_undefined();
    if (try vv = value_opt) { value = vv; }

    HObject*? outer = async_from_sync_continuation(heap, ctx.vm, sync_iter, value, done, close_on_rejection);
    if (catch err = outer) { return; }
    ctx.result.set_object(outer);
}

/// %AsyncFromSyncIteratorPrototype%.next(value) — ES2018 §27.1.4.2.
fn void builtin_async_from_sync_next(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    ctx.result.set_undefined();

    HObject* sync_iter = async_from_sync_get_wrapped(ctx);
    if (sync_iter == null) {
        builtin_throw(ctx, heap.type_err_proto, "not an AsyncFromSyncIterator");
        return;
    }

    HString* next_key = builtin_intern_string(heap, "next");
    TVal? next_method_opt = builtins_generic_get(sync_iter, next_key, ctx);
    if (ctx.should_throw) {
        ctx.should_throw = false;
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, ctx.throw_value);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }
    TVal next_method;
    if (try nm = next_method_opt) { next_method = nm; } else { next_method.set_undefined(); }
    if (!next_method.is_object() || !((HObject*)next_method.get_heapptr()).is_callable()) {
        builtin_throw(ctx, heap.type_err_proto, "iterator.next is not a function");
        return;
    }

    // §27.1.4.2 steps 5-6: pass `value` only when it is present (IteratorNext
    // with an argument), otherwise call `next` with no arguments at all.
    TVal arg;
    arg.set_undefined();
    bool has_arg = ctx.argc >= 1;
    if (has_arg) arg = ctx.regs[ctx.base_reg];
    TVal sync_this;
    sync_this.set_object(sync_iter);
    TVal step_result = heap.call_fn(ctx.vm, next_method, &arg, has_arg ? 1 : 0, sync_this);
    if (heap.has_error) {
        TVal thrown = heap.error_value;
        heap.has_error = false;
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, thrown);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }
    if (!step_result.is_object() || step_result.get_heapptr() == null) {
        TVal te = async_from_sync_type_error(heap, "Iterator result is not an object");
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, te);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }
    HObject* result_obj = (HObject*)step_result.get_heapptr();

    // next/throw close the sync iterator on a rejected yielded value; return does not.
    async_from_sync_finish_continuation(ctx, sync_iter, result_obj, true);
}

/// %AsyncFromSyncIteratorPrototype%.return(value) — ES2018 §27.1.4.3.
fn void builtin_async_from_sync_return(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    ctx.result.set_undefined();

    HObject* sync_iter = async_from_sync_get_wrapped(ctx);
    if (sync_iter == null) {
        builtin_throw(ctx, heap.type_err_proto, "not an AsyncFromSyncIterator");
        return;
    }

    TVal arg;
    arg.set_undefined();
    bool has_arg = ctx.argc >= 1;
    if (has_arg) arg = ctx.regs[ctx.base_reg];

    HString* return_key = builtin_intern_string(heap, "return");
    TVal? return_method_opt = builtins_generic_get(sync_iter, return_key, ctx);
    if (ctx.should_throw) {
        // §27.1.4.3 step 5-6: a poisoned `return` getter rejects the promise.
        ctx.should_throw = false;
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, ctx.throw_value);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }
    TVal return_method;
    if (try rm = return_method_opt) { return_method = rm; } else { return_method.set_undefined(); }

    if (return_method.is_nullish()) {
        // Step 3: no .return on the sync iterator — resolve with
        // {value: argument, done: true} directly (nothing to await-unwrap
        // per spec since AsyncFromSyncIteratorContinuation isn't invoked).
        HObject*? iter_result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = iter_result_raw) return;
        HObject* iter_result = iter_result_raw;
        iter_result.prototype = heap.object_proto;
        HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
        iter_result.put_prop(value_key, arg, hobject::PROP_FLAGS_WEC);
        HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
        TVal done_tv; done_tv.set_boolean(true);
        iter_result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);
        TVal iter_result_tv;
        iter_result_tv.set_object(iter_result);

        HObject*? p_raw = promise_create(heap);
        if (catch err = p_raw) return;
        HObject* p = p_raw;
        promise_settle(p, PROMISE_FULFILLED, &iter_result_tv, heap);
        promise_trigger_reactions(p, heap, ctx.vm);
        ctx.result.set_object(p);
        return;
    }

    if (!return_method.is_object() || !((HObject*)return_method.get_heapptr()).is_callable()) {
        builtin_throw(ctx, heap.type_err_proto, "iterator.return is not a function");
        return;
    }

    TVal sync_this;
    sync_this.set_object(sync_iter);
    TVal step_result = heap.call_fn(ctx.vm, return_method, &arg, has_arg ? 1 : 0, sync_this);
    if (heap.has_error) {
        TVal thrown = heap.error_value;
        heap.has_error = false;
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, thrown);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }
    if (!step_result.is_object() || step_result.get_heapptr() == null) {
        TVal te = async_from_sync_type_error(heap, "Iterator result is not an object");
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, te);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }
    HObject* result_obj = (HObject*)step_result.get_heapptr();

    // return does not close the sync iterator on a rejected yielded value.
    async_from_sync_finish_continuation(ctx, sync_iter, result_obj, false);
}

/// %AsyncFromSyncIteratorPrototype%.throw(value) — ES2018 §27.1.4.5.
fn void builtin_async_from_sync_throw(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    ctx.result.set_undefined();

    HObject* sync_iter = async_from_sync_get_wrapped(ctx);
    if (sync_iter == null) {
        builtin_throw(ctx, heap.type_err_proto, "not an AsyncFromSyncIterator");
        return;
    }

    TVal arg;
    arg.set_undefined();
    bool has_arg = ctx.argc >= 1;
    if (has_arg) arg = ctx.regs[ctx.base_reg];

    HString* throw_key = builtin_intern_string(heap, "throw");
    TVal? throw_method_opt = builtins_generic_get(sync_iter, throw_key, ctx);
    if (ctx.should_throw) {
        // §27.1.4.5 step 5-6: a poisoned `throw` getter rejects the promise.
        ctx.should_throw = false;
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, ctx.throw_value);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }
    TVal throw_method;
    if (try tm = throw_method_opt) { throw_method = tm; } else { throw_method.set_undefined(); }

    if (throw_method.is_nullish()) {
        // §27.1.4.5 step 7: no `throw` on the sync iterator. Close it (with a
        // normal completion) to let it clean up, then reject with a TypeError —
        // unless closing itself throws, in which case that error is the reason.
        AsyncFromSyncCloseResult cr = async_from_sync_iterator_close_normal(heap, ctx.vm, sync_iter);
        TVal reason;
        if (cr.threw) {
            reason = cr.error;
        } else {
            reason = async_from_sync_type_error(heap, "iterator.throw is not a function");
        }
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, reason);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }

    if (!throw_method.is_object() || !((HObject*)throw_method.get_heapptr()).is_callable()) {
        builtin_throw(ctx, heap.type_err_proto, "iterator.throw is not a function");
        return;
    }

    TVal sync_this;
    sync_this.set_object(sync_iter);
    TVal step_result = heap.call_fn(ctx.vm, throw_method, &arg, has_arg ? 1 : 0, sync_this);
    if (heap.has_error) {
        TVal thrown = heap.error_value;
        heap.has_error = false;
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, thrown);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }
    if (!step_result.is_object() || step_result.get_heapptr() == null) {
        TVal te = async_from_sync_type_error(heap, "Iterator result is not an object");
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, te);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }
    HObject* result_obj = (HObject*)step_result.get_heapptr();

    // next/throw close the sync iterator on a rejected yielded value.
    async_from_sync_finish_continuation(ctx, sync_iter, result_obj, true);
}

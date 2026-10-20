// DisposableStack and AsyncDisposableStack (explicit resource management).
//
// A stack carries three hidden slots:
//   \xFFresources  an ARRAY of records, four slots each:
//                    [4*i + 0] value   the resource value
//                    [4*i + 1] method  the dispose method, undefined when the
//                                       record has none
//                    [4*i + 2] hint    sync or async
//                    [4*i + 3] call    how the method is invoked
//   \xFFdisposed   the [[Disposed]] state
//   \xFFkind       sync or async, so the two stacks keep separate brands
//
// The hidden names are the engine's internal-slot convention: they are
// invisible to reflection, so the records stay implementation details.
//
// Disposal runs the records in reverse (last declared first), folding each
// failure into the pending one: the newest failure becomes the outer
// SuppressedError.error and the error it displaced its .suppressed
// (DisposeResources).
module boomkat::builtins;
import boomkat::types;
import boomkat::hstring;
import boomkat::env;
import boomkat::heap;
import boomkat::hobject;

// A sync record disposes without awaiting; an async record awaits the
// method's result.
const uint DISPOSABLE_HINT_SYNC = 0;
const uint DISPOSABLE_HINT_ASYNC = 1;

// How a record's method is invoked. `use` calls the method with the resource
// as the receiver; `adopt` and `defer` call it with an undefined receiver, and
// `adopt` passes the resource as the argument.
const uint DISPOSABLE_CALL_METHOD = 0;
const uint DISPOSABLE_CALL_ARG = 1;
const uint DISPOSABLE_CALL_NOARG = 2;

// Stack kinds, so a sync method rejects an AsyncDisposableStack receiver.
const uint DISPOSABLE_KIND_SYNC = 0;
const uint DISPOSABLE_KIND_ASYNC = 1;

const uint DISPOSABLE_RECORD_SIZE = 4;

// ============================================================================
// Internal slots
// ============================================================================

fn HObject* disposable_resources(Heap* heap, HObject* obj) {
    HString* key = builtin_intern_string(heap, "\xFFresources");
    if (key == null) return null;
    if (try rv = obj.get_prop(key, heap)) {
        if (rv.is_object() && rv.get_heapptr() != null) return (HObject*)rv.get_heapptr();
    }
    return null;
}

fn uint disposable_kind(Heap* heap, HObject* obj) {
    HString* key = builtin_intern_string(heap, "\xFFkind");
    if (key == null) return DISPOSABLE_KIND_SYNC;
    if (try kv = obj.get_prop(key, heap)) {
        if (kv.is_fastint()) return (uint)kv.get_fastint();
    }
    return DISPOSABLE_KIND_SYNC;
}

fn void disposable_set_kind(Heap* heap, HObject* obj, uint kind) {
    HString* key = builtin_intern_string(heap, "\xFFkind");
    if (key == null) return;
    TVal tv; tv.set_fastint((long)kind);
    obj.put_prop(key, tv, hobject::PROP_FLAGS_WEC, heap);
}

fn void disposable_set_resources(Heap* heap, HObject* obj, HObject* records) {
    HString* key = builtin_intern_string(heap, "\xFFresources");
    if (key == null) return;
    TVal tv; tv.set_object(records);
    obj.put_prop(key, tv, hobject::PROP_FLAGS_WEC, heap);
}

fn bool disposable_disposed(Heap* heap, HObject* obj) {
    HString* key = builtin_intern_string(heap, "\xFFdisposed");
    if (key == null) return false;
    if (try dv = obj.get_prop(key, heap)) {
        return dv.is_boolean() && dv.get_boolean();
    }
    return false;
}

fn void disposable_set_disposed(Heap* heap, HObject* obj, bool disposed) {
    HString* key = builtin_intern_string(heap, "\xFFdisposed");
    if (key == null) return;
    TVal tv; tv.set_boolean(disposed);
    obj.put_prop(key, tv, hobject::PROP_FLAGS_WEC, heap);
}

// The receiver when it carries the stack's own slots, else null. This is the
// brand check: every method throws (or rejects) for anything else.
fn HObject* disposable_this(BuiltinContext* ctx, uint kind) {
    if (!ctx.this_val.is_object() || ctx.this_val.get_heapptr() == null) return null;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    if (disposable_kind(ctx.heap, obj) != kind) return null;
    if (disposable_resources(ctx.heap, obj) == null) return null;
    return obj;
}

// Allocate a stack instance with an empty record array and [[Disposed]] false.
fn HObject*? disposable_alloc(BuiltinContext* ctx, HObject* default_proto, uint kind) {
    Heap* heap = ctx.heap;
    HObject*? raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = raw) return null;
    HObject* stack = raw;
    heap.set_prototype(stack, builtin_proto_from_new_target(ctx, default_proto));
    if (ctx.should_throw) return null;
    HObject*? records_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err_r = records_raw) return null;
    HObject* records = records_raw;
    heap.set_prototype(records, heap.array_proto);
    disposable_set_resources(heap, stack, records);
    disposable_set_disposed(heap, stack, false);
    disposable_set_kind(heap, stack, kind);
    return stack;
}

// Append one record; the hint decides whether the disposal awaits the
// method's result, the call kind how the method is invoked.
fn void disposable_push(Heap* heap, HObject* records, TVal value, TVal method, uint hint, uint call) {
    if (records == null) return;
    uint base = (uint)*records.array_len_ptr();
    records.set_array_idx(base, value, heap);
    records.set_array_idx(base + 1, method, heap);
    TVal hint_tv; hint_tv.set_fastint((long)hint);
    records.set_array_idx(base + 2, hint_tv, heap);
    TVal call_tv; call_tv.set_fastint((long)call);
    records.set_array_idx(base + 3, call_tv, heap);
    array_set_length(records, base + DISPOSABLE_RECORD_SIZE, heap);
}

// ============================================================================
// Disposal
// ============================================================================

// Fold the failure waiting on the heap error channel into `*pending`, wrapping
// a previous failure so the newest error is the outer one.
fn void disposable_fold_error(Heap* heap, void* vm, TVal* pending, bool* threw) {
    TVal failed; failed.set_undefined();
    if (heap.has_error) failed = heap.error_value;
    promise_clear_error_channels(heap, vm);
    *pending = *threw ? error_new_suppressed(heap, failed, *pending) : failed;
    *threw = true;
    heap.shade_root_tval(*pending);
}

// Invoke a record's dispose method: `use` calls it with the resource as the
// receiver, `adopt` with an undefined receiver and the resource as the
// argument, `defer` with an undefined receiver and no argument.
fn TVal disposable_call(Heap* heap, void* vm, TVal method, TVal value, uint call) {
    TVal undef; undef.set_undefined();
    if (call == DISPOSABLE_CALL_METHOD) return heap.call_fn(vm, method, null, 0, value);
    if (call == DISPOSABLE_CALL_ARG) {
        TVal[1] args;
        args[0] = value;
        return heap.call_fn(vm, method, &args[0], 1, undef);
    }
    return heap.call_fn(vm, method, null, 0, undef);
}

// Dispose every record in `records` from the last down. `threw` says whether
// a failure is already in flight; the returned flag says whether one is after
// the walk, and `*pending` then holds the folded failure to throw.
fn bool disposable_dispose_records(Heap* heap, void* vm, HObject* records, TVal* pending, bool threw) {
    uint count = (uint)*records.array_len_ptr() / DISPOSABLE_RECORD_SIZE;
    for (uint i = count; i > 0; i--) {
        uint base = (i - 1) * DISPOSABLE_RECORD_SIZE;
        TVal value; value.set_undefined();
        if (try v = records.get_array_idx(base)) value = v;
        TVal method; method.set_undefined();
        if (try m = records.get_array_idx(base + 1)) method = m;
        uint call = DISPOSABLE_CALL_METHOD;
        if (try c = records.get_array_idx(base + 3)) {
            if (c.is_fastint()) call = (uint)c.get_fastint();
        }
        if (!is_callable_tval(method)) continue;
        disposable_call(heap, vm, method, value, call);
        if (heap.has_error) {
            disposable_fold_error(heap, vm, pending, &threw);
        }
    }
    array_set_length(records, 0, heap);
    return threw;
}

// ============================================================================
// DisposableStack
// ============================================================================

fn void builtin_disposable_stack(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Constructor DisposableStack requires 'new'");
        return;
    }
    HObject*? stack = disposable_alloc(ctx, ctx.heap.disposable_stack_proto, DISPOSABLE_KIND_SYNC);
    if (catch err = stack) { ctx.result_undefined(); return; }
    ctx.result_object(stack);
}

fn void builtin_async_disposable_stack(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Constructor AsyncDisposableStack requires 'new'");
        return;
    }
    HObject*? stack = disposable_alloc(ctx, ctx.heap.async_disposable_stack_proto, DISPOSABLE_KIND_ASYNC);
    if (catch err = stack) { ctx.result_undefined(); return; }
    ctx.result_object(stack);
}

fn void builtin_disposable_stack_proto_use(BuiltinContext* ctx) { disposable_proto_use(ctx, false); }
fn void builtin_async_disposable_stack_proto_use(BuiltinContext* ctx) { disposable_proto_use(ctx, true); }

// Look up the dispose method of `value`. An async scope reads @@asyncDispose
// first and falls back to @@dispose, which the adapter turns into a method
// with async semantics: it discards the sync result and turns a thrown error
// into a rejection.
fn bool disposable_lookup_method(BuiltinContext* ctx, TVal value, bool async, TVal* out) {
    Heap* heap = ctx.heap;
    HObject* obj = (HObject*)value.get_heapptr();
    TVal method; method.set_undefined();
    bool fallback = false;
    if (async) {
        HString* key = ensure_asyncdispose_symbol(heap);
        if (key == null || !promise_object_get(heap, ctx.vm, obj, key, &method)) return false;
        if (method.is_undefined() || method.is_null()) {
            key = ensure_dispose_symbol(heap);
            if (key == null || !promise_object_get(heap, ctx.vm, obj, key, &method)) return false;
            fallback = true;
        }
    } else {
        HString* key = ensure_dispose_symbol(heap);
        if (key == null || !promise_object_get(heap, ctx.vm, obj, key, &method)) return false;
    }
    if (fallback && !method.is_undefined() && !method.is_null() && is_callable_tval(method)) {
        HObject*? adapter_raw = disposable_async_adapter_fn(heap, method);
        if (catch err_a = adapter_raw) return false;
        TVal adapter; adapter.set_object(adapter_raw);
        method = adapter;
    }
    *out = method;
    return true;
}

// use(value): record `value` with its @@dispose (or @@asyncDispose, falling back
// to @@dispose, for the async stack). A nullish value is not a resource: the
// sync stack drops it, the async stack keeps a methodless record so the
// disposal still awaits.
fn void disposable_proto_use(BuiltinContext* ctx, bool async) {
    Heap* heap = ctx.heap;
    HObject* stack = disposable_this(ctx, async ? DISPOSABLE_KIND_ASYNC : DISPOSABLE_KIND_SYNC);
    if (stack == null) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "use called on incompatible receiver");
        return;
    }
    if (disposable_disposed(heap, stack)) {
        builtin_throw_no_result_change(ctx, heap.ref_err_proto, "use called on a disposed stack");
        return;
    }
    TVal value; value.set_undefined();
    if (ctx.argc >= 1) value = ctx.regs[ctx.base_reg];
    TVal method; method.set_undefined();
    if (value.is_null() || value.is_undefined()) {
        if (async) {
            TVal none; none.set_undefined();
            disposable_push(heap, disposable_resources(heap, stack), none, none, DISPOSABLE_HINT_ASYNC, DISPOSABLE_CALL_METHOD);
        }
        ctx.copy_result(value);
        return;
    }
    if (!value.is_object() || value.get_heapptr() == null) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "use requires an object");
        return;
    }
    HObject* obj = (HObject*)value.get_heapptr();

    if (!disposable_lookup_method(ctx, value, async, &method)) return;
    if (!is_callable_tval(method)) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "dispose method is not a function");
        return;
    }
    disposable_push(heap, disposable_resources(heap, stack), value, method,
                    async ? DISPOSABLE_HINT_ASYNC : DISPOSABLE_HINT_SYNC, DISPOSABLE_CALL_METHOD);
    ctx.copy_result(value);
}

fn void builtin_disposable_stack_proto_adopt(BuiltinContext* ctx) { disposable_proto_adopt(ctx, false); }
fn void builtin_async_disposable_stack_proto_adopt(BuiltinContext* ctx) { disposable_proto_adopt(ctx, true); }

// adopt(value, onDispose): record `value` with a caller-supplied callback,
// which is called with an undefined receiver and the value as its argument.
fn void disposable_proto_adopt(BuiltinContext* ctx, bool async) {
    Heap* heap = ctx.heap;
    HObject* stack = disposable_this(ctx, async ? DISPOSABLE_KIND_ASYNC : DISPOSABLE_KIND_SYNC);
    if (stack == null) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "adopt called on incompatible receiver");
        return;
    }
    if (disposable_disposed(heap, stack)) {
        builtin_throw_no_result_change(ctx, heap.ref_err_proto, "adopt called on a disposed stack");
        return;
    }
    TVal value; value.set_undefined();
    if (ctx.argc >= 1) value = ctx.regs[ctx.base_reg];
    TVal method; method.set_undefined();
    if (ctx.argc >= 2) method = ctx.regs[ctx.base_reg + 1];
    if (!is_callable_tval(method)) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "adopt requires a callable");
        return;
    }
    disposable_push(heap, disposable_resources(heap, stack), value, method,
                    async ? DISPOSABLE_HINT_ASYNC : DISPOSABLE_HINT_SYNC, DISPOSABLE_CALL_ARG);
    ctx.copy_result(value);
}

fn void builtin_disposable_stack_proto_defer(BuiltinContext* ctx) { disposable_proto_defer(ctx, false); }
fn void builtin_async_disposable_stack_proto_defer(BuiltinContext* ctx) { disposable_proto_defer(ctx, true); }

// defer(onDispose): record a callback called with an undefined receiver and
// no argument.
fn void disposable_proto_defer(BuiltinContext* ctx, bool async) {
    Heap* heap = ctx.heap;
    HObject* stack = disposable_this(ctx, async ? DISPOSABLE_KIND_ASYNC : DISPOSABLE_KIND_SYNC);
    if (stack == null) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "defer called on incompatible receiver");
        return;
    }
    if (disposable_disposed(heap, stack)) {
        builtin_throw_no_result_change(ctx, heap.ref_err_proto, "defer called on a disposed stack");
        return;
    }
    TVal method; method.set_undefined();
    if (ctx.argc >= 1) method = ctx.regs[ctx.base_reg];
    if (!is_callable_tval(method)) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "defer requires a callable");
        return;
    }
    TVal value; value.set_undefined();
    disposable_push(heap, disposable_resources(heap, stack), value, method,
                    async ? DISPOSABLE_HINT_ASYNC : DISPOSABLE_HINT_SYNC, DISPOSABLE_CALL_NOARG);
    ctx.result_undefined();
}

fn void builtin_disposable_stack_proto_dispose(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    ctx.result_undefined();
    HObject* stack = disposable_this(ctx, DISPOSABLE_KIND_SYNC);
    if (stack == null) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "dispose called on incompatible receiver");
        return;
    }
    if (disposable_disposed(heap, stack)) return;
    disposable_set_disposed(heap, stack, true);
    HObject* records = disposable_resources(heap, stack);
    TVal pending; pending.set_undefined();
    if (!disposable_dispose_records(heap, ctx.vm, records, &pending, false)) return;
    ctx.should_throw = true;
    ctx.throw_value = pending;
}

fn void builtin_disposable_stack_proto_disposed(BuiltinContext* ctx) {
    disposable_proto_disposed(ctx, DISPOSABLE_KIND_SYNC);
}

fn void builtin_async_disposable_stack_proto_disposed(BuiltinContext* ctx) {
    disposable_proto_disposed(ctx, DISPOSABLE_KIND_ASYNC);
}

fn void disposable_proto_disposed(BuiltinContext* ctx, uint kind) {
    Heap* heap = ctx.heap;
    HObject* stack = disposable_this(ctx, kind);
    if (stack == null) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "disposed called on incompatible receiver");
        return;
    }
    TVal v; v.set_boolean(disposable_disposed(heap, stack));
    ctx.copy_result(v);
}

fn void builtin_disposable_stack_proto_move(BuiltinContext* ctx) { disposable_proto_move(ctx, false); }
fn void builtin_async_disposable_stack_proto_move(BuiltinContext* ctx) { disposable_proto_move(ctx, true); }

// move(): hand the records to a fresh stack of the base class and mark this one
// disposed. Resources are not disposed and stay in declaration order.
fn void disposable_proto_move(BuiltinContext* ctx, bool async) {
    Heap* heap = ctx.heap;
    ctx.result_undefined();
    HObject* stack = disposable_this(ctx, async ? DISPOSABLE_KIND_ASYNC : DISPOSABLE_KIND_SYNC);
    if (stack == null) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "move called on incompatible receiver");
        return;
    }
    if (disposable_disposed(heap, stack)) {
        builtin_throw_no_result_change(ctx, heap.ref_err_proto, "move called on a disposed stack");
        return;
    }
    HObject*? moved_raw = disposable_alloc(ctx, async ? heap.async_disposable_stack_proto
                                                       : heap.disposable_stack_proto,
                                           async ? DISPOSABLE_KIND_ASYNC : DISPOSABLE_KIND_SYNC);
    if (catch err = moved_raw) return;
    HObject* moved = moved_raw;
    HObject* records = disposable_resources(heap, stack);
    disposable_set_resources(heap, moved, records);

    HObject*? empty_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err_e = empty_raw) { disposable_set_disposed(heap, stack, true); return; }
    HObject* empty = empty_raw;
    heap.set_prototype(empty, heap.array_proto);
    disposable_set_resources(heap, stack, empty);
    disposable_set_disposed(heap, stack, true);
    ctx.result_object(moved);
}

// ============================================================================
// The adapter for a sync @@dispose on an async stack
// ============================================================================
//
// GetDisposeMethod wraps a sync @@dispose in a function that calls it with
// the receiver it was called with, discards the result, and settles a
// promise with undefined. The promise keeps a returned value from being
// awaited and turns a thrown error into a rejection.

fn HObject*? disposable_async_adapter_fn(Heap* heap, TVal method) {
    HObject*? raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = raw) return null;
    HObject* adapter = raw;
    (*adapter.extra_ptr()).func.builtin_fn_index = (int)Builtin.DISPOSABLE_ASYNC_ADAPTER.ordinal;
    adapter.flags.callable = true;
    adapter.flags.constructable = false;
    heap.set_prototype(adapter, heap.function_proto);
    HString* key = builtin_intern_string(heap, "\xFFmethod");
    if (key == null) return null;
    adapter.put_prop(key, method, hobject::PROP_FLAGS_WEC, heap);
    return adapter;
}

fn void builtin_disposable_async_adapter(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal method; method.set_undefined();
    if (ctx.callee_obj != null) {
        HString* key = builtin_intern_string(heap, "\xFFmethod");
        if (key != null) {
            if (try m = ctx.callee_obj.get_prop(key, heap)) method = m;
        }
    }
    HObject*? p_raw = promise_create(heap);
    if (catch err_p = p_raw) { ctx.result_undefined(); return; }
    HObject* p = p_raw;
    TVal p_tv; p_tv.set_object(p);
    ctx.copy_result(p_tv);
    PromiseCapability cap = promise_new_capability(heap, p);
    if (cap.resolve_func == null || cap.reject_func == null) {
        promise_reject_with_channel(p, heap, ctx.vm);
        return;
    }
    TVal undef; undef.set_undefined();
    TVal resolve; resolve.set_object(cap.resolve_func);
    TVal reject; reject.set_object(cap.reject_func);
    heap.call_fn(ctx.vm, method, null, 0, ctx.this_val);
    if (heap.has_error) {
        TVal err = heap.error_value;
        promise_clear_error_channels(heap, ctx.vm);
        heap.call_fn(ctx.vm, reject, &err, 1, undef);
        return;
    }
    heap.call_fn(ctx.vm, resolve, &undef, 1, undef);
}

// ============================================================================
// AsyncDisposableStack.disposeAsync()
// ============================================================================
//
// The loop lives in a state object so it can resume from a reaction after an
// await:
//   \xFFrecords  the detached record array
//   \xFFindex    the number of records left to dispose
//   \xFFpending  the folded failure, valid when \xFFhasError is set
//   \xFFhasError whether a disposer failed
//   \xFFneedsAwait whether an async resource was recorded
//   \xFFhasAwaited whether a disposer was awaited
//   \xFFphase    the step the loop resumes at
//   \xFFpromise  the result promise
//   \xFFstep     \xFFstepReject  the two closures that resume the loop

// The step the loop resumes at: 0 starts a record, 1 continues a record whose
// pending await already happened.
const uint DISPOSABLE_PHASE_RECORD = 0;
const uint DISPOSABLE_PHASE_CONTINUE = 1;

fn HObject*? disposable_async_step_fn(Heap* heap, uint builtin_index, HObject* state) {
    HObject*? raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = raw) return null;
    HObject* step = raw;
    (*step.extra_ptr()).func.builtin_fn_index = (int)builtin_index;
    step.flags.callable = true;
    step.flags.constructable = false;
    heap.set_prototype(step, heap.function_proto);
    HString* key = builtin_intern_string(heap, "\xFFstate");
    if (key != null) {
        TVal st; st.set_object(state);
        step.put_prop(key, st, hobject::PROP_FLAGS_WEC, heap);
    }
    return step;
}

fn TVal disposable_state_get(Heap* heap, HObject* state, char[] name) {
    TVal out; out.set_undefined();
    HString* key = builtin_intern_string(heap, name);
    if (key == null) return out;
    if (try v = state.get_prop(key, heap)) out = v;
    return out;
}

fn void disposable_state_set(Heap* heap, HObject* state, char[] name, TVal value) {
    HString* key = builtin_intern_string(heap, name);
    if (key == null) return;
    state.put_prop(key, value, hobject::PROP_FLAGS_WEC, heap);
}

fn bool disposable_state_bool(Heap* heap, HObject* state, char[] name) {
    TVal v = disposable_state_get(heap, state, name);
    return v.is_boolean() && v.get_boolean();
}

fn void disposable_state_set_bool(Heap* heap, HObject* state, char[] name, bool value) {
    TVal v; v.set_boolean(value);
    disposable_state_set(heap, state, name, v);
}

fn void builtin_disposable_async_step(BuiltinContext* ctx) {
    ctx.result_undefined();
    disposable_async_run(ctx, null, false);
}

fn void builtin_disposable_async_step_reject(BuiltinContext* ctx) {
    ctx.result_undefined();
    disposable_async_run(ctx, null, true);
}

// Attach the resume closures to the promise `result` resolves to. The loop
// continues when that promise settles.
fn void disposable_async_await(BuiltinContext* ctx, HObject* state, TVal result) {
    Heap* heap = ctx.heap;
    HObject*? wrapper_raw = promise_resolve_default_ctor(heap, ctx.vm, result);
    if (catch err_w = wrapper_raw) return;
    HObject* wrapper = wrapper_raw;
    TVal step_tv = disposable_state_get(heap, state, "\xFFstep");
    TVal step_reject_tv = disposable_state_get(heap, state, "\xFFstepReject");
    HObject*? reaction_raw = promise_create_reaction(heap);
    if (catch err_r = reaction_raw) return;
    HObject* reaction = reaction_raw;
    reaction_set(reaction, 0, step_tv, heap);
    reaction_set(reaction, 1, step_reject_tv, heap);
    promise_add_reaction(wrapper, reaction, heap);
    if (promise_get_state(wrapper, PROMISE_PENDING) != PROMISE_PENDING) {
        promise_trigger_reactions(wrapper, heap, ctx.vm);
    }
}

// Run the disposal loop until it needs to await, then attach the resume
// closures to that promise. `state` is null when the caller is a step closure,
// which carries it instead.
fn void disposable_async_run(BuiltinContext* ctx, HObject* state_arg, bool rejected) {
    Heap* heap = ctx.heap;
    HObject* state = state_arg;
    if (state == null && ctx.callee_obj != null) {
        TVal st = disposable_state_get(heap, ctx.callee_obj, "\xFFstate");
        if (st.is_object() && st.get_heapptr() != null) state = (HObject*)st.get_heapptr();
    }
    if (state == null) return;

    bool has_error = disposable_state_bool(heap, state, "\xFFhasError");
    TVal pending = disposable_state_get(heap, state, "\xFFpending");
    if (rejected) {
        // The awaited disposer rejected: the reason becomes the pending
        // failure, folded into an earlier one.
        TVal reason; reason.set_undefined();
        if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];
        pending = has_error ? error_new_suppressed(heap, reason, pending) : reason;
        has_error = true;
        disposable_state_set(heap, state, "\xFFpending", pending);
        disposable_state_set_bool(heap, state, "\xFFhasError", true);
        heap.shade_root_tval(pending);
    }

    TVal records_tv = disposable_state_get(heap, state, "\xFFrecords");
    if (!records_tv.is_object() || records_tv.get_heapptr() == null) return;
    HObject* records = (HObject*)records_tv.get_heapptr();

    bool needs_await = disposable_state_bool(heap, state, "\xFFneedsAwait");
    bool has_awaited = disposable_state_bool(heap, state, "\xFFhasAwaited");
    long phase = 0;
    TVal phase_tv = disposable_state_get(heap, state, "\xFFphase");
    if (phase_tv.is_fastint()) phase = phase_tv.get_fastint();

    while (true) {
        TVal index_tv = disposable_state_get(heap, state, "\xFFindex");
        long remaining = index_tv.is_fastint() ? index_tv.get_fastint() : 0;
        if (remaining <= 0) break;
        uint base = (uint)(remaining - 1) * DISPOSABLE_RECORD_SIZE;
        TVal value; value.set_undefined();
        if (try v = records.get_array_idx(base)) value = v;
        TVal method; method.set_undefined();
        if (try m = records.get_array_idx(base + 1)) method = m;
        long hint = DISPOSABLE_HINT_SYNC;
        if (try h = records.get_array_idx(base + 2)) {
            if (h.is_fastint()) hint = h.get_fastint();
        }
        uint call = DISPOSABLE_CALL_METHOD;
        if (try c = records.get_array_idx(base + 3)) {
            if (c.is_fastint()) call = (uint)c.get_fastint();
        }

        if (phase == DISPOSABLE_PHASE_RECORD) {
            // A sync resource disposed after an async one waits for the
            // pending await first.
            if (hint == DISPOSABLE_HINT_SYNC && needs_await && !has_awaited) {
                needs_await = false;
                phase = DISPOSABLE_PHASE_CONTINUE;
                disposable_state_set_bool(heap, state, "\xFFneedsAwait", false);
                TVal phase_save; phase_save.set_fastint(phase);
                disposable_state_set(heap, state, "\xFFphase", phase_save);
                TVal undef; undef.set_undefined();
                disposable_async_await(ctx, state, undef);
                return;
            }
        } else {
            phase = DISPOSABLE_PHASE_RECORD;
            TVal phase_save; phase_save.set_fastint(phase);
            disposable_state_set(heap, state, "\xFFphase", phase_save);
        }

        if (is_callable_tval(method)) {
            TVal result = disposable_call(heap, ctx.vm, method, value, call);
            if (heap.has_error) {
                bool threw = has_error;
                disposable_fold_error(heap, ctx.vm, &pending, &threw);
                has_error = threw;
                disposable_state_set(heap, state, "\xFFpending", pending);
                disposable_state_set_bool(heap, state, "\xFFhasError", true);
            } else if (hint == DISPOSABLE_HINT_ASYNC) {
                // An async disposer: await its result before the next
                // resource.
                has_awaited = true;
                disposable_state_set_bool(heap, state, "\xFFhasAwaited", true);
                TVal index_save; index_save.set_fastint(remaining - 1);
                disposable_state_set(heap, state, "\xFFindex", index_save);
                disposable_async_await(ctx, state, result);
                return;
            }
        } else {
            // A methodless record still costs an await: an async stack awaits
            // even when the resource was null or undefined.
            needs_await = true;
            disposable_state_set_bool(heap, state, "\xFFneedsAwait", true);
        }

        TVal index_save; index_save.set_fastint(remaining - 1);
        disposable_state_set(heap, state, "\xFFindex", index_save);
    }

    // The stack is empty. A stack that only held methodless resources still
    // awaits once, so the caller's continuation lands behind the jobs
    // already queued.
    if (needs_await && !has_awaited) {
        needs_await = false;
        disposable_state_set_bool(heap, state, "\xFFneedsAwait", false);
        TVal undef; undef.set_undefined();
        disposable_async_await(ctx, state, undef);
        return;
    }

    // Settle the result promise: the folded failure rejects it, a clean
    // disposal resolves it with undefined.
    array_set_length(records, 0, heap);
    TVal undef; undef.set_undefined();
    TVal p_tv = disposable_state_get(heap, state, "\xFFpromise");
    if (!p_tv.is_object() || p_tv.get_heapptr() == null) return;
    HObject* p = (HObject*)p_tv.get_heapptr();
    if (has_error) {
        promise_settle(p, PROMISE_REJECTED, &pending, heap);
    } else {
        promise_settle(p, PROMISE_FULFILLED, &undef, heap);
    }
    promise_trigger_reactions(p, heap, ctx.vm);
}

fn void builtin_async_disposable_stack_proto_dispose_async(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    HObject*? p_raw = promise_create(heap);
    if (catch err_p = p_raw) { ctx.result_undefined(); return; }
    HObject* p = p_raw;
    TVal p_tv; p_tv.set_object(p);
    ctx.copy_result(p_tv);

    HObject* stack = disposable_this(ctx, DISPOSABLE_KIND_ASYNC);
    if (stack == null) {
        species_throw_typeerror(heap, "disposeAsync called on incompatible receiver");
        promise_reject_with_channel(p, heap, ctx.vm);
        return;
    }
    if (disposable_disposed(heap, stack)) {
        TVal undef; undef.set_undefined();
        promise_settle(p, PROMISE_FULFILLED, &undef, heap);
        promise_trigger_reactions(p, heap, ctx.vm);
        return;
    }
    disposable_set_disposed(heap, stack, true);

    // Detach the records: a second disposeAsync finds the stack disposed, and
    // the state object keeps the array alive for the loop.
    HObject* records = disposable_resources(heap, stack);
    HObject*? empty_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err_e = empty_raw) { promise_reject_with_channel(p, heap, ctx.vm); return; }
    HObject* empty = empty_raw;
    heap.set_prototype(empty, heap.array_proto);
    disposable_set_resources(heap, stack, empty);

    TVal undef; undef.set_undefined();
    disposable_dispose_async(ctx, p, records, undef, false);
}

// Release `records` asynchronously: the promise settles with the outcome, and
// the failure in flight folds with the disposers' failures.
fn void disposable_dispose_async(BuiltinContext* ctx, HObject* p, HObject* records, TVal pending, bool has_error) {
    Heap* heap = ctx.heap;
    HObject*? state_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err_s = state_raw) { promise_reject_with_channel(p, heap, ctx.vm); return; }
    HObject* state = state_raw;
    heap.set_prototype(state, heap.object_proto);
    TVal records_tv; records_tv.set_object(records);
    disposable_state_set(heap, state, "\xFFrecords", records_tv);
    TVal index_tv; index_tv.set_fastint((long)(*records.array_len_ptr() / DISPOSABLE_RECORD_SIZE));
    disposable_state_set(heap, state, "\xFFindex", index_tv);
    disposable_state_set(heap, state, "\xFFpending", pending);
    disposable_state_set_bool(heap, state, "\xFFhasError", has_error);
    disposable_state_set_bool(heap, state, "\xFFneedsAwait", false);
    disposable_state_set_bool(heap, state, "\xFFhasAwaited", false);
    TVal phase_tv; phase_tv.set_fastint(DISPOSABLE_PHASE_RECORD);
    disposable_state_set(heap, state, "\xFFphase", phase_tv);
    TVal p_tv; p_tv.set_object(p);
    disposable_state_set(heap, state, "\xFFpromise", p_tv);

    HObject*? step_raw = disposable_async_step_fn(heap, Builtin.DISPOSABLE_ASYNC_STEP.ordinal, state);
    if (catch err_st = step_raw) { promise_reject_with_channel(p, heap, ctx.vm); return; }
    HObject*? step_reject_raw = disposable_async_step_fn(heap, Builtin.DISPOSABLE_ASYNC_STEP_REJECT.ordinal, state);
    if (catch err_sr = step_reject_raw) { promise_reject_with_channel(p, heap, ctx.vm); return; }
    TVal step_tv; step_tv.set_object(step_raw);
    disposable_state_set(heap, state, "\xFFstep", step_tv);
    TVal step_reject_tv; step_reject_tv.set_object(step_reject_raw);
    disposable_state_set(heap, state, "\xFFstepReject", step_reject_tv);

    disposable_async_run(ctx, state, false);
}

// ============================================================================
// The `using` declaration's scope resources
// ============================================================================
//
// A scope's resource list is an ARRAY of records, the same shape the stacks
// keep: the resource value, its dispose method, the hint, and how the method
// is invoked. The compiler collects the resources there and releases them
// when the scope is left.

fn void builtin_scope_add_resource(BuiltinContext* ctx) { disposable_scope_add_resource(ctx, false); }
fn void builtin_scope_add_resource_async(BuiltinContext* ctx) { disposable_scope_add_resource(ctx, true); }

// Register a resource with the scope's list and return the list.
fn void disposable_scope_add_resource(BuiltinContext* ctx, bool async) {
    Heap* heap = ctx.heap;
    TVal list; list.set_undefined();
    if (ctx.argc >= 1) list = ctx.regs[ctx.base_reg];
    TVal value; value.set_undefined();
    if (ctx.argc >= 2) value = ctx.regs[ctx.base_reg + 1];
    TVal method; method.set_undefined();
    if (value.is_null() || value.is_undefined()) {
        // A nullish value is not a resource. An async scope still records
        // it, so the release awaits even when nothing was disposed.
        if (!async) {
            ctx.copy_result(list);
            return;
        }
    } else {
        if (!value.is_object() || value.get_heapptr() == null) {
            builtin_throw_no_result_change(ctx, heap.type_err_proto, "a using declaration requires an object");
            return;
        }
        if (!disposable_lookup_method(ctx, value, async, &method)) return;
        if (!is_callable_tval(method)) {
            builtin_throw_no_result_change(ctx, heap.type_err_proto, "the dispose method is not a function");
            return;
        }
    }
    HObject* records = null;
    if (list.is_object() && list.get_heapptr() != null) records = (HObject*)list.get_heapptr();
    if (records == null) {
        // The inline capacity keeps the first record's write allocation-free:
        // the fresh list is not reachable from anywhere yet, so a collection
        // during the write would sweep it.
        HObject*? raw = heap.alloc_object(hobject::ObjClass.ARRAY, DISPOSABLE_RECORD_SIZE);
        if (catch err = raw) { ctx.result_undefined(); return; }
        records = raw;
        heap.set_prototype(records, heap.array_proto);
    }
    disposable_push(heap, records, value, method,
                    async ? DISPOSABLE_HINT_ASYNC : DISPOSABLE_HINT_SYNC, DISPOSABLE_CALL_METHOD);
    TVal out; out.set_object(records);
    ctx.copy_result(out);
}

// Whether the scope holds a resource whose disposal awaits.
fn bool disposable_has_async_record(HObject* records) {
    uint count = (uint)*records.array_len_ptr() / DISPOSABLE_RECORD_SIZE;
    for (uint i = 0; i < count; i++) {
        if (try h = records.get_array_idx(i * DISPOSABLE_RECORD_SIZE + 2)) {
            if (h.is_fastint() && h.get_fastint() == (long)DISPOSABLE_HINT_ASYNC) return true;
        }
    }
    return false;
}

fn void builtin_scope_dispose(BuiltinContext* ctx) { disposable_scope_dispose(ctx, false); }
fn void builtin_scope_dispose_async(BuiltinContext* ctx) { disposable_scope_dispose(ctx, true); }

// Release the scope's resources. The failure in flight, if any, folds with
// the disposers' failures: the newest failure is the outer error.
fn void disposable_scope_dispose(BuiltinContext* ctx, bool async) {
    Heap* heap = ctx.heap;
    TVal list; list.set_undefined();
    if (ctx.argc >= 1) list = ctx.regs[ctx.base_reg];
    TVal pending; pending.set_undefined();
    if (ctx.argc >= 2) pending = ctx.regs[ctx.base_reg + 1];
    bool has_error = false;
    if (ctx.argc >= 3) {
        TVal flag = ctx.regs[ctx.base_reg + 2];
        has_error = flag.is_boolean() && flag.get_boolean();
    }
    HObject* records = null;
    if (list.is_object() && list.get_heapptr() != null) records = (HObject*)list.get_heapptr();
    if (records == null) {
        if (has_error) {
            ctx.should_throw = true;
            ctx.throw_value = pending;
        }
        return;
    }
    if (async && disposable_has_async_record(records)) {
        // The scope holds an async resource, so the release awaits.
        HObject*? p_raw = promise_create(heap);
        if (catch err_p = p_raw) { ctx.result_undefined(); return; }
        HObject* p = p_raw;
        TVal p_tv; p_tv.set_object(p);
        ctx.copy_result(p_tv);
        disposable_dispose_async(ctx, p, records, pending, has_error);
        return;
    }
    bool threw = disposable_dispose_records(heap, ctx.vm, records, &pending, has_error);
    if (threw) {
        ctx.should_throw = true;
        ctx.throw_value = pending;
    }
}

// ============================================================================
// Registration
// ============================================================================

fn bool register_disposable_stack(EnvRecord* global_env, Heap* heap) {
    HObject* proto = register_plain_constructor(global_env, heap, "DisposableStack", 0,
                                                Builtin.DISPOSABLE_STACK);
    if (proto == null) return false;
    heap.disposable_stack_proto = proto;

    const uint[*] METHODS = {
        Builtin.DISPOSABLE_STACK_PROTO_USE.ordinal,
        Builtin.DISPOSABLE_STACK_PROTO_ADOPT.ordinal,
        Builtin.DISPOSABLE_STACK_PROTO_DEFER.ordinal,
        Builtin.DISPOSABLE_STACK_PROTO_DISPOSE.ordinal,
        Builtin.DISPOSABLE_STACK_PROTO_MOVE.ordinal,
    };
    if (!register_builtin_members(proto, heap, METHODS[..])) return false;
    if (!register_proto_getter_accessor(proto, heap, "disposed",
                               Builtin.DISPOSABLE_STACK_PROTO_DISPOSED.ordinal, "get disposed")) return false;
    return alias_proto_symbol(proto, heap, "dispose", ensure_dispose_symbol(heap));
}

fn bool register_async_disposable_stack(EnvRecord* global_env, Heap* heap) {
    HObject* proto = register_plain_constructor(global_env, heap, "AsyncDisposableStack", 0,
                                                Builtin.ASYNC_DISPOSABLE_STACK);
    if (proto == null) return false;
    heap.async_disposable_stack_proto = proto;

    const uint[*] METHODS = {
        Builtin.ASYNC_DISPOSABLE_STACK_PROTO_USE.ordinal,
        Builtin.ASYNC_DISPOSABLE_STACK_PROTO_ADOPT.ordinal,
        Builtin.ASYNC_DISPOSABLE_STACK_PROTO_DEFER.ordinal,
        Builtin.ASYNC_DISPOSABLE_STACK_PROTO_DISPOSE_ASYNC.ordinal,
        Builtin.ASYNC_DISPOSABLE_STACK_PROTO_MOVE.ordinal,
    };
    if (!register_builtin_members(proto, heap, METHODS[..])) return false;
    if (!register_proto_getter_accessor(proto, heap, "disposed",
                               Builtin.ASYNC_DISPOSABLE_STACK_PROTO_DISPOSED.ordinal, "get disposed")) return false;
    return alias_proto_symbol(proto, heap, "disposeAsync", ensure_asyncdispose_symbol(heap));
}

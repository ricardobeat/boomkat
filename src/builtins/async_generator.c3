// Async generators, `async function*` (ES2018 §27.4 / §27.6).
//
// This module implements the object surface and request-queue machinery
// (plan 060 Phase B):
//   - %AsyncIteratorPrototype%       (§27.1.3), holds @@asyncIterator → this
//   - %AsyncGeneratorPrototype%      (§27.6.1), next/return/throw + @@toStringTag
//   - %AsyncGeneratorFunction.prototype% (= %AsyncGenerator%, §27.4.3)
//   - %AsyncGeneratorFunction%       (§27.4.1), the constructor
//
// AsyncGeneratorEnqueue (§27.6.3.1): each next/return/throw call always
// returns a *fresh* promise, pushes a request `{completion_kind, value,
// capability}` onto a FIFO queue on the generator's GeneratorState, and, when
// the generator is not EXECUTING/AWAITING_RETURN, drains the queue.
//
// The drain reuses the synchronous generator resume machinery (the same body
// the sync Generator.prototype.next drives) via `heap.call_fn`, which returns
// the body's `{value, done}` IteratorResult (or sets heap.has_error on an
// uncaught throw). That result is used to settle the request's promise. The
// yield-vs-await resume-driver split (§27.6.3.8 AsyncGeneratorYield: await the
// operand before settling) is Phase C, for now a `yield v` settles the
// current request's promise with `{v, false}` synchronously, which is correct
// for bodies without an `await` between the yield and the settle.
module boomkat::builtins;
import boomkat::types;
import boomkat::hstring;
import boomkat::heap;
import boomkat::hobject;
import boomkat::bytecode;
import boomkat::env;

// ============================================================================
// Prototype-chain registration (heap init)
// ============================================================================

// Create the async-generator prototype chain (ES2018 §27.1.3 / §27.4 / §27.6).
// Called after register_generator_constructor (needs function_proto,
// object_proto, generator machinery) and after the async-iterator symbol
// helpers are available.
fn bool register_async_generator(EnvRecord* global_env, Heap* heap) {
    // %AsyncIteratorPrototype% (§27.1.3).
    // A plain object inheriting from %Object.prototype% whose sole own member
    // is @@asyncIterator, an accessor-free method returning `this`.
    HObject*? ai_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = ai_raw) return false;
    HObject* ai_proto = ai_raw;
    ai_proto.prototype = heap.object_proto;
    heap.async_iterator_proto = ai_proto;
    {
        HString* asynciter_key = ensure_asynciterator_symbol(heap);
        if (asynciter_key != null) {
            HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (catch err = fn_raw) return false;
            HObject* fn_obj = fn_raw;
            (*fn_obj.extra_ptr()).func.builtin_fn_index =
                (int)Builtin.ASYNC_ITERATOR_PROTO_SYMBOL_ASYNCITER.ordinal;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            // .length = 0, .name = "[Symbol.asyncIterator]" (ES2018 §27.1.3.1).
            {
                HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
                TVal len_tv; len_tv.set_fastint(0);
                fn_obj.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC, heap);
                HString* name_key = heap.str(heap::BuiltinStr.NAME);
                HString* name_val = builtin_intern_string(heap, "[Symbol.asyncIterator]");
                if (name_key != null && name_val != null) {
                    TVal name_tv; name_tv.set_string(name_val);
                    fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC, heap);
                }
            }
            TVal iter_tv;
            iter_tv.set_object(fn_obj);
            ai_proto.put_prop(asynciter_key, iter_tv, hobject::PROP_FLAGS_WC, heap);
        }
    }

    // %AsyncGeneratorPrototype% (§27.6.1).
    // Inherits from %AsyncIteratorPrototype%; next/return/throw + @@toStringTag.
    HObject*? ag_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = ag_raw) return false;
    HObject* ag_proto = ag_raw;
    ag_proto.prototype = ai_proto;
    heap.async_generator_proto = ag_proto;

    if (!register_string_proto_method(ag_proto, heap, "next",   Builtin.ASYNC_GENERATOR_PROTO_NEXT.ordinal))   return false;
    if (!register_string_proto_method(ag_proto, heap, "return", Builtin.ASYNC_GENERATOR_PROTO_RETURN.ordinal)) return false;
    if (!register_string_proto_method(ag_proto, heap, "throw",  Builtin.ASYNC_GENERATOR_PROTO_THROW.ordinal))  return false;

    {
        HString* tag_key = ensure_tostringtag_symbol(heap);
        if (tag_key != null) {
            TVal tag_tv;
            tag_tv.set_string(builtin_intern_string(heap, "AsyncGenerator"));
            ag_proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
        }
    }

    // %AsyncGeneratorFunction.prototype% (= %AsyncGenerator%, §27.4.3).
    // Inherits from %Function.prototype%; its own `.prototype` is
    // %AsyncGeneratorPrototype%, and @@toStringTag = "AsyncGeneratorFunction".
    HObject*? agf_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = agf_raw) return false;
    HObject* agf_proto = agf_raw;
    agf_proto.prototype = heap.function_proto;
    heap.async_generator_func_proto = agf_proto;

    {
        // %AsyncGenerator%.prototype → %AsyncGeneratorPrototype%
        // {writable:false, enumerable:false, configurable:true}.
        HString* proto_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
        TVal proto_tv;
        proto_tv.set_object(ag_proto);
        agf_proto.put_prop(proto_key, proto_tv, hobject::PROP_FLAGS_NWC, heap);
    }
    {
        HString* tag_key = ensure_tostringtag_symbol(heap);
        if (tag_key != null) {
            TVal tag_tv;
            tag_tv.set_string(builtin_intern_string(heap, "AsyncGeneratorFunction"));
            agf_proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
        }
    }

    // %AsyncGeneratorFunction% constructor (§27.4.1).
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.ASYNC_GENERATOR_FUNCTION.ordinal;
    ctor.flags.callable = true;
    // AsyncGeneratorFunction is a subclass of Function (ES2018 §27.4.2): its
    // [[Prototype]] is %Function%, not Function.prototype.
    ctor.prototype = heap.function_ctor != null ? heap.function_ctor : heap.function_proto;

    // %AsyncGenerator%.constructor → %AsyncGeneratorFunction%
    {
        HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
        TVal constructor_tv;
        constructor_tv.set_object(ctor);
        agf_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_NWC, heap);
    }
    // %AsyncGeneratorPrototype%.constructor → %AsyncGenerator% (§27.6.1.1).
    {
        HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
        TVal constructor_tv;
        constructor_tv.set_object(agf_proto);
        ag_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_NWC, heap);
    }
    // %AsyncGeneratorFunction%.prototype → %AsyncGenerator%
    // {writable:false, enumerable:false, configurable:false} (§27.4.2.2).
    {
        HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
        TVal agf_proto_tv;
        agf_proto_tv.set_object(agf_proto);
        ctor.put_prop(prototype_key, agf_proto_tv, hobject::PROP_FLAGS_NNC, heap);
    }
    {
        HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        TVal length_tv;
        length_tv.set_fastint(1);
        ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC, heap);
    }
    set_func_ctor_name(ctor, heap, "AsyncGeneratorFunction");

    return true;
}

// ============================================================================
// %AsyncIteratorPrototype%[@@asyncIterator](), ES2018 §27.1.3.1 → returns this
// ============================================================================

fn void builtin_async_iterator_proto_symbol_asynciter(BuiltinContext* ctx) {
    *ctx.result = ctx.this_val;
}

// ============================================================================
// AsyncGeneratorFunction constructor (ES2018 §27.4.1), CreateDynamicFunction
// ============================================================================

fn void builtin_async_generator_function(BuiltinContext* ctx) {
    // is_gen=true, is_async=true → `async function*` dynamic source.
    builtin_dynamic_gen_function(ctx, true, true);
}

// ============================================================================
// AsyncGenerator request queue (ES2018 §27.6.3.1 AsyncGeneratorEnqueue)
// ============================================================================

// Resolve `this` to the GeneratorState of an async generator, or null if
// `this` isn't one (guards against `AsyncGenerator.prototype.next.call(x)`).
fn GeneratorState* async_gen_state_of(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object()) return null;
    HObject* gen_obj = (HObject*)ctx.this_val.get_heapptr();
    if (gen_obj == null || gen_obj.flags.obj_class != hobject::ObjClass.GENERATOR) return null;
    GeneratorState* gs = (GeneratorState*)(*gen_obj.extra_ptr()).gen.generator_data;
    if (gs == null || !gs.is_async_gen) return null;
    return gs;
}

// Build a rejected promise for a `this` that isn't an async generator: per
// §27.6.1.2/.3/.4 the method returns a promise rejected with a TypeError
// rather than throwing synchronously.
fn void async_gen_reject_bad_this(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal te = async_gen_type_error(heap, "not an AsyncGenerator");
    HObject*? p_raw = promise_create(heap);
    if (catch err = p_raw) { ctx.result.set_undefined(); return; }
    HObject* p = p_raw;
    promise_settle(p, PROMISE_REJECTED, &te, heap);
    promise_trigger_reactions(p, heap, ctx.vm);
    ctx.result.set_object(p);
}

// Build a TypeError value without touching heap.has_error.
fn TVal async_gen_type_error(Heap* heap, char[] msg) {
    TVal out;
    out.set_undefined();
    HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = heap.type_err_proto;
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

// Allocate an IteratorResult `{value, done}` object.
fn HObject* async_gen_iter_result(Heap* heap, TVal value, bool done) {
    HObject*? r_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = r_raw) return null;
    HObject* r = r_raw;
    r.prototype = heap.object_proto;
    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    r.put_prop(value_key, value, hobject::PROP_FLAGS_WEC, heap);
    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv; done_tv.set_boolean(done);
    r.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC, heap);
    return r;
}

// AsyncGeneratorEnqueue (§27.6.3.1): create a fresh promise, push a request,
// and, if the generator is not currently running the body or awaiting a
// return, drain the queue. Writes the promise into ctx.result.
fn void async_gen_enqueue(BuiltinContext* ctx, GeneratorState* gs, ResumeKind kind, TVal completion) {
    Heap* heap = ctx.heap;

    HObject*? p_raw = promise_create(heap);
    if (catch err = p_raw) { ctx.result.set_undefined(); return; }
    HObject* promise = p_raw;

    AsyncGenRequest* req = (AsyncGenRequest*)heap.alloc_func(heap.heap_udata, AsyncGenRequest::size);
    if (req == null) { ctx.result.set_undefined(); return; }
    mem::clear(req, (sz)(AsyncGenRequest::size));
    req.completion_kind = kind;
    req.value = completion;
    req.capability = promise;
    req.next = null;

    // FIFO append.
    if (gs.agr_tail != null) {
        gs.agr_tail.next = req;
        gs.agr_tail = req;
    } else {
        gs.agr_head = req;
        gs.agr_tail = req;
    }

    // Hand the promise back to the caller before draining (draining may settle
    // it synchronously in this Phase-B increment).
    ctx.result.set_object(promise);

    if (gs.state != GEN_EXECUTING && gs.state != GEN_AWAITING_RETURN) {
        async_gen_drain(ctx, gs);
    }
}

// Pop the head request off the queue and free its node, returning the request
// data by value.
//
// The returned struct lives in a C3 local, which the mark phase cannot see, so
// the promise is parked in gs.ag_root_promise (marked by
// mark_generator_state) before this returns. Without that hand-off the promise
// is unrooted from the moment it leaves the queue, and the first allocation the
// caller makes can sweep the very promise it is about to settle.
fn AsyncGenRequest async_gen_dequeue(Heap* heap, GeneratorState* gs) {
    AsyncGenRequest* head = gs.agr_head;
    AsyncGenRequest out = *head;
    gs.agr_head = head.next;
    if (gs.agr_head == null) gs.agr_tail = null;
    out.next = null;
    heap.free_func(heap.heap_udata, head);
    gs.ag_root_promise = (void*)out.capability;
    gs.ag_current_value = out.value;
    return out;
}

// Release the in-flight request: drop the re-entrancy guard so a reaction may
// start the next request, then hand the promise back with gs.ag_root_promise
// still rooting it. The caller settles and only then calls
// async_gen_release_root, so the promise stays marked across the allocating
// settle and its synchronous reactions.
fn HObject* async_gen_release_guard(GeneratorState* gs) {
    gs.ag_body_in_flight = false;
    return (HObject*)gs.ag_root_promise;
}

// Drop the request's GC roots, once its promise has settled and the reactions
// it triggered have returned.
fn void async_gen_release_root(GeneratorState* gs) {
    gs.ag_root_promise = null;
    gs.ag_current_value.set_undefined();
}

// Settle the in-flight request's promise with an IteratorResult `{value, done}`.
// Owns the guard/root lifetimes for every settle site in this module.
fn void async_gen_settle_result(Heap* heap, void* vm, GeneratorState* gs, TVal value, bool done) {
    HObject* promise = async_gen_release_guard(gs);
    if (promise != null) {
        HObject* r = async_gen_iter_result(heap, value, done);
        if (r != null) {
            TVal r_tv; r_tv.set_object(r);
            promise_settle(promise, PROMISE_FULFILLED, &r_tv, heap);
            promise_trigger_reactions(promise, heap, vm);
        }
    }
    async_gen_release_root(gs);
}

// Reject the in-flight request's promise with `reason`. Same lifetime rules as
// async_gen_settle_result.
fn void async_gen_settle_reject(Heap* heap, void* vm, GeneratorState* gs, TVal reason) {
    HObject* promise = async_gen_release_guard(gs);
    if (promise != null) {
        promise_settle(promise, PROMISE_REJECTED, &reason, heap);
        promise_trigger_reactions(promise, heap, vm);
    }
    async_gen_release_root(gs);
}

// AsyncGeneratorDrainQueue / AsyncGeneratorResume (§27.6.3.3/.4).
// Processes queued requests FIFO until the queue is empty, the generator
// suspends at a `yield`, or the body suspends internally on an `await` (in
// which case a microtask ASYNC_GEN_AWAIT_RESUME reaction resumes the drain).
fn void async_gen_drain(BuiltinContext* ctx, GeneratorState* gs) {
    Heap* heap = ctx.heap;
    void* vm = ctx.vm;

    // If a body resume is already outstanding (an internal await or an awaited
    // `.return()` value), don't start a new one, the reaction will re-drive.
    if (gs.ag_body_in_flight) return;

    while (gs.agr_head != null) {
        // COMPLETED-state fast answers (§27.6.3.7 AsyncGeneratorResume-style):
        //   next   → {undefined, true}
        //   return → {value, true}   (§27.6.3.7 AsyncGeneratorReturn, value awaited)
        //   throw  → reject(value)
        if (gs.state == GEN_COMPLETED) {
            AsyncGenRequest req = async_gen_dequeue(heap, gs);
            switch (req.completion_kind) {
                case NEXT: {
                    TVal undef; undef.set_undefined();
                    async_gen_settle_result(heap, vm, gs, undef, true);
                }
                case RETURN:
                    // §27.6.3.8: await the value before settling {value, done}.
                    if (async_gen_await_return(ctx, gs, req.value)) return;
                    async_gen_settle_result(heap, vm, gs, req.value, true);
                case THROW:
                    async_gen_settle_reject(heap, vm, gs, req.value);
            }
            continue;
        }

        // SUSPENDED_START / SUSPENDED_YIELD: resume the body with the request's
        // completion. Reuses the synchronous generator resume path, which
        // returns the body's {value, done} IteratorResult (or sets
        // heap.has_error on an uncaught throw).
        AsyncGenRequest req = async_gen_dequeue(heap, gs);

        // A `.throw()` on SUSPENDED_START completes the generator without
        // running any body code (§27.6.3.7-style): reject and mark COMPLETED.
        if (gs.state == GEN_SUSPENDED_START && req.completion_kind == THROW) {
            gs.state = GEN_COMPLETED;
            async_gen_settle_reject(heap, vm, gs, req.value);
            continue;
        }
        // A `.return()` on SUSPENDED_START closes the generator without running
        // any body code, but first awaits the value (§27.6.3.8 AwaitReturn).
        if (gs.state == GEN_SUSPENDED_START && req.completion_kind == RETURN) {
            if (async_gen_await_return(ctx, gs, req.value)) return;
            gs.state = GEN_COMPLETED;
            async_gen_settle_result(heap, vm, gs, req.value, true);
            continue;
        }

        // A `.return()` on SUSPENDED_YIELD awaits the value before injecting the
        // return completion at the yield point (§27.6.3.7
        // AsyncGeneratorUnwrapYieldResumption). The eventual body resume happens
        // in the YRET fulfill/reject reaction.
        if (gs.state == GEN_SUSPENDED_YIELD && req.completion_kind == RETURN) {
            if (async_gen_yield_return_await(ctx, gs, req.value)) return;
        }

        // Hold the request across a possible internal await, then resume.
        gs.ag_body_in_flight = true;
        heap.ag_did_await = false;
        gs.ag_suspend_kind = AG_SUSPEND_NONE;
        TVal result = async_gen_resume_body(ctx, gs, req.completion_kind, req.value);

        // If the body suspended internally on an await, leave the current
        // request in flight; the ASYNC_GEN_AWAIT_RESUME reaction re-drives.
        if (heap.ag_did_await) {
            heap.ag_did_await = false;
            return;
        }

        // Body settled (yield / return / throw), service the outcome. The
        // settle helpers release the guard before running the downstream
        // reactions and the roots after.
        if (!async_gen_finish_body(ctx, gs, result)) break;
    }
}

// Service the outcome of a body resume that did NOT suspend on an internal
// await: settle the current request's promise. Returns true to keep draining
// (completed request), false to stop (the body yielded and is now suspended).
fn bool async_gen_finish_body(BuiltinContext* ctx, GeneratorState* gs, TVal result) {
    Heap* heap = ctx.heap;
    void* vm = ctx.vm;

    if (heap.has_error) {
        TVal thrown = heap.error_value;
        heap.has_error = false;
        gs.state = GEN_COMPLETED;
        async_gen_settle_reject(heap, vm, gs, thrown);
        return true;
    }

    TVal value; value.set_undefined();
    bool done = false;
    if (result.is_object() && result.get_heapptr() != null) {
        HObject* robj = (HObject*)result.get_heapptr();
        HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
        if (try dv = robj.get_prop(done_key, ctx.heap)) { done = builtin_to_boolean(&dv); }
        HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
        if (try vv = robj.get_prop(value_key, ctx.heap)) { value = vv; }
    }
    async_gen_settle_result(heap, vm, gs, value, done);
    // Continue draining regardless of done: AsyncGeneratorDrainQueue
    // (§27.6.3.4) resumes one queued request per step, so after a yield settles
    // the next queued request resumes the body again. The while-loop's
    // queue-empty test terminates the single-consumer (for-await) case.
    return true;
}

// AsyncGeneratorAwaitReturn (§27.6.3.8): a `.return(v)` request reached the
// generator while it was in a state where no body code runs (SUSPENDED_START or
// COMPLETED). Rather than settling `{v, done:true}` immediately, spec awaits v
// first: `PromiseResolve(%Promise%, v)` then, on fulfillment, settle the
// in-flight request `{unwrapped, done:true}`; on rejection, reject it. The
// generator stays GEN_AWAITING_RETURN (draining paused) until the await settles.
// Returns true if the await was scheduled (drain must pause), false on an
// allocation failure (caller falls back to immediate settle).
fn bool async_gen_await_return(BuiltinContext* ctx, GeneratorState* gs, TVal value) {
    Heap* heap = ctx.heap;

    HObject*? resolved_raw = promise_resolve_default_ctor(heap, ctx.vm, value);
    if (catch err = resolved_raw) return false;
    HObject* resolved = resolved_raw;
    if (resolved == null) {
        // PromiseResolve(%Promise%, value) threw (e.g. a poisoned `constructor`
        // getter). §27.6.3.8 propagates the abrupt completion by rejecting the
        // request's promise and completing the generator (AsyncGeneratorReject).
        if (heap.has_error) {
            TVal thrown = heap.error_value;
            heap.has_error = false;
            gs.state = GEN_COMPLETED;
            async_gen_settle_reject(heap, ctx.vm, gs, thrown);
            return true;
        }
        return false;
    }

    HObject*? ff_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    HObject*? rj_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    HObject*? rxn_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch e = ff_raw)  return false;
    if (catch e = rj_raw)  return false;
    if (catch e = rxn_raw) return false;
    HObject* ff = ff_raw;
    (*ff.extra_ptr()).func.builtin_fn_index = (int)Builtin.ASYNC_GEN_RETURN_FULFILL.ordinal;
    (*ff.extra_ptr()).func.var_env = (EnvRecord*)gs;
    ff.flags.callable = true;
    // var_env holds a GeneratorState*, not an EnvRecord*: is_async_state tells
    // both the GC mark phase and hobject_free to read it as one (without the
    // flag, mark_hobject would follow the EnvRecord.bindings offset into
    // GeneratorState.func and mark a CompiledFunction* as an HObject).
    ff.flags.is_async_state = true;
    heap::gs_acquire(gs);
    HObject* rj = rj_raw;
    (*rj.extra_ptr()).func.builtin_fn_index = (int)Builtin.ASYNC_GEN_RETURN_REJECT.ordinal;
    (*rj.extra_ptr()).func.var_env = (EnvRecord*)gs;
    rj.flags.callable = true;
    rj.flags.is_async_state = true;
    heap::gs_acquire(gs);
    HObject* rxn = rxn_raw;
    rxn.prototype = heap.object_proto;
    TVal ff_tv; ff_tv.set_object(ff);
    TVal rj_tv; rj_tv.set_object(rj);
    HString* ff_key = builtin_intern_string(heap, "onFulfilled");
    HString* rj_key = builtin_intern_string(heap, "onRejected");
    if (ff_key != null) rxn.put_prop(ff_key, ff_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
    if (rj_key != null) rxn.put_prop(rj_key, rj_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

    // Hold the request across the await and pause draining. ag_root_promise
    // already points at it from the dequeue.
    gs.state = GEN_AWAITING_RETURN;
    gs.ag_body_in_flight = true;

    promise_add_reaction(resolved, rxn, heap);
    if (promise_get_state(resolved, PROMISE_PENDING) != PROMISE_PENDING) {
        promise_trigger_reactions(resolved, heap, ctx.vm);
    }
    return true;
}

// ASYNC_GEN_RETURN_FULFILL native reaction (§27.6.3.8): the awaited `.return()`
// value fulfilled, settle the in-flight request `{value, done:true}`, mark the
// generator COMPLETED, and resume draining any queued requests.
fn void builtin_async_gen_return_fulfill(BuiltinContext* ctx) {
    GeneratorState* gs = (GeneratorState*)(*ctx.callee_obj.extra_ptr()).func.var_env;
    if (gs == null) { ctx.result.set_undefined(); return; }
    TVal arg; arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    gs.state = GEN_COMPLETED;
    async_gen_settle_result(ctx.heap, ctx.vm, gs, arg, true);
    async_gen_drain(ctx, gs);
    ctx.result.set_undefined();
}

// ASYNC_GEN_RETURN_REJECT native reaction (§27.6.3.8): the awaited `.return()`
// value rejected, reject the in-flight request, mark COMPLETED, resume drain.
fn void builtin_async_gen_return_reject(BuiltinContext* ctx) {
    GeneratorState* gs = (GeneratorState*)(*ctx.callee_obj.extra_ptr()).func.var_env;
    if (gs == null) { ctx.result.set_undefined(); return; }
    TVal arg; arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    gs.state = GEN_COMPLETED;
    async_gen_settle_reject(ctx.heap, ctx.vm, gs, arg);
    async_gen_drain(ctx, gs);
    ctx.result.set_undefined();
}

// AsyncGeneratorUnwrapYieldResumption (§27.6.3.7): a `.return(v)` request
// reached a generator suspended at a `yield`. Before injecting the return
// completion at the yield point, spec awaits v; on fulfillment the body resumes
// with a return completion carrying the unwrapped value (running finally
// blocks); on rejection the body resumes with a throw completion (catchable).
// The generator is held in GEN_AWAITING_RETURN across the await. Returns true
// when the await was scheduled (drain must pause); false on allocation failure
// (caller falls back to a direct resume).
fn bool async_gen_yield_return_await(BuiltinContext* ctx, GeneratorState* gs, TVal value) {
    Heap* heap = ctx.heap;

    HObject*? resolved_raw = promise_resolve_default_ctor(heap, ctx.vm, value);
    if (catch err = resolved_raw) return false;
    HObject* resolved = resolved_raw;
    if (resolved == null) {
        // PromiseResolve threw: resume the body with a throw completion at the
        // yield point so an enclosing try/catch can observe it (§27.6.3.7).
        if (heap.has_error) {
            TVal thrown = heap.error_value;
            heap.has_error = false;
            gs.ag_body_in_flight = true;
            gs.state = GEN_EXECUTING;
            // yret_resume writes ctx.result (undefined). In this synchronous
            // path ctx is the live `.return()` call's context whose result is
            // the request promise, preserve it across the nested resume.
            TVal saved_result = *ctx.result;
            async_gen_yret_resume(ctx, gs, THROW, thrown);
            *ctx.result = saved_result;
            return true;
        }
        return false;
    }

    HObject*? ff_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    HObject*? rj_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    HObject*? rxn_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch e = ff_raw)  return false;
    if (catch e = rj_raw)  return false;
    if (catch e = rxn_raw) return false;
    HObject* ff = ff_raw;
    (*ff.extra_ptr()).func.builtin_fn_index = (int)Builtin.ASYNC_GEN_YRET_FULFILL.ordinal;
    (*ff.extra_ptr()).func.var_env = (EnvRecord*)gs;
    ff.flags.callable = true;
    // See the ASYNC_GEN_RETURN_FULFILL pair above: var_env is a
    // GeneratorState*, so is_async_state must mark it as such for the GC.
    ff.flags.is_async_state = true;
    heap::gs_acquire(gs);
    HObject* rj = rj_raw;
    (*rj.extra_ptr()).func.builtin_fn_index = (int)Builtin.ASYNC_GEN_YRET_REJECT.ordinal;
    (*rj.extra_ptr()).func.var_env = (EnvRecord*)gs;
    rj.flags.callable = true;
    rj.flags.is_async_state = true;
    heap::gs_acquire(gs);
    HObject* rxn = rxn_raw;
    rxn.prototype = heap.object_proto;
    TVal ff_tv; ff_tv.set_object(ff);
    TVal rj_tv; rj_tv.set_object(rj);
    HString* ff_key = builtin_intern_string(heap, "onFulfilled");
    HString* rj_key = builtin_intern_string(heap, "onRejected");
    if (ff_key != null) rxn.put_prop(ff_key, ff_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
    if (rj_key != null) rxn.put_prop(rj_key, rj_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

    gs.state = GEN_AWAITING_RETURN;
    gs.ag_body_in_flight = true;

    promise_add_reaction(resolved, rxn, heap);
    if (promise_get_state(resolved, PROMISE_PENDING) != PROMISE_PENDING) {
        promise_trigger_reactions(resolved, heap, ctx.vm);
    }
    return true;
}

// Resume a `.return()`-at-yield body with the settled completion (return on
// fulfill, throw on reject), then finish the in-flight request and continue
// draining. Shared by the YRET fulfill/reject reactions.
fn void async_gen_yret_resume(BuiltinContext* ctx, GeneratorState* gs, ResumeKind kind, TVal completion) {
    Heap* heap = ctx.heap;

    gs.ag_body_in_flight = true;
    heap.ag_did_await = false;
    gs.ag_suspend_kind = AG_SUSPEND_NONE;
    TVal result = async_gen_resume_body(ctx, gs, kind, completion);

    // The resumed return/throw completion may itself hit an internal await
    // (e.g. a finally-block `await`), stay in flight if so.
    if (heap.ag_did_await) {
        heap.ag_did_await = false;
        ctx.result.set_undefined();
        return;
    }

    if (async_gen_finish_body(ctx, gs, result)) {
        async_gen_drain(ctx, gs);
    }
    ctx.result.set_undefined();
}

// ASYNC_GEN_YRET_FULFILL native reaction: the awaited `.return()` value settled;
// resume the body with a return completion carrying the unwrapped value.
fn void builtin_async_gen_yret_fulfill(BuiltinContext* ctx) {
    GeneratorState* gs = (GeneratorState*)(*ctx.callee_obj.extra_ptr()).func.var_env;
    if (gs == null) { ctx.result.set_undefined(); return; }
    TVal arg; arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    gs.state = GEN_EXECUTING;
    async_gen_yret_resume(ctx, gs, RETURN, arg);
}

// ASYNC_GEN_YRET_REJECT native reaction: the awaited `.return()` value rejected;
// resume the body with a throw completion at the yield point (catchable).
fn void builtin_async_gen_yret_reject(BuiltinContext* ctx) {
    GeneratorState* gs = (GeneratorState*)(*ctx.callee_obj.extra_ptr()).func.var_env;
    if (gs == null) { ctx.result.set_undefined(); return; }
    TVal arg; arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    gs.state = GEN_EXECUTING;
    async_gen_yret_resume(ctx, gs, THROW, arg);
}

// ASYNC_GEN_AWAIT_RESUME native reaction (§27.6): an internal `await` inside an
// async-gen body fulfilled. Deliver the value as the resume completion, re-run
// the body, and continue draining.
fn void builtin_async_gen_await_resume(BuiltinContext* ctx) {
    GeneratorState* gs = (GeneratorState*)(*ctx.callee_obj.extra_ptr()).func.var_env;
    if (gs == null) { ctx.result.set_undefined(); return; }
    TVal arg; arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    async_gen_await_reenter(ctx, gs, NEXT, arg);
}

// ASYNC_GEN_AWAIT_REJECT native reaction (§27.6): an internal `await` rejected.
// Inject the reason as a throw completion at the await point.
fn void builtin_async_gen_await_reject(BuiltinContext* ctx) {
    GeneratorState* gs = (GeneratorState*)(*ctx.callee_obj.extra_ptr()).func.var_env;
    if (gs == null) { ctx.result.set_undefined(); return; }
    TVal arg; arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    async_gen_await_reenter(ctx, gs, THROW, arg);
}

// Re-enter a suspended async-gen body after an internal await settled, then
// resume draining. Shared by the fulfill/reject reactions.
fn void async_gen_await_reenter(BuiltinContext* ctx, GeneratorState* gs, ResumeKind kind, TVal completion) {
    Heap* heap = ctx.heap;

    gs.ag_body_in_flight = true;
    heap.ag_did_await = false;
    gs.ag_suspend_kind = AG_SUSPEND_NONE;
    TVal result = async_gen_resume_body(ctx, gs, kind, completion);

    // Suspended again on another internal await, stay in flight.
    if (heap.ag_did_await) {
        heap.ag_did_await = false;
        ctx.result.set_undefined();
        return;
    }

    // The body settled. Finish the in-flight request, then drain the rest.
    if (async_gen_finish_body(ctx, gs, result)) {
        async_gen_drain(ctx, gs);
    }
    ctx.result.set_undefined();
}

// Resume the async generator's body synchronously (reusing the sync generator
// resume machinery) with the given completion, returning the body's
// `{value, done}` IteratorResult. Sets heap.has_error on an uncaught throw.
fn TVal async_gen_resume_body(BuiltinContext* ctx, GeneratorState* gs, ResumeKind kind, TVal completion) {
    Heap* heap = ctx.heap;
    TVal out; out.set_undefined();

    // Install the resume completion, mirroring Generator.prototype.next/throw/
    // return but driving the body via heap.call_fn instead of re-dispatch.
    gs.resume_kind = kind;
    switch (kind) {
        case NEXT:   gs.resume_value = completion;
        case THROW:  gs.throw_value  = completion;
        case RETURN: gs.return_value = completion;
    }
    heap.resume_gen = gs;
    heap.did_yield = false;

    HObject*? wrapper_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = wrapper_raw) { heap.resume_gen = null; return out; }
    HObject* wrapper = wrapper_raw;
    wrapper.flags.callable = true;
    (*wrapper.extra_ptr()).func.comp_func = (CompiledFunction*)gs.func;
    (*wrapper.extra_ptr()).func.var_env = (EnvRecord*)gs.var_env;
    (*wrapper.extra_ptr()).func.lex_env = (EnvRecord*)gs.lex_env;

    TVal wrapper_tv; wrapper_tv.set_object(wrapper);
    TVal this_tv = gs.this_binding;
    out = heap.call_fn(ctx.vm, wrapper_tv, null, 0, this_tv);

    if (heap.resume_gen == gs) heap.resume_gen = null;
    return out;
}

// ============================================================================
// %AsyncGeneratorPrototype%.next / .return / .throw (§27.6.1.2/.3/.4)
// ============================================================================

fn void builtin_async_generator_proto_next(BuiltinContext* ctx) {
    GeneratorState* gs = async_gen_state_of(ctx);
    if (gs == null) { async_gen_reject_bad_this(ctx); return; }
    TVal arg; arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    async_gen_enqueue(ctx, gs, NEXT, arg);
}

fn void builtin_async_generator_proto_return(BuiltinContext* ctx) {
    GeneratorState* gs = async_gen_state_of(ctx);
    if (gs == null) { async_gen_reject_bad_this(ctx); return; }
    TVal arg; arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    async_gen_enqueue(ctx, gs, RETURN, arg);
}

fn void builtin_async_generator_proto_throw(BuiltinContext* ctx) {
    GeneratorState* gs = async_gen_state_of(ctx);
    if (gs == null) { async_gen_reject_bad_this(ctx); return; }
    TVal arg; arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    async_gen_enqueue(ctx, gs, THROW, arg);
}

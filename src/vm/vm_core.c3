module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;

// ============================================================================
// GC activation marking
// ============================================================================

/// Mark env bindings held by a single activation.  Shared between the live
/// activation array and the shadow frame stack.
fn void mark_activation_envs(heap::Heap* h, Activation* act) @inline {
    if (act.var_env != null && act.var_env.bindings != null) {
        h.mark_hobject(act.var_env.bindings);
    }
    if (act.lex_env != null && act.lex_env.bindings != null && act.lex_env != act.var_env) {
        h.mark_hobject(act.lex_env.bindings);
    }
    // Walk the full var_env parent chain to keep all enclosing scopes alive.
    env::EnvRecord* cur = act.var_env;
    while (cur != null) {
        if (cur.bindings != null) { h.mark_hobject(cur.bindings); }
        cur = cur.parent;
    }
    // Also walk the lex_env parent chain in case it diverges from var_env.
    cur = act.lex_env;
    while (cur != null) {
        if (cur.bindings != null) { h.mark_hobject(cur.bindings); }
        cur = cur.parent;
    }
}

/// Mark every heap value held in a JS activation's [bottom, frame_end) span.
/// The valstack range scanned by mark_roots is bounded by vm.valstack_top,
/// which is only a high-water mark for the deepest frame and can sit below an
/// outer frame's full register span (inline JS-to-JS calls do not raise it),
/// or below scratch slots where a builtin has staged call arguments. A live
/// value in such a slot (e.g. a BigInt box held across a callee) would then be
/// invisible to the GC, collected, and later read as freed memory. Marking each
/// live frame's own span makes register rooting independent of valstack_top.
/// Native/builtin frames have func==null and no registers here. Callers choose
/// frame_end to cover the frame's registers plus any staged-argument scratch.
fn void mark_activation_regs(heap::Heap* h, Activation* act, TVal* frame_end) @inline {
    if (act.func == null || act.bottom == null) return;
    TVal* regs = act.bottom;
    if (frame_end <= regs) return;
    usz span = (usz)(frame_end - regs);
    for (usz i = 0; i < span; i++) {
        h.mark_tval(&regs[i]);
    }
}

/// Mark heap references held in an Activation's own struct fields (not the
/// register span, not the env chain). These slots can be the sole surviving
/// root for a value across a safepoint GC:
///  - this_binding: owned ref (ACT_FLAG_THIS_OWNED); for getters/setters the
///    receiver is copied ONLY here (registers are cleared, no arg slot holds it).
///  - this_binding (construct): the freshly allocated constructor instance is
///    parked here by a raw assign and, under GC pressure inside the constructor
///    body, is otherwise collected — its [[Prototype]] then reads as freed
///    memory (confirmed via a Reflect.construct/derived-class stress repro).
///  - new_target: an HObject* for the constructor/newTarget. Defensive — every
///    repro attempted co-rooted it via a caller register or the class binding,
///    but marking it removes the dependence on that incidental rooting.
///  - async_promise: the async function/module's outer Promise, owned while the
///    activation is live and settled only after the body returns. Defensive:
///    co-rooted by the microtask queue / resolve-reject closures in practice.
///  - async_gen_state: the GeneratorState this frame is resuming; mark its
///    contents so a suspended-then-resumed async generator is not swept mid-body.
///    Defensive: the gs is normally reachable via its owning generator object.
///  - Catcher.thrown_val: an in-flight exception parked in a catcher across a
///    GC that runs while unwinding (e.g. allocation-heavy finally blocks) —
///    confirmed collectible without this mark via a throw-through-finally repro.
/// Marking a null/undefined slot is a harmless no-op (mark_tval/mark_hobject and
/// mark_generator_state all null-check).
fn void mark_activation_fields(heap::Heap* h, Activation* act) @inline {
    // this_binding can be the sole root of a heap value in two cases:
    //  - ACT_FLAG_THIS_OWNED: the frame incref'd `this` into this slot
    //    (getters/setters, inline CALL) — the register copy may be gone.
    //  - ACT_FLAG_CONSTRUCT: the freshly allocated instance is stored here by a
    //    raw assign (vm_execute construct entry) and is not reliably in any
    //    register during the constructor body (verified collectible under GC).
    // An ordinary call's `this` was copied from a register/env that still roots
    // it, so deep non-method recursion (this === undefined, both flags clear)
    // stays free of the per-frame mark.
    if ((act.flags & (ACT_FLAG_THIS_OWNED | ACT_FLAG_CONSTRUCT)) != 0) {
        h.mark_tval(&act.this_binding);
    }
    if (act.new_target != null) { h.mark_hobject(act.new_target); }
    if (act.async_promise != null) { h.mark_hobject(act.async_promise); }
    if (act.async_gen_state != null) {
        h.mark_generator_state((heap::GeneratorState*)act.async_gen_state);
    }
    // Walk the catcher chain: an in-flight exception parked in Catcher.thrown_val
    // (set by THROW, not yet consumed by CATCH) is not on the valstack and would
    // otherwise be collected across a safepoint GC that runs while unwinding.
    Catcher* c = (Catcher*)act.cat;
    while (c != null) {
        h.mark_tval(&c.thrown_val);
        h.mark_tval(&c.return_val);
        c = c.parent;
    }
}

/// Mark all env bindings held by live activation records.
/// Called from heap's mark_roots to keep per-call var_envs alive during GC.
/// Also marks saved activations stored in vm_call_fn_impl's shadow frame list
/// so that outer call frames remain alive during nested Vm.run() execution.
fn void vm_mark_activations(void* vm_ptr, void* heap_ptr) {
    Vm* vm = (Vm*)vm_ptr;
    heap::Heap* h = (heap::Heap*)heap_ptr;

    // VM-level TVal scratch that outlives any single register span and is not
    // part of the scanned valstack: a heap value parked here (e.g. a closure
    // returned into vm.return_val by a top-level RET, or a pending throw value)
    // must be rooted, or a safepoint GC — which clears temproots — collects it
    // and the next decref of the stale slot is a use-after-free.
    h.mark_tval(&vm.return_val);
    h.mark_tval(&vm.throw_value);

    // Mark live activations (inner-most vm_call_fn_impl's callback + inline callees).
    // Each frame's register span runs from its bottom to the next inner frame's
    // bottom (which contains the argument/scratch slots this frame staged for
    // that callee); the innermost frame runs to the end of the allocated
    // valstack (see below — staged-argument scratch is not tracked precisely).
    for (uint i = 0; i < vm.activation_count; i++) {
        mark_activation_envs(h, &vm.activations[i]);
        mark_activation_fields(h, &vm.activations[i]);
        Activation* a = &vm.activations[i];
        // Lower bound on this frame's span: its own declared registers plus the
        // builtin arg/scratch margin. valstack_top can sit BELOW an outer (or
        // even the current) frame's num_regs because inline JS-to-JS calls do
        // not raise it, so it cannot be trusted as the frame end on its own.
        TVal* frame_end = a.bottom;
        if (a.func != null) {
            CompiledFunction* acf = (CompiledFunction*)a.func;
            frame_end = a.bottom + acf.num_regs + 4;
        }
        // Extend to the next inner frame's bottom (covers args this frame staged
        // for that callee). For the innermost frame, extend to the end of the
        // allocated valstack: builtins stage call arguments in scratch slots
        // above num_regs whose exact extent is not tracked by valstack_top, and
        // a live value there must not be collected. Slots past the live data are
        // zero-initialised (undefined) — marking them is a harmless no-op — so
        // scanning to valstack_end is safe and cannot miss a staged argument.
        if (i + 1 < vm.activation_count) {
            TVal* nb = vm.activations[i + 1].bottom;
            if (nb > frame_end) { frame_end = nb; }
        } else if (vm.valstack_end > frame_end) {
            frame_end = vm.valstack_end;
        }
        mark_activation_regs(h, a, frame_end);
    }

    // Mark saved outer activations from all vm_call_fn_impl frames on the C stack.
    // These are stored in C-stack ShadowActFrame structs linked via vm.shadow_act_list.
    // Their exact physical span is not tracked here, so cover num_regs plus the
    // builtin arg/scratch margin (matches the +4 slots reserved at call sites).
    ShadowActFrame* shadow = (ShadowActFrame*)vm.shadow_act_list;
    while (shadow != null) {
        for (uint i = 0; i < shadow.count; i++) {
            mark_activation_envs(h, &shadow.acts[i]);
            mark_activation_fields(h, &shadow.acts[i]);
            Activation* sa = &shadow.acts[i];
            if (sa.func != null && sa.bottom != null) {
                CompiledFunction* scf = (CompiledFunction*)sa.func;
                TVal* send = sa.bottom + scf.num_regs + 4;
                mark_activation_regs(h, sa, send);
            }
        }
        shadow = (ShadowActFrame*)shadow.prev;
    }
}

// ============================================================================
// Call handling (matches duk_js_call.c)
// ============================================================================

/// Invoke a getter function found on the prototype chain.
/// Sets up an ECMAScript call frame for the getter with `this` = this_obj,
/// and result register = result_reg (in the caller's frame).
/// Returns true if the call was set up (caller should `break` with needs_restart).
fn bool invoke_getter(Vm* vm, hobject::AccessorResult* acc,
                      TVal* this_val, uint result_reg,
                      Activation* act, Instruction** curr_pc, bool* needs_restart,
                      TVal* regs_base) {
    TVal getter_fn = acc.accessor_fn;

    // If getter is undefined/null, return undefined (no-op)
    if (getter_fn.is_undefined() || getter_fn.is_null()) {
        regs_base[result_reg].set_undefined();
        return false;
    }

    if (!getter_fn.is_object()) return false;
    HObject* func_obj = (HObject*)getter_fn.get_heapptr();
    if (func_obj == null || !func_obj.is_callable()) return false;

    // Fast path: builtin function getter — call directly, no JS frame needed
    if (func_obj.callable_kind() == hobject::CallableKind.BUILTIN_FN &&
        (*func_obj.extra_ptr()).func.builtin_fn_index >= 0) {
        uint fn_idx = (uint)(*func_obj.extra_ptr()).func.builtin_fn_index;
        TVal[1] temp_regs;
        temp_regs[0] = *this_val;  // this at regs[base_reg - 1] = regs[0]
        builtins::BuiltinContext ctx;
        ctx.vm = vm;
        ctx.regs = &temp_regs;
        ctx.base_reg = 1;
        ctx.argc = 0;
        ctx.result = &temp_regs[0];
        ctx.heap = vm.heap;
        ctx.this_val = *this_val;
        ctx.is_constructor = false;
        ctx.needs_re_dispatch = false;
        ctx.re_nargs = 0;
        ctx.global_env = vm.global_env;
        ctx.should_throw = false;
        ctx.callee_obj = func_obj;
        builtins::dispatch_builtin(fn_idx, &ctx);
        if (ctx.should_throw) {
            if (!vm_throw_value(vm, ctx.throw_value, act, curr_pc, needs_restart)) {
                // Uncaught — mark error state so dispatch_property propagates VM_ERROR~.
                vm.has_error = true;
                vm.heap.has_error = true;
                vm.heap.tval_copy_ref(&vm.heap.error_value, &ctx.throw_value);
                vm.heap.tval_copy_ref(&vm.return_val, &ctx.throw_value);
                regs_base[result_reg].set_undefined();
                return false;
            }
            regs_base = act.bottom;
        } else {
            vm.heap.store_builtin_result(&regs_base[result_reg], ctx.result);
        }
        return false;
    }

    CompiledFunction* target = (*func_obj.extra_ptr()).func.comp_func;
    if (target == null) return false;

    // Set up call frame: callee_reg = result_reg (we reuse it)
    uint callee_reg = result_reg;
    uint frame_start = callee_reg + 2;
    TVal* new_bottom = act.bottom + frame_start;
    uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

    if (!ensure_valstack(vm, needed)) {
        regs_base[result_reg].set_undefined();
        return false;
    }

    // Re-acquire regs_base after potential reallocation
    TVal* caller_regs = act.bottom;
    // Recompute new_bottom after realloc (act.bottom may have moved)
    new_bottom = act.bottom + frame_start;
    vm.heap.tval_copy_ref(&caller_regs[callee_reg], &getter_fn);
    vm.heap.tval_copy_ref(&caller_regs[callee_reg + 1], this_val);

    if (vm.activation_count >= MAX_CALLS) {
        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = vm.heap.range_err_proto;
            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
            HString* msg_val = intern_string(vm, "Maximum call stack size exceeded");
            TVal msg_tv; msg_tv.set_string(msg_val);
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
            TVal err_val; err_val.set_object(err);
            if (!vm_throw_value(vm, err_val, act, curr_pc, needs_restart)) {
                caller_regs[result_reg].set_undefined();
                return false;
            }
        } else {
            caller_regs[result_reg].set_undefined();
            return false;
        }
        return false;
    }

    Activation* new_act = &vm.activations[vm.activation_count];
    vm.activation_count++;
    new_act.max_heap_reg = 0;
    new_act.caller_valstack_top = vm.valstack_top;

    EnvRecord* invoke_getter_var_env = (*func_obj.extra_ptr()).func.var_env;
    if (try fv_ig = env::env_create_function_scope(vm.heap, (*func_obj.extra_ptr()).func.var_env)) { invoke_getter_var_env = fv_ig; }
    new_act.parent = act;
    new_act.func = target;
    new_act.var_env = invoke_getter_var_env;
    new_act.lex_env = resolve_call_lex_env(vm, func_obj, target, invoke_getter_var_env);
    new_act.cat = null;
    new_act.curr_pc = target.code;
    new_act.bottom = new_bottom;
    new_act.retval = act.bottom + result_reg;
    new_act.flags = 0;
    // Getter invocation is never a construct call — new.target must read as
    // undefined inside the getter body, regardless of how the property
    // access was reached (including via super.prop from a constructor).
    new_act.new_target = null;
    if (target.has_direct_eval()) {
        new_act.flags |= ACT_FLAG_DIRECT_EVAL;
    }
    vm.heap.tval_copy_ref(&new_act.this_binding, this_val);
    new_act.flags |= ACT_FLAG_THIS_OWNED;

    // Clear registers and copy args (getters have 0 args)
    TVal* new_regs = new_act.bottom;
    uint new_nregs = target.num_regs;
    mem::clear(new_regs, (sz)((usz)new_nregs * TVal::size));

    // Create the arguments object for getters/setters that reference `arguments`.
    // Per ES2015 §14.3 step 7 + §14.5.14 step 11 (Runtime Semantics: ClassDefinitionEvaluation
    // for MethodDefinition), the `arguments` object is bound for getter/setter bodies just
    // like for ordinary methods — without this, a getter body doing `var a = arguments`
    // raises ReferenceError. Getters/setters never receive user-supplied args (the
    // property-access syntax passes none), so the object is always empty.
    if (target.uses_arguments()) {
        HObject*? args_obj_raw_ig = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
        if (try args_obj_ig = args_obj_raw_ig) {
            args_obj_ig.prototype = vm.heap.object_proto;
            finish_arguments_object(vm, args_obj_ig, func_obj, 0);
            HString* args_name_ig = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
            if (args_name_ig != null) {
                TVal args_tv_ig; args_tv_ig.set_object(args_obj_ig);
                env::env_declare(new_act.var_env, args_name_ig, args_tv_ig);
            }
        }
    }

    vm.valstack_top = new_regs + new_nregs;
    vm.valstack_bottom = new_act.bottom;

    // Save caller's PC so it resumes correctly after getter returns
    act.curr_pc = *curr_pc;

    *needs_restart = true;
    return true;
}

/// Track a heap-ref store in the current activation.  Call after any
/// instruction that writes an object or buffer TVal into a register.
/// Updates max_heap_reg so decref_callee_regs can skip non-heap registers.
fn void track_heap_store(Activation* act, TVal* val, uint reg_idx) @inline {
    if (val.is_heap_allocated()) {
        if (val.get_heapptr() != null && reg_idx > act.max_heap_reg) {
            act.max_heap_reg = reg_idx;
        }
    }
}

/// ES2015 §9.2.2 step 15 / §8.1.1.3.4: an explicit `return;`, `return undefined;`,
/// or implicit fallthrough from a derived constructor falls through to
/// GetThisBinding() — if super() was never called, this_binding is still the
/// TDZ sentinel and must throw ReferenceError. Shared by RET (when the return
/// value is undefined) and RETUNDEF so both opcodes enforce the same check.
fn bool derived_ctor_returns_undefined_uninitialized(Activation* callee_act) @inline {
    return (callee_act.flags & ACT_FLAG_CONSTRUCT) != 0
        && (callee_act.flags & ACT_FLAG_DERIVED) != 0
        && env::is_tdz_sentinel(&callee_act.this_binding);
}

/// When an activation whose callee was BORROWED (ACT_FLAG_BORROWED_CALLEE) is
/// unwound abnormally (exception), its retval slot in the surviving caller
/// still holds the borrowed, non-owned callee value. A later decref_callee_regs
/// sweep of that caller frame would decref a reference the caller never owned
/// (the callee register is inside the caller's [0..max_heap_reg] range whenever
/// a heap argument was passed). Neutralize the borrowed bits with a raw
/// overwrite so the sweep skips over harmless undefined. No decref: borrowed.
fn void clear_borrowed_callee_slot(Activation* act) @inline {
    if ((act.flags & ACT_FLAG_BORROWED_CALLEE) != 0 && act.retval != null) {
        act.retval.set_undefined();
    }
}

/// Free every Catcher still chained on an activation that is being popped.
/// A `return` from inside a try block (or an unwind past the frame) leaves
/// the TRY-allocated catcher(s) on act.cat: CATCH/ENDTRY/ENDFINALLY only pop
/// them on their own control paths, which an early return never reaches —
/// without this, each such frame permanently leaks its Catcher allocation(s).
/// thrown_val is the one owned reference a parked catcher can hold (written
/// via tval_copy_ref while routing a throw to a finally); release it too.
fn void free_catcher_chain(Vm* vm, Activation* act) @inline {
    Catcher* c = (Catcher*)act.cat;
    if (c == null) return;
    do {
        Catcher* parent = c.parent;
        vm.heap.decref_tval(&c.thrown_val);
        vm.heap.free_func(vm.heap.heap_udata, c);
        c = parent;
    } while (c != null);
    act.cat = null;
}

/// Decrement the reference count of every register in the given activation.
/// Must be called BEFORE the activation is popped, while the register range
/// is still valid.  Safe to call on activations with null func (no registers).
/// Fast-path: if max_heap_reg == 0, no register ever held a heap ref — skip.
fn void decref_callee_regs(Vm* vm, Activation* callee_act) {
    if (callee_act.func == null) return;
    if (callee_act.max_heap_reg == 0) return;  // fast path: no heap refs
    CompiledFunction* callee_func = (CompiledFunction*)callee_act.func;
    uint nregs = callee_func.num_regs;
    if (nregs == 0) return;  // no registers to decref
    TVal* regs = callee_act.bottom;
    uint limit = callee_act.max_heap_reg;
    if (limit >= nregs) limit = nregs - 1;
    for (uint i = 0; i <= limit; i++) {
        // Clear the slot after releasing the ref: callee frames overlap the
        // caller's register window (sliding-window calls), and the caller's
        // own decref_callee_regs would otherwise decref the stale bits a
        // second time, underflowing the refcount.
        vm.heap.decref_tval(&regs[i]);
        regs[i].set_undefined();
    }
}

/// val: the return value (or undefined for RETUNDEF)
/// @inline: critical hot-path, called on every RET instruction.
/// Zero-initialize a range of registers to undefined.  For the small ranges
/// typical of function prologues, an inline scalar-store loop beats a bulk
/// memset call overhead.  A pointer-increment loop (rather than an index loop)
/// is deliberate: at -O2 LLVM's loop-idiom-recognition pass re-derives a
/// `memset_pattern16` libc call from the index form when this helper is inlined
/// at the call sites, re-introducing exactly the call overhead we mean to
/// avoid — measured ~9% of fib(32) samples.  The pointer form is not lowered to
/// memset. Verify with `objdump` after any change here (the lowering decision is
/// sensitive to the surrounding inlined context, not just this loop's shape).
fn void zero_regs_undefined(TVal* regs, uint start, uint end) @inline {
    TVal* p = regs + start;
    TVal* stop = regs + end;
    while (p < stop) {
        p.set_undefined();
        p++;
    }
}

fn TVal handle_return(Vm* vm, TVal val) @inline {
    if (vm.activation_count == 0) {
        vm.heap.tval_copy_ref(&vm.return_val, &val);
        return val;
    }

    Activation* callee_act = curr_act(vm);
    TVal* callee_result = callee_act.retval;

    // Free catchers a return-from-try left on the chain (frame is popping).
    free_catcher_chain(vm, callee_act);
    // Decrement references for all callee registers before popping
    decref_callee_regs(vm, callee_act);

    // Pop activation
    vm.activation_count--;

    // If we just popped the last activation, there is no caller
    if (vm.activation_count == 0) {
        vm.heap.tval_copy_ref(&vm.return_val, &val);
        // Release the this_binding reference after the return value is saved.
        if ((callee_act.flags & ACT_FLAG_THIS_OWNED) != 0) {
            vm.heap.decref_tval(&callee_act.this_binding);
        }
        return val;
    }

    Activation* caller_act = curr_act(vm);
    assert(caller_act != null);

    // Restore valstack_bottom to caller's
    vm.valstack_bottom = caller_act.bottom;

    // Write result to caller's frame at the saved retval
    if (callee_result != null && callee_result >= vm.valstack && callee_result < vm.valstack_end) {
        // For construct calls: if return value is not an object, use this_binding.
        // (The inline RET path in vm_execute.c3 already converts derived-ctor
        // non-object non-undefined returns into throws before reaching here.
        // This handle_return path is only reached from vm_call_fn_impl, which
        // handles its own derived-ctor check via ACT_FLAG_DERIVED.)
        TVal final_val = val;
        if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
            if (!final_val.is_object() || final_val.get_heapptr() == null) {
                // Return the instance (this) instead of the constructor's return value
                if (callee_act.this_binding.is_object() && callee_act.this_binding.get_heapptr() != null) {
                    final_val = callee_act.this_binding;
                }
            }
        }
        TVal* result_slot = callee_result;
        if ((callee_act.flags & ACT_FLAG_BORROWED_CALLEE) != 0) {
            // Borrowed callee: the old value in result_slot is the non-owned
            // borrowed closure — incref the result and raw-overwrite, never
            // decref the borrowed value.
            if (final_val.is_heap_allocated() && final_val.get_heapptr() != null) {
                ((HeapHeader*)final_val.get_heapptr()).incref();
            }
            *result_slot = final_val;
        } else {
            vm.heap.tval_copy_ref(result_slot, &final_val);
        }
        // A heap result (e.g. a large non-interned string) now lives in a
        // caller register the caller may never have tracked. Raise the
        // caller's max_heap_reg so its decref_callee_regs sweep releases the
        // reference instead of leaking it.
        if (result_slot >= caller_act.bottom && result_slot.is_heap_allocated()) {
            track_heap_store(caller_act, result_slot, (uint)(result_slot - caller_act.bottom));
        }
    }

    // Release the this_binding reference AFTER the result has been written
    // (construct returns may read this_binding to produce the result value).
    // ACT_FLAG_THIS_OWNED is set by paths that incref this_binding (inline CALL,
    // getter invocation) and NOT set by vm_call_fn_impl (raw assign + restore).
    if ((callee_act.flags & ACT_FLAG_THIS_OWNED) != 0) {
        vm.heap.decref_tval(&callee_act.this_binding);
    }

    // Restore valstack_top to match caller's nregs
    if (caller_act.func != null) {
        CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;
        vm.valstack_top = caller_act.bottom + caller_func.num_regs;
    }

    return val;
}


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

/// Mark all env bindings held by live activation records.
/// Called from heap's mark_roots to keep per-call var_envs alive during GC.
/// Also marks saved activations stored in vm_call_fn_impl's shadow frame list
/// so that outer call frames remain alive during nested Vm.run() execution.
fn void vm_mark_activations(void* vm_ptr, void* heap_ptr) {
    Vm* vm = (Vm*)vm_ptr;
    heap::Heap* h = (heap::Heap*)heap_ptr;

    // Mark live activations (inner-most vm_call_fn_impl's callback + inline callees)
    for (uint i = 0; i < vm.activation_count; i++) {
        mark_activation_envs(h, &vm.activations[i]);
    }

    // Mark saved outer activations from all vm_call_fn_impl frames on the C stack.
    // These are stored in C-stack ShadowActFrame structs linked via vm.shadow_act_list.
    ShadowActFrame* shadow = (ShadowActFrame*)vm.shadow_act_list;
    while (shadow != null) {
        for (uint i = 0; i < shadow.count; i++) {
            mark_activation_envs(h, &shadow.acts[i]);
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
    if (target.has_direct_eval()) {
        new_act.flags |= ACT_FLAG_DIRECT_EVAL;
    }
    vm.heap.tval_copy_ref(&new_act.this_binding, this_val);
    new_act.flags |= ACT_FLAG_THIS_OWNED;

    // Clear registers and copy args (getters have 0 args)
    TVal* new_regs = new_act.bottom;
    uint new_nregs = target.num_regs;
    mem::clear(new_regs, (sz)((usz)new_nregs * TVal::size));

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
        vm.heap.tval_copy_ref(result_slot, &final_val);
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


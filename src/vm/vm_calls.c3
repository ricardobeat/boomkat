module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;
import libc;
import duktape::re_bindings;
import std::math;

// ============================================================================
// vm_calls — function/object/generator call dispatch
// ============================================================================
/// Sub-dispatch for CALL, CALL_S, CALL_PROP, SETPROTO, SUPER_CALL, SUPER_CALL_S, NEWTARGET, NEW_OBJ, NEW_OBJ_S, TAILCALL opcodes.
fn TVal? dispatch_calls(Dispatch* ds, Opcode op, TVal* ra, TVal* rb, TVal* rc, Instruction insn) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.CALL:
        case Opcode.CALL_S: {
            // Safe point: run deferred GC before entering callee
            if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); }
            // Compiler convention: A=result_reg, B=callee_reg, C=nargs (or nargs_reg for CALL_S)
            uint result_reg = insn.a;
            uint callee_reg = insn.b;
            uint nargs;
            if (op == Opcode.CALL_S) {
                // Read nargs from the register at index C
                TVal* nargs_slot = ds.regs_base + insn.c;
                if (nargs_slot.is_fastint()) {
                    nargs = (uint)nargs_slot.get_fastint();
                } else if (nargs_slot.is_number()) {
                    nargs = (uint)nargs_slot.get_number();
                } else {
                    nargs = 0;
                }
            } else {
                nargs = insn.c;
            }

            TVal* func_slot = ds.regs_base + callee_reg;
            TVal func_val = *func_slot;

            // === Fast path: direct compiled HObject call (most common) ===
            if (func_val.is_object()) {
                HObject* hobj_fast = (HObject*)func_val.get_heapptr();
                if (hobj_fast != null && hobj_fast.is_callable() && hobj_fast.callable_kind() == hobject::CallableKind.COMPILED_FN) {
                    CompiledFunction* target_fast = (*hobj_fast.extra_ptr()).func.comp_func;
                    if (target_fast == null) { ds.regs_base[result_reg].set_undefined(); break; }
                    if (!target_fast.is_generator()) {

                    // Async function: create Promise before entering body
                    HObject* async_prom = null;
                    if (target_fast.is_async()) {
                        HObject*? prom_raw = builtins::promise_create(vm.heap);
                        if (try p = prom_raw) {
                            async_prom = p;
                        } else {
                            ds.regs_base[result_reg].set_undefined();
                            return (TVal){};
                        }
                    }

                    // New callee frame starts right after func and this in the caller frame
                    uint frame_start = callee_reg + 2;
                    TVal* new_bottom = ds.regs_base + frame_start;
                    uint needed = (uint)(new_bottom - vm.valstack) + target_fast.num_regs;

                    if (!ensure_valstack(vm, needed)) {
                        ds.regs_base[result_reg].set_undefined();
                        return (TVal){};
                    }

                    ds.regs_base = ds.act.bottom;
                    // Recompute new_bottom after realloc (ds.act.bottom may have moved)
                    new_bottom = ds.regs_base + frame_start;

                    if (vm.activation_count >= MAX_CALLS) {
                        {
                            HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = vm.heap.range_err_proto;
                                HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                HString* msg_val = intern_string(vm, "Maximum call stack size exceeded");
                                TVal msg_tv; msg_tv.set_string(msg_val);
                                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                                TVal err_val; err_val.set_object(err);
                                if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    return vm_uncaught_error(vm, &err_val);
                                }
                            } else {
                                return VM_ERROR~;
                            }
                        }
                        return (TVal){};
                    }

                    // Save the 'this' value before clearing the slot, so that GC
                    // during env creation doesn't follow a stale object pointer
                    // from a previous call in the sliding-window model.
                    TVal saved_this = ds.regs_base[callee_reg + 1];
                    ds.regs_base[callee_reg + 1].set_undefined();

                    Activation* new_act = &vm.activations[vm.activation_count];

                    EnvRecord* fast_var_env;
                    // Arrow functions inherit their enclosing lexical environment —
                    // they don't get a fresh function scope, and they don't have a
                    // var_env of their own.  Use the captured lex_env directly.
                    if (target_fast.is_arrow()) {
                        EnvRecord* arrow_lex = (*hobj_fast.extra_ptr()).func.lex_env;
                        if (arrow_lex == null) {
                            ds.regs_base[result_reg].set_undefined();
                            return (TVal){};
                        }
                        fast_var_env = arrow_lex;
                    } else if (target_fast.needs_env()) {
                        // needs_env=true → the function actually accesses its scope at
                        // runtime (closures / eval / arguments / default-or-rest params /
                        // captured locals), so allocate a fresh scope object.
                        // Functions with plain parameters but needs_env=false no longer
                        // need one: the compiler elides their param/local DECLVARs (see
                        // the register-resident-locals pass in context.c3), so their
                        // bindings live purely in registers and cannot clobber the
                        // parent env. They reuse func.var_env (the parent) directly,
                        // skipping the per-call scope HObject allocation entirely.
                        fast_var_env = (*hobj_fast.extra_ptr()).func.var_env;
                        if (try fv_f = env::env_create_function_scope(vm.heap, (*hobj_fast.extra_ptr()).func.var_env)) { fast_var_env = fv_f; }
                    } else {
                        fast_var_env = (*hobj_fast.extra_ptr()).func.var_env;
                    }
                    if (fast_var_env == null) {
                        ds.regs_base[result_reg].set_undefined();
                        return (TVal){};
                    }
                    new_act.parent = ds.act;
                    new_act.func = target_fast;
                    new_act.var_env = fast_var_env;
                    // Named function expressions get a fresh declarative lex_env
                    // with the function name bound immutably (ES2015 §14.1.20).
                    // This takes precedence over the lex_bridge for default
                    // thunks: the name binding must live in the function's own
                    // immediate lex scope (not on the captured bridge).
                    if (target_fast.is_namebinding()) {
                        char[] name_data = target_fast.get_name();
                        HString* name_hstr = intern_string(vm, name_data);
                        if (name_hstr != null) {
                            if (try name_lex2 = setup_named_function_expr_env(vm, fast_var_env, name_hstr, hobj_fast)) {
                                new_act.lex_env = name_lex2;
                            } else {
                                new_act.lex_env = fast_var_env;
                            }
                        } else {
                            new_act.lex_env = fast_var_env;
                        }
                    } else {
                        // Use the captured lex_env so block-scoped let/const
                        // bindings from the enclosing function body are visible.
                        // Only when the captured env is a *declarative* (block) scope
                        // — i.e., created by PUSH_LEX inside the function body —
                        // not when it's the function-scope env or the global env
                        // (which are object/object-like envs, not lexical block scopes).
                        EnvRecord* cap_lex_noname = (*hobj_fast.extra_ptr()).func.lex_env;
                        if (cap_lex_noname != null
                            && cap_lex_noname != fast_var_env
                            && cap_lex_noname.is_declarative) {
                            new_act.lex_env = cap_lex_noname;
                        } else {
                            new_act.lex_env = fast_var_env;
                        }
                    }
                    // Bridge captured lex scope for default thunks that need
                    // to see TDZ sentinels in the parent's param scope.
                    if (target_fast.needs_lex_bridge()) {
                        EnvRecord* cap_lex = (*hobj_fast.extra_ptr()).func.lex_env;
                        if (cap_lex != null && cap_lex != fast_var_env) {
                            EnvRecord*? bridge = env::env_create_declarative(vm.heap, cap_lex);
                            if (try b = bridge) {
                                new_act.lex_env = b;
                            }
                        }
                    }
                    new_act.cat = null;
                    new_act.curr_pc = target_fast.code;
                    new_act.bottom = new_bottom;
                    new_act.retval = ds.regs_base + result_reg;
                    new_act.flags = 0;
                    if (target_fast.has_direct_eval()) {
                        new_act.flags |= ACT_FLAG_DIRECT_EVAL;
                    }
                    new_act.async_promise = null;
                    if (async_prom != null) {
                        new_act.flags |= ACT_FLAG_ASYNC;
                        new_act.async_promise = async_prom;
                    }
                    new_act.max_heap_reg = 0;
                    new_act.caller_valstack_top = vm.valstack_top;
                    // Arrow functions use lexical this (inherited from enclosing scope)
                    // Fast path: skip refcounting when this value is not a heap ref
                    {
                        TVal* this_src = target_fast.is_arrow() ? &ds.act.this_binding : &saved_this;
                        if (!this_src.is_heap_allocated()) {
                            if (new_act.this_binding.is_heap_allocated()) {
                                vm.heap.decref_tval(&new_act.this_binding);
                            }
                            new_act.this_binding = *this_src;
                        } else {
                            vm.heap.tval_copy_ref(&new_act.this_binding, this_src);
                        }
                    }

                    // Activation fully initialized — now make it visible to GC.
                    vm.activation_count++;

                    TVal* new_regs = new_act.bottom;
                    uint new_nregs = target_fast.num_regs;

                    // Create arguments object BEFORE the rest parameter handling
                    // below overwrites new_regs[0] with the rest array. (Sliding
                    // window: new_regs aliases the caller's arg slots at this point.)
                    if (target_fast.uses_arguments()) {
                        HObject*? args_obj_raw = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
                        if (try args_obj = args_obj_raw) {
                            for (uint ai = 0; ai < nargs; ai++) {
                                args_obj.set_array_idx(ai, new_regs[ai]);
                            }
                            args_obj.prototype = vm.heap.object_proto;
                            HString* callee_key = (HString*)vm.heap.strs[heap::BuiltinStr.CALLEE];
                            if (callee_key != null) {
                                TVal callee_tv;
                                callee_tv.set_object(hobj_fast);
                                args_obj.put_prop(callee_key, callee_tv, hobject::PROP_FLAGS_WC);
                            }
                            HString* length_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                            if (length_key != null) {
                                TVal length_tv;
                                length_tv.set_fastint((long)nargs);
                                args_obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);
                            }
                            HString* args_name = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
                            if (args_name != null) {
                                TVal args_tv;
                                args_tv.set_object(args_obj);
                                env::env_declare(new_act.var_env, args_name, args_tv);
                            }
                        }
                    }

                    // Copy args: in the sliding-window model new_regs == old_args
                    // Values are already in place — set missing parameter registers
                    // to undefined so default parameter checks (param !== undefined) work.
                    uint formals = (uint)target_fast.num_formals;
                    if (target_fast.has_rest()) {
                        // Build rest array from overflow args (indices formals..nargs-1)
                        uint rest_idx = formals;
                        uint overflow = (nargs > formals) ? (nargs - formals) : 0;
                        HObject*? rest_arr_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                        if (try rest_arr = rest_arr_raw) {
                            rest_arr.prototype = vm.heap.array_proto;
                            for (uint ri = 0; ri < overflow; ri++) {
                                HString* rkey = vm.heap.int_to_hstring((long)ri);
                                if (rkey != null) {
                                    rest_arr.put_prop(rkey, new_regs[rest_idx + ri], hobject::PROP_FLAGS_WEC);
                                }
                            }
                            HString* len_str = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                            TVal len_val;
                            len_val.set_fastint((long)overflow);
                            rest_arr.put_prop(len_str, len_val, hobject::PROP_FLAGS_WEC);
                            new_regs[rest_idx].set_object(rest_arr);
                        } else {
                            new_regs[rest_idx].set_undefined();
                        }
                        // Set missing formals (after rest) to undefined
                        if (nargs < formals) {
                            for (uint i = nargs; i < formals; i++) {
                                new_regs[i].set_undefined();
                            }
                        }
                        // Zero remaining registers (temps after rest)
                        uint zero_start = rest_idx + 1;
                        if (zero_start < new_nregs) {
                            zero_regs_undefined(new_regs, zero_start, new_nregs);
                        }
                    } else {
                        uint undef_limit = formals < new_nregs ? formals : new_nregs;
                        if (nargs < undef_limit) {
                            zero_regs_undefined(new_regs, nargs, undef_limit);
                        }
                        // Zero remaining registers (temps), but skip past any
                        // actual arguments already in the sliding-window slots.
                        uint zero_start = undef_limit > nargs ? undef_limit : nargs;
                        if (zero_start < new_nregs) {
                            zero_regs_undefined(new_regs, zero_start, new_nregs);
                        }
                    }

                    vm.valstack_top = new_regs + new_nregs;
                    vm.valstack_bottom = new_act.bottom;

                    // Save caller resume point before switching activations
                    ds.act.curr_pc = ds.curr_pc;

                    // Direct dispatch to new activation (avoid restart overhead)
                    ds.act = new_act;
                    vm.current_func = target_fast;
                    ds.code_base = target_fast.code;
                    ds.code_count = target_fast.code_count;
                    ds.code_end = ds.code_base + ds.code_count;
                    ds.ic_base = (hobject::ICEntry*)target_fast.ic_entries;
                    ds.var_ic_base = (hobject::VarICEntry*)target_fast.var_ic_entries;
                    ds.constants = target_fast.constants;
                    ds.nregs = target_fast.num_regs;
                    ds.curr_pc = ds.act.curr_pc;
                    ds.regs_base = ds.act.bottom;
                    return (TVal){};
                    }
                }
            }

            if (func_val.is_lightfunc()) {
                uint fn_idx = (uint)(usz)func_val.get_heapptr();

                builtins::BuiltinContext ctx;
                ctx.vm = vm;
                ctx.regs = vm.valstack;
                ctx.base_reg = (ushort)((ds.act.bottom - vm.valstack) + callee_reg + 2);
                ctx.argc = (ushort)nargs;
                ctx.result = ds.regs_base + result_reg;
                ctx.heap = vm.heap;
                ctx.this_val = ds.regs_base[callee_reg + 1];
                ctx.is_constructor = false;
                ctx.needs_re_dispatch = false;
                ctx.re_nargs = 0;
                ctx.global_env = vm.global_env;
                ctx.should_throw = false;
                ctx.callee_obj = null;

                builtins::dispatch_builtin(fn_idx, &ctx);

                if (ctx.should_throw) {
                    if (!vm_throw_value(vm, ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &ctx.throw_value);
                    }
                    return (TVal){};
                }

                if (ctx.needs_re_dispatch) {
                    // Builtin (.call/.apply/bound) modified the stack — re-dispatch
                    func_val = ds.regs_base[callee_reg];
                    nargs = ctx.re_nargs;
                    // Fall through to OBJECT handling
                } else {
                    return (TVal){};
                }
            }

            if (!func_val.is_object()) {
                // TypeError: value is not a function
                HString* type_str = typeof_string(vm, &func_val);
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a function",
                                             type_str.get_cstr());
                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val;
                    err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &err_val);
                    }
                } else {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            // === OBJECT CALL HANDLING ===
            HObject* hobj = (HObject*)func_val.get_heapptr();
            if (hobj == null || !hobj.is_callable()) {
                // TypeError: object is not callable (e.g., a non-function object)
                HString* type_str = typeof_string(vm, &func_val);
                HObject*? err_raw2 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err2 = err_raw2) {
                    err2.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a function",
                                             type_str.get_cstr());
                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err2.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val2;
                    err_val2.set_object(err2);
                    if (!vm_throw_value(vm, err_val2, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &err_val2);
                    }
                } else {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            // Handle bound function objects — dispatch to builtin_bound_call
            if (hobj.callable_kind() == hobject::CallableKind.BOUND_FN) {
                if ((*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((ds.act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = ds.regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = ds.regs_base[callee_reg + 1];
                    ctx.is_constructor = false;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    ctx.callee_obj = hobj;
                    builtins::dispatch_builtin(fn_idx, &ctx);

                    if (ctx.should_throw) {
                        if (!vm_throw_value(vm, ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return vm_uncaught_error(vm, &ctx.throw_value);
                        }
                        return (TVal){};
                    }

                    if (ctx.needs_re_dispatch) {
                        func_val = ds.regs_base[callee_reg];
                        nargs = ctx.re_nargs;
                        // Safety: re-dispatch may produce a lightfunc (e.g., bound eval)
                        if (func_val.is_lightfunc()) {
                            uint lf_idx = (uint)(usz)func_val.get_heapptr();
                            builtins::BuiltinContext inner;
                            inner.vm = vm;
                            inner.regs = vm.valstack;
                            inner.base_reg = (ushort)((ds.act.bottom - vm.valstack) + callee_reg + 2);
                            inner.argc = (ushort)nargs;
                            inner.result = ds.regs_base + result_reg;
                            inner.heap = vm.heap;
                            inner.this_val = ds.regs_base[callee_reg + 1];
                            inner.is_constructor = false;
                            inner.needs_re_dispatch = false;
                            inner.re_nargs = 0;
                            inner.global_env = vm.global_env;
                            inner.should_throw = false;
                            inner.callee_obj = null;
                            builtins::dispatch_builtin(lf_idx, &inner);
                            if (inner.should_throw) {
                                if (!vm_throw_value(vm, inner.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    return vm_uncaught_error(vm, &inner.throw_value);
                                }
                            }
                            return (TVal){};
                        }
                        if (func_val.is_object()) {
                            hobj = (HObject*)func_val.get_heapptr();
                            // Fall through to compiled function handling below
                        } else {
                            return (TVal){};
                        }
                    } else {
                        return (TVal){};
                    }
                } else {
                    return (TVal){};
                }
            } else if (hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN) {
                if ((*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((ds.act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = ds.regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = ds.regs_base[callee_reg + 1];
                    ctx.is_constructor = false;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    ctx.callee_obj = hobj;
                    builtins::dispatch_builtin(fn_idx, &ctx);

                    if (ctx.should_throw) {
                        if (!vm_throw_value(vm, ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return vm_uncaught_error(vm, &ctx.throw_value);
                        }
                        return (TVal){};
                    }

                    if (ctx.needs_re_dispatch) {
                        // Re-dispatch: re-read target from stack
                        func_val = ds.regs_base[callee_reg];
                        nargs = ctx.re_nargs;
                        // Safety: check for lightfunc before casting to HObject*
                        if (func_val.is_lightfunc()) {
                            uint lf_idx = (uint)(usz)func_val.get_heapptr();
                            builtins::BuiltinContext inner;
                            inner.vm = vm;
                            inner.regs = vm.valstack;
                            inner.base_reg = (ushort)((ds.act.bottom - vm.valstack) + callee_reg + 2);
                            inner.argc = (ushort)nargs;
                            inner.result = ds.regs_base + result_reg;
                            inner.heap = vm.heap;
                            inner.this_val = ds.regs_base[callee_reg + 1];
                            inner.is_constructor = false;
                            inner.needs_re_dispatch = false;
                            inner.re_nargs = 0;
                            inner.global_env = vm.global_env;
                            inner.should_throw = false;
                            inner.callee_obj = null;
                            builtins::dispatch_builtin(lf_idx, &inner);
                            if (inner.should_throw) {
                                if (!vm_throw_value(vm, inner.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    return vm_uncaught_error(vm, &inner.throw_value);
                                }
                            }
                            return (TVal){};
                        }
                        if (func_val.is_object()) {
                            hobj = (HObject*)func_val.get_heapptr();
                            if ((*hobj.extra_ptr()).func.comp_func != null) {
                                // Continue to compiled function handling below (skip error)
                            } else {
                                return (TVal){};
                            }
                        } else {
                            return (TVal){};
                        }
                    } else {
                        return (TVal){};
                    }
                } else {
                    // Callable object with no compiled function and no builtin index: error
                    HString* type_str = typeof_string(vm, &func_val);
                    HObject*? err_raw2 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err2 = err_raw2) {
                        err2.prototype = vm.heap.type_err_proto;
                        char[types::ERROR_MSG_BUF] buf;
                        int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a function",
                                                 type_str.get_cstr());
                        if (len > 0 && len < types::ERROR_MSG_BUF) {
                            HString* msg_str = intern_string(vm, buf[:len]);
                            TVal msg_val;
                            msg_val.set_string(msg_str);
                            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                            err2.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                        }
                        TVal err_val2;
                        err_val2.set_object(err2);
                        if (!vm_throw_value(vm, err_val2, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return vm_uncaught_error(vm, &err_val2);
                        }
                    } else {
                        return VM_ERROR~;
                    }
                    return (TVal){};
                }
            }

            CompiledFunction* target = null;
            // Safety: hobj may not have a comp_func (e.g., after bound function re-dispatch).
            // Only dereference if hobj is a compiled-function HObject.
            if (hobj != null && (*hobj.extra_ptr()).func.comp_func != null) {
                target = (*hobj.extra_ptr()).func.comp_func;
            } else {
                // Not a compiled function — result should already be set by the handler
                ds.regs_base[result_reg].set_undefined();
                return (TVal){};
            }

            // === Generator function handling (ES6 §25.3) ===
            HObject* async_prom = null;
            if (target.is_generator()) {
                // Resume path: .next()/.throw()/.return() set heap.resume_gen
                if (vm.heap.resume_gen != null && (CompiledFunction*)vm.heap.resume_gen.func == target) {
                    GeneratorState* gs = vm.heap.resume_gen;

                    if (gs.state == GEN_COMPLETED) {
                        vm.heap.resume_gen = null;
                        ds.regs_base[result_reg].set_undefined();
                        return (TVal){};
                    }

                    // .throw() on SUSPENDED_START: exception before any body code
                    // (ES6 §25.3.3.4 step 8: resume with abrupt throw completion)
                    if (gs.state == GEN_SUSPENDED_START && gs.resume_kind == THROW) {
                        gs.state = GEN_COMPLETED;
                        vm.heap.resume_gen = null;
                        // Propagate exception to the .throw() caller
                        if (!vm_throw_value(vm, gs.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            vm.has_error = true;
                            vm.heap.has_error = true;
                            if (ds.act.retval != null) {
                                vm.heap.tval_copy_ref(ds.act.retval, &gs.throw_value);
                            }
                        }
                        ds.needs_restart = true;
                        return (TVal){};
                    }

                    // Set state to EXECUTING
                    gs.state = GEN_EXECUTING;

                    // Calculate register layout
                    uint frame_start_r = callee_reg + 2;
                    TVal* new_bottom_r = ds.regs_base + frame_start_r;
                    uint needed_r = (uint)(new_bottom_r - vm.valstack) + target.num_regs;

                    if (!ensure_valstack(vm, needed_r)) {
                        gs.state = GEN_SUSPENDED_YIELD;
                        ds.regs_base[result_reg].set_undefined();
                        return (TVal){};
                    }

                    ds.regs_base = ds.act.bottom;
                    // Recompute new_bottom after realloc (ds.act.bottom may have moved)
                    new_bottom_r = ds.regs_base + frame_start_r;

                    if (vm.activation_count >= MAX_CALLS) {
                        gs.state = GEN_SUSPENDED_YIELD;
                        {
                            HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = vm.heap.range_err_proto;
                                HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                HString* msg_val = intern_string(vm, "Maximum call stack size exceeded");
                                TVal msg_tv; msg_tv.set_string(msg_val);
                                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                                TVal err_val; err_val.set_object(err);
                                if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    return vm_uncaught_error(vm, &err_val);
                                }
                            } else {
                                return VM_ERROR~;
                            }
                        }
                        return (TVal){};
                    }

                    // Push activation
                    Activation* new_act_r = &vm.activations[vm.activation_count];
                    vm.activation_count++;
                    new_act_r.max_heap_reg = 0;
                    new_act_r.caller_valstack_top = vm.valstack_top;

                    new_act_r.parent = ds.act;
                    new_act_r.func = target;
                    new_act_r.var_env = gs.var_env;
                    new_act_r.lex_env = gs.lex_env;
                    new_act_r.cat = gs.cat;
                    new_act_r.curr_pc = gs.saved_pc;
                    new_act_r.bottom = new_bottom_r;
                    new_act_r.retval = ds.regs_base + result_reg;
                    new_act_r.flags = ACT_FLAG_PREVENT_YIELD
                                    | (target.has_direct_eval() ? ACT_FLAG_DIRECT_EVAL : 0);
                    vm.heap.tval_copy_ref(&new_act_r.this_binding, &gs.this_binding);

                    // Copy saved registers to valstack
                    $if $feature(HEAP_VERIFY):
                        vm.heap.verify_roots("before_call_resume_restore");
                        vm.heap.verify_tval_array(gs.saved_regs, gs.num_regs, "call_resume_saved_regs");
                    $endif
                    TVal* new_regs_r = new_act_r.bottom;
                    uint new_nregs_r = target.num_regs;
                    for (uint i = 0; i < new_nregs_r; i++) {
                        vm.heap.tval_copy_ref(&new_regs_r[i], &gs.saved_regs[i]);
                    }
                    $if $feature(HEAP_VERIFY):
                        vm.heap.verify_roots("after_call_resume_restore");
                    $endif

                    vm.valstack_top = new_regs_r + new_nregs_r;
                    vm.valstack_bottom = new_act_r.bottom;

                    // Save caller resume point before switching activation
                    ds.act.curr_pc = ds.curr_pc;

                    ds.needs_restart = true;
                    return (TVal){};
                }

                // Async initial call: create Promise, fall through to non-generator path
                if (target.is_async()) {
                    HObject*? prom_raw = builtins::promise_create(vm.heap);
                    if (try p = prom_raw) {
                        async_prom = p;
                    } else {
                        ds.regs_base[result_reg].set_undefined();
                        return (TVal){};
                    }
                    // Don't break — fall through to non-generator path below
                } else {
                // Initial call: create generator object, don't execute body
                // Calculate register layout
                uint frame_start = callee_reg + 2;
                TVal* new_bottom = ds.regs_base + frame_start;
                uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

                if (!ensure_valstack(vm, needed)) {
                    ds.regs_base[result_reg].set_undefined();
                    return (TVal){};
                }

                ds.regs_base = ds.act.bottom;
                // Recompute new_bottom after realloc (ds.act.bottom may have moved)
                new_bottom = ds.regs_base + frame_start;

                // Allocate GeneratorState
                void* gs_raw = vm.heap.alloc_func(vm.heap.heap_udata, GeneratorState::size);
                if (gs_raw == null) {
                    ds.regs_base[result_reg].set_undefined();
                    return (TVal){};
                }
                GeneratorState* gs = (GeneratorState*)gs_raw;
                libc::memset(gs_raw, 0, GeneratorState::size);

                gs.state = GEN_SUSPENDED_START;
                gs.func = target;
                gs.num_regs = target.num_regs;
                gs.saved_pc = target.code;
                gs.var_env = (*hobj.extra_ptr()).func.var_env;
                gs.lex_env = (*hobj.extra_ptr()).func.lex_env;
                vm.heap.tval_copy_ref(&gs.this_binding, &ds.regs_base[callee_reg + 1]);

                // Allocate and copy saved registers
                usz regs_bytes = (usz)target.num_regs * TVal::size;
                void* regs_raw;
                if (regs_bytes > 0) {
                    regs_raw = vm.heap.alloc_func(vm.heap.heap_udata, regs_bytes);
                    if (regs_raw == null) {
                        vm.heap.free_func(vm.heap.heap_udata, gs_raw);
                        ds.regs_base[result_reg].set_undefined();
                        return (TVal){};
                    }
                    libc::memset(regs_raw, 0, regs_bytes);
                } else {
                    regs_raw = null;
                }
                gs.saved_regs = (TVal*)regs_raw;

                // Initialize registers with args (rest = undefined for extra slots)
                TVal* base = new_bottom;
                TVal* old_args = ds.regs_base + callee_reg + 2;
                uint copy_count = target.has_rest() ? (uint)target.num_formals : nargs;
                if (copy_count > target.num_regs) copy_count = target.num_regs;
                for (uint i = 0; i < copy_count; i++) {
                    vm.heap.tval_copy_ref(&base[i], &old_args[i]);
                }
                for (uint i = 0; i < copy_count && target.num_regs > 0; i++) {
                    vm.heap.tval_copy_ref(&gs.saved_regs[i], &old_args[i]);
                }
                for (uint i = copy_count; i < target.num_regs; i++) {
                    base[i].set_undefined();
                }
                for (uint i = copy_count; i < target.num_regs; i++) {
                    if (gs.saved_regs != null) {
                        gs.saved_regs[i].set_undefined();
                    }
                }

                // Handle rest parameter: build rest array and store in saved_regs
                if (target.has_rest() && nargs > (uint)target.num_formals) {
                    uint rest_idx = (uint)target.num_formals;
                    uint overflow = nargs - (uint)target.num_formals;

                    HObject*? arr_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                    if (try a = arr_raw) {
                        a.prototype = vm.heap.array_proto;
                        for (uint i = 0; i < overflow; i++) {
                            HString* key = vm.heap.int_to_hstring((long)i);
                            if (key != null) {
                                a.put_prop(key, old_args[(uint)target.num_formals + i], hobject::PROP_FLAGS_WEC);
                            }
                        }
                        HString* len_str = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                        TVal len_val;
                        len_val.set_fastint((long)overflow);
                        a.put_prop(len_str, len_val, hobject::PROP_FLAGS_WEC);

                        base[rest_idx].set_object(a);
                        gs.saved_regs[rest_idx].set_object(a);
                    }
                }

                // Create Generator HObject
                HObject*? gen_obj_raw = vm.heap.alloc_object(hobject::ObjClass.GENERATOR);
                HObject* gen_obj;
                if (try go = gen_obj_raw) {
                    gen_obj = go;
                } else {
                    vm.heap.free_func(vm.heap.heap_udata, gs.saved_regs);
                    vm.heap.free_func(vm.heap.heap_udata, gs_raw);
                    ds.regs_base[result_reg].set_undefined();
                    return (TVal){};
                }
                gen_obj.prototype = vm.heap.generator_proto;
                (*gen_obj.extra_ptr()).gen.generator_data = gs;

                // Return generator object as the call result
                TVal* result_slot = ds.regs_base + result_reg;
                result_slot.set_object(gen_obj);
                return (TVal){};
                } // end else (non-async generator initial call)
            }

            // New callee frame starts right after func and this in the caller frame
            // Layout: callee_reg = func, callee_reg+1 = this, callee_reg+2.. callee_reg+1+nargs = args
            uint frame_start = callee_reg + 2;
            TVal* new_bottom = ds.regs_base + frame_start;
            uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

            if (!ensure_valstack(vm, needed)) {
                ds.regs_base[result_reg].set_undefined();
                return (TVal){};
            }

            ds.regs_base = ds.act.bottom;
            // Recompute new_bottom after realloc (ds.act.bottom may have moved)
            new_bottom = ds.regs_base + frame_start;

            if (vm.activation_count >= MAX_CALLS) {
                {
                    HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        err.prototype = vm.heap.range_err_proto;
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        HString* msg_val = intern_string(vm, "Maximum call stack size exceeded");
                        TVal msg_tv; msg_tv.set_string(msg_val);
                        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                        TVal err_val; err_val.set_object(err);
                        if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return vm_uncaught_error(vm, &err_val);
                        }
                    } else {
                        return VM_ERROR~;
                    }
                }
                return (TVal){};
            }

            Activation* new_act = &vm.activations[vm.activation_count];
            vm.activation_count++;
            new_act.max_heap_reg = 0;
            new_act.caller_valstack_top = vm.valstack_top;

            EnvRecord* call_var_env2 = (*hobj.extra_ptr()).func.var_env;
            // Only allocate a fresh scope when the function actually uses its env
            // (see the fast-call path above and the register-resident-locals pass).
            if (target.needs_env()) {
                if (try fv_c2 = env::env_create_function_scope(vm.heap, (*hobj.extra_ptr()).func.var_env)) { call_var_env2 = fv_c2; }
            }
            new_act.parent = ds.act;
            new_act.func = target;
            new_act.var_env = call_var_env2;
            new_act.lex_env = call_var_env2;
            new_act.cat = null;
            new_act.curr_pc = target.code;
            new_act.bottom = new_bottom;
            new_act.retval = ds.regs_base + result_reg;
            new_act.flags = 0;
            if (target.has_direct_eval()) {
                new_act.flags |= ACT_FLAG_DIRECT_EVAL;
            }
            new_act.async_promise = null;
            new_act.async_gen_state = null;
            if (async_prom != null) {
                // Async function entered from the generator block above
                new_act.flags |= ACT_FLAG_ASYNC;
                new_act.async_promise = async_prom;
                // Write Promise to result register now so the caller gets it
                // if the function suspends at an AWAIT before returning.
                ds.regs_base[result_reg].set_object(async_prom);
            } else if (target.is_async()) {
                // Async function from the fast path or other path
                HObject*? prom_raw = builtins::promise_create(vm.heap);
                if (try p = prom_raw) {
                    new_act.flags |= ACT_FLAG_ASYNC;
                    new_act.async_promise = p;
                }
            }
            // Arrow functions use lexical this (inherited from enclosing scope).
            // Strict-only engine: non-arrow functions always use raw `this` (no
            // sloppy-mode null/undefined→global or primitive→ToObject coercion).
            if (target.is_arrow()) {
                vm.heap.tval_copy_ref(&new_act.this_binding, &ds.act.this_binding);
            } else {
                TVal raw_this = ds.regs_base[callee_reg + 1];
                vm.heap.tval_copy_ref(&new_act.this_binding, &raw_this);
            }

            TVal* new_regs = new_act.bottom;
            uint new_nregs = target.num_regs;

            // Copy args
            TVal* old_args = ds.regs_base + callee_reg + 2;
            if (target.has_rest()) {
                // Only copy the formal parameters (not the rest parameter)
                uint copy_count = (uint)target.num_formals;
                for (uint i = 0; i < nargs && i < copy_count; i++) {
                    vm.heap.tval_copy_ref(&new_regs[i], &old_args[i]);
                }

                // Set missing formals to undefined (for default param checks)
                for (uint i = nargs; i < copy_count; i++) {
                    new_regs[i].set_undefined();
                }

                // Build rest array from overflow args
                uint rest_idx = copy_count;
                uint overflow = (nargs > copy_count) ? (nargs - copy_count) : 0;

                HObject*? arr_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                if (try a = arr_raw) {
                    a.prototype = vm.heap.array_proto;
                    // Copy overflow args into the array
                    for (uint i = 0; i < overflow; i++) {
                        HString* key = vm.heap.int_to_hstring((long)i);
                        if (key != null) {
                            TVal elem = old_args[copy_count + i];
                            a.put_prop(key, elem, hobject::PROP_FLAGS_WEC);
                        }
                    }
                    // Set .length
                    HString* len_str = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    TVal len_val;
                    len_val.set_fastint((long)overflow);
                    a.put_prop(len_str, len_val, hobject::PROP_FLAGS_WEC);

                    new_regs[rest_idx].set_object(a);
                } else {
                    new_regs[rest_idx].set_undefined();
                }

                // Fill remaining registers with UNDEFINED (after the rest param)
                if (rest_idx + 1 < new_nregs) {
                    libc::memset(&new_regs[rest_idx + 1], 0, (usz)(new_nregs - rest_idx - 1) * TVal::size);
                }
            } else {
                // Args are already in position (new_regs == old_args, sliding window).
                // Skip self-copy when they point to the same location.
                if (new_regs != old_args) {
                    for (uint i = 0; i < nargs && i < (uint)target.num_args; i++) {
                        vm.heap.tval_copy_ref(&new_regs[i], &old_args[i]);
                    }
                }
                if (nargs < new_nregs) {
                    // Mirror the fast-path register-zeroing: only formal
                    // parameter slots that don't have a value are set to
                    // undefined, and the temp-register zeroing starts at
                    // max(formals, nargs) so the call args themselves stay
                    // in place. Without this, a bound re-dispatch where
                    // nargs > num_formals zeros the arg slots and the
                    // arguments object built from new_regs[0..nargs-1] is
                    // filled with zeros.
                    uint formals = (uint)target.num_formals;
                    uint undef_limit = formals < new_nregs ? formals : new_nregs;
                    if (nargs < undef_limit) {
                        for (uint zi = nargs; zi < undef_limit; zi++) {
                            new_regs[zi].set_undefined();
                        }
                    }
                    uint zero_start = undef_limit > nargs ? undef_limit : nargs;
                    if (zero_start < new_nregs) {
                        libc::memset(&new_regs[zero_start], 0, (usz)(new_nregs - zero_start) * TVal::size);
                    }
                }
            }

            // Create arguments object for the new activation if the target
            // function references it. This is the slow-path mirror of the
            // fast-path version above — needed when the call re-dispatched
            // through a bound function (BUILTIN_FN → bound call → compiled
            // target via the fallback generic path) and the target uses
            // `arguments`. Without this, the function sees `arguments is
            // not defined` because the arguments object was never created.
            if (target.uses_arguments()) {
                HObject*? args_obj_raw = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
                if (try args_obj = args_obj_raw) {
                    for (uint ai = 0; ai < nargs; ai++) {
                        args_obj.set_array_idx(ai, new_regs[ai]);
                    }
                    args_obj.prototype = vm.heap.object_proto;
                    HString* callee_key = (HString*)vm.heap.strs[heap::BuiltinStr.CALLEE];
                    if (callee_key != null) {
                        TVal callee_tv;
                        callee_tv.set_object(hobj);
                        args_obj.put_prop(callee_key, callee_tv, hobject::PROP_FLAGS_WC);
                    }
                    HString* length_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    if (length_key != null) {
                        TVal length_tv;
                        length_tv.set_fastint((long)nargs);
                        args_obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);
                    }
                    HString* args_name = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
                    if (args_name != null) {
                        TVal args_tv;
                        args_tv.set_object(args_obj);
                        env::env_declare(new_act.var_env, args_name, args_tv);
                    }
                }
            }

            vm.valstack_top = new_regs + new_nregs;
            vm.valstack_bottom = new_act.bottom;

            // Save caller resume point before switching activations
            ds.act.curr_pc = ds.curr_pc;

            // Direct dispatch to new activation (avoid restart overhead)
            ds.act = new_act;
            vm.current_func = target;
            ds.code_base = target.code;
            ds.code_count = target.code_count;
            ds.code_end = ds.code_base + ds.code_count;
            ds.ic_base = (hobject::ICEntry*)target.ic_entries;
            ds.var_ic_base = (hobject::VarICEntry*)target.var_ic_entries;
            ds.constants = target.constants;
            ds.nregs = target.num_regs;
            ds.curr_pc = ds.act.curr_pc;
            ds.regs_base = ds.act.bottom;
            return (TVal){};
        }

        case Opcode.CALL_PROP:
            ra.set_undefined();
            return (TVal){};

        case Opcode.SETPROTO: {
            // A.[[Prototype]] = B
            // ABC format: A=obj_reg, B=proto_reg
            if (!ra.is_object() || !rb.is_object()) {
                // Non-object operands — silently ignore or error
                return (TVal){};
            }
            HObject* obj = (HObject*)ra.get_heapptr();
            HObject* proto = (HObject*)rb.get_heapptr();
            if (obj != null && proto != null) {
                obj.prototype = proto;
            }
            return (TVal){};
        }

        case Opcode.SUPER_CALL:
        case Opcode.SUPER_CALL_S: {
            // A = super(B, args...) — call superclass constructor
            // SUPER_CALL: C = immediate arg count
            // SUPER_CALL_S: C = register holding runtime arg count
            // Uses current activation's new.target
            uint result_reg = insn.a;
            uint callee_reg = insn.b;
            uint nargs;
            if (op == Opcode.SUPER_CALL_S) {
                TVal* nargs_slot = ds.regs_base + insn.c;
                if (nargs_slot.is_fastint()) {
                    nargs = (uint)nargs_slot.get_fastint();
                } else if (nargs_slot.is_number()) {
                    nargs = (uint)nargs_slot.get_number();
                } else {
                    nargs = 0;
                }
            } else {
                nargs = insn.c;
            }

            TVal* super_slot = ds.regs_base + callee_reg;
            TVal super_val = *super_slot;

            if (!super_val.is_object()) {
                // TypeError: superclass is not a constructor
                HString* type_str = typeof_string(vm, &super_val);
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a constructor",
                                             type_str.get_cstr());
                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val;
                    err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &err_val);
                    }
                }
                return (TVal){};
            }

            HObject* super_hobj = (HObject*)super_val.get_heapptr();
            if (super_hobj == null || !super_hobj.is_callable() || !super_hobj.is_constructable()) {
                // TypeError: not a constructor
                HString* type_str = typeof_string(vm, &super_val);
                HObject*? err_raw2 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err2 = err_raw2) {
                    err2.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len2 = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a constructor",
                                              type_str.get_cstr());
                    if (len2 > 0 && len2 < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len2]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err2.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val2;
                    err_val2.set_object(err2);
                    if (!vm_throw_value(vm, err_val2, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &err_val2);
                    }
                }
                return (TVal){};
            }

            // Use new.target from the current activation (set by NEW_OBJ)
            HObject* new_target = ds.act.new_target;
            if (new_target == null) {
                // Not in a constructor — new.target is undefined
                // Fall back to simple call behavior
                // This shouldn't normally happen since super() is only valid in constructors
                ra.set_undefined();
                return (TVal){};
            }

            // Handle builtin super constructors
            if (super_hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN) {
                if ((*super_hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*super_hobj.extra_ptr()).func.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((uint)(ds.act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = ds.regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = ds.regs_base[callee_reg + 1];
                    ctx.is_constructor = true;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    ctx.callee_obj = super_hobj;
                    builtins::dispatch_builtin(fn_idx, &ctx);
                }
                return (TVal){};
            }

            CompiledFunction* super_target = (*super_hobj.extra_ptr()).func.comp_func;

            // Set up activation frame for superclass constructor
            // The 'this' slot should already have new_target (set by caller)
            uint frame_start = callee_reg + 2;
            TVal* new_bottom = ds.regs_base + frame_start;
            uint needed = (uint)(new_bottom - vm.valstack) + super_target.num_regs;

            if (!ensure_valstack(vm, needed)) {
                ra.set_undefined();
                return (TVal){};
            }

            ds.regs_base = ds.act.bottom;
            // Recompute new_bottom after realloc (ds.act.bottom may have moved)
            new_bottom = ds.regs_base + frame_start;

            if (vm.activation_count >= MAX_CALLS) {
                {
                    HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        err.prototype = vm.heap.range_err_proto;
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        HString* msg_val = intern_string(vm, "Maximum call stack size exceeded");
                        TVal msg_tv; msg_tv.set_string(msg_val);
                        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                        TVal err_val; err_val.set_object(err);
                        if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return vm_uncaught_error(vm, &err_val);
                        }
                    } else {
                        return VM_ERROR~;
                    }
                }
                return (TVal){};
            }

            Activation* new_act = &vm.activations[vm.activation_count];
            vm.activation_count++;
            new_act.max_heap_reg = 0;
            new_act.caller_valstack_top = vm.valstack_top;

            EnvRecord* super_var_env = (*super_hobj.extra_ptr()).func.var_env;
            if (try fv_su = env::env_create_function_scope(vm.heap, (*super_hobj.extra_ptr()).func.var_env)) { super_var_env = fv_su; }
            new_act.parent = ds.act;
            new_act.func = super_target;
            new_act.var_env = super_var_env;
            // Named function expressions get a fresh declarative lex_env
            // with the function name bound immutably (ES2015 §14.1.20).
            if (super_target.is_namebinding()) {
                char[] name_data = super_target.get_name();
                HString* name_hstr = intern_string(vm, name_data);
                if (name_hstr != null) {
                    if (try name_lex = setup_named_function_expr_env(vm, super_var_env, name_hstr, super_hobj)) {
                        new_act.lex_env = name_lex;
                    } else {
                        new_act.lex_env = super_var_env;
                    }
                } else {
                    new_act.lex_env = super_var_env;
                }
            } else {
                new_act.lex_env = super_var_env;
            }
            new_act.cat = null;
            new_act.curr_pc = super_target.code;
            new_act.bottom = new_bottom;
            new_act.retval = ds.regs_base + result_reg;
            new_act.flags = ACT_FLAG_CONSTRUCT
                          | (super_target.has_direct_eval() ? ACT_FLAG_DIRECT_EVAL : 0);
            vm.heap.tval_copy_ref(&new_act.this_binding, &ds.regs_base[callee_reg + 1]);
            new_act.new_target = new_target;  // Pass through new.target

            TVal* new_regs = new_act.bottom;
            uint new_nregs = super_target.num_regs;

            // Copy args
            TVal* old_args = ds.regs_base + callee_reg + 2;

            // Create arguments object BEFORE the rest parameter handling below
            // overwrites new_regs[0] with the rest array.
            if (super_target.uses_arguments()) {
                HObject*? args_obj_raw_su = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
                if (try args_obj_su = args_obj_raw_su) {
                    for (uint ai = 0; ai < nargs; ai++) {
                        args_obj_su.set_array_idx(ai, old_args[ai]);
                    }
                    args_obj_su.prototype = vm.heap.object_proto;
                    HString* callee_key_su = (HString*)vm.heap.strs[heap::BuiltinStr.CALLEE];
                    if (callee_key_su != null) {
                        TVal callee_tv_su; callee_tv_su.set_object(super_hobj);
                        args_obj_su.put_prop(callee_key_su, callee_tv_su, hobject::PROP_FLAGS_WC);
                    }
                    HString* length_key_su = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    if (length_key_su != null) {
                        TVal length_tv_su; length_tv_su.set_fastint((long)nargs);
                        args_obj_su.put_prop(length_key_su, length_tv_su, hobject::PROP_FLAGS_WC);
                    }
                    HString* args_name_su = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
                    if (args_name_su != null) {
                        TVal args_tv_su; args_tv_su.set_object(args_obj_su);
                        env::env_declare(super_var_env, args_name_su, args_tv_su);
                    }
                }
            }

            if (super_target.has_rest()) {
                uint copy_count = (uint)super_target.num_formals;
                for (uint i = 0; i < nargs && i < copy_count; i++) {
                    vm.heap.tval_copy_ref(&new_regs[i], &old_args[i]);
                }
                uint rest_idx = copy_count;
                uint overflow = (nargs > copy_count) ? (nargs - copy_count) : 0;
                HObject*? rest_obj_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                if (try rest_obj = rest_obj_raw) {
                    rest_obj.prototype = vm.heap.array_proto;
                    // Copy overflow args into the array
                    for (uint j = 0; j < overflow; j++) {
                        HString* key = vm.heap.int_to_hstring((long)j);
                        if (key != null) {
                            TVal elem = old_args[copy_count + j];
                            rest_obj.put_prop(key, elem, hobject::PROP_FLAGS_WEC);
                        }
                    }
                    // Set .length
                    HString* len_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    TVal len_val;
                    len_val.set_fastint((long)overflow);
                    rest_obj.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
                    new_regs[rest_idx].set_object(rest_obj);
                } else {
                    new_regs[rest_idx].set_undefined();
                }
                for (uint i = copy_count + 1; i < new_nregs; i++) {
                    new_regs[i].set_undefined();
                }
            } else {
                for (uint i = 0; i < nargs && i < new_nregs; i++) {
                    vm.heap.tval_copy_ref(&new_regs[i], &old_args[i]);
                }
                if (nargs < new_nregs) {
                    libc::memset(&new_regs[nargs], 0, (usz)(new_nregs - nargs) * TVal::size);
                }
            }

            vm.valstack_top = new_regs + new_nregs;
            vm.valstack_bottom = new_act.bottom;

            // Save caller resume point before switching activation
            ds.act.curr_pc = ds.curr_pc;

            ds.needs_restart = true;
            return (TVal){};
        }

        case Opcode.NEWTARGET: {
            // A = new.target
            HObject* nt = ds.act.new_target;
            if (nt != null) {
                ra.set_object(nt);
                track_heap_store(ds.act, ra, (uint)insn.a);
            } else {
                ra.set_undefined();
            }
            return (TVal){};
        }

        case Opcode.NEW_OBJ:
        case Opcode.NEW_OBJ_S: {
            // Compiler convention: A=result_reg, B=callee_reg, C=nargs (NEW_OBJ)
            // or C=nargs_reg (NEW_OBJ_S — reads nargs at runtime).
            uint result_reg = insn.a;
            uint callee_reg = insn.b;
            uint nargs;
            if (op == Opcode.NEW_OBJ_S) {
                TVal* nargs_slot = ds.regs_base + insn.c;
                if (nargs_slot.is_fastint()) {
                    nargs = (uint)nargs_slot.get_fastint();
                } else if (nargs_slot.is_number()) {
                    nargs = (uint)nargs_slot.get_number();
                } else {
                    nargs = 0;
                }
            } else {
                nargs = insn.c;
            }

            TVal* func_slot = ds.regs_base + callee_reg;
            TVal func_val = *func_slot;

            // Handle lightfunc built-in constructors (Error, TypeError, etc.)
            if (func_val.is_lightfunc()) {
                uint fn_idx = (uint)(usz)func_val.get_heapptr();

                // Check if this lightfunc is actually constructable.
                // lightfunc_get_proto returns null for non-constructors
                // (e.g. Object.seal, Object.freeze, Math.max, etc.)
                HObject* ctor_proto = lightfunc_get_proto(vm, fn_idx);
                if (ctor_proto == null) {
                    HString* type_str = typeof_string(vm, &func_val);
                    HObject*? err_raw_nc = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err_nc = err_raw_nc) {
                        err_nc.prototype = vm.heap.type_err_proto;
                        char[types::ERROR_MSG_BUF] buf;
                        int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a constructor",
                                                 type_str.get_cstr());
                        if (len > 0 && len < types::ERROR_MSG_BUF) {
                            HString* msg_str = intern_string(vm, buf[:len]);
                            TVal msg_val;
                            msg_val.set_string(msg_str);
                            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                            err_nc.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                        }
                        TVal err_val_nc;
                        err_val_nc.set_object(err_nc);
                        if (!vm_throw_value(vm, err_val_nc, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return vm_uncaught_error(vm, &err_val_nc);
                        }
                    } else {
                        return VM_ERROR~;
                    }
                    return (TVal){};
                }

                builtins::BuiltinContext ctx;
                ctx.vm = vm;
                ctx.regs = vm.valstack;
                ctx.base_reg = (ushort)((uint)(ds.act.bottom - vm.valstack) + callee_reg + 2);
                ctx.argc = (ushort)nargs;
                ctx.result = ds.regs_base + result_reg;
                ctx.heap = vm.heap;
                ctx.this_val = ds.regs_base[callee_reg + 1];
                ctx.is_constructor = true;
                ctx.needs_re_dispatch = false;
                ctx.re_nargs = 0;
                ctx.global_env = vm.global_env;
                ctx.should_throw = false;
                builtins::dispatch_builtin(fn_idx, &ctx);
                if (ctx.should_throw) {
                    if (!vm_throw_value(vm, ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &ctx.throw_value);
                    }
                    return (TVal){};
                }
                return (TVal){};
            }

            if (!func_val.is_object()) {
                // TypeError: value is not a constructor
                HString* type_str = typeof_string(vm, &func_val);
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a constructor",
                                             type_str.get_cstr());
                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val;
                    err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &err_val);
                    }
                } else {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            HObject* hobj = (HObject*)func_val.get_heapptr();
            if (hobj == null || !hobj.is_callable() || !hobj.is_constructable()) {
                // TypeError: object is not a constructor
                HString* type_str = typeof_string(vm, &func_val);
                HObject*? err_raw2 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err2 = err_raw2) {
                    err2.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a constructor",
                                             type_str.get_cstr());
                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err2.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val2;
                    err_val2.set_object(err2);
                    if (!vm_throw_value(vm, err_val2, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &err_val2);
                    }
                } else {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            // Handle bound function objects — dispatch to builtin_bound_call
            if (hobj.callable_kind() == hobject::CallableKind.BOUND_FN) {
                if ((*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((ds.act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = ds.regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = ds.regs_base[callee_reg + 1];
                    ctx.is_constructor = false;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    ctx.callee_obj = hobj;
                    builtins::dispatch_builtin(fn_idx, &ctx);

                    if (ctx.should_throw) {
                        if (!vm_throw_value(vm, ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return vm_uncaught_error(vm, &ctx.throw_value);
                        }
                        return (TVal){};
                    }

                    if (ctx.needs_re_dispatch) {
                        func_val = ds.regs_base[callee_reg];
                        hobj = (HObject*)func_val.get_heapptr();
                        nargs = ctx.re_nargs;
                        // Fall through to compiled function handling below
                    } else {
                        return (TVal){};
                    }
                } else {
                    return (TVal){};
                }
            } else if (hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN) {
                if ((*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((uint)(ds.act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = ds.regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = ds.regs_base[callee_reg + 1];
                    ctx.is_constructor = true;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    ctx.callee_obj = hobj;
                    builtins::dispatch_builtin(fn_idx, &ctx);
                    if (ctx.should_throw) {
                        if (!vm_throw_value(vm, ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return vm_uncaught_error(vm, &ctx.throw_value);
                        }
                        return (TVal){};
                    }
                    return (TVal){};
                }
                // Object claims to be callable but has no compiled function
                // and no builtin index — treat as non-constructor
                HString* type_str = typeof_string(vm, &func_val);
                HObject*? err_raw2 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err2 = err_raw2) {
                    err2.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a constructor",
                                             type_str.get_cstr());
                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err2.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val2;
                    err_val2.set_object(err2);
                    if (!vm_throw_value(vm, err_val2, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &err_val2);
                    }
                } else {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            CompiledFunction* target = (*hobj.extra_ptr()).func.comp_func;

            // Arrow functions cannot be used as constructors (ES6 §14.2.2)
            if (target.is_arrow()) {
                HString* type_str = typeof_string(vm, &func_val);
                HObject*? err_raw3 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err3 = err_raw3) {
                    err3.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not a constructor",
                                             type_str.get_cstr());
                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err3.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val3;
                    err_val3.set_object(err3);
                    if (!vm_throw_value(vm, err_val3, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &err_val3);
                    }
                } else {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            // Step 1: Create new object
            HObject*? new_obj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
            if (catch err = new_obj_raw) {
                ds.regs_base[result_reg].set_undefined();
                return (TVal){};
            }
            HObject* new_obj = new_obj_raw;

            // Step 2: Set prototype from constructor.prototype
            HString* proto_key = (HString*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE];
            TVal? proto_val = hobj.get_prop_proto(proto_key);
            if (try pv = proto_val) {
                if (pv.is_object() && pv.get_heapptr() != null) {
                    new_obj.prototype = (HObject*)pv.get_heapptr();
                }
            }

            // Step 3: Place new object in this-slot
            TVal this_tval;
            this_tval.set_object(new_obj);
            vm.heap.tval_copy_ref(&ds.regs_base[callee_reg + 1], &this_tval);
            uint frame_start = callee_reg + 2;
            TVal* new_bottom = ds.regs_base + frame_start;
            uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

            if (!ensure_valstack(vm, needed)) {
                ds.regs_base[result_reg].set_undefined();
                return (TVal){};
            }

            ds.regs_base = ds.act.bottom;
            // Recompute new_bottom after realloc (ds.act.bottom may have moved)
            new_bottom = ds.regs_base + frame_start;
            func_slot = ds.regs_base + callee_reg;

            if (vm.activation_count >= MAX_CALLS) {
                {
                    HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        err.prototype = vm.heap.range_err_proto;
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        HString* msg_val = intern_string(vm, "Maximum call stack size exceeded");
                        TVal msg_tv; msg_tv.set_string(msg_val);
                        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                        TVal err_val; err_val.set_object(err);
                        if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return vm_uncaught_error(vm, &err_val);
                        }
                    } else {
                        return VM_ERROR~;
                    }
                }
                return (TVal){};
            }

            Activation* new_act = &vm.activations[vm.activation_count];
            vm.activation_count++;
            new_act.max_heap_reg = 0;
            new_act.caller_valstack_top = vm.valstack_top;

            EnvRecord* ctor_var_env = (*hobj.extra_ptr()).func.var_env;
            if (try fv_ct = env::env_create_function_scope(vm.heap, (*hobj.extra_ptr()).func.var_env)) { ctor_var_env = fv_ct; }
            new_act.parent = ds.act;
            new_act.func = target;
            new_act.var_env = ctor_var_env;
            // Named function expressions get a fresh declarative lex_env
            // with the function name bound immutably (ES2015 §14.1.20).
            if (target.is_namebinding()) {
                char[] name_data = target.get_name();
                HString* name_hstr = intern_string(vm, name_data);
                if (name_hstr != null) {
                    if (try name_lex = setup_named_function_expr_env(vm, ctor_var_env, name_hstr, hobj)) {
                        new_act.lex_env = name_lex;
                    } else {
                        new_act.lex_env = ctor_var_env;
                    }
                } else {
                    new_act.lex_env = ctor_var_env;
                }
            } else {
                // Use the captured lex_env so block-scoped let/const bindings
                // from the enclosing function body are visible.  Mirrors the
                // CALL fast path (line ~4503) which also honors func.lex_env
                // when it's a *declarative* (block) scope.  Without this,
                // constructors for `class B extends A { constructor() { super(); } }`
                // can't see the classScope's `__super__` binding — the
                // constructor's CLOSURE captures func.lex_env = classScope but
                // NEW_OBJ was unconditionally resetting it to ctor_var_env.
                EnvRecord* cap_lex_noname = (*hobj.extra_ptr()).func.lex_env;
                if (cap_lex_noname != null
                    && cap_lex_noname != ctor_var_env
                    && cap_lex_noname.is_declarative) {
                    new_act.lex_env = cap_lex_noname;
                } else {
                    new_act.lex_env = ctor_var_env;
                }
            }
            new_act.cat = null;
            new_act.curr_pc = target.code;
            new_act.bottom = new_bottom;
            new_act.retval = ds.regs_base + result_reg;
            new_act.flags = ACT_FLAG_CONSTRUCT
                          | (target.has_direct_eval() ? ACT_FLAG_DIRECT_EVAL : 0);
            vm.heap.tval_copy_ref(&new_act.this_binding, &this_tval);
            new_act.new_target = hobj;  // constructor function, not instance

            TVal* new_regs2 = new_act.bottom;
            uint new_nregs2 = target.num_regs;

            // Copy args
            TVal* old_args2 = ds.regs_base + callee_reg + 2;

            // Create arguments object BEFORE the rest parameter handling below
            // overwrites new_regs2[0] with the rest array.  Capture the original
            // (pre-overwrite) args via the same stack pointer the rest code will
            // mutate.
            if (target.uses_arguments()) {
                HObject*? args_obj_raw2 = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
                if (try args_obj2 = args_obj_raw2) {
                    for (uint ai = 0; ai < nargs; ai++) {
                        args_obj2.set_array_idx(ai, old_args2[ai]);
                    }
                    args_obj2.prototype = vm.heap.object_proto;
                    HString* callee_key2 = (HString*)vm.heap.strs[heap::BuiltinStr.CALLEE];
                    if (callee_key2 != null) {
                        TVal callee_tv2; callee_tv2.set_object(hobj);
                        args_obj2.put_prop(callee_key2, callee_tv2, hobject::PROP_FLAGS_WC);
                    }
                    HString* length_key2 = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    if (length_key2 != null) {
                        TVal length_tv2; length_tv2.set_fastint((long)nargs);
                        args_obj2.put_prop(length_key2, length_tv2, hobject::PROP_FLAGS_WC);
                    }
                    HString* args_name2 = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
                    if (args_name2 != null) {
                        TVal args_tv2; args_tv2.set_object(args_obj2);
                        env::env_declare(ctor_var_env, args_name2, args_tv2);
                    }
                }
            }

            if (target.has_rest()) {
                uint copy_count = (uint)target.num_formals;
                for (uint i = 0; i < nargs && i < copy_count; i++) {
                    vm.heap.tval_copy_ref(&new_regs2[i], &old_args2[i]);
                }

                uint rest_idx = copy_count;
                uint overflow = (nargs > copy_count) ? (nargs - copy_count) : 0;

                HObject*? arr2_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                if (try a2 = arr2_raw) {
                    a2.prototype = vm.heap.array_proto;
                    for (uint i = 0; i < overflow; i++) {
                        HString* key2 = vm.heap.int_to_hstring((long)i);
                        if (key2 != null) {
                            TVal elem2 = old_args2[copy_count + i];
                            a2.put_prop(key2, elem2, hobject::PROP_FLAGS_WEC);
                        }
                    }
                    HString* len_str2 = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    TVal len_val2;
                    len_val2.set_fastint((long)overflow);
                    a2.put_prop(len_str2, len_val2, hobject::PROP_FLAGS_WEC);

                    new_regs2[rest_idx].set_object(a2);
                } else {
                    new_regs2[rest_idx].set_undefined();
                }

                if (rest_idx + 1 < new_nregs2) {
                    libc::memset(&new_regs2[rest_idx + 1], 0, (usz)(new_nregs2 - rest_idx - 1) * TVal::size);
                }
            } else {
                for (uint i = 0; i < nargs && i < (uint)target.num_args; i++) {
                    vm.heap.tval_copy_ref(&new_regs2[i], &old_args2[i]);
                }
                if (nargs < new_nregs2) {
                    zero_regs_undefined(new_regs2, nargs, new_nregs2);
                }
            }

            vm.valstack_top = (TVal*)((usz)new_regs2 + (usz)new_nregs2 * (usz)TVal::size);
            vm.valstack_bottom = new_act.bottom;

            ds.act.curr_pc = ds.curr_pc;
            ds.needs_restart = true;
            return (TVal){};
        }

        case Opcode.TAILCALL:
            return (TVal){};

        default:
            return (TVal){};
    }
    return (TVal){};
}


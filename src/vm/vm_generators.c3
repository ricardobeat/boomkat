module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;
import duktape::re_bindings;
import std::math;

// ============================================================================
// vm_generators — generator opcodes
// ============================================================================
/// Sub-dispatch for LOAD_RESUME, AWAIT, YIELD, YIELD_STAR opcodes.
fn TVal? dispatch_generators(Dispatch* ds, Opcode op, TVal* ra, TVal* rb, TVal* rc, Instruction insn) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.LOAD_RESUME: {
            // LOAD_RESUME A — load the value passed to .next(val) into A.
            // Emitted after YIELD so the yield expression evaluates to the
            // resume value. Also handles throw/return injection: for THROW,
            // call vm_throw_value to find the nearest catcher; for RETURN,
            // mark the generator complete and return to the caller.
            $if $feature(HEAP_VERIFY):
                vm.heap.verify_roots("before_load_resume");
                if (vm.heap.resume_gen != null) {
                    GeneratorState* gs_chk = vm.heap.resume_gen;
                    if (gs_chk.saved_regs != null) {
                        vm.heap.verify_tval_array(gs_chk.saved_regs, gs_chk.num_regs, "load_resume_saved_regs");
                    }
                }
            $endif
            if (vm.heap.resume_gen != null) {
                GeneratorState* gs_lr = vm.heap.resume_gen;
                ResumeKind rk = gs_lr.resume_kind;

                if (rk == THROW) {
                    // Inject exception: find catcher only within the generator activation.
                    // Use local_only=true so we don't mistakenly find the caller's catcher
                    // and then fail to complete the generator (ES6 §25.3.3.4 step 8).
                    TVal throw_val = gs_lr.throw_value;

                    if (!vm_throw_value(vm, throw_val, ds.act, &ds.curr_pc, &ds.needs_restart, true)) {
                        // No catcher in generator/async function.
                        vm.heap.resume_gen = null;
                        gs_lr.state = GEN_COMPLETED;

                        // For async functions: reject the async Promise and return
                        if (gs_lr.async_promise != null) {
                            HObject* async_prom = (HObject*)gs_lr.async_promise;
                            builtins::promise_settle(async_prom, builtins::PROMISE_REJECTED, &throw_val, vm.heap);
                            builtins::promise_trigger_reactions(async_prom, vm.heap, (void*)vm);
                            // Pop the single activation and return undefined
                            decref_callee_regs(vm, ds.act);
                            vm.activation_count--;
                            TVal undef_val;
                            undef_val.set_undefined();
                            vm.heap.tval_copy_ref(&vm.return_val, &undef_val);
                            ds.halt = true;
                            ds.halt_value = vm.return_val;
                            return (TVal){};
                        }

                        // Generator path: pop activation and propagate error
                        if (vm.activation_count > 0) {
                            vm.activation_count--;
                            if (vm.activation_count > 0) {
                                Activation* caller_act = &vm.activations[vm.activation_count - 1];
                                vm.valstack_bottom = caller_act.bottom;
                                if (caller_act.func != null) {
                                    CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;
                                    vm.valstack_top = caller_act.bottom + caller_func.num_regs;
                                }

                                // Try to find a catcher in the caller's chain
                                if (!vm_throw_value(vm, throw_val, caller_act,
                                                    &caller_act.curr_pc, &ds.needs_restart)) {
                                    // Unhandled — set error for the VM to return
                                    vm.has_error = true;
                                    vm.heap.has_error = true;
                                    if (caller_act.retval != null) {
                                        vm.heap.tval_copy_ref(caller_act.retval, &throw_val);
                                    }
                                }
                            }
                        }
                    } else {
                        // Catcher found in generator — the exception will be caught.
                        // Keep resume_gen set but switch to NEXT so the next YIELD
                        // properly saves state and sets gs.state = GEN_SUSPENDED_YIELD.
                        gs_lr.resume_kind = NEXT;
                        gs_lr.resume_value.set_undefined();
                    }
                    ds.needs_restart = true;
                    return (TVal){};
                }

                if (rk == RETURN) {
                    // Inject return at the suspended yield point: this acts like
                    // a `return` statement executing there, so a try/finally
                    // enclosing the yield must run before the generator
                    // actually completes (mirrors plain RET/RET_GEN).
                    TVal ret_val_raw = gs_lr.return_value;
                    gs_lr.resume_kind = NEXT;

                    Catcher* ret_cat3 = (Catcher*)ds.act.cat;
                    if (ret_cat3 != null && ret_cat3.finally_pc != null) {
                        ret_cat3.return_val = ret_val_raw;
                        if (!(ret_cat3.flags & CATCHER_FLAG_PENDING_RETURN)) {
                            ret_cat3.flags |= CATCHER_FLAG_PENDING_RETURN | CATCHER_FLAG_PENDING_RETURN_GEN;
                            ds.curr_pc = ret_cat3.finally_pc;
                            ds.act.curr_pc = ds.curr_pc;
                        }
                        ds.needs_restart = true;
                        return (TVal){};
                    }

                    gs_lr.state = GEN_COMPLETED;
                    vm.heap.resume_gen = null;
                    vm_complete_generator_return(ds, &ret_val_raw);
                    return (TVal){};
                }

                // Normal NEXT — load resume value
                vm.heap.tval_copy_ref(&ra[0], &gs_lr.resume_value);
            }
            // If resume_gen is null (e.g., after AWAIT with non-thenable),
            // don't overwrite the register — the value is already correct.
            return (TVal){};
        }

        case Opcode.AWAIT: {
            // AWAIT A — await the value in register A.
            // If the value is not a thenable, continue (no-op).
            // If the value is a settled Promise, extract the result.
            // If the value is a pending Promise, suspend and resume later.
            TVal await_val = ra[0];

            // Not an object → not a thenable, continue
            if (!await_val.is_object() || await_val.get_heapptr() == null) {
                return (TVal){};
            }

            HObject* await_obj = (HObject*)await_val.get_heapptr();

            // Non-Promise thenable: wrap in a Promise via the thenable protocol
            if (await_obj.flags.obj_class != hobject::ObjClass.PROMISE) {
                HObject*? wrapper_raw = builtins::promise_coerce_thenable(vm.heap, await_val, (void*)vm);
                if (try HObject* wrapper = wrapper_raw) {
                    if (wrapper != null) {
                        await_val.set_object(wrapper);
                        await_obj = wrapper;
                    } else {
                        // Not a thenable: await is a no-op for plain objects
                        return (TVal){};
                    }
                } else {
                    // Not a thenable (fault)
                    return (TVal){};
                }
            }

            // Check if it's a Promise
            if (await_obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                uint pstate = builtins::promise_get_state(await_obj, 0);
                if (pstate == builtins::PROMISE_FULFILLED) {
                    // Fulfilled: extract the value into the register
                    TVal result = builtins::promise_get_result(await_obj);
                    vm.heap.tval_copy_ref(&ra[0], &result);
                    return (TVal){};
                }
                if (pstate == builtins::PROMISE_REJECTED) {
                    // Rejected: throw the rejection reason.
                    // If caught by try/catch, execution continues; otherwise
                    // the error propagates (rejecting the async Promise if applicable).
                    TVal reason = builtins::promise_get_result(await_obj);
                    if (!vm_throw_value(vm, reason, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        // No catcher — if async, reject the outer Promise
                        if ((ds.act.flags & ACT_FLAG_ASYNC) != 0 && ds.act.async_promise != null) {
                            builtins::promise_settle(ds.act.async_promise, builtins::PROMISE_REJECTED, &reason, vm.heap);
                            builtins::promise_trigger_reactions(ds.act.async_promise, vm.heap, (void*)vm);
                            decref_callee_regs(vm, ds.act);
                            vm.activation_count--;
                            if (vm.activation_count == 0) {
                                TVal undef_val;
                                undef_val.set_undefined();
                                vm.heap.tval_copy_ref(&vm.return_val, &undef_val);
                                ds.halt = true;
                                ds.halt_value = vm.return_val;
                                return (TVal){};
                            }
                            ds.act = &vm.activations[vm.activation_count - 1];
                            vm.valstack_bottom = ds.act.bottom;
                            vm.valstack_top = ds.act.caller_valstack_top;
                            CompiledFunction* caller_f = (CompiledFunction*)ds.act.func;
                            if (caller_f != vm.current_func) {
                                vm.current_func = caller_f;
                                ds.code_base = caller_f.code;
                                ds.code_count = caller_f.code_count;
                                ds.code_end = ds.code_base + ds.code_count;
                                ds.constants = caller_f.constants;
                                ds.ic_base = (hobject::ICEntry*)caller_f.ic_entries;
                                ds.var_ic_base = (hobject::VarICEntry*)caller_f.var_ic_entries;
                                ds.nregs = caller_f.num_regs;
                            }
                            ds.curr_pc = ds.act.curr_pc;
                            ds.regs_base = ds.act.bottom;
                        } else {
                            // Not an async frame (or its promise is missing):
                            // an uncaught rejected await terminates execution.
                            // Restarting here would rerun the frame from its
                            // stale saved pc and loop forever.
                            return vm_uncaught_error(vm, &reason);
                        }
                    }
                    ds.needs_restart = true;
                    return (TVal){};
                }
                // Pending (pstate == 0): fall through to suspension below

                // Pending Promise: suspend the async function
                // 1. Allocate GeneratorState for saving execution state
                void* gs_raw = vm.heap.alloc_func(vm.heap.heap_udata, GeneratorState::size);
                if (gs_raw == null) {
                    // OOM: cannot suspend.  Reject the async Promise if
                    // applicable, otherwise propagate as an uncaught error.
                    TVal oom_reason;
                    oom_reason.set_undefined();
                    if ((ds.act.flags & ACT_FLAG_ASYNC) != 0 && ds.act.async_promise != null) {
                        builtins::promise_settle(ds.act.async_promise, builtins::PROMISE_REJECTED, &oom_reason, vm.heap);
                        builtins::promise_trigger_reactions(ds.act.async_promise, vm.heap, (void*)vm);
                        decref_callee_regs(vm, ds.act);
                        vm.activation_count--;
                        if (vm.activation_count == 0) {
                            TVal undef_val;
                            undef_val.set_undefined();
                            vm.heap.tval_copy_ref(&vm.return_val, &undef_val);
                            ds.halt = true;
                            ds.halt_value = vm.return_val;
                            return (TVal){};
                        }
                        ds.act = &vm.activations[vm.activation_count - 1];
                        vm.valstack_bottom = ds.act.bottom;
                        vm.valstack_top = ds.act.caller_valstack_top;
                        CompiledFunction* caller_f = (CompiledFunction*)ds.act.func;
                        if (caller_f != vm.current_func) {
                            vm.current_func = caller_f;
                            ds.code_base = caller_f.code;
                            ds.code_count = caller_f.code_count;
                            ds.code_end = ds.code_base + ds.code_count;
                            ds.constants = caller_f.constants;
                            ds.ic_base = (hobject::ICEntry*)caller_f.ic_entries;
                            ds.var_ic_base = (hobject::VarICEntry*)caller_f.var_ic_entries;
                            ds.nregs = caller_f.num_regs;
                        }
                        ds.curr_pc = ds.act.curr_pc;
                        ds.regs_base = ds.act.bottom;
                    }
                    return vm_uncaught_error(vm, &oom_reason);
                }
                GeneratorState* gs = (GeneratorState*)gs_raw;
                mem::clear(gs_raw, (sz)(GeneratorState::size));
                gs.pending_resume_reg = 0xFFFF;

                CompiledFunction* cur_func = (CompiledFunction*)ds.act.func;

                gs.state = GEN_SUSPENDED_YIELD;
                gs.func = ds.act.func;
                gs.num_regs = cur_func.num_regs;
                gs.saved_pc = ds.curr_pc; // PC after AWAIT (points to LOAD_RESUME)
                gs.var_env = ds.act.var_env;
                gs.lex_env = ds.act.lex_env;
                gs.cat = ds.act.cat;
                vm.heap.tval_copy_ref(&gs.this_binding, &ds.act.this_binding);
                gs.async_promise = (void*)ds.act.async_promise;
                usz regs_bytes = (usz)gs.num_regs * TVal::size;
                void* regs_mem = vm.heap.alloc_func(vm.heap.heap_udata, regs_bytes);
                if (regs_mem == null) {
                    vm.heap.decref_tval(&gs.this_binding);
                    vm.heap.free_func(vm.heap.heap_udata, gs_raw);
                    return (TVal){};
                }
                gs.saved_regs = (TVal*)regs_mem;
                mem::clear(regs_mem, (sz)(regs_bytes));
                TVal* regs_src = ds.act.bottom;
                for (uint i = 0; i < gs.num_regs; i++) {
                    vm.heap.tval_copy_ref(&gs.saved_regs[i], &regs_src[i]);
                }

                $if $feature(HEAP_VERIFY):
                    vm.heap.verify_roots("after_await_save");
                    vm.heap.verify_tval_array(gs.saved_regs, gs.num_regs, "await_saved_regs");
                $endif

                // 2. Create resume callback (builtin)
                HObject*? resume_raw = vm.heap.alloc_object(hobject::ObjClass.FUNCTION);
                if (catch _e1 = resume_raw) {
                    for (uint i = 0; i < gs.num_regs; i++) {
                        vm.heap.decref_tval(&gs.saved_regs[i]);
                    }
                    vm.heap.decref_tval(&gs.this_binding);
                    vm.heap.free_func(vm.heap.heap_udata, gs.saved_regs);
                    vm.heap.free_func(vm.heap.heap_udata, gs_raw);
                    return (TVal){};
                }
                HObject* resume_fn = resume_raw;
                (*resume_fn.extra_ptr()).func.builtin_fn_index = (int)builtins::Builtin.ASYNC_RESUME.ordinal;
                (*resume_fn.extra_ptr()).func.var_env = (EnvRecord*)gs;
                resume_fn.flags.is_async_state = true;
                TVal resume_tv;
                resume_tv.set_object(resume_fn);

                // 3. Create reject callback (builtin)
                HObject*? reject_raw = vm.heap.alloc_object(hobject::ObjClass.FUNCTION);
                if (catch _e2 = reject_raw) {
                    // Clear resume_fn's async_state so the GC won't dereference
                    // the freed GeneratorState via var_env.
                    resume_fn.flags.is_async_state = false;
                    (*resume_fn.extra_ptr()).func.var_env = null;
                    for (uint i = 0; i < gs.num_regs; i++) {
                        vm.heap.decref_tval(&gs.saved_regs[i]);
                    }
                    vm.heap.decref_tval(&gs.this_binding);
                    vm.heap.free_func(vm.heap.heap_udata, gs.saved_regs);
                    vm.heap.free_func(vm.heap.heap_udata, gs_raw);
                    return (TVal){};
                }
                HObject* reject_fn = reject_raw;
                (*reject_fn.extra_ptr()).func.builtin_fn_index = (int)builtins::Builtin.ASYNC_REJECT.ordinal;
                (*reject_fn.extra_ptr()).func.var_env = (EnvRecord*)gs;
                reject_fn.flags.is_async_state = true;
                TVal reject_tv;
                reject_tv.set_object(reject_fn);

                // 4. Create reaction and add to the pending Promise
                HObject*? rxn_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (catch _e3 = rxn_raw) {
                    // Clear both callbacks' async_state so the GC won't
                    // dereference the freed GeneratorState via var_env.
                    resume_fn.flags.is_async_state = false;
                    (*resume_fn.extra_ptr()).func.var_env = null;
                    reject_fn.flags.is_async_state = false;
                    (*reject_fn.extra_ptr()).func.var_env = null;
                    for (uint i = 0; i < gs.num_regs; i++) {
                        vm.heap.decref_tval(&gs.saved_regs[i]);
                    }
                    vm.heap.decref_tval(&gs.this_binding);
                    vm.heap.free_func(vm.heap.heap_udata, gs.saved_regs);
                    vm.heap.free_func(vm.heap.heap_udata, gs_raw);
                    return (TVal){};
                }
                HObject* rxn = rxn_raw;
                rxn.prototype = vm.heap.object_proto;
                HString* ff_key = builtins::builtin_intern_string(vm.heap, "onFulfilled");
                HString* rj_key = builtins::builtin_intern_string(vm.heap, "onRejected");
                if (ff_key != null) rxn.put_prop(ff_key, resume_tv, hobject::PROP_FLAGS_WEC);
                if (rj_key != null) rxn.put_prop(rj_key, reject_tv, hobject::PROP_FLAGS_WEC);
                builtins::promise_add_reaction(await_obj, rxn, vm.heap);

                // 5. Pop activation (suspend the async function)
                decref_callee_regs(vm, ds.act);
                vm.activation_count--;
                if (vm.activation_count == 0) {
                    TVal undef_val2;
                    undef_val2.set_undefined();
                    vm.heap.tval_copy_ref(&vm.return_val, &undef_val2);
                    ds.halt = true;
                    ds.halt_value = vm.return_val;
                    return (TVal){};
                }

                // Restore caller state
                if (vm.activation_count > 0) {
                    ds.act = &vm.activations[vm.activation_count - 1];
                    vm.valstack_bottom = ds.act.bottom;
                    vm.valstack_top = ds.act.caller_valstack_top;
                    CompiledFunction* caller_f = (CompiledFunction*)ds.act.func;
                    if (caller_f != vm.current_func) {
                        vm.current_func = caller_f;
                        ds.code_base = caller_f.code;
                        ds.code_count = caller_f.code_count;
                        ds.code_end = ds.code_base + ds.code_count;
                        ds.constants = caller_f.constants;
                        ds.ic_base = (hobject::ICEntry*)caller_f.ic_entries;
                        ds.var_ic_base = (hobject::VarICEntry*)caller_f.var_ic_entries;
                        ds.nregs = caller_f.num_regs;
                    }
                    ds.curr_pc = ds.act.curr_pc;
                    ds.regs_base = ds.act.bottom;
                }
                ds.needs_restart = true;
                return (TVal){};
            }
            // Unreachable: the thenable-wrap above ensures await_obj is
            // always a PROMISE by this point.  The only way to reach here
            // is via the alloc-failure `break` at line 227, which exits
            // the case entirely (falling out of the switch).
            return (TVal){};
        }

        case Opcode.YIELD: {
            // YIELD A — suspend generator and return {value: A, done: false}
            // Prefer async_gen_state from the current activation — this is the stable
            // reference to the generator being suspended.  heap.resume_gen may have
            // been overwritten by a nested call to another generator's .next() during
            // the body (e.g. a for-of loop over an inner generator), so we cannot
            // rely on it alone.
            GeneratorState* gs_yield = (GeneratorState*)ds.act.async_gen_state;
            if (gs_yield == null) { gs_yield = vm.heap.resume_gen; }
            if (gs_yield != null) {
                GeneratorState* gs = gs_yield;
                // Clear heap.resume_gen if it still points at this gs to avoid
                // a stale reference on the next resume.
                if (vm.heap.resume_gen == gs) { vm.heap.resume_gen = null; }

                // Find the activation that owns this generator state.
                // When yield appears inside a non-generator inner function
                // (e.g. a default expression thunk [x = yield]), ds.act is the
                // inner function's activation, not the generator's. Walk up the
                // activation chain to find the generator's frame and pop any
                // intervening activations.
                Activation* gen_act = ds.act;
                if (ds.act.func != gs.func) {
                    // Current activation is not the generator — walk parents.
                    Activation* walk = ds.act.parent;
                    while (walk != null) {
                        if (walk.async_gen_state == gs) {
                            gen_act = walk;
                            break;
                        }
                        walk = walk.parent;
                    }
                }

                // Pop activations above the generator's activation.
                // The generator's activation is the one we'll save state from.
                while (vm.activation_count > 0) {
                    Activation* top = &vm.activations[vm.activation_count - 1];
                    if (top == gen_act) break;
                    vm.activation_count--;
                }

                // Save current state from the generator's activation.
                // When yield appears inside a non-generator inner function
                // (e.g. a default expression thunk [x = yield]), ds.act is the
                // inner function's activation, not the generator's. Use the
                // generator's activation for all saved state.

                // The saved PC must point into the generator's bytecode, not
                // the inner function's bytecode. gen_act.curr_pc was set by
                // the CALL opcode to the instruction after the call site in
                // the generator's code — that's where execution should resume.
                //
                // However, the CALL that invoked the default thunk never
                // completed (the thunk yielded instead of returning). We must
                // record the call result register so that when the generator
                // resumes, the resume value (.next(val)) is placed into the
                // correct slot for the code after the CALL to read.
                if (ds.act.async_gen_state == null && gen_act != ds.act) {
                    // Yield inside a non-generator inner function — record the
                    // call result register for the resume path.
                    Instruction call_insn = gen_act.curr_pc[-1];
                    gs.pending_resume_reg = (uint)call_insn.a;
                }

                // Save current state
                TVal* regs_base_r = gen_act.bottom;
                for (uint i = 0; i < gs.num_regs; i++) {
                    vm.heap.tval_copy_ref(&gs.saved_regs[i], &regs_base_r[i]);
                }
                gs.saved_pc = (gen_act == ds.act) ? ds.curr_pc : gen_act.curr_pc;
                gs.var_env = gen_act.var_env;
                gs.lex_env = gen_act.lex_env;
                gs.cat = gen_act.cat;
                vm.heap.tval_copy_ref(&gs.this_binding, &gen_act.this_binding);
                gs.state = GEN_SUSPENDED_YIELD;

                $if $feature(HEAP_VERIFY):
                    vm.heap.verify_roots("after_yield");
                    vm.heap.verify_tval_array(gs.saved_regs, gs.num_regs, "yield_saved_regs");
                $endif

                // Store the yielded value
                vm.heap.tval_copy_ref(&vm.heap.yield_value, &ra[0]);

                // Check resume kind for throw/return injection
                ResumeKind rkind = gs.resume_kind;

                if (rkind == THROW) {
                    // .throw() — inject exception at yield point
                    // Pop activation, set has_error so the outer loop
                    // re-enters the generator with an exception pending
                    vm.heap.resume_gen = null;
                    vm.heap.did_yield = true;

                    if (vm.activation_count > 0) {
                        Activation* yield_act = &vm.activations[vm.activation_count - 1];

                        // Write the exception as the result (will be caught by
                        // try/catch inside generator). retval is null when this
                        // activation was entered via the re-entrant call_fn path
                        // (e.g. YIELD_STAR calling a delegated generator's
                        // .next() directly) — the result is read back via
                        // vm.return_val in that case instead.
                        if (yield_act.retval != null) {
                            vm.heap.tval_copy_ref(yield_act.retval, &gs.throw_value);
                        } else {
                            vm.heap.tval_copy_ref(&vm.return_val, &gs.throw_value);
                        }

                        vm.activation_count--;
                        // activation_count can hit 0 here for the same
                        // re-entrant-call reason — halt like the plain RET path.
                        if (vm.activation_count == 0) {
                            ds.halt = true;
                            ds.halt_value = vm.return_val;
                            return (TVal){};
                        }
                        Activation* caller_act2 = &vm.activations[vm.activation_count - 1];
                        vm.valstack_bottom = caller_act2.bottom;
                        if (caller_act2.func != null) {
                            CompiledFunction* caller_func2 = (CompiledFunction*)caller_act2.func;
                            vm.valstack_top = caller_act2.bottom + caller_func2.num_regs;
                        }
                    }
                    ds.needs_restart = true;
                    return (TVal){};
                }

                if (rkind == RETURN) {
                    // .return() — inject return at yield point
                    // Mark generator as completed, return {value: rv, done: true}
                    gs.state = GEN_COMPLETED;
                    vm.heap.resume_gen = null;
                    vm.heap.did_yield = false;

                    HObject*? robj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                    TVal wrapped_val;
                    if (try robj = robj_raw) {
                        robj.prototype = vm.heap.object_proto;
                        HString* val_key = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                        if (val_key != null) robj.put_prop(val_key, gs.return_value, hobject::PROP_FLAGS_WEC);
                        HString* done_key = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                        TVal done_val;
                        done_val.set_boolean(true);
                        if (done_key != null) robj.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);
                        wrapped_val.set_object(robj);
                    } else {
                        wrapped_val = gs.return_value;
                    }

                    if (vm.activation_count > 0) {
                        Activation* yield_act = &vm.activations[vm.activation_count - 1];
                        // retval is null when this activation was entered via
                        // the re-entrant call_fn path (e.g. YIELD_STAR calling
                        // a delegated generator's .next() directly) — the
                        // result is read back via vm.return_val in that case.
                        if (yield_act.retval != null) {
                            vm.heap.tval_copy_ref(yield_act.retval, &wrapped_val);
                        } else {
                            vm.heap.tval_copy_ref(&vm.return_val, &wrapped_val);
                        }

                        vm.activation_count--;
                        // activation_count can hit 0 here for the same
                        // re-entrant-call reason — halt like the plain RET path.
                        if (vm.activation_count == 0) {
                            ds.halt = true;
                            ds.halt_value = vm.return_val;
                            return (TVal){};
                        }
                        Activation* caller_act2 = &vm.activations[vm.activation_count - 1];
                        vm.valstack_bottom = caller_act2.bottom;
                        if (caller_act2.func != null) {
                            CompiledFunction* caller_func2 = (CompiledFunction*)caller_act2.func;
                            vm.valstack_top = caller_act2.bottom + caller_func2.num_regs;
                        }
                    }
                    ds.needs_restart = true;
                    return (TVal){};
                }

                // Normal .next() — clear resume_gen so CALL handler doesn't try to resume again
                vm.heap.resume_gen = null;
            }

            vm.heap.did_yield = true;

            // Store the yielded value for IteratorResult creation below
            vm.heap.tval_copy_ref(&vm.heap.yield_value, &ra[0]);

            // Pop activation and return to caller (the .next() builtin's context)
            if (vm.activation_count > 0) {
                Activation* yield_act = &vm.activations[vm.activation_count - 1];

                // Create IteratorResult {value: yieldVal, done: false}
                HObject*? result_obj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                TVal wrapped_val;
                if (try robj = result_obj_raw) {
                    robj.prototype = vm.heap.object_proto;
                    HString* val_key = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                    if (val_key != null) robj.put_prop(val_key, vm.heap.yield_value, hobject::PROP_FLAGS_WEC);
                    HString* done_key = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                    TVal done_val;
                    done_val.set_boolean(false);
                    if (done_key != null) robj.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);
                    wrapped_val.set_object(robj);
                } else {
                    wrapped_val = vm.heap.yield_value;
                }

                // Write wrapped result to caller's frame. retval is null when
                // this activation was entered via the re-entrant call_fn path
                // (e.g. YIELD_STAR calling a delegated generator's .next()
                // directly) rather than the CALL opcode — the result is read
                // back via vm.return_val in that case instead.
                if (yield_act.retval != null) {
                    vm.heap.tval_copy_ref(yield_act.retval, &wrapped_val);
                } else {
                    vm.heap.tval_copy_ref(&vm.return_val, &wrapped_val);
                }

                vm.activation_count--;
                // activation_count can hit 0 here for the same re-entrant-call
                // reason — there is no caller activation in *this* Vm.run
                // invocation to fall back to, so halt like the plain RET path.
                if (vm.activation_count == 0) {
                    ds.halt = true;
                    ds.halt_value = vm.return_val;
                    return (TVal){};
                }
                Activation* caller_act2 = &vm.activations[vm.activation_count - 1];
                vm.valstack_bottom = caller_act2.bottom;
                if (caller_act2.func != null) {
                    CompiledFunction* caller_func2 = (CompiledFunction*)caller_act2.func;
                    vm.valstack_top = caller_act2.bottom + caller_func2.num_regs;
                }
            }
            ds.needs_restart = true;
            return (TVal){};
        }

        case Opcode.YIELD_STAR: {
            // yield* iterable — delegate to another iterable (ES2020 §14.4.14).
            // A = result_reg, B = iterable_reg, C = 0.
            // Use async_gen_state from the current activation — stable reference
            // that doesn't get overwritten by nested generator calls.
            TVal iterable_val = *rb;
            GeneratorState* gs = (GeneratorState*)ds.act.async_gen_state;
            if (gs == null) { gs = vm.heap.resume_gen; }
            if (gs == null) { ra[0].set_undefined(); break; }
            // Clear heap.resume_gen if it points to this gs to avoid stale refs
            if (vm.heap.resume_gen == gs) { vm.heap.resume_gen = null; }

            HObject* iterator = null;
            TVal received_val;
            received_val.set_undefined();
            bool is_resuming = (gs.delegated_iter != null);

            // State machine: YS_CALL_NEXT → call iterator.next().
            // YS_YIELD → suspend and yield `received_val` to the outer caller.
            // When ys_yield_raw=true, received_val is a full IteratorResult object
            // and must be passed as-is (not wrapped).  When false, wrap in {value:..., done:false}.
            const uint YS_CALL_NEXT = 0;
            const uint YS_YIELD     = 1;
            uint ys_state = YS_CALL_NEXT;
            bool ys_yield_raw = false; // set to true when yielding the inner next() result directly

            // Helper: read a property from `obj` with accessor support.
            // Invokes the getter via call_fn when the property is an accessor.
            // Returns false and throws if the getter throws; sets *out_val.
            // Returns true with out_val=undefined when the property is absent.
            // is_present is set to false only when completely absent.
            // (Inlined at each call site to allow early break/return.)

            if (is_resuming) {
                iterator = (HObject*)gs.delegated_iter;

                if (gs.resume_kind == THROW) {
                    // ES2020 §14.4.14 step 5.b: GetMethod(iterator, "throw")
                    HString* throw_key = intern_string(vm, "throw");
                    TVal throw_method; throw_method.set_undefined();
                    bool throw_has_method = false;
                    {
                        hobject::PropLookupResult thr_res = iterator.get_prop_or_accessor_proto(throw_key, true);
                        if (thr_res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                            TVal acc_fn = thr_res.acc.accessor_fn;
                            if (!acc_fn.is_undefined() && !acc_fn.is_null()) {
                                TVal thr_this; thr_this.set_object(iterator);
                                throw_method = vm.heap.call_fn(vm, acc_fn, null, 0, thr_this);
                                if (vm.has_error) {
                                    TVal err_ta = vm.return_val; vm.has_error = false; vm.heap.has_error = false;
                                    gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                                    if (!vm_throw_value(vm, err_ta, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                        gs.delegated_iter = null; gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                                        vm.has_error = true; vm.heap.has_error = true;
                                        vm.heap.tval_copy_ref(&vm.return_val, &err_ta);
                                    }
                                    ds.needs_restart = true; break;
                                }
                                throw_has_method = throw_method.is_lightfunc() ||
                                    (throw_method.is_object() && throw_method.get_heapptr() != null &&
                                     ((HObject*)throw_method.get_heapptr()).is_callable());
                            }
                        } else if (thr_res.kind == hobject::PropLookupKind.PROP_DATA) {
                            throw_method = thr_res.data_val;
                            throw_has_method = !throw_method.is_undefined() && !throw_method.is_null() &&
                                (throw_method.is_lightfunc() ||
                                 (throw_method.is_object() && throw_method.get_heapptr() != null &&
                                  ((HObject*)throw_method.get_heapptr()).is_callable()));
                        }
                        // PROP_NOT_FOUND: throw_has_method stays false
                    }

                    if (!throw_has_method) {
                        // No throw method: IteratorClose(iterator, NormalCompletion) then TypeError
                        // (§14.4.14 step 5.b.iii). Errors from IteratorClose propagate (? prefix).
                        gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                        HString* ret_key_ic = intern_string(vm, "return");
                        bool ric_break = false;
                        {
                            hobject::PropLookupResult ret_ic_res = iterator.get_prop_or_accessor_proto(ret_key_ic, true);
                            TVal ret_ic_method; ret_ic_method.set_undefined();
                            bool ret_ic_callable = false;
                            if (ret_ic_res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                                TVal acc_fn2 = ret_ic_res.acc.accessor_fn;
                                if (!acc_fn2.is_undefined() && !acc_fn2.is_null()) {
                                    TVal ric_this; ric_this.set_object(iterator);
                                    ret_ic_method = vm.heap.call_fn(vm, acc_fn2, null, 0, ric_this);
                                    if (vm.has_error) {
                                        // GetMethod threw: propagate (IteratorClose step 3: ?)
                                        TVal err_ric = vm.return_val; vm.has_error = false; vm.heap.has_error = false;
                                        gs.delegated_iter = null;
                                        if (!vm_throw_value(vm, err_ric, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                            gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                                            vm.has_error = true; vm.heap.has_error = true;
                                            vm.heap.tval_copy_ref(&vm.return_val, &err_ric);
                                        }
                                        ds.needs_restart = true; ric_break = true;
                                    } else {
                                        ret_ic_callable = ret_ic_method.is_lightfunc() ||
                                            (ret_ic_method.is_object() && ret_ic_method.get_heapptr() != null &&
                                             ((HObject*)ret_ic_method.get_heapptr()).is_callable());
                                    }
                                }
                            } else if (ret_ic_res.kind == hobject::PropLookupKind.PROP_DATA) {
                                ret_ic_method = ret_ic_res.data_val;
                                ret_ic_callable = !ret_ic_method.is_undefined() && !ret_ic_method.is_null() &&
                                    (ret_ic_method.is_lightfunc() ||
                                     (ret_ic_method.is_object() && ret_ic_method.get_heapptr() != null &&
                                      ((HObject*)ret_ic_method.get_heapptr()).is_callable()));
                            }
                            if (!ric_break && ret_ic_callable) {
                                // IteratorClose step 5: Call(return, iterator)
                                TVal ric_this2; ric_this2.set_object(iterator);
                                vm.heap.call_fn(vm, ret_ic_method, null, 0, ric_this2);
                                if (vm.has_error) {
                                    // IteratorClose step 7: innerResult throws → propagate
                                    TVal err_ric2 = vm.return_val; vm.has_error = false; vm.heap.has_error = false;
                                    gs.delegated_iter = null;
                                    if (!vm_throw_value(vm, err_ric2, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                        gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                                        vm.has_error = true; vm.heap.has_error = true;
                                        vm.heap.tval_copy_ref(&vm.return_val, &err_ric2);
                                    }
                                    ds.needs_restart = true; ric_break = true;
                                }
                            }
                        }
                        if (ric_break) { break; }
                        // IteratorClose completed without error → throw TypeError for protocol violation
                        gs.delegated_iter = null;
                        if (!vm_throw_error(vm, vm.heap.type_err_proto, "The iterator does not provide a 'throw' method",
                                            ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                            return VM_ERROR~;
                        }
                        ds.needs_restart = true; break;
                    }

                    // Call iterator.throw(exception)
                    TVal itv; itv.set_object(iterator);
                    TVal[1] targs; targs[0] = gs.throw_value;
                    TVal tresult = vm.heap.call_fn(vm, throw_method, &targs, 1, itv);
                    if (vm.has_error) {
                        TVal err_tc = vm.return_val; vm.has_error = false; vm.heap.has_error = false;
                        gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                        if (!vm_throw_value(vm, err_tc, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            gs.delegated_iter = null; gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                            vm.has_error = true; vm.heap.has_error = true;
                            vm.heap.tval_copy_ref(&vm.return_val, &err_tc);
                        }
                        ds.needs_restart = true; break;
                    }
                    if (!tresult.is_object() || tresult.get_heapptr() == null) {
                        gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                        if (!vm_throw_error(vm, vm.heap.type_err_proto, "Iterator result is not an object",
                                            ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        ds.needs_restart = true; break;
                    }
                    // Read done/value from throw() result with accessor support
                    HObject* tro = (HObject*)tresult.get_heapptr();
                    HString* dk = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                    HString* vk = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                    bool td = false;
                    {
                        hobject::PropLookupResult td_res = tro.get_prop_or_accessor_proto(dk, true);
                        TVal td_val; td_val.set_undefined();
                        if (td_res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                            TVal acc_fn3 = td_res.acc.accessor_fn;
                            if (!acc_fn3.is_undefined() && !acc_fn3.is_null()) {
                                TVal td_this; td_this.set_object(tro);
                                td_val = vm.heap.call_fn(vm, acc_fn3, null, 0, td_this);
                                if (vm.has_error) {
                                    TVal err_td = vm.return_val; vm.has_error = false; vm.heap.has_error = false;
                                    gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                                    if (!vm_throw_value(vm, err_td, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                        gs.delegated_iter = null; gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                                        vm.has_error = true; vm.heap.has_error = true;
                                        vm.heap.tval_copy_ref(&vm.return_val, &err_td);
                                    }
                                    ds.needs_restart = true; break;
                                }
                            }
                        } else if (td_res.kind == hobject::PropLookupKind.PROP_DATA) {
                            td_val = td_res.data_val;
                        }
                        td = builtins::builtin_to_boolean(&td_val);
                    }
                    gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                    if (td) {
                        // done=true: read value and return it as the yield* result
                        TVal tv; tv.set_undefined();
                        {
                            hobject::PropLookupResult tv_res = tro.get_prop_or_accessor_proto(vk, true);
                            if (tv_res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                                TVal acc_fn4 = tv_res.acc.accessor_fn;
                                if (!acc_fn4.is_undefined() && !acc_fn4.is_null()) {
                                    TVal tv_this; tv_this.set_object(tro);
                                    tv = vm.heap.call_fn(vm, acc_fn4, null, 0, tv_this);
                                    if (vm.has_error) {
                                        TVal err_tv = vm.return_val; vm.has_error = false; vm.heap.has_error = false;
                                        if (!vm_throw_value(vm, err_tv, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                            gs.delegated_iter = null; gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                                            vm.has_error = true; vm.heap.has_error = true;
                                            vm.heap.tval_copy_ref(&vm.return_val, &err_tv);
                                        }
                                        ds.needs_restart = true; break;
                                    }
                                }
                            } else if (tv_res.kind == hobject::PropLookupKind.PROP_DATA) {
                                tv = tv_res.data_val;
                            }
                        }
                        gs.delegated_iter = null; vm.heap.tval_copy_ref(&ra[0], &tv); break;
                    }
                    // done=false: yield tresult directly (GeneratorYield(innerResult))
                    received_val = tresult; ys_yield_raw = true; ys_state = YS_YIELD;
                }
                else if (gs.resume_kind == RETURN) {
                    // ES2020 §14.4.14 step 5.c: GetMethod(iterator, "return")
                    HString* ret_key = intern_string(vm, "return");
                    TVal ret_method; ret_method.set_undefined();
                    bool ret_has_method = false;
                    {
                        hobject::PropLookupResult ret_res = iterator.get_prop_or_accessor_proto(ret_key, true);
                        if (ret_res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                            TVal acc_fn5 = ret_res.acc.accessor_fn;
                            if (!acc_fn5.is_undefined() && !acc_fn5.is_null()) {
                                TVal ret_this; ret_this.set_object(iterator);
                                ret_method = vm.heap.call_fn(vm, acc_fn5, null, 0, ret_this);
                                if (vm.has_error) {
                                    TVal err_ra2 = vm.return_val; vm.has_error = false; vm.heap.has_error = false;
                                    gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                                    if (!vm_throw_value(vm, err_ra2, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                        gs.delegated_iter = null; gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                                        vm.has_error = true; vm.heap.has_error = true;
                                        vm.heap.tval_copy_ref(&vm.return_val, &err_ra2);
                                    }
                                    ds.needs_restart = true; break;
                                }
                                ret_has_method = ret_method.is_lightfunc() ||
                                    (ret_method.is_object() && ret_method.get_heapptr() != null &&
                                     ((HObject*)ret_method.get_heapptr()).is_callable());
                            }
                        } else if (ret_res.kind == hobject::PropLookupKind.PROP_DATA) {
                            ret_method = ret_res.data_val;
                            ret_has_method = !ret_method.is_undefined() && !ret_method.is_null() &&
                                (ret_method.is_lightfunc() ||
                                 (ret_method.is_object() && ret_method.get_heapptr() != null &&
                                  ((HObject*)ret_method.get_heapptr()).is_callable()));
                        }
                    }

                    if (!ret_has_method) {
                        // §14.4.14 step 5.c.iii: "If return is undefined, return Completion(received)."
                        // Inject a RETURN completion into the outer generator body so any enclosing
                        // finally block runs before the generator actually completes.
                        gs.delegated_iter = null;
                        TVal no_ret_val = gs.return_value;
                        Catcher* no_ret_cat = (Catcher*)ds.act.cat;
                        if (no_ret_cat != null && no_ret_cat.finally_pc != null) {
                            no_ret_cat.return_val = no_ret_val;
                            if (!(no_ret_cat.flags & CATCHER_FLAG_PENDING_RETURN)) {
                                no_ret_cat.flags |= CATCHER_FLAG_PENDING_RETURN | CATCHER_FLAG_PENDING_RETURN_GEN;
                                ds.curr_pc = no_ret_cat.finally_pc;
                                ds.act.curr_pc = ds.curr_pc;
                            }
                            ds.needs_restart = true; break;
                        }
                        // No finally: complete the generator now
                        vm_complete_generator_return(ds, &no_ret_val);
                        break;
                    }

                    // Call iterator.return(value)
                    TVal itv2; itv2.set_object(iterator);
                    TVal[1] rargs; rargs[0] = gs.return_value;
                    TVal rresult = vm.heap.call_fn(vm, ret_method, &rargs, 1, itv2);
                    if (vm.has_error) {
                        TVal err_rc = vm.return_val; vm.has_error = false; vm.heap.has_error = false;
                        gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                        if (!vm_throw_value(vm, err_rc, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            gs.delegated_iter = null; gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                            vm.has_error = true; vm.heap.has_error = true;
                            vm.heap.tval_copy_ref(&vm.return_val, &err_rc);
                        }
                        ds.needs_restart = true; break;
                    }
                    if (!rresult.is_object() || rresult.get_heapptr() == null) {
                        gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                        if (!vm_throw_error(vm, vm.heap.type_err_proto, "Iterator result is not an object",
                                            ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        ds.needs_restart = true; break;
                    }
                    // Read done from return() result with accessor support
                    HObject* rro2 = (HObject*)rresult.get_heapptr();
                    HString* dk2 = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                    HString* vk2 = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                    bool rd = false;
                    {
                        hobject::PropLookupResult rd_res = rro2.get_prop_or_accessor_proto(dk2, true);
                        TVal rd_val; rd_val.set_undefined();
                        if (rd_res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                            TVal acc_fn6 = rd_res.acc.accessor_fn;
                            if (!acc_fn6.is_undefined() && !acc_fn6.is_null()) {
                                TVal rd_this; rd_this.set_object(rro2);
                                rd_val = vm.heap.call_fn(vm, acc_fn6, null, 0, rd_this);
                                if (vm.has_error) {
                                    TVal err_rd = vm.return_val; vm.has_error = false; vm.heap.has_error = false;
                                    gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                                    if (!vm_throw_value(vm, err_rd, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                        gs.delegated_iter = null; gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                                        vm.has_error = true; vm.heap.has_error = true;
                                        vm.heap.tval_copy_ref(&vm.return_val, &err_rd);
                                    }
                                    ds.needs_restart = true; break;
                                }
                            }
                        } else if (rd_res.kind == hobject::PropLookupKind.PROP_DATA) {
                            rd_val = rd_res.data_val;
                        }
                        rd = builtins::builtin_to_boolean(&rd_val);
                    }
                    gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                    if (rd) {
                        // ES2020 §14.4.14 step 5.c.ii.7: done=true — read value and return it
                        TVal rv2; rv2.set_undefined();
                        {
                            hobject::PropLookupResult rv2_res = rro2.get_prop_or_accessor_proto(vk2, true);
                            if (rv2_res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                                TVal acc_fn7b = rv2_res.acc.accessor_fn;
                                if (!acc_fn7b.is_undefined() && !acc_fn7b.is_null()) {
                                    TVal rv2_this; rv2_this.set_object(rro2);
                                    rv2 = vm.heap.call_fn(vm, acc_fn7b, null, 0, rv2_this);
                                    if (vm.has_error) {
                                        TVal err_rv2 = vm.return_val; vm.has_error = false; vm.heap.has_error = false;
                                        if (!vm_throw_value(vm, err_rv2, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                            gs.delegated_iter = null; gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                                            vm.has_error = true; vm.heap.has_error = true;
                                            vm.heap.tval_copy_ref(&vm.return_val, &err_rv2);
                                        }
                                        ds.needs_restart = true; break;
                                    }
                                }
                            } else if (rv2_res.kind == hobject::PropLookupKind.PROP_DATA) {
                                rv2 = rv2_res.data_val;
                            }
                        }
                        // ES2020 §14.4.14 step 5.c.ii.6: delegate's .return() completed (done:true)
                        // — outer generator returns rv2, routing through any enclosing finally.
                        gs.delegated_iter = null;
                        Catcher* ys_ret_cat = (Catcher*)ds.act.cat;
                        if (ys_ret_cat != null && ys_ret_cat.finally_pc != null) {
                            ys_ret_cat.return_val = rv2;
                            if (!(ys_ret_cat.flags & CATCHER_FLAG_PENDING_RETURN)) {
                                ys_ret_cat.flags |= CATCHER_FLAG_PENDING_RETURN | CATCHER_FLAG_PENDING_RETURN_GEN;
                                ds.curr_pc = ys_ret_cat.finally_pc;
                                ds.act.curr_pc = ds.curr_pc;
                            }
                            ds.needs_restart = true; break;
                        }
                        vm_complete_generator_return(ds, &rv2);
                        break;
                    }
                    // done=false: yield rresult directly (GeneratorYield(innerReturnResult))
                    received_val = rresult; ys_yield_raw = true; ys_state = YS_YIELD;
                }
                else {
                    // NEXT resume — use resume value for iterator.next()
                    received_val = gs.resume_value; gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                }
            } else {
                // First entry: GetIterator(iterable) — get @@iterator method with accessor support.
                HString* iter_sym = vm.heap.iterator_symbol;
                if (iter_sym == null) iter_sym = builtins::ensure_iterator_symbol(vm.heap);
                if (iter_sym == null) {
                    HString* tstr = typeof_string(vm, &iterable_val);
                    if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not iterable", tstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return VM_ERROR~;
                    }
                    ds.needs_restart = true; break;
                }
                TVal iter_method; iter_method.set_undefined();
                bool has_method = false;
                {
                    hobject::PropLookupResult im_res;
                    im_res.kind = hobject::PropLookupKind.PROP_NOT_FOUND;
                    if (iterable_val.is_object() && iterable_val.get_heapptr() != null) {
                        im_res = ((HObject*)iterable_val.get_heapptr()).get_prop_or_accessor_proto(iter_sym, true);
                    } else if (iterable_val.is_string() && vm.heap.string_proto != null) {
                        im_res = vm.heap.string_proto.get_prop_or_accessor_proto(iter_sym, true);
                    } else if (iterable_val.is_boolean() && vm.heap.bool_proto != null) {
                        im_res = vm.heap.bool_proto.get_prop_or_accessor_proto(iter_sym, true);
                    } else if ((iterable_val.is_number() || iterable_val.is_fastint()) && vm.heap.number_proto != null) {
                        im_res = vm.heap.number_proto.get_prop_or_accessor_proto(iter_sym, true);
                    }
                    if (im_res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                        TVal acc_fn8 = im_res.acc.accessor_fn;
                        if (!acc_fn8.is_undefined() && !acc_fn8.is_null()) {
                            iter_method = vm.heap.call_fn(vm, acc_fn8, null, 0, iterable_val);
                            if (vm.has_error) {
                                TVal err_gi = vm.return_val; vm.has_error = false; vm.heap.has_error = false;
                                if (!vm_throw_value(vm, err_gi, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    gs.delegated_iter = null; gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                                    vm.has_error = true; vm.heap.has_error = true;
                                    vm.heap.tval_copy_ref(&vm.return_val, &err_gi);
                                }
                                ds.needs_restart = true; break;
                            }
                            has_method = iter_method.is_lightfunc() ||
                                (iter_method.is_object() && iter_method.get_heapptr() != null &&
                                 ((HObject*)iter_method.get_heapptr()).is_callable());
                        }
                    } else if (im_res.kind == hobject::PropLookupKind.PROP_DATA) {
                        iter_method = im_res.data_val;
                        has_method = iter_method.is_lightfunc() ||
                            (iter_method.is_object() && iter_method.get_heapptr() != null &&
                             ((HObject*)iter_method.get_heapptr()).is_callable());
                    }
                }
                if (!has_method) {
                    HString* tstr2 = typeof_string(vm, &iterable_val);
                    if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not iterable", tstr2.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return VM_ERROR~;
                    }
                    ds.needs_restart = true; break;
                }
                // Call iterable[@@iterator]() to obtain the iterator object
                TVal itv3 = vm.heap.call_fn(vm, iter_method, null, 0, iterable_val);
                if (vm.has_error) {
                    TVal err_ic = vm.return_val; vm.has_error = false; vm.heap.has_error = false;
                    if (!vm_throw_value(vm, err_ic, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                        vm.has_error = true; vm.heap.has_error = true;
                        vm.heap.tval_copy_ref(&vm.return_val, &err_ic);
                    }
                    ds.needs_restart = true; break;
                }
                // GetIterator step 3: iterator must be an Object (ES7.4.1)
                if (!itv3.is_object() || itv3.get_heapptr() == null) {
                    if (!vm_throw_error(vm, vm.heap.type_err_proto, "GetIterator: result is not an object",
                                        ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return VM_ERROR~;
                    }
                    ds.needs_restart = true; break;
                }
                iterator = (HObject*)itv3.get_heapptr();
                gs.delegated_iter = iterator;
            }

            // State YS_CALL_NEXT: call iterator.next(received) and check done.
            // Only access "value" when done=true (for the return value of yield*)
            // or to yield forward (done=false case).
            if (ys_state == YS_CALL_NEXT) {
                HString* nk = intern_string(vm, "next");
                // Get the .next method — accessor support
                TVal nm; nm.set_undefined(); bool nm_callable = false;
                {
                    hobject::PropLookupResult nk_res = iterator.get_prop_or_accessor_proto(nk, true);
                    if (nk_res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                        TVal acc_fn9 = nk_res.acc.accessor_fn;
                        if (!acc_fn9.is_undefined() && !acc_fn9.is_null()) {
                            TVal nk_this; nk_this.set_object(iterator);
                            nm = vm.heap.call_fn(vm, acc_fn9, null, 0, nk_this);
                            if (vm.has_error) {
                                TVal err_nk = vm.return_val; vm.has_error = false; vm.heap.has_error = false;
                                if (!vm_throw_value(vm, err_nk, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    gs.delegated_iter = null; gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                                    vm.has_error = true; vm.heap.has_error = true;
                                    vm.heap.tval_copy_ref(&vm.return_val, &err_nk);
                                }
                                ds.needs_restart = true; break;
                            }
                            nm_callable = nm.is_lightfunc() ||
                                (nm.is_object() && nm.get_heapptr() != null &&
                                 ((HObject*)nm.get_heapptr()).is_callable());
                        }
                    } else if (nk_res.kind == hobject::PropLookupKind.PROP_DATA) {
                        nm = nk_res.data_val;
                        nm_callable = nm.is_lightfunc() ||
                            (nm.is_object() && nm.get_heapptr() != null &&
                             ((HObject*)nm.get_heapptr()).is_callable());
                    }
                }
                if (!nm_callable) { ra[0].set_undefined(); break; }

                TVal itv4; itv4.set_object(iterator);
                TVal[1] nargs; nargs[0] = received_val;
                TVal nres = vm.heap.call_fn(vm, nm, &nargs, 1, itv4);
                if (vm.has_error) {
                    TVal err_nr = vm.return_val; vm.has_error = false; vm.heap.has_error = false;
                    if (!vm_throw_value(vm, err_nr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        gs.delegated_iter = null; gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                        vm.has_error = true; vm.heap.has_error = true;
                        vm.heap.tval_copy_ref(&vm.return_val, &err_nr);
                    }
                    ds.needs_restart = true; break;
                }
                if (!nres.is_object() || nres.get_heapptr() == null) {
                    if (!vm_throw_error(vm, vm.heap.type_err_proto, "Iterator result is not an object",
                                        ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return VM_ERROR~;
                    }
                    ds.needs_restart = true; break;
                }
                HObject* nro = (HObject*)nres.get_heapptr();
                HString* dk3 = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                HString* vk3 = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                // Read done with accessor support
                bool nd = false;
                {
                    hobject::PropLookupResult nd_res = nro.get_prop_or_accessor_proto(dk3, true);
                    TVal nd_val; nd_val.set_undefined();
                    if (nd_res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                        TVal acc_fnA = nd_res.acc.accessor_fn;
                        if (!acc_fnA.is_undefined() && !acc_fnA.is_null()) {
                            TVal nd_this; nd_this.set_object(nro);
                            nd_val = vm.heap.call_fn(vm, acc_fnA, null, 0, nd_this);
                            if (vm.has_error) {
                                TVal err_nd = vm.return_val; vm.has_error = false; vm.heap.has_error = false;
                                if (!vm_throw_value(vm, err_nd, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    gs.delegated_iter = null; gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                                    vm.has_error = true; vm.heap.has_error = true;
                                    vm.heap.tval_copy_ref(&vm.return_val, &err_nd);
                                }
                                ds.needs_restart = true; break;
                            }
                        }
                    } else if (nd_res.kind == hobject::PropLookupKind.PROP_DATA) {
                        nd_val = nd_res.data_val;
                    }
                    nd = builtins::builtin_to_boolean(&nd_val);
                }
                if (nd) {
                    // done=true: read value (IteratorValue) and return it as yield* result
                    TVal nv; nv.set_undefined();
                    {
                        hobject::PropLookupResult nv_res = nro.get_prop_or_accessor_proto(vk3, true);
                        if (nv_res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                            TVal acc_fnB = nv_res.acc.accessor_fn;
                            if (!acc_fnB.is_undefined() && !acc_fnB.is_null()) {
                                TVal nv_this; nv_this.set_object(nro);
                                nv = vm.heap.call_fn(vm, acc_fnB, null, 0, nv_this);
                                if (vm.has_error) {
                                    TVal err_nv = vm.return_val; vm.has_error = false; vm.heap.has_error = false;
                                    if (!vm_throw_value(vm, err_nv, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                        gs.delegated_iter = null; gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                                        vm.has_error = true; vm.heap.has_error = true;
                                        vm.heap.tval_copy_ref(&vm.return_val, &err_nv);
                                    }
                                    ds.needs_restart = true; break;
                                }
                            }
                        } else if (nv_res.kind == hobject::PropLookupKind.PROP_DATA) {
                            nv = nv_res.data_val;
                        }
                    }
                    gs.delegated_iter = null; gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                    vm.heap.tval_copy_ref(&ra[0], &nv); break;
                }
                // done=false: yield the whole nres IteratorResult directly to the outer caller
                // (spec §14.4.14 step 5.a.iv: GeneratorYield(innerResult))
                received_val = nres; ys_yield_raw = true; ys_state = YS_YIELD;
            }

            // State YS_YIELD: suspend the generator and yield received_val to the outer caller.
            // When ys_yield_raw=true, received_val is already a full IteratorResult object
            // (from the inner iterator's next() result — spec §14.4.14 step 5.a.iv).
            // Otherwise wrap it in {value: received_val, done: false}.
            if (ys_state == YS_YIELD) {
                for (uint i = 0; i < gs.num_regs; i++) {
                    vm.heap.tval_copy_ref(&gs.saved_regs[i], &ds.act.bottom[i]);
                }
                gs.saved_pc = ds.curr_pc - 1;
                gs.var_env = ds.act.var_env; gs.lex_env = ds.act.lex_env; gs.cat = ds.act.cat;
                vm.heap.tval_copy_ref(&gs.this_binding, &ds.act.this_binding);
                gs.state = GEN_SUSPENDED_YIELD;
                $if $feature(HEAP_VERIFY):
                    vm.heap.verify_roots("after_yield_star");
                    vm.heap.verify_tval_array(gs.saved_regs, gs.num_regs, "yield_star_saved_regs");
                $endif
                vm.heap.resume_gen = null; vm.heap.did_yield = true;
                if (vm.activation_count > 0) {
                    Activation* p_act = &vm.activations[vm.activation_count - 1];
                    TVal p_wrapped;
                    if (ys_yield_raw) {
                        // Pass the inner iterator's result object directly
                        p_wrapped = received_val;
                    } else {
                        // Wrap value in a new IteratorResult {value: received_val, done: false}
                        HObject*? p_robj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                        if (try p_robj = p_robj_raw) {
                            p_robj.prototype = vm.heap.object_proto;
                            HString* p_vk = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                            if (p_vk != null) p_robj.put_prop(p_vk, received_val, hobject::PROP_FLAGS_WEC);
                            HString* p_dk = (HString*)vm.heap.strs[heap::BuiltinStr.DONE]; TVal p_dt; p_dt.set_boolean(false);
                            if (p_dk != null) p_robj.put_prop(p_dk, p_dt, hobject::PROP_FLAGS_WEC); p_wrapped.set_object(p_robj);
                        } else { p_wrapped = received_val; }
                    }
                    // retval is null when this activation was entered via the
                    // re-entrant call_fn path (e.g. an outer YIELD_STAR calling
                    // this generator's .next() directly) — the result is read
                    // back via vm.return_val in that case instead.
                    if (p_act.retval != null) {
                        vm.heap.tval_copy_ref(p_act.retval, &p_wrapped);
                    } else {
                        vm.heap.tval_copy_ref(&vm.return_val, &p_wrapped);
                    }
                    vm.activation_count--;
                    // activation_count can hit 0 here for the same
                    // re-entrant-call reason — halt like the plain RET path.
                    if (vm.activation_count == 0) {
                        ds.halt = true;
                        ds.halt_value = vm.return_val;
                        return (TVal){};
                    }
                    Activation* p_caller = &vm.activations[vm.activation_count - 1];
                    vm.valstack_bottom = p_caller.bottom;
                    if (p_caller.func != null) {
                        CompiledFunction* p_cfunc = (CompiledFunction*)p_caller.func;
                        vm.valstack_top = p_caller.bottom + p_cfunc.num_regs;
                    }
                }
                ds.needs_restart = true;
            }
            return (TVal){};
        }

        case Opcode.GEN_START: {
            // GEN_START — emitted by the compiler after all parameter initialization
            // in a generator function.  Reached only during the initial call (when
            // heap.gen_initial_gs is non-null).  Saves the current activation state
            // into the pre-allocated GeneratorState, writes the generator object to
            // the caller's result register, then returns to the caller.
            //
            // On subsequent resumes via .next()/.throw()/.return(), saved_pc already
            // points past this instruction so GEN_START is never re-executed.
            GeneratorState* gs = vm.heap.gen_initial_gs;
            if (gs == null) {
                // Should not happen in well-formed code, but be defensive.
                return (TVal){};
            }

            // Save register state (the param-init code may have written to regs).
            TVal* cur_regs = ds.act.bottom;
            for (uint i = 0; i < gs.num_regs; i++) {
                vm.heap.tval_copy_ref(&gs.saved_regs[i], &cur_regs[i]);
            }

            // saved_pc points to the instruction AFTER GEN_START (ds.curr_pc was
            // already incremented before dispatch).
            gs.saved_pc = ds.curr_pc;
            gs.var_env = ds.act.var_env;
            gs.lex_env = ds.act.lex_env;
            gs.cat = ds.act.cat;
            vm.heap.tval_copy_ref(&gs.this_binding, &ds.act.this_binding);
            gs.state = GEN_SUSPENDED_START;
            gs.resume_kind = NEXT;

            // Write the generator object to the caller's result register.
            // Use ds.act.retval rather than gen_initial_retval: if ensure_valstack_grow
            // ran during param-init, it relocates all activation retval pointers but
            // gen_initial_retval would be stale.  ds.act.retval is always up to date.
            HObject* gen_obj_g = (HObject*)vm.heap.gen_initial_obj;
            TVal* retval_g = ds.act.retval;

            // ES2015 §25.3.3 step 1: OrdinaryCreateFromConstructor(functionObject,
            // "%GeneratorPrototype%") — resolved here (after FunctionDeclaration-
            // Instantiation/param-init has run, per EvaluateBody step ordering) so
            // a default parameter's side effect on functionObject.prototype is
            // observed (generator-created-after-decl-inst.js). Falls back to the
            // shared Generator.prototype set at creation time if .prototype isn't
            // an object at this point.
            if (gen_obj_g != null && gs.func_obj != null) {
                HObject* func_obj_g = (HObject*)gs.func_obj;
                HString* gen_proto_key_g = (HString*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE];
                TVal? gen_proto_val_g = func_obj_g.get_prop_proto(gen_proto_key_g);
                if (try gpv_g = gen_proto_val_g) {
                    if (gpv_g.is_object() && gpv_g.get_heapptr() != null) {
                        gen_obj_g.prototype = (HObject*)gpv_g.get_heapptr();
                    } else {
                        gen_obj_g.prototype = vm.heap.generator_proto;
                    }
                }
            }

            // Restore any enclosing generator's initial-call state that was
            // saved when this inner generator was called during an outer
            // generator's param-init phase (e.g. `*outer([[,] = innerGen()])`).
            if (vm.heap.gen_init_stack_depth > 0) {
                uint depth = vm.heap.gen_init_stack_depth - 1;
                vm.heap.gen_initial_gs = vm.heap.gen_init_stack_gs[depth];
                vm.heap.gen_initial_obj = vm.heap.gen_init_stack_obj[depth];
                vm.heap.gen_initial_retval = vm.heap.gen_init_stack_retval[depth];
                vm.heap.gen_init_stack_gs[depth] = null;
                vm.heap.gen_init_stack_obj[depth] = null;
                vm.heap.gen_init_stack_retval[depth] = null;
                vm.heap.gen_init_stack_depth = depth;
            } else {
                vm.heap.gen_initial_gs = null;
                vm.heap.gen_initial_obj = null;
                vm.heap.gen_initial_retval = null;
            }

            if (gen_obj_g != null && retval_g != null) {
                TVal gen_tv;
                gen_tv.set_object(gen_obj_g);
                vm.heap.tval_copy_ref(retval_g, &gen_tv);
            }

            // Pop the generator's activation and return to the caller.
            decref_callee_regs(vm, ds.act);
            vm.activation_count--;

            if (vm.activation_count == 0) {
                // Caller was the top-level — return the generator object.
                if (retval_g != null) {
                    ds.halt = true;
                    ds.halt_value = *retval_g;
                }
                return (TVal){};
            }

            // Restore caller activation.
            Activation* caller_act_g = &vm.activations[vm.activation_count - 1];
            vm.valstack_bottom = caller_act_g.bottom;
            if (caller_act_g.func != null) {
                CompiledFunction* caller_func_g = (CompiledFunction*)caller_act_g.func;
                vm.valstack_top = caller_act_g.bottom + caller_func_g.num_regs;
                if (caller_func_g != vm.current_func) {
                    vm.current_func = caller_func_g;
                    ds.code_base = caller_func_g.code;
                    ds.code_count = caller_func_g.code_count;
                    ds.code_end = ds.code_base + ds.code_count;
                    ds.constants = caller_func_g.constants;
                    ds.ic_base = (hobject::ICEntry*)caller_func_g.ic_entries;
                    ds.var_ic_base = (hobject::VarICEntry*)caller_func_g.var_ic_entries;
                    ds.nregs = caller_func_g.num_regs;
                }
            }
            ds.act = caller_act_g;
            ds.curr_pc = caller_act_g.curr_pc;
            ds.regs_base = caller_act_g.bottom;
            ds.needs_restart = true;
            return (TVal){};
        }

        default:
            return (TVal){};
    }
    return (TVal){};
}


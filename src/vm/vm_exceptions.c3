module boomkat::vm;

import boomkat::types;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::env;
import boomkat::builtins;
import boomkat::re_bindings;
import std::math;

// ============================================================================
// Exception handling
// ============================================================================
// Sub-dispatch for TRY, ENDTRY, THROW, CATCH, FINALLY, ENDFINALLY opcodes.
fn TVal? dispatch_exceptions(Dispatch* ds, Opcode op, TVal* ra, TVal* rb, TVal* rc, DecodedInsn insn) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.TRY: {
            // Encoding: A = flags (bit0=catch, bit1=finally)
            //           BC = catch_offset (from TRY PC to CATCH instruction)
            // The next instruction word is the finally slot (make_finally_slot).
            uint flags = insn.a;
            uint catch_offset = insn.get_bc();

            // Read the jump slot (next instruction word) for finally_offset
            Instruction jump_slot = *ds.curr_pc;
            ds.curr_pc++;
            ds.act.curr_pc = ds.curr_pc;
            uint finally_offset = bytecode::try_finally_offset(jump_slot);

            // Compute absolute handler PCs
            Instruction* base_pc = ds.curr_pc - 2; // back to TRY instruction
            Instruction* catch_pc = base_pc + (int)catch_offset;
            Instruction* finally_pc = (finally_offset != 0)
                ? (base_pc + (int)finally_offset)
                : null;

            // Allocate catcher
            Catcher* cat = catcher_acquire(vm.heap);
            if (cat == null) {
                // Out of memory, so skip the catcher and let the try body run unprotected
                break;
            }
            cat.parent = (Catcher*)ds.act.cat;
            cat.flags = flags;
            cat.thrown_val.set_undefined();
            // Every catcher field a reader can reach before its writer runs
            // starts out valid: the GC marks return_val and ENDFINALLY reads it
            // on every completion, and alloc_func hands back recycled memory
            // that can still hold the previous owner's TVal or jump target.
            cat.return_val.set_undefined();
            cat.pending_pc = null;
            cat.catch_pc = catch_pc;
            cat.finally_pc = finally_pc;
            cat.endfinally_pc = null;
            cat.saved_lex_env = (void*)ds.act.lex_env;
            vm.heap.shade_root_env(cat.saved_lex_env);

                    ds.act.cat = (void*)cat;
            return (TVal){};
        }

        case Opcode.ENDTRY: {
            // Normal fall-through out of the try body. A catcher that owns a
            // finally block must survive until its ENDFINALLY: the finally
            // handler reads that catcher's saved_lex_env (to rebalance the lex
            // chain on abrupt entry) and pending-completion flags, and ENDFINALLY
            // pops it. Freeing it here would leave the following FINALLY reading
            // the enclosing catcher, corrupting the lex chain when an outer
            // try (e.g. a for-of iterator-close guard) sits above a block-scoped
            // destructuring whose own iterator-close finally runs on the normal
            // path. Only catchers without a finally are popped here.
            Catcher* cat = (Catcher*)ds.act.cat;
            if (cat != null && cat.finally_pc == null) {
                            ds.act.cat = (void*)cat.parent;
                catcher_release(vm.heap, cat);
            }
            return (TVal){};
        }

        case Opcode.THROW: {
            TVal thrown_val = *ra;
            if (!vm_throw_value(vm, thrown_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                vm.has_error = true;
                vm.heap.has_error = true;
                vm.heap.tval_copy_ref(&vm.heap.error_value, &thrown_val);
                vm.heap.tval_copy_ref(&vm.return_val, &thrown_val);
                return VM_ERROR~;
            }
            return (TVal){};
        }

        case Opcode.THROW_REF: {
            // Throw a ReferenceError with a constant-pool message string.
            // Format: A=unused, B=msg_const_idx (A_BC encoding).
            uint bc = insn.get_bc();
            TVal msg_tv = ds.constants[bc];
            char[] msg_str = "Cannot delete a super property";
            if (msg_tv.is_string()) {
                hstring::HString* hs = (hstring::HString*)msg_tv.get_heapptr();
                msg_str = hs.get_data();
            }
            if (!vm_throw_error(vm, vm.heap.ref_err_proto, msg_str, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                vm.has_error = true;
                vm.heap.has_error = true;
                return VM_ERROR~;
            }
            return (TVal){};
        }

        case Opcode.THROW_SYNTAX: {
            // Throw a SyntaxError with a constant-pool message string.
            // Format: A=unused, B=msg_const_idx (A_BC encoding). Used for
            // GlobalDeclarationInstantiation checks that must surface as a
            // runtime throw (ECMA-262 GlobalDeclarationInstantiation), e.g. a top-level `let`/`const`
            // colliding with a restricted global name.
            uint bc = insn.get_bc();
            TVal msg_tv = ds.constants[bc];
            char[] msg_str = "Invalid or unexpected token";
            if (msg_tv.is_string()) {
                hstring::HString* hs = (hstring::HString*)msg_tv.get_heapptr();
                msg_str = hs.get_data();
            }
            if (!vm_throw_error(vm, vm.heap.syntax_err_proto, msg_str, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                vm.has_error = true;
                vm.heap.has_error = true;
                return VM_ERROR~;
            }
            return (TVal){};
        }

        case Opcode.CATCH: {
            // Read the thrown exception from the nearest catcher
            Catcher* cat = (Catcher*)ds.act.cat;
            if (cat != null) {
                // An exceptional entry skipped the try block's POP_LEX ops, so
                // rebalance the lex chain to the TRY-entry level.
                if (cat.saved_lex_env != null) {
                    ds.act.lex_env = (env::EnvRecord*)cat.saved_lex_env;
                    ds.vm.heap.shade_root_env(ds.act.lex_env);
                }
                vm.heap.tval_copy_ref(ra, &cat.thrown_val);
                track_heap_store(ds.act, ra, (uint)insn.a);

                // Clear thrown value
                cat.thrown_val.set_undefined();

                // The throw has been caught, so clear the VM error flags.
                // Without this, a phantom vm.has_error from a deep throw
                // persists and causes phantom errors in subsequent call_fn
                // invocations (e.g., ToPrimitive valueOf/toString).
                vm.has_error = false;
                vm.heap.has_error = false;

                // If no finally handler, pop the catcher now.
                // If there IS a finally, keep the catcher on the chain so that
                // re-throws in the catch block are handled by the finally handler.
                if (cat.finally_pc == null) {
                                    ds.act.cat = (void*)cat.parent;
                    catcher_release(vm.heap, cat);
                }
            } else {
                ra.set_undefined();
            }
            return (TVal){};
        }

        case Opcode.FINALLY:
            // Marker at catcher.finally_pc. Flags the catcher IN_FINALLY so
            // vm_throw_value skips it for a throw inside the finally block.
            {
                Catcher* fin_cat = (Catcher*)ds.act.cat;
                if (fin_cat != null) {
                    fin_cat.flags |= CATCHER_FLAG_IN_FINALLY;
                    // Cache this finally's ENDFINALLY so a `return` in the body
                    // can jump there. ds.curr_pc is just past this marker.
                    if (fin_cat.endfinally_pc == null) {
                        fin_cat.endfinally_pc =
                            find_matching_endfinally(ds.curr_pc - 1, ds.code_end);
                    }
                    // Clear CATCH_ENABLED. A throw inside the finally must not
                    // reach this try's catch clause, which would re-run the finally.
                    fin_cat.flags &= ~CATCHER_FLAG_CATCH_ENABLED;
                    // Exceptional entry skipped POP_LEX ops (harmless no-op on
                    // the balanced normal-flow entry).
                    if (fin_cat.saved_lex_env != null) {
                        ds.act.lex_env = (env::EnvRecord*)fin_cat.saved_lex_env;
                        ds.vm.heap.shade_root_env(ds.act.lex_env);
                    }
                }
            }
            return (TVal){};

        case Opcode.ENDFINALLY: {
            Catcher* cat = (Catcher*)ds.act.cat;
            // A return in finally cannot replace host termination. Nested
            // cleanup finally blocks without a pending throw complete normally.
            if (vm.heap.uncatchable_throw && cat != null && !cat.thrown_val.is_undefined()) {
                if (!vm_throw_error(vm, vm.heap.err_proto, "interrupted", ds.act,
                        &ds.curr_pc, &ds.needs_restart)) return VM_ERROR~;
                return (TVal){};
            }
            if (cat != null && (cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0) {
                bool has_pending_exc = (!cat.thrown_val.is_undefined());
                TVal pending_exc_val = cat.thrown_val;
                bool has_pending_ret = (cat.flags & CATCHER_FLAG_PENDING_RETURN) != 0;
                bool has_pending_ret_gen = (cat.flags & CATCHER_FLAG_PENDING_RETURN_GEN) != 0;
                TVal saved_ret_val = cat.return_val;
                bool has_pending_break = (cat.flags & CATCHER_FLAG_PENDING_BREAK) != 0;
                bool has_pending_continue = (cat.flags & CATCHER_FLAG_PENDING_CONTINUE) != 0;
                Instruction* saved_pending_pc = cat.pending_pc;
                Catcher* parent_cat = (Catcher*)cat.parent;

                ds.act.cat = (void*)parent_cat;
                catcher_release(vm.heap, cat);

                if (has_pending_ret) {
                    // When the parent catcher also has a finally,
                    // propagate the pending return through it before completing.
                    if (parent_cat != null && parent_cat.finally_pc != null
                        && (parent_cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0) {
                        parent_cat.return_val = saved_ret_val;
                        vm.heap.shade_root_tval(parent_cat.return_val);
                        parent_cat.flags |= CATCHER_FLAG_PENDING_RETURN;
                        if (has_pending_ret_gen) parent_cat.flags |= CATCHER_FLAG_PENDING_RETURN_GEN;
                        // If the parent's finally is already running, jumping to it
                        // again would loop forever. Its own ENDFINALLY completes the return.
                        if ((parent_cat.flags & CATCHER_FLAG_IN_FINALLY) == 0) {
                            ds.curr_pc = parent_cat.finally_pc;
                            ds.act.curr_pc = ds.curr_pc;
                        }
                        break;
                    }
                    if (has_pending_ret_gen) {
                        // Return deferred from a generator body (RET_GEN, RETUNDEF_GEN,
                        // or a .return()/.throw() injected via LOAD_RESUME).
                        TVal gval = saved_ret_val;
                        vm_complete_generator_return(ds, &gval);
                        return (TVal){};
                    }
                    TVal val = saved_ret_val;
                    Activation* callee_act = &vm.activations[vm.activation_count - 1];
                    TVal* callee_result = callee_act.retval;
                    if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) record_constructor_capacity(callee_act);

                    bool val_pinned = false;
                    if (val.is_heap_allocated() && val.get_heapptr() != null) {
                        ((HeapHeader*)val.get_heapptr()).incref();
                        val_pinned = true;
                    }

                    free_catcher_chain(vm, callee_act);
                    decref_callee_regs(vm, callee_act);

                                    vm.activation_count--;
                                    vm.gc_root_frame_count_changed();

                    // Async function: resolve the promise with the return value and
                    // write the promise to callee_result, as the RET path in
                    // vm_execute.c3 does. promise_resolve_with_value adopts a returned
                    // thenable (ECMA-262 AsyncFunctionStart); a bare settle would not.
                    if ((callee_act.flags & ACT_FLAG_ASYNC) != 0 && callee_act.async_promise != null) {
                        builtins::promise_resolve_with_value(callee_act.async_promise, val, vm.heap, (void*)vm);
                        // Release pin on original return value (promise now holds a ref)
                        if (val_pinned) {
                            vm.heap.decref_tval(&val);
                        }
                        // val now owns a reference to the promise (set_object
                        // increfs). The writeback below consumes it or releases it
                        // via val_pinned. The birth ref belongs to
                        // callee_act.async_promise; callee_result holds its own.
                        val.set_object(callee_act.async_promise);
                        val_pinned = true;
                    }

                    if (vm.activation_count == 0) {
                        // call_fn resume path: no caller frame to receive the value.
                        // Halt with vm.return_val. Returning it from dispatch_exceptions
                        // would not propagate, since Vm.run only checks faults.
                        vm.heap.tval_copy_ref(&vm.return_val, &val);
                        if (val_pinned) vm.heap.decref_tval(&val);
                        callee_act.release_callee(vm.heap);
                        ds.halt = true;
                        ds.halt_value = vm.return_val;
                        return (TVal){};
                    }
                    if (callee_result != null) {
                        // Borrowed callee (CALL_VAR from a global binding): callee_result
                        // aliases a closure this frame never incref'd, so overwrite it raw
                        // and never decref it. The plain RET path does the same.
                        bool ret_borrowed = (callee_act.flags & ACT_FLAG_BORROWED_CALLEE) != 0;
                        // ECMA-262 [[Construct]]: a non-object return yields 'this'. The
                        // inner RET set PENDING_RETURN and skipped this logic, since
                        // a finally intercepted the return.
                        if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
                            if (val.is_object()) {
                                if (!val.is_heap_allocated()) {
                                    if (!ret_borrowed && callee_result.is_heap_allocated()) {
                                        vm.heap.decref_tval(callee_result);
                                    }
                                    *callee_result = val;
                                } else if (val_pinned) {
                                    if (!ret_borrowed) vm.heap.decref_tval(callee_result);
                                    *callee_result = val;
                                    val_pinned = false;
                                } else if (ret_borrowed) {
                                    ((HeapHeader*)val.get_heapptr()).incref();
                                    *callee_result = val;
                                } else {
                                    vm.heap.tval_copy_ref(callee_result, &val);
                                }
                            } else {
                                // Non-object return (undefined) → use 'this' binding
                                if (!ret_borrowed && callee_result.is_heap_allocated()) {
                                    vm.heap.decref_tval(callee_result);
                                }
                                // A borrowed slot is overwritten raw, so take the reference here.
                                if (ret_borrowed && callee_act.this_binding.is_heap_allocated()
                                    && callee_act.this_binding.get_heapptr() != null) {
                                    ((HeapHeader*)callee_act.this_binding.get_heapptr()).incref();
                                }
                                *callee_result = callee_act.this_binding;
                            }
                        } else {
                            // Non-constructor: copy the return value.
                            if (!val.is_heap_allocated()) {
                                if (!ret_borrowed && callee_result.is_heap_allocated()) {
                                    vm.heap.decref_tval(callee_result);
                                }
                                *callee_result = val;
                            } else if (val_pinned) {
                                if (!ret_borrowed) vm.heap.decref_tval(callee_result);
                                *callee_result = val;
                                val_pinned = false;
                            } else if (ret_borrowed) {
                                ((HeapHeader*)val.get_heapptr()).incref();
                                *callee_result = val;
                            } else {
                                vm.heap.tval_copy_ref(callee_result, &val);
                            }
                        }
                    }
                    if (val_pinned) vm.heap.decref_tval(&val);
                    callee_act.release_refs(vm.heap);
                    ds.act = &vm.activations[vm.activation_count - 1];
                    vm.valstack_bottom = ds.act.bottom;
                    vm.valstack_top = ds.act.caller_valstack_top;
                    // Record the write-back in the caller's heap watermark, as the
                    // plain RET path does. Otherwise a heap reference parked in an
                    // untracked caller register would be read later as a live register
                    // by whatever frame next occupies that valstack range.
                    if ((val.is_heap_allocated() || (callee_act.flags & ACT_FLAG_CONSTRUCT) != 0)
                        && callee_result != null && callee_result >= ds.act.bottom
                        && callee_result.is_heap_allocated()) {
                        track_heap_store(ds.act, callee_result, (uint)(callee_result - ds.act.bottom));
                    }
                    CompiledFunction* caller_func = (CompiledFunction*)ds.act.func;
                    if (caller_func != vm.current_func) {
                        vm.current_func = caller_func;
                        ds.code_base = caller_func.code;
                        ds.code_count = caller_func.code_count;
                        ds.code_end = ds.code_base + ds.code_count;
                        ds.constants = caller_func.constants;
                        ds.bind_caches(caller_func);
                        ds.nregs = caller_func.num_regs;
                    }
                    ds.curr_pc = ds.act.curr_pc;
                    ds.regs_base = ds.act.bottom;
                    break;
                }

                if (has_pending_break || has_pending_continue) {
                    // Route the break/continue through the parent's finally first,
                    // unless that finally is already running; then jump directly.
                    if (parent_cat != null && parent_cat.finally_pc != null
                        && (parent_cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0
                        && (parent_cat.flags & CATCHER_FLAG_IN_FINALLY) == 0) {
                        parent_cat.pending_pc = saved_pending_pc;
                        if (has_pending_break) {
                            parent_cat.flags |= CATCHER_FLAG_PENDING_BREAK;
                        } else {
                            parent_cat.flags |= CATCHER_FLAG_PENDING_CONTINUE;
                        }
                        ds.curr_pc = parent_cat.finally_pc;
                        ds.act.curr_pc = ds.curr_pc;
                        break;
                    }
                    // All finally blocks have run; jump to the saved target.
                    ds.curr_pc = saved_pending_pc;
                    ds.act.curr_pc = ds.curr_pc;
                    break;
                }

                if (has_pending_exc) {
                    // Re-throw the pending exception
                    if (!vm_throw_value(vm, pending_exc_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &pending_exc_val);
                    }
                }
            }
            return (TVal){};
        }

        default:
            return (TVal){};
    }
    return (TVal){};
}


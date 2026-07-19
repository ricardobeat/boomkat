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
// vm_exceptions — exception handling
// ============================================================================
/// Sub-dispatch for TRY, ENDTRY, THROW, CATCH, FINALLY, ENDFINALLY opcodes.
fn TVal? dispatch_exceptions(Dispatch* ds, Opcode op, TVal* ra, TVal* rb, TVal* rc, Instruction insn) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.TRY: {
            // Encoding: A = flags (bit0=catch, bit1=finally)
            //           BC = catch_offset (from TRY PC to CATCH instruction)
            // The next instruction word stores finally_offset in its BC field.
            uint flags = insn.a;
            uint catch_offset = insn.get_bc();

            // Read the jump slot (next instruction word) for finally_offset
            Instruction jump_slot = *ds.curr_pc;
            ds.curr_pc++;
            ds.act.curr_pc = ds.curr_pc;
            uint finally_offset = jump_slot.get_bc(); // BC field stores finally offset

            // Compute absolute handler PCs
            Instruction* base_pc = ds.curr_pc - 2; // back to TRY instruction
            Instruction* catch_pc = base_pc + (int)catch_offset;
            Instruction* finally_pc = (finally_offset != 0)
                ? (base_pc + (int)finally_offset)
                : null;

            // Allocate catcher
            Catcher* cat = (Catcher*)vm.heap.alloc_func(vm.heap.heap_udata, Catcher::size);
            if (cat == null) {
                // Out of memory — skip catcher creation, try block will run unprotected
                break;
            }
            cat.parent = (Catcher*)ds.act.cat;
            cat.flags = flags;
            cat.thrown_val.set_undefined();
            cat.catch_pc = catch_pc;
            cat.finally_pc = finally_pc;
            cat.saved_lex_env = (void*)ds.act.lex_env;

            ds.act.cat = (void*)cat;
            return (TVal){};
        }

        case Opcode.ENDTRY: {
            // Pop the catcher (normal exit from try block)
            Catcher* cat = (Catcher*)ds.act.cat;
            if (cat != null) {
                ds.act.cat = (void*)cat.parent;
                vm.heap.free_func(vm.heap.heap_udata, cat);
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
            // runtime throw (ES6+ §15.1.8), e.g. a top-level `let`/`const`
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
                // Exceptional entry skipped the try block's POP_LEX ops —
                // rebalance the lex chain to the TRY-entry level.
                if (cat.saved_lex_env != null) {
                    ds.act.lex_env = (env::EnvRecord*)cat.saved_lex_env;
                }
                vm.heap.tval_copy_ref(ra, &cat.thrown_val);
                track_heap_store(ds.act, ra, (uint)insn.a);

                // Clear thrown value
                cat.thrown_val.set_undefined();

                // Clear VM-level error flags — the throw has been caught.
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
                    vm.heap.free_func(vm.heap.heap_udata, cat);
                }
            } else {
                ra.set_undefined();
            }
            return (TVal){};
        }

        case Opcode.FINALLY:
            // No-op marker — the catcher's finally_pc points here.
            // When entered via normal fall-through (after catch or via jump),
            // there may or may not be a catcher on the chain.
            // Mark the catcher as "in finally" so that vm_throw_value skips it
            // if a throw occurs inside the finally block (prevents infinite loop).
            {
                Catcher* fin_cat = (Catcher*)ds.act.cat;
                if (fin_cat != null) {
                    fin_cat.flags |= CATCHER_FLAG_IN_FINALLY;
                    // Exceptional entry skipped POP_LEX ops (harmless no-op on
                    // the balanced normal-flow entry).
                    if (fin_cat.saved_lex_env != null) {
                        ds.act.lex_env = (env::EnvRecord*)fin_cat.saved_lex_env;
                    }
                }
            }
            return (TVal){};

        case Opcode.ENDFINALLY: {
            Catcher* cat = (Catcher*)ds.act.cat;
            if (cat != null && (cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0) {
                // Save pending state before freeing the catcher
                bool has_pending_exc = (!cat.thrown_val.is_undefined());
                TVal pending_exc_val = cat.thrown_val;
                bool has_pending_ret = (cat.flags & CATCHER_FLAG_PENDING_RETURN) != 0;
                bool has_pending_ret_gen = (cat.flags & CATCHER_FLAG_PENDING_RETURN_GEN) != 0;
                TVal saved_ret_val = cat.return_val;
                bool has_pending_break = (cat.flags & CATCHER_FLAG_PENDING_BREAK) != 0;
                bool has_pending_continue = (cat.flags & CATCHER_FLAG_PENDING_CONTINUE) != 0;
                Instruction* saved_pending_pc = cat.pending_pc;
                Catcher* parent_cat = (Catcher*)cat.parent;

                // Pop the finally catcher
                ds.act.cat = (void*)parent_cat;
                vm.heap.free_func(vm.heap.heap_udata, cat);

                if (has_pending_ret) {
                    // Check if the parent catcher also has a finally — if so,
                    // propagate the pending return through it before completing.
                    if (parent_cat != null && parent_cat.finally_pc != null
                        && (parent_cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0) {
                        parent_cat.return_val = saved_ret_val;
                        parent_cat.flags |= CATCHER_FLAG_PENDING_RETURN;
                        if (has_pending_ret_gen) parent_cat.flags |= CATCHER_FLAG_PENDING_RETURN_GEN;
                        // If the parent's finally is already executing (this
                        // ENDFINALLY is completing a try/finally nested inside
                        // it), redirecting to parent.finally_pc again would
                        // loop forever. Just record the pending return on the
                        // parent (its own eventual ENDFINALLY will complete
                        // it) and fall through to keep executing here.
                        if ((parent_cat.flags & CATCHER_FLAG_IN_FINALLY) == 0) {
                            ds.curr_pc = parent_cat.finally_pc;
                            ds.act.curr_pc = ds.curr_pc;
                        }
                        break;
                    }
                    if (has_pending_ret_gen) {
                        // Return was deferred from a generator body (RET_GEN/
                        // RETUNDEF_GEN, or a .return()/.throw() completion
                        // injected via LOAD_RESUME) — complete via the
                        // generator-aware path instead of a plain RET.
                        TVal gval = saved_ret_val;
                        vm_complete_generator_return(ds, &gval);
                        return (TVal){};
                    }
                    // Complete the return that was intercepted by the finally block.
                    TVal val = saved_ret_val;
                    Activation* callee_act = &vm.activations[vm.activation_count - 1];
                    TVal* callee_result = callee_act.retval;

                    bool val_pinned = false;
                    if (val.is_heap_allocated() && val.get_heapptr() != null) {
                        ((HeapHeader*)val.get_heapptr()).incref();
                        val_pinned = true;
                    }

                    decref_callee_regs(vm, callee_act);

                    vm.activation_count--;

                    if (vm.activation_count == 0) {
                        vm.heap.tval_copy_ref(&vm.return_val, &val);
                        if (val_pinned) vm.heap.decref_tval(&val);
                        return vm.return_val;
                    }
                    if (callee_result != null) {
                        // ES2015 §9.2.2 step 13: constructor returning a
                        // non-Object must use 'this' binding.  Derived
                        // non-object non-undefined was already converted to
                        // TypeError by the inner RET opcode's
                        // derived_return_error flag.  Here we handle the
                        // case where the return was intercepted by a finally
                        // block: the inner RET set PENDING_RETURN but never
                        // ran the constructor return logic.
                        if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
                            if (val.is_object()) {
                                if (!val.is_heap_allocated()) {
                                    if (callee_result.is_heap_allocated()) {
                                        vm.heap.decref_tval(callee_result);
                                    }
                                    *callee_result = val;
                                } else if (val_pinned) {
                                    vm.heap.decref_tval(callee_result);
                                    *callee_result = val;
                                    val_pinned = false;
                                } else {
                                    vm.heap.tval_copy_ref(callee_result, &val);
                                }
                            } else {
                                // Non-object return (undefined) → use 'this' binding
                                if (callee_result.is_heap_allocated()) {
                                    vm.heap.decref_tval(callee_result);
                                }
                                *callee_result = callee_act.this_binding;
                            }
                        } else {
                            // Non-constructor path: plain return value copy
                            if (!val.is_heap_allocated()) {
                                if (callee_result.is_heap_allocated()) {
                                    vm.heap.decref_tval(callee_result);
                                }
                                *callee_result = val;
                            } else if (val_pinned) {
                                vm.heap.decref_tval(callee_result);
                                *callee_result = val;
                                val_pinned = false;
                            } else {
                                vm.heap.tval_copy_ref(callee_result, &val);
                            }
                        }
                    }
                    if (val_pinned) vm.heap.decref_tval(&val);
                    ds.act = &vm.activations[vm.activation_count - 1];
                    vm.valstack_bottom = ds.act.bottom;
                    vm.valstack_top = ds.act.caller_valstack_top;
                    CompiledFunction* caller_func = (CompiledFunction*)ds.act.func;
                    if (caller_func != vm.current_func) {
                        vm.current_func = caller_func;
                        ds.code_base = caller_func.code;
                        ds.code_count = caller_func.code_count;
                        ds.code_end = ds.code_base + ds.code_count;
                        ds.constants = caller_func.constants;
                        ds.ic_base = (hobject::ICEntry*)caller_func.ic_entries;
                        ds.var_ic_base = (hobject::VarICEntry*)caller_func.var_ic_entries;
                        ds.nregs = caller_func.num_regs;
                    }
                    ds.curr_pc = ds.act.curr_pc;
                    ds.regs_base = ds.act.bottom;
                    break;
                }

                if (has_pending_break || has_pending_continue) {
                    // Check if the parent catcher also has a finally — if so,
                    // propagate the pending break/continue through it first.
                    // But if the parent's finally is already executing (this
                    // ENDFINALLY is completing a try/finally nested inside
                    // it), redirecting to parent.finally_pc again would loop
                    // forever — the jump target already lies inside that
                    // still-active finally, so just go there directly.
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
                    // All finally blocks have run — complete the break/continue
                    // by jumping to the saved target.
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


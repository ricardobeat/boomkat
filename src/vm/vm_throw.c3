module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::hobject;
import duktape::hstring;
import duktape::heap;
import duktape::builtins;

// ============================================================================
// Catcher chain — helper functions
// ============================================================================

/// If the activation being unwound is a generator/async body, transition its
/// GeneratorState to GEN_COMPLETED (ES6 §25.3.3.2: a generator whose body
/// throws is completed). Without this a later .next()/.throw()/.return() sees a
/// stale GEN_EXECUTING state and wrongly reports "Generator is executing".
fn void vm_complete_gen_on_unwind(Vm* vm, Activation* act) {
    if (act.async_gen_state == null) return;
    // Async functions settle their Promise (reject) via their own throw path;
    // don't pre-complete their GeneratorState here.
    if ((act.flags & ACT_FLAG_ASYNC) != 0) return;
    GeneratorState* gs = (GeneratorState*)act.async_gen_state;
    gs.state = GEN_COMPLETED;
    if (vm.heap.resume_gen == act.async_gen_state) {
        vm.heap.resume_gen = null;
    }
    act.async_gen_state = null;
}

/// Walk the catcher chain and throw a value.
/// Searches the full activation chain, unwinding intermediate activations
/// when a catcher is found in a parent activation.
///
/// If `local_only` is true, only searches the current activation (does not
/// walk parent activations). Used by generator LOAD_RESUME THROW to determine
/// whether the generator itself has a catcher without finding the caller's.
///
/// Returns true if a catcher was found (execution continues after restart).
/// Returns false if no catcher was found anywhere in the call stack
/// (caller should return VM_ERROR~).
fn bool vm_throw_value(Vm* vm, TVal thrown_val, Activation* act,
                       Instruction** curr_pc, bool* needs_restart,
                       bool local_only = false) {
    // Walk through current and parent activations
    Activation* search_act = act;
    for (;;) {
        Catcher* cat = (Catcher*)search_act.cat;
        while (cat != null) {
            if (cat.flags & CATCHER_FLAG_CATCH_ENABLED) {
                // If this is not the innermost catcher (i.e., we skipped
                // catchers with IN_FINALLY), pop the skipped catchers so
                // that the CATCH handler reads from the correct catcher.
                if (cat != (Catcher*)search_act.cat) {
                    // Pop catchers from the chain up to (but not including) this one.
                    while ((Catcher*)search_act.cat != cat) {
                        Catcher* skip = (Catcher*)search_act.cat;
                        search_act.cat = (void*)skip.parent;
                        vm.heap.free_func(vm.heap.heap_udata, skip);
                    }
                }
                vm.heap.tval_copy_ref(&cat.thrown_val, &thrown_val);
                cat.flags &= ~CATCHER_FLAG_CATCH_ENABLED;
                *curr_pc = cat.catch_pc;
                search_act.curr_pc = *curr_pc;
                *needs_restart = true;

                // If we found the catcher in a parent activation, unwind
                // intermediate activations so the VM resumes at the right level.
                if (search_act != act) {
                    // Pop all activations down to the one with the catcher,
                    // completing any generator body we unwind through.
                    while (vm.activation_count > 0
                           && &vm.activations[vm.activation_count - 1] != search_act) {
                        vm_complete_gen_on_unwind(vm, &vm.activations[vm.activation_count - 1]);
                        vm.activation_count--;
                    }
                    // Restore the valstack_bottom for the target activation
                    vm.valstack_bottom = search_act.bottom;
                    // Restore valstack_top to match the target function's nregs
                    if (search_act.func != null) {
                        CompiledFunction* target_func = (CompiledFunction*)search_act.func;
                        uint target_nregs = target_func.num_regs;
                        vm.valstack_top = search_act.bottom + target_nregs;
                    }
                }
                return true;
            }
            if ((cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0
                && (cat.flags & CATCHER_FLAG_IN_FINALLY) == 0) {
                // Skip catchers whose finally block is currently being executed
                // (CATCHER_FLAG_IN_FINALLY is set).  Without this, a throw
                // inside a finally block would re-enter the same finally block,
                // causing an infinite loop.
                vm.heap.tval_copy_ref(&cat.thrown_val, &thrown_val);
                *curr_pc = cat.finally_pc;
                search_act.curr_pc = *curr_pc;
                *needs_restart = true;

                if (search_act != act) {
                    while (vm.activation_count > 0
                           && &vm.activations[vm.activation_count - 1] != search_act) {
                        vm_complete_gen_on_unwind(vm, &vm.activations[vm.activation_count - 1]);
                        vm.activation_count--;
                    }
                    vm.valstack_bottom = search_act.bottom;
                    if (search_act.func != null) {
                        CompiledFunction* target_func = (CompiledFunction*)search_act.func;
                        uint target_nregs = target_func.num_regs;
                        vm.valstack_top = search_act.bottom + target_nregs;
                    }
                }
                return true;
            }
            // If this catcher has IN_FINALLY, it means we're inside its finally
            // block and a throw occurred.  Pop it and continue to the next handler.
            if (cat.flags & CATCHER_FLAG_IN_FINALLY) {
                Catcher* next = (Catcher*)cat.parent;
                search_act.cat = (void*)next;
                vm.heap.free_func(vm.heap.heap_udata, cat);
                cat = next;
                continue;
            }
            cat = cat.parent;
        }
        if (local_only) break;  // Don't walk parent activations
        // No catcher in this activation — the throw unwinds past it. If it is an
        // async function body, the throw does not propagate to the caller: it
        // rejects the function's Promise (which the caller already received) and
        // the async frame returns normally. Absorb it here.
        if ((search_act.flags & ACT_FLAG_ASYNC) != 0 && search_act.async_promise != null
            && !local_only) {
            HObject* prom = search_act.async_promise;
            // Pop every activation above and including the async frame.
            while (vm.activation_count > 0
                   && &vm.activations[vm.activation_count - 1] != search_act) {
                vm_complete_gen_on_unwind(vm, &vm.activations[vm.activation_count - 1]);
                vm.activation_count--;
            }
            if (search_act.async_gen_state != null
                && vm.heap.resume_gen == search_act.async_gen_state) {
                vm.heap.resume_gen = null;
            }
            decref_callee_regs(vm, search_act);
            if (vm.activation_count > 0) vm.activation_count--;  // pop the async frame

            builtins::promise_settle(prom, builtins::PROMISE_REJECTED, &thrown_val, vm.heap);
            builtins::promise_trigger_reactions(prom, vm.heap, (void*)vm);

            if (vm.activation_count == 0) {
                // Top-level async call: no caller to resume. Deliver undefined.
                TVal undef; undef.set_undefined();
                vm.heap.tval_copy_ref(&vm.return_val, &undef);
                *needs_restart = true;
                return true;
            }
            // Resume the caller; it already holds the Promise in its result reg.
            Activation* caller = &vm.activations[vm.activation_count - 1];
            vm.valstack_bottom = caller.bottom;
            if (caller.func != null) {
                CompiledFunction* cf = (CompiledFunction*)caller.func;
                vm.valstack_top = caller.bottom + cf.num_regs;
            }
            *curr_pc = caller.curr_pc;
            *needs_restart = true;
            return true;
        }
        // Generator body: complete it before moving to the caller.
        vm_complete_gen_on_unwind(vm, search_act);
        search_act = search_act.parent;
        if (search_act == null) break;
    }
    return false;
}

/// Record an uncaught exception in the VM and return the VM_ERROR~ sentinel.
///
/// When an opcode allocates an error and calls vm_throw_value but no catcher
/// is found, the VM must surface the error to the embedder (CLI, batch
/// runner, host app) rather than silently swallowing it. This helper mirrors
/// the THROW opcode's uncaught-exception handling (vm.c3:8098-8107) so every
/// opcode that can fail vm_throw_value behaves consistently.
fn TVal? vm_uncaught_error(Vm* vm, TVal* err_val) {
    vm.has_error = true;
    vm.heap.has_error = true;
    vm.heap.tval_copy_ref(&vm.heap.error_value, err_val);
    vm.heap.tval_copy_ref(&vm.return_val, err_val);
    return VM_ERROR~;
}

/// Create and throw an error object with the given prototype and message.
/// Returns true if a catcher caught the error (caller continues execution).
/// Returns false if uncaught (caller should `return VM_ERROR~`).
/// On allocation failure, also returns false.
fn bool vm_throw_error(Vm* vm, HObject* proto, char[] msg, Activation* act,
                       Instruction** curr_pc, bool* needs_restart) {
    HObject*? err_obj = vm.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_obj) {
        err.prototype = proto;
        if (msg.len > 0) {
            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
            HString* msg_str = intern_string(vm, msg);
            TVal msg_tv;
            msg_tv.set_string(msg_str);
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        }
        TVal err_val;
        err_val.set_object(err);
        if (vm_throw_value(vm, err_val, act, curr_pc, needs_restart)) {
            return true;
        }
        (void)vm_uncaught_error(vm, &err_val);
        return false;
    }
    return false;
}

/// Splice a format string containing `%s` placeholders and NUL-terminated
/// `char*` args into `buf`, returning the bytes written (truncated to fit).
/// All error-message formats used here are `%s`-only, so this fully replaces
/// the previous snprintf without pulling in a printf implementation.
fn int splice_fmt(char[] buf, char* fmt, char*[] args) @local {
    int out = 0;
    int cap = (int)buf.len;
    int ai = 0;
    for (int fi = 0; fmt[fi] != 0; fi++) {
        if (fmt[fi] == '%' && fmt[fi + 1] == 's' && ai < args.len) {
            char* a = args[ai++];
            fi++;  // consume 's'
            if (a != null) {
                for (int j = 0; a[j] != 0; j++) {
                    if (out >= cap) return out;
                    buf[out++] = a[j];
                }
            }
            continue;
        }
        if (out >= cap) return out;
        buf[out++] = fmt[fi];
    }
    return out;
}

/// Create and throw an error with a single %s formatted message.
fn bool vm_throw_error_fmt(Vm* vm, HObject* proto, char* fmt, char* arg,
                           Activation* act, Instruction** curr_pc, bool* needs_restart) {
    char[types::ERROR_MSG_BUF] buf;
    char*[1] args = { arg };
    int len = splice_fmt(&buf, fmt, args[..]);
    return vm_throw_error(vm, proto, buf[:len], act, curr_pc, needs_restart);
}

/// Create and throw an error with two %s formatted arguments.
fn bool vm_throw_error_fmt2(Vm* vm, HObject* proto, char* fmt, char* arg1, char* arg2,
                            Activation* act, Instruction** curr_pc, bool* needs_restart) {
    char[types::ERROR_MSG_BUF] buf;
    char*[2] args = { arg1, arg2 };
    int len = splice_fmt(&buf, fmt, args[..]);
    return vm_throw_error(vm, proto, buf[:len], act, curr_pc, needs_restart);
}

/// Helper to get index from valstack base to a pointer
fn uint byte_offset(TVal* base, TVal* ptr) @inline {
    return (uint)(ptr - base);
}

/// Helper to get TVal* from valstack base and index.
fn TVal* ptr_from_byteoff(TVal* base, uint idx) @inline {
    return base + idx;
}

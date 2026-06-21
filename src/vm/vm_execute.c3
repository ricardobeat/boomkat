module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;
import duktape::re_bindings;
import std::io;
import std::math;
import libc;

/// Implementation of Heap.call_fn — calls a JS function with N arguments through the VM.
fn TVal vm_call_fn_impl(void* vm_ptr, TVal func, TVal* args, uint nargs, TVal this_val) {
    Vm* vm = (Vm*)vm_ptr;
    TVal undef;
    undef.set_undefined();

    // Case 1: lightfunc — dispatch directly via BuiltinContext
    if (func.is_lightfunc()) {
        uint fn_idx = (uint)(usz)func.get_heapptr();

        // Temporary register layout: [this, arg0, arg1, ...]
        // Use stack-allocated array for up to 8 args
        uint total = 1 + nargs;
        if (total > 16) total = 16;

        TVal[16] temp_regs;
        temp_regs[0] = this_val;
        for (uint i = 0; i < nargs && i < 16; i++) {
            temp_regs[1 + i] = args[i];
        }

        builtins::BuiltinContext ctx;
        ctx.vm = vm;
        ctx.regs = &temp_regs;
        ctx.base_reg = 1;
        ctx.argc = (ushort)nargs;
        ctx.result = &temp_regs[0];
        ctx.heap = vm.heap;
        ctx.this_val = this_val;
        ctx.is_constructor = false;
        ctx.needs_re_dispatch = false;
        ctx.re_nargs = 0;
        ctx.global_env = vm.global_env;
        ctx.should_throw = false;
        ctx.callee_obj = null;

        builtins::dispatch_builtin(fn_idx, &ctx);
        return *ctx.result;
    }

    // Case 2: HObject with builtin_fn_index — dispatch via BuiltinContext
    if (func.is_object() && func.get_heapptr() != null) {
        HObject* hobj = (HObject*)func.get_heapptr();
        if (hobj != null && hobj.is_callable() && hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN) {
            uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;

            // Builtins may modify callee/this via base_reg-2 and base_reg-1.
            // Layout: [callee, this, arg0, arg1, ...]
            uint total = 2 + nargs;
            if (total > 18) total = 18;

            TVal[18] temp_regs;
            temp_regs[0] = func;       // callee at index 0 (base_reg - 2)
            temp_regs[1] = this_val;   // this at index 1   (base_reg - 1)
            for (uint i = 0; i < nargs && i < 16; i++) {
                temp_regs[2 + i] = args[i];
            }

            builtins::BuiltinContext ctx;
            ctx.vm = vm;
            ctx.regs = &temp_regs;
            ctx.base_reg = 2;          // base_reg - 2 = 0 = callee, base_reg - 1 = 1 = this
            ctx.argc = (ushort)nargs;
            ctx.result = &temp_regs[0];
            ctx.heap = vm.heap;
            ctx.this_val = this_val;
            ctx.is_constructor = false;
            ctx.needs_re_dispatch = false;
            ctx.re_nargs = 0;
            ctx.global_env = vm.global_env;
            ctx.should_throw = false;
            ctx.callee_obj = hobj;

            builtins::dispatch_builtin(fn_idx, &ctx);

            if (ctx.should_throw) {
                vm.throw_pending = true;
                vm.heap.tval_copy_ref(&vm.throw_value, &ctx.throw_value);
                return undef;
            }

            if (ctx.needs_re_dispatch) {
                // Builtin (e.g., generator .next()) modified the callee/this and
                // expects the call to be re-dispatched.
                func = temp_regs[0];
                this_val = temp_regs[1];
                // Rebuild args from temp_regs[2..] with the re-dispatched nargs
                uint new_nargs = ctx.re_nargs;
                for (uint i = 0; i < new_nargs && i < 16; i++) {
                    if (2 + i < 18) args[i] = temp_regs[2 + i];
                }
                nargs = new_nargs;
                // Fall through to Case 3
            } else {
                return *ctx.result;
            }
        }
    }

    // Case 3: compiled function on HObject
    if (func.is_object() && func.get_heapptr() != null) {
        HObject* hobj = (HObject*)func.get_heapptr();
        if (hobj != null && hobj.is_callable() && (*hobj.extra_ptr()).func.comp_func != null) {
            CompiledFunction* target = (*hobj.extra_ptr()).func.comp_func;
            uint nregs = target.num_regs;

            // Grow the valstack first (while activation_count is still the
            // caller's, so ensure_valstack_grow relocates all live pointers).
            // The callback frame is placed at the current valstack_top, above
            // all live caller registers — they are never touched.
            if (!ensure_valstack(vm, nregs)) {
                return undef;
            }

            // Save current VM state (after potential realloc)
            uint saved_act_count = vm.activation_count;
            TVal* saved_valstack_bottom = vm.valstack_bottom;
            TVal* saved_valstack_top = vm.valstack_top;
            TVal* saved_valstack = vm.valstack;
            CompiledFunction* saved_current_func = vm.current_func;
            void* saved_resume_gen = vm.heap.resume_gen;  // preserve across nested generator calls

            Activation[MAX_CALLS] saved_acts;
            libc::memcpy(&saved_acts, &vm.activations, saved_act_count * Activation::size);

            TVal* frame = vm.valstack_top;

            // Set up activation[0] for the function
            Activation* act = &vm.activations[0];
            vm.activation_count = 1;
            EnvRecord* cfn_var_env = (*hobj.extra_ptr()).func.var_env;
            if (try fv_cfn = env::env_create_function_scope(vm.heap, (*hobj.extra_ptr()).func.var_env)) { cfn_var_env = fv_cfn; }
            act.func = target;
            act.parent = null;
            act.var_env = cfn_var_env;
            act.lex_env = cfn_var_env;
            act.cat = null;
            act.curr_pc = target.code;
            act.async_promise = null;
            act.async_gen_state = null;

            // Check for generator/async resume: if heap.resume_gen is set
            // and matches this function, restore the saved PC and registers.
            bool did_resume = false;
            if (vm.heap.resume_gen != null) {
                GeneratorState* gs_r = vm.heap.resume_gen;
                if ((CompiledFunction*)gs_r.func == target) {
                    did_resume = true;
                    act.curr_pc = (Instruction*)gs_r.saved_pc;
                    act.var_env = (EnvRecord*)gs_r.var_env;
                    act.lex_env = (EnvRecord*)gs_r.lex_env;
                    act.cat = gs_r.cat;
                    // Restore saved registers instead of initializing fresh
                    $if $feature(HEAP_VERIFY):
                        vm.heap.verify_roots("before_resume_restore");
                        if (gs_r.saved_regs != null) {
                            vm.heap.verify_tval_array(gs_r.saved_regs, gs_r.num_regs, "resume_saved_regs");
                        }
                    $endif
                    for (uint i = 0; i < nregs; i++) {
                        if (gs_r.saved_regs != null) {
                            vm.heap.tval_copy_ref(&frame[i], &gs_r.saved_regs[i]);
                        } else {
                            frame[i].set_undefined();
                        }
                    }
                    // Put the resume value into register 0 (LOAD_RESUME will read it)
                    // The resume value is read by LOAD_RESUME from gs_r.resume_value
                    // into the A operand register, so no need to pre-populate frame[0].
                    // vm.heap.tval_copy_ref(&frame[0], &gs_r.resume_value);
                    // Propagate async context so RET can settle the async Promise
                    if (gs_r.async_promise != null) {
                        act.flags |= ACT_FLAG_ASYNC;
                        act.async_promise = (hobject::HObject*)gs_r.async_promise;
                    }
                    $if $feature(HEAP_VERIFY):
                        vm.heap.verify_roots("after_resume_restore");
                    $endif
                }
            }

            act.bottom = frame;
            act.retval = null;
            // Preserve any flags already set (e.g. ACT_FLAG_ASYNC for resumed async fns)
            uint preserved_flags = act.flags;
            act.flags = (target.has_direct_eval() ? ACT_FLAG_DIRECT_EVAL : 0)
                      | preserved_flags;
            act.max_heap_reg = 0;
            act.caller_valstack_top = frame + nregs;
            // Raw assign: this_val is kept alive by the caller for the duration
            // of the call; the previous activation[0].this_binding bits are
            // restored verbatim below, so refcounts stay balanced.
            act.this_binding = this_val;

            if (!did_resume) {
                for (uint i = 0; i < nregs; i++) {
                    frame[i].set_undefined();
                }
                uint copy_n = nargs < nregs ? nargs : nregs;
                for (uint i = 0; i < copy_n; i++) {
                    vm.heap.tval_copy_ref(&frame[i], &args[i]);
                }
            }
            vm.valstack_top = frame + nregs;
            vm.valstack_bottom = frame;
            vm.current_func = target;

            // Create arguments object if the function references 'arguments'
            if (target.uses_arguments()) {
                HObject*? args_obj_raw = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
                if (try args_obj = args_obj_raw) {
                    // Store arguments in dense array_part (avoids O(argc) string key allocs)
                    for (uint ai = 0; ai < nargs; ai++) {
                        args_obj.set_array_idx(ai, frame[ai]);
                    }
                    // ES5 §10.6: [[Prototype]] is Object.prototype
                    args_obj.prototype = vm.heap.object_proto;
                    // ES5 §10.6: define 'callee' property (writable, non-enumerable, configurable)
                    HString* callee_key = (HString*)vm.heap.strs[heap::BuiltinStr.CALLEE];
                    if (callee_key != null) {
                        TVal callee_tv;
                        callee_tv.set_object(hobj);
                        args_obj.put_prop(callee_key, callee_tv, hobject::PROP_FLAGS_WC);
                    }
                    // ES5 §10.6: define 'length' property (writable, non-enumerable, configurable)
                    HString* length_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    if (length_key != null) {
                        TVal length_tv;
                        length_tv.set_fastint((long)nargs);
                        args_obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);
                    }
                    // Declare 'arguments' in the function's var_env
                    HString* args_name = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
                    if (args_name != null) {
                        TVal args_tv;
                        args_tv.set_object(args_obj);
                        env::env_declare(act.var_env, args_name, args_tv);
                    }
                }
            }

            // Run the function via Vm.run (skip Vm.execute init — we already set up state)
            TVal? result_opt = Vm.run(vm);
            TVal result;
            if (try r = result_opt) {
                result = r;
            } else {
                result = vm.return_val;
            }

            // If the nested run reallocated the valstack, relocate the saved
            // absolute pointers by the same delta (the saved snapshot was not
            // covered by ensure_valstack_grow's relocation pass).
            long reloc = (char*)vm.valstack - (char*)saved_valstack;
            if (reloc != 0) {
                saved_valstack_bottom = (TVal*)((char*)saved_valstack_bottom + reloc);
                saved_valstack_top = (TVal*)((char*)saved_valstack_top + reloc);
                for (uint i = 0; i < saved_act_count; i++) {
                    saved_acts[i].bottom = (TVal*)((char*)saved_acts[i].bottom + reloc);
                    if (saved_acts[i].retval != null) {
                        saved_acts[i].retval = (TVal*)((char*)saved_acts[i].retval + reloc);
                    }
                    if (saved_acts[i].caller_valstack_top != null) {
                        saved_acts[i].caller_valstack_top = (TVal*)((char*)saved_acts[i].caller_valstack_top + reloc);
                    }
                }
            }

            // Restore VM state (caller registers were never touched)
            vm.activation_count = saved_act_count;
            vm.current_func = saved_current_func;
            libc::memcpy(&vm.activations, &saved_acts, saved_act_count * Activation::size);
            vm.valstack_bottom = saved_valstack_bottom;
            vm.valstack_top = saved_valstack_top;
            vm.heap.resume_gen = (GeneratorState*)saved_resume_gen;  // restore after nested generator

            // Drain microtasks after callback execution
            vm.heap.drain_microtasks((void*)vm);

            return result;
        }
    }

    return undef;
}

/// Print a TVal to stderr (for --trace-vm debugging).
fn void trace_print_tval(TVal* v) {
    switch (v.get_tag()) {
        case types::TValTag.UNDEFINED:  io::eprintf("undef");    break;
        case types::TValTag.NULL_VAL:   io::eprintf("null");     break;
        case types::TValTag.BOOLEAN:    io::eprintf(v.get_boolean() ? "true" : "false"); break;
        case types::TValTag.FASTINT:    io::eprintf("%d", v.get_fastint()); break;
        case types::TValTag.NUMBER:     io::eprintf("%g", v.get_number()); break;
        case types::TValTag.STRING: {
            HString* s = (HString*)v.get_heapptr();
            if (s != null) {
                char[] d = s.get_data();
                io::eprintf("\"");
                for (usz i = 0; i < d.len; i++) { io::eprintf("%c", d[i]); }
                io::eprintf("\"");
            } else { io::eprintf("(null)"); }
            break;
        }
        case types::TValTag.OBJECT: {
            HObject* o = (HObject*)v.get_heapptr();
            if (o != null) { io::eprintf("[object %d]", (int)o.flags.obj_class.ordinal); }
            else           { io::eprintf("[object (null)]"); }
            break;
        }
        default: io::eprintf("<?>"); break;
    }
}

/// Trace a single instruction before dispatch (for --trace-vm).
/// Writes to stderr so it doesn't interfere with program output.
fn void trace_instruction(Vm* vm, Instruction* ip, uint offset,
                          TVal* ra, TVal* rb, TVal* rc,
                          TVal* regs_base, Activation* act) {
    char[160] line_buf;
    usz written = ip.disassemble(line_buf[..]);
    uint end = written < (usz)line_buf.len ? (uint)written : line_buf.len;
    io::eprintf("[0x%04X] %s  | ", offset, (String)line_buf[0:end]);

    // Print register values for the operands
    ushort a = (ushort)ip.a;
    ushort b = (ushort)ip.b;
    ushort c = (ushort)ip.c;
    io::eprintf("r%d=", a); trace_print_tval(ra);
    io::eprintf(" r%d=", b); trace_print_tval(rb);
    if (c != 0 || ip.op != Opcode.NOP) {
        io::eprintf(" r%d=", c); trace_print_tval(rc);
    }
    io::eprintf("\n");
}

/// Implementation of Heap.call_handler_fn — delegates to vm_call_fn_impl.
fn TVal vm_call_handler_fn_impl(void* vm_ptr, TVal handler, TVal* arg) {
    TVal undef;
    undef.set_undefined();
    return vm_call_fn_impl(vm_ptr, handler, arg, 1, undef);
}

fn TVal? Vm.execute(Vm* vm, CompiledFunction* func) {
    // Set up initial activation (matches outer executor setup)
    Activation* entry_act = &vm.activations[0];
    vm.activation_count = 1;

    entry_act.func = func;
    entry_act.parent = null;
    entry_act.var_env = vm.global_env;
    entry_act.lex_env = vm.global_env;
    entry_act.cat = null;
    entry_act.curr_pc = func.code;  // Points into bytecode
    entry_act.bottom = vm.valstack;
    entry_act.retval = null;
    // ES5 §10.4.1: at the top level of a script in strict mode, the global `this`
    // is `undefined` (strict-only engine: always undefined).
    entry_act.flags = 0;
    if (func.has_direct_eval()) {
        entry_act.flags |= ACT_FLAG_DIRECT_EVAL;
    }

    TVal this_val;
    this_val.set_undefined();
    vm.heap.tval_copy_ref(&entry_act.this_binding, &this_val);

    // Allocate value stack slots for the function (nregs = total register count)
    uint nregs = func.num_regs;
    if (!ensure_valstack(vm, nregs)) {
        return VM_ERROR~;
    }

    // Initialize registers to undefined
    for (uint i = 0; i < nregs; i++) {
        vm.valstack[i].set_undefined();
    }
    vm.valstack_top = (TVal*)((usz)vm.valstack + (usz)nregs * TVal::size);
    vm.valstack_bottom = vm.valstack;
    // The top-level activation has no caller, but caller_valstack_top must be
    // set to a valid value so that RET restoring back to this activation
    // (after a compiled callee returns) doesn't corrupt vm.valstack_top.
    entry_act.caller_valstack_top = vm.valstack_top;

    vm.current_func = func;

    TVal? result = Vm.run(vm);

    // Drain microtask queue after top-level script execution
    vm.heap.drain_microtasks((void*)vm);

    return result;
}

/// Execute a compiled function with a specific environment (for ESM modules).
/// Same as execute() but uses the provided env for var_env/lex_env instead
/// of the global environment.
fn TVal? Vm.execute_in_env(Vm* vm, CompiledFunction* func, EnvRecord* env) {
    Activation* entry_act = &vm.activations[0];
    vm.activation_count = 1;

    entry_act.func = func;
    entry_act.parent = null;
    entry_act.var_env = env;
    entry_act.lex_env = env;
    entry_act.cat = null;
    entry_act.curr_pc = func.code;
    entry_act.bottom = vm.valstack;
    entry_act.retval = null;
    entry_act.flags = 0;
    if (func.has_direct_eval()) {
        entry_act.flags |= ACT_FLAG_DIRECT_EVAL;
    }

    TVal this_val;
    this_val.set_undefined();
    vm.heap.tval_copy_ref(&entry_act.this_binding, &this_val);

    uint nregs = func.num_regs;
    if (!ensure_valstack(vm, nregs)) {
        return VM_ERROR~;
    }

    for (uint i = 0; i < nregs; i++) {
        vm.valstack[i].set_undefined();
    }
    vm.valstack_top = (TVal*)((usz)vm.valstack + (usz)nregs * TVal::size);
    vm.valstack_bottom = vm.valstack;
    entry_act.caller_valstack_top = vm.valstack_top;

    vm.current_func = func;

    TVal? result = Vm.run(vm);

    vm.heap.drain_microtasks((void*)vm);

    return result;
}

/// Execute the bytecode dispatch loop. Assumes activation stack and registers
/// are already set up by the caller.
fn TVal? Vm.run(Vm* vm) {
    Instruction* code_base;
    uint code_count;
    TVal* constants;
    Activation* act;
    Instruction* curr_pc;
    bool needs_restart;
    hobject::ICEntry* ic_base;
    hobject::VarICEntry* var_ic_base;
    uint nregs;

    // Outer restart loop: on ECMAScript-to-ECMAScript calls, reload state
    needs_restart = true;
    for (;;) {
        if (!needs_restart) {
            break;
        }
        needs_restart = false;

        act = &vm.activations[vm.activation_count - 1];
        vm.current_func = (CompiledFunction*)act.func;
        code_base = vm.current_func.code;
        code_count = vm.current_func.code_count;
        constants = vm.current_func.constants;
        ic_base = (hobject::ICEntry*)vm.current_func.ic_entries;
        var_ic_base = (hobject::VarICEntry*)vm.current_func.var_ic_entries;
        nregs = vm.current_func.num_regs;

        curr_pc = act.curr_pc;
        Instruction* code_end = code_base + code_count;

        TVal* regs_base = act.bottom;

        // Inner dispatch loop
        for (; !needs_restart; ) {
            if (curr_pc >= code_end) {
                // Inline handle_return for fall-off-end — avoids function call overhead.
                Activation* callee_act = &vm.activations[vm.activation_count - 1];
                TVal* callee_result = callee_act.retval;

                // Decref callee registers before popping
                decref_callee_regs(vm, callee_act);

                vm.activation_count--;

                if (vm.activation_count == 0) {
                    TVal undef_val;
                    undef_val.set_undefined();
                    vm.heap.tval_copy_ref(&vm.return_val, &undef_val);
                    return vm.return_val;
                }

                Activation* caller_act = &vm.activations[vm.activation_count - 1];
                vm.valstack_bottom = caller_act.bottom;

                TVal undef_val;
                undef_val.set_undefined();
                TVal final_val = undef_val;
                if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
                    if (!final_val.is_object() || final_val.get_heapptr() == null) {
                        if (callee_act.this_binding.is_object() && callee_act.this_binding.get_heapptr() != null) {
                            final_val = callee_act.this_binding;
                        }
                    }
                }
                vm.heap.tval_copy_ref(callee_result, &final_val);

                CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;

                act = caller_act;
                vm.valstack_top = caller_act.caller_valstack_top;
                if (caller_func != vm.current_func) {
                    vm.current_func = caller_func;
                    code_base = caller_func.code;
                    code_count = caller_func.code_count;
                    code_end = code_base + code_count;
                    constants = caller_func.constants;
                    ic_base = (hobject::ICEntry*)caller_func.ic_entries;
                    var_ic_base = (hobject::VarICEntry*)caller_func.var_ic_entries;
                    nregs = caller_func.num_regs;
                }
                curr_pc = act.curr_pc;
                regs_base = act.bottom;
                continue;
            }

            Instruction insn = *curr_pc;
            curr_pc++;

            Opcode op = insn.op;

            TVal* ra = regs_base + ((uint)insn.a);
            TVal* rb = regs_base + ((uint)insn.b);
            TVal* rc = regs_base + ((uint)insn.c);

        if (@unlikely(vm.trace)) {
            trace_instruction(vm, curr_pc - 1, (uint)((curr_pc - 1) - code_base),
                              ra, rb, rc, regs_base, act);
        }

        switch (op) {

        // === LOAD / STORE ===

        case Opcode.LDREG:
            // Fast path: if source is not a heap ref (fastint, undefined, etc.),
            // skip full refcounting — only decref dst if it held a heap pointer.
            if (!rb.is_heap_allocated()) {
                if (ra.is_heap_allocated()) {
                    vm.heap.decref_tval(ra);
                }
                *ra = *rb;
            } else {
                vm.heap.tval_copy_ref(ra, rb);
                track_heap_store(act, ra, (uint)insn.a);
            }
            break;

        case Opcode.LDCONST: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                vm.heap.tval_copy_ref(ra, &constants[bc]);
            } else {
                ra.set_undefined();
            }
            break;
        }

        case Opcode.LDINT:
            ra.set_fastint((long)insn.get_sbc());
            break;

        case Opcode.LDINTX: {
            long ix_high = ra.get_fastint();
            ra.set_fastint((ix_high << 16) | (long)insn.get_bc());
            break;
        }

        case Opcode.LDUNDEF:
            ra.set_undefined();
            break;

        case Opcode.LDNULL:
            ra.set_null();
            break;

        case Opcode.LDTRUE:
            ra.set_boolean(true);
            break;

        case Opcode.LDFALSE:
            ra.set_boolean(false);
            break;

        case Opcode.LDTHIS:
            vm.heap.tval_copy_ref(ra, &act.this_binding);
            track_heap_store(act, ra, (uint)insn.a);
            break;

        // === ARITHMETIC ===

        case Opcode.ADD: {
            // ES5 §11.6.1: ToPrimitive both, then string concat or numeric add
            // Fast path: FASTINT + FASTINT — most common in arithmetic benchmarks.
            // Check this BEFORE OBJECT/STRING to avoid unnecessary tag dispatch.
            if (rb.is_fastint() && rc.is_fastint()) {
                long sum = rb.get_fastint() + rc.get_fastint();
                if (sum >= types::FASTINT_MIN && sum <= types::FASTINT_MAX) {
                    ra.set_fastint(sum);
                } else {
                    ra.set_number((double)sum);
                }
                break;
            }
            // Fast path: STRING + FASTINT or FASTINT + STRING
            // Format the integer directly into the concat buffer, avoiding
            // the intermediate HString allocation for the integer.
            if ((rb.is_string() && rc.is_fastint()) || (rb.is_fastint() && rc.is_string())) {
                HString* str;
                long int_val;
                if (rb.is_string()) {
                    str = (HString*)rb.get_heapptr();
                    int_val = rc.get_fastint();
                } else {
                    str = (HString*)rc.get_heapptr();
                    int_val = rb.get_fastint();
                }
                if (str != null) {
                    char[32] int_buf;
                    int int_len = hstring::int_to_buf(int_val, &int_buf, 32);
                    if (int_len > 0) {
                        uint s_len = str.blen;
                        uint total = s_len + (uint)int_len;
                        char[544] stack_buf;
                        char* buf;
                        bool heap_allocated = false;
                        if (total <= 544) {
                            buf = &stack_buf;
                        } else {
                            buf = (char*)vm.heap.alloc_func(vm.heap.heap_udata, total);
                            if (buf == null) { ra.set_undefined(); break; }
                            heap_allocated = true;
                        }
                        if (rb.is_string()) {
                            libc::memcpy(buf, str.get_cstr(), s_len);
                            libc::memcpy(buf + s_len, &int_buf, (usz)int_len);
                        } else {
                            libc::memcpy(buf, &int_buf, (usz)int_len);
                            libc::memcpy(buf + int_len, str.get_cstr(), s_len);
                        }
                        // Skip interning for accumulator (ra == source register),
                        // intern for new strings that may be used as property keys.
                        bool is_accum = (ra == rb || ra == rc);
                        if (is_accum) {
                            uint hash = vm.heap.hash_string(buf[:total]);
                            HString*? maybe_s = hstring::hstring_alloc((void*)vm.heap, buf[:total], hash);
                            if (heap_allocated) vm.heap.free_func(vm.heap.heap_udata, buf);
                            if (try s = maybe_s) {
                                vm.heap.set_reg_string(ra, s);
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            HString* interned = intern_string(vm, buf[:total]);
                            if (heap_allocated) vm.heap.free_func(vm.heap.heap_udata, buf);
                            vm.heap.set_reg_string(ra, interned);
                        }
                        break;
                    }
                }
                // Fall through to generic path if str is null or int_to_buf failed
            }
            TVal prim_b = *rb;
            TVal prim_c = *rc;
            // ES5 §11.6.1: + operator uses ToPrimitive with no hint (default "number")
            if (rb.get_tag() == OBJECT) { prim_b = to_primitive_value(vm, rb, false); }
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            if (rc.get_tag() == OBJECT) { prim_c = to_primitive_value(vm, rc, false); }
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            TValTag pt_b = prim_b.get_tag();
            TValTag pt_c = prim_c.get_tag();
            if (pt_b == STRING || pt_c == STRING) {
                HString*? left_str = vm_to_string(vm, &prim_b);
                if (vm.throw_pending) {
                    if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                    break;
                }
                HString*? right_str = vm_to_string(vm, &prim_c);
                if (vm.throw_pending) {
                    if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                    break;
                }
                if (try ls = left_str && try rs = right_str) {
                    uint a_len = ls.blen;
                    uint b_len = rs.blen;
                    uint total = a_len + b_len;

                    // Use stack buffer for small strings, heap for large
                    char[512] stack_buf;
                    char* buf;
                    bool heap_allocated = false;
                    if (total <= 512) {
                        buf = &stack_buf;
                    } else {
                        buf = (char*)vm.heap.alloc_func(vm.heap.heap_udata, total);
                        if (buf == null) { ra.set_undefined(); break; }
                        heap_allocated = true;
                    }

                    // Copy both halves directly into buffer
                    if (a_len > 0) {
                        libc::memcpy(buf, ls.get_cstr(), a_len);
                    }
                    if (b_len > 0) {
                        libc::memcpy(buf + a_len, rs.get_cstr(), b_len);
                    }

                    // Skip interning for accumulator (ra == source register),
                    // intern for new strings that may be used as property keys.
                    bool is_accum = (ra == rb || ra == rc);
                    if (is_accum) {
                        uint hash = vm.heap.hash_string(buf[:total]);
                        HString*? maybe_s = hstring::hstring_alloc((void*)vm.heap, buf[:total], hash);
                        if (heap_allocated) vm.heap.free_func(vm.heap.heap_udata, buf);
                        if (try s = maybe_s) {
                            vm.heap.set_reg_string(ra, s);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        HString* interned = intern_string(vm, buf[:total]);
                        if (heap_allocated) vm.heap.free_func(vm.heap.heap_udata, buf);
                        vm.heap.set_reg_string(ra, interned);
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                double add_b = vm_to_number(vm,&prim_b);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                double add_c = vm_to_number(vm,&prim_c);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                ra.set_number(add_b + add_c);
            }
        }

        case Opcode.SUB:
            if (rb.is_fastint() && rc.is_fastint()) {
                long diff = rb.get_fastint() - rc.get_fastint();
                if (diff >= types::FASTINT_MIN && diff <= types::FASTINT_MAX) {
                    ra.set_fastint(diff);
                } else {
                    ra.set_number((double)diff);
                }
            } else {
                double sub_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double sub_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                ra.set_number(sub_b - sub_c);
            }
            break;

        case Opcode.MUL:
            if (rb.is_fastint() && rc.is_fastint()) {
                // Use 64-bit multiply and check overflow
                long mul_result = rb.get_fastint() * rc.get_fastint();
                if (mul_result >= types::FASTINT_MIN && mul_result <= types::FASTINT_MAX) {
                    ra.set_fastint(mul_result);
                } else {
                    ra.set_number((double)mul_result);
                }
            } else {
                double mul_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double mul_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                ra.set_number(mul_b * mul_c);
            }
            break;

        case Opcode.DIV: {
            double div_b = vm_to_number(vm,rb);
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            double div_c = vm_to_number(vm,rc);
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            ra.set_number(div_b / div_c);
            break;
        }

        case Opcode.MOD:
            if (rb.is_fastint() && rc.is_fastint() && rc.get_fastint() != 0) {
                long mod_result = rb.get_fastint() % rc.get_fastint();
                if (mod_result == 0 && rb.get_fastint() < 0) {
                    // -1 % 1 → -0: sign of zero matches dividend per ES5 §11.5.3
                    ra.set_number(-0.0);
                } else {
                    ra.set_fastint(mod_result);
                }
            } else {
                double mod_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double mod_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                ra.set_number((mod_b % mod_c));
            }
            break;

        case Opcode.EXP: {
            double exp_b = vm_to_number(vm,rb);
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            double exp_c = vm_to_number(vm,rc);
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            ra.set_number(math::pow(exp_b, exp_c));
            break;
        }

        // === UNARY ===

        case Opcode.UNP:
            if (rb.is_fastint()) {
                // Unary + on FASTINT stays FASTINT
                ra.set_fastint(rb.get_fastint());
            } else {
                double unp_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                ra.set_number(unp_b);
            }
            break;

        case Opcode.UNM:
            if (rb.is_fastint()) {
                long unm_val = rb.get_fastint();
                if (unm_val == 0) {
                    // -0 must be NUMBER, not FASTINT (integers have no -0)
                    ra.set_number(-0.0);
                } else {
                    ra.set_fastint(-unm_val);
                }
            } else {
                double unm_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                ra.set_number(-unm_b);
            }
            break;

        case Opcode.BNOT:
            // Bitwise NOT always produces Int32, always fits in FASTINT
        {
            int bnot_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            ra.set_fastint((long)(~bnot_b));
            break;
        }

        case Opcode.LNOT:
            ra.set_boolean(!is_truthy(rb));
            break;

        case Opcode.TYPEOF: {
            HString* ts = typeof_string(vm, rb);
            vm.heap.set_reg_string(ra, ts);
            break;
        }

        case Opcode.VOID:
            ra.set_undefined();
            break;

        // === IN-PLACE FASTINT ++ / -- ===
        // Fused LDINT 1 + ADD/SUB pair. Hot for loop counters and similar.
        case Opcode.INC:
            if (ra.is_fastint()) {
                ra.set_fastint(ra.get_fastint() + 1L);
            } else {
                // Slow path: convert to number, increment, store back
                double d = vm_to_number(vm,ra);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                ra.set_number(d + 1.0);
            }
            break;
        case Opcode.DEC:
            if (ra.is_fastint()) {
                ra.set_fastint(ra.get_fastint() - 1L);
            } else {
                double d = vm_to_number(vm,ra);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                ra.set_number(d - 1.0);
            }
            break;

        // === VARIABLE ARITHMETIC FUSION ===
        // Fused GETVAR + INC/PUTVAR.  Reads a variable by name, increments
        // or decrements it, and writes it back in a single dispatch.
        // Hot for loop counters: `for (i = 0; i < N; i++) { ... }`
        case Opcode.INC_VAR:
        case Opcode.DEC_VAR: {
            uint bc = insn.get_bc();
            if (bc >= vm.current_func.const_count) break;
            TVal name_val = constants[bc];
            if (!name_val.is_string()) break;
            void* key = name_val.get_heapptr();
            bool is_inc = (op == Opcode.INC_VAR);

            // --- Variable IC fast path (read + op + write) ---
            if (var_ic_base != null) {
                uint pc_off = (uint)(curr_pc - 1 - code_base);
                hobject::VarICEntry* vic = var_ic_base + pc_off;
                if (vic.env != null && vic.key == key && vic.search_head == (void*)act.lex_env) {
                    HObject* b = (HObject*)vic.bindings;
                    if (b.shape_id == vic.shape_id
                        && vm.heap.shapes[b.shape_id].generation == vic.generation) {
                        TVal old_val = b.prop_values()[vic.prop_idx];
                        if (!env::is_tdz_sentinel(&old_val)
                            && b.get_prop_flags(vic.prop_idx).writable) {
                            if (old_val.is_fastint()) {
                                long v = old_val.get_fastint() + (is_inc ? 1L : -1L);
                                if (v >= types::FASTINT_MIN && v <= types::FASTINT_MAX) {
                                    b.prop_values()[vic.prop_idx].set_fastint(v);
                                    ra.set_fastint(v);
                                } else {
                                    b.prop_values()[vic.prop_idx].set_number((double)v);
                                    ra.set_number((double)v);
                                }
                            } else {
                                double d = vm_to_number(vm,&old_val);
                                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                                double new_d = d + (is_inc ? 1.0 : -1.0);
                                b.prop_values()[vic.prop_idx].set_number(new_d);
                                ra.set_number(new_d);
                            }
                            break;
                        }
                        vic.env = null;
                    } else {
                        vic.env = null;
                    }
                }
            }

            // --- Slow path: full env walk + op + write ---
            bool found = false;
            EnvRecord* ic_env = null;
            int ic_prop_idx = -1;
            EnvRecord* cur = act.lex_env;
            while (cur != null) {
                int idx = cur.bindings.find_prop_idx(key);
                if (idx >= 0) {
                    TVal old_val = cur.bindings.prop_values()[idx];
                    if (env::is_tdz_sentinel(&old_val)) {
                        HString* name_hstr = (HString*)key;
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.ref_err_proto;
                            char[types::ERROR_MSG_BUF] ebuf;
                            int elen = libc::snprintf(&ebuf, types::ERROR_MSG_BUF,
                                                      "%s is not defined", name_hstr.get_cstr());
                            if (elen > 0 && elen < types::ERROR_MSG_BUF) {
                                HString* emsg = intern_string(vm, ebuf[:elen]);
                                TVal emsg_val;
                                emsg_val.set_string(emsg);
                                HString* ekey = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                err.put_prop(ekey, emsg_val, hobject::PROP_FLAGS_WEC);
                            }
                            TVal err_val;
                            err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                return vm_uncaught_error(vm, &err_val);
                            }
                        } else {
                            return VM_ERROR~;
                        }
                        break;
                    }
                    if (!cur.bindings.get_prop_flags((uint)idx).writable) {
                        HString* name_hstr = (HString*)key;
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.type_err_proto;
                            char[types::ERROR_MSG_BUF] ebuf;
                            int elen = libc::snprintf(&ebuf, types::ERROR_MSG_BUF,
                                                      "Assignment to constant variable '%s'",
                                                      name_hstr.get_cstr());
                            if (elen > 0 && elen < types::ERROR_MSG_BUF) {
                                HString* emsg = intern_string(vm, ebuf[:elen]);
                                TVal emsg_val;
                                emsg_val.set_string(emsg);
                                HString* ekey = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                err.put_prop(ekey, emsg_val, hobject::PROP_FLAGS_WEC);
                            }
                            TVal err_val;
                            err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                return vm_uncaught_error(vm, &err_val);
                            }
                        } else {
                            return VM_ERROR~;
                        }
                        break;
                    }
                    if (old_val.is_fastint()) {
                        long v = old_val.get_fastint() + (is_inc ? 1L : -1L);
                        if (v >= types::FASTINT_MIN && v <= types::FASTINT_MAX) {
                            cur.bindings.prop_values()[idx].set_fastint(v);
                            ra.set_fastint(v);
                        } else {
                            cur.bindings.prop_values()[idx].set_number((double)v);
                            ra.set_number((double)v);
                        }
                    } else {
                        double d = vm_to_number(vm,&old_val);
                        if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                        double new_d = d + (is_inc ? 1.0 : -1.0);
                        cur.bindings.prop_values()[idx].set_number(new_d);
                        ra.set_number(new_d);
                    }
                    found = true;
                    ic_env = cur;
                    ic_prop_idx = idx;
                    break;
                }
                cur = cur.parent;
            }

            if (!found) {
                // var_env fallback (with-blocks)
                if (act.lex_env != act.var_env) {
                    TVal? result = env::env_get(act.var_env, key);
                    if (try v2 = result) {
                        TVal new_val;
                        if (v2.is_fastint()) {
                            long v = v2.get_fastint() + (is_inc ? 1L : -1L);
                            if (v >= types::FASTINT_MIN && v <= types::FASTINT_MAX) {
                                new_val.set_fastint(v);
                            } else {
                                new_val.set_number((double)v);
                            }
                        } else {
                            double d = vm_to_number(vm,&v2);
                            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                            new_val.set_number(d + (is_inc ? 1.0 : -1.0));
                        }
                        env::env_put(act.var_env, key, new_val);
                        vm.heap.tval_copy_ref(ra, &new_val);
                        found = true;
                    }
                }
                if (!found) {
                    // ReferenceError
                    HString* name_hstr = (HString*)key;
                    HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        err.prototype = vm.heap.ref_err_proto;
                        char[types::ERROR_MSG_BUF] ebuf;
                        int elen = libc::snprintf(&ebuf, types::ERROR_MSG_BUF,
                                                  "%s is not defined", name_hstr.get_cstr());
                        if (elen > 0 && elen < types::ERROR_MSG_BUF) {
                            HString* emsg = intern_string(vm, ebuf[:elen]);
                            TVal emsg_val;
                            emsg_val.set_string(emsg);
                            HString* ekey = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                            err.put_prop(ekey, emsg_val, hobject::PROP_FLAGS_WEC);
                        }
                        TVal err_val;
                        err_val.set_object(err);
                        if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                            return vm_uncaught_error(vm, &err_val);
                        }
                    } else {
                        return VM_ERROR~;
                    }
                }
            }

            // Populate IC for next time
            if (found && var_ic_base != null && ic_env != null) {
                uint pc_off = (uint)(curr_pc - 1 - code_base);
                hobject::VarICEntry* vic = var_ic_base + pc_off;
                vic.env = ic_env;
                vic.bindings = ic_env.bindings;
                vic.shape_id = ic_env.bindings.shape_id;
                vic.generation = vm.heap.shapes[ic_env.bindings.shape_id].generation;
                vic.prop_idx = (ushort)ic_prop_idx;
                if (vic.key != null) { vm.heap.decref((types::HeapHeader*)vic.key); }
                vic.key = key;
                if (key != null) { ((types::HeapHeader*)key).incref(); }
                vic.search_head = (void*)act.lex_env;
            }
            break;
        }

        // === BITWISE ===

        case Opcode.BAND:
            // Bitwise ops always produce Int32, always fit in FASTINT
        {
            int band_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            int band_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            ra.set_fastint((long)(band_b & band_c));
            break;
        }

        case Opcode.BOR:
        {
            int bor_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            int bor_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            ra.set_fastint((long)(bor_b | bor_c));
            break;
        }

        case Opcode.BXOR:
        {
            int bxor_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            int bxor_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            ra.set_fastint((long)(bxor_b ^ bxor_c));
            break;
        }

        case Opcode.SHL:
        {
            int shl_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            int shl_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            ra.set_fastint((long)(shl_b << (shl_c & 0x1F)));
            break;
        }

        case Opcode.SHR:
        {
            int shr_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            int shr_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            ra.set_fastint((long)(shr_b >> (shr_c & 0x1F)));
            break;
        }

        case Opcode.USHR:
        {
            uint ushr_b = (uint)toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            if (needs_restart) break;
            int  ushr_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            ra.set_fastint((long)(ushr_b >> (ushr_c & 0x1F)));
            break;
        }

        // === COMPARISON ===

        case Opcode.EQ:
            ra.set_boolean(abstract_eq(vm, rb, rc));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            break;

        case Opcode.NEQ:
            ra.set_boolean(!abstract_eq(vm, rb, rc));
            if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
            break;

        case Opcode.SEQ: {
            // Fast path: FASTINT === FASTINT — most common in loop counters and
            // arithmetic benchmarks. Short-circuit before full tag dispatch.
            if (rb.is_fastint() && rc.is_fastint()) {
                ra.set_boolean(rb.get_fastint() == rc.get_fastint());
                break;
            }
            bool seq_r = false;
            TValTag tag_b = rb.get_tag();
            TValTag tag_c = rc.get_tag();
            if (tag_b == tag_c) {
                switch (tag_b) {
                    case UNDEFINED: seq_r = true; break;
                    case NULL_VAL:  seq_r = true; break;
                    case BOOLEAN:   seq_r = (rb.get_boolean() == rc.get_boolean()); break;
                    case NUMBER:
                        if (math::is_nan(rb.get_number()) || math::is_nan(rc.get_number())) {
                            seq_r = false;
                        } else {
                            seq_r = (rb.get_number() == rc.get_number());
                        }
                        break;
                    case FASTINT:   seq_r = (rb.get_fastint() == rc.get_fastint()); break;
                    case STRING: {
                        HString* sa = (HString*)rb.get_heapptr();
                        HString* sb = (HString*)rc.get_heapptr();
                        seq_r = sa != null && sb != null && sa.equals_hstring(sb);
                        break;
                    }
                    case OBJECT:    seq_r = (rb.get_heapptr() == rc.get_heapptr()); break;
                    case LIGHTFUNC: seq_r = (rb.get_heapptr() == rc.get_heapptr()); break;
                    case POINTER:   seq_r = (rb.get_heapptr() == rc.get_heapptr()); break;
                    case BUFFER:    seq_r = (rb.get_heapptr() == rc.get_heapptr()); break;
                    default: break;
                }
            } else if ((tag_b == NUMBER && tag_c == FASTINT) ||
                       (tag_b == FASTINT && tag_c == NUMBER)) {
                double nb = (tag_b == FASTINT) ? (double)rb.get_fastint() : rb.get_number();
                double nc = (tag_c == FASTINT) ? (double)rc.get_fastint() : rc.get_number();
                seq_r = (nb == nc);
            }
            ra.set_boolean(seq_r);
            break;
        }

        case Opcode.SNEQ: {
            // Fast path: FASTINT !== FASTINT — short-circuit before full tag dispatch.
            if (rb.is_fastint() && rc.is_fastint()) {
                ra.set_boolean(rb.get_fastint() != rc.get_fastint());
                break;
            }
            bool sneq_r = true;
            TValTag tag_b = rb.get_tag();
            TValTag tag_c = rc.get_tag();
            if (tag_b == tag_c) {
                switch (tag_b) {
                    case UNDEFINED: sneq_r = false; break;
                    case NULL_VAL:  sneq_r = false; break;
                    case BOOLEAN:   sneq_r = (rb.get_boolean() != rc.get_boolean()); break;
                    case NUMBER:
                        if (math::is_nan(rb.get_number()) || math::is_nan(rc.get_number())) {
                            sneq_r = true;
                        } else {
                            sneq_r = (rb.get_number() != rc.get_number());
                        }
                        break;
                    case FASTINT:   sneq_r = (rb.get_fastint() != rc.get_fastint()); break;
                    case STRING: {
                        HString* sa = (HString*)rb.get_heapptr();
                        HString* sb = (HString*)rc.get_heapptr();
                        sneq_r = !(sa != null && sb != null && sa.equals_hstring(sb));
                        break;
                    }
                    case OBJECT:    sneq_r = (rb.get_heapptr() != rc.get_heapptr()); break;
                    case LIGHTFUNC: sneq_r = (rb.get_heapptr() != rc.get_heapptr()); break;
                    case POINTER:   sneq_r = (rb.get_heapptr() != rc.get_heapptr()); break;
                    case BUFFER:    sneq_r = (rb.get_heapptr() != rc.get_heapptr()); break;
                    default: break;
                }
            } else if ((tag_b == NUMBER && tag_c == FASTINT) ||
                       (tag_b == FASTINT && tag_c == NUMBER)) {
                double nb = (tag_b == FASTINT) ? (double)rb.get_fastint() : rb.get_number();
                double nc = (tag_c == FASTINT) ? (double)rc.get_fastint() : rc.get_number();
                sneq_r = (nb != nc);
            }
            ra.set_boolean(sneq_r);
            break;
        }

        case Opcode.LT: {
            bool result;
            if (rb.is_fastint() && rc.is_fastint()) {
                result = rb.get_fastint() < rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                result = tval_numeric_to_double(rb) < tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) < 0;
            } else {
                double lt_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double lt_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                result = lt_b < lt_c;
            }
            ra.set_boolean(result);
            break;
        }

        case Opcode.LE: {
            bool result;
            if (rb.is_fastint() && rc.is_fastint()) {
                result = rb.get_fastint() <= rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                result = tval_numeric_to_double(rb) <= tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) <= 0;
            } else {
                double le_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double le_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                result = le_b <= le_c;
            }
            ra.set_boolean(result);
            break;
        }

        case Opcode.GT: {
            bool result;
            if (rb.is_fastint() && rc.is_fastint()) {
                result = rb.get_fastint() > rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                result = tval_numeric_to_double(rb) > tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) > 0;
            } else {
                double gt_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double gt_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                result = gt_b > gt_c;
            }
            ra.set_boolean(result);
            break;
        }

        case Opcode.GE: {
            bool result;
            if (rb.is_fastint() && rc.is_fastint()) {
                result = rb.get_fastint() >= rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                result = tval_numeric_to_double(rb) >= tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) >= 0;
            } else {
                double ge_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double ge_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                result = ge_b >= ge_c;
            }
            ra.set_boolean(result);
            break;
        }

        // === FUSED COMPARE-AND-BRANCH ===
        // Each op replicates the corresponding compare's exact semantics, then
        // branches if the result is FALSE (i.e. branches when condition does NOT hold).
        // Offset in A (signed 8-bit, cast via char) is relative to the already-
        // incremented pc (same convention as IF_FALSE).
        // NaN: !(NaN op x) is always true, so the branch IS taken — correct because
        // we negate the same compare result that IF_FALSE would have tested.

        case Opcode.JMP_NLT: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() < rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) < tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) < 0;
            } else {
                double jnlt_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double jnlt_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                jmp_result = jnlt_b < jnlt_c;
            }
            if (!jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } curr_pc += (int)(ichar)insn.a; }
            break;
        }

        case Opcode.JMP_NLE: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() <= rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) <= tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) <= 0;
            } else {
                double jnle_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double jnle_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                jmp_result = jnle_b <= jnle_c;
            }
            if (!jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } curr_pc += (int)(ichar)insn.a; }
            break;
        }

        case Opcode.JMP_NGT: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() > rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) > tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) > 0;
            } else {
                double jngt_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double jngt_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                jmp_result = jngt_b > jngt_c;
            }
            if (!jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } curr_pc += (int)(ichar)insn.a; }
            break;
        }

        case Opcode.JMP_NGE: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() >= rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) >= tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) >= 0;
            } else {
                double jnge_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double jnge_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                jmp_result = jnge_b >= jnge_c;
            }
            if (!jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } curr_pc += (int)(ichar)insn.a; }
            break;
        }

        case Opcode.JMP_LT: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() < rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) < tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) < 0;
            } else {
                double jlt_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double jlt_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                jmp_result = jlt_b < jlt_c;
            }
            if (jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } curr_pc += (int)(ichar)insn.a; }
            break;
        }

        case Opcode.JMP_LE: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() <= rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) <= tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) <= 0;
            } else {
                double jle_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double jle_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                jmp_result = jle_b <= jle_c;
            }
            if (jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } curr_pc += (int)(ichar)insn.a; }
            break;
        }

        case Opcode.JMP_GT: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() > rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) > tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) > 0;
            } else {
                double jgt_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double jgt_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                jmp_result = jgt_b > jgt_c;
            }
            if (jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } curr_pc += (int)(ichar)insn.a; }
            break;
        }

        case Opcode.JMP_GE: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() >= rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) >= tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) >= 0;
            } else {
                double jge_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                if (needs_restart) break;
                double jge_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, act, &curr_pc, &needs_restart)) return VM_ERROR~;
                jmp_result = jge_b >= jge_c;
            }
            if (jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } curr_pc += (int)(ichar)insn.a; }
            break;
        }

        case Opcode.INSTANCEOF: {
            // ES5 §11.8.6: RelationalExpression instanceof ShiftExpression
            // ra may alias rb (compiler optimization), so read rb before writing ra.
            TVal lval = *rb;
            TVal rval = *rc;
            ra.set_boolean(false);

            if (rval.is_lightfunc()) {
                // LIGHTFUNC builtins are callable; look up their prototype
                uint fn_idx = (uint)(usz)rval.get_heapptr();
                HObject* proto_obj = lightfunc_get_proto(vm, fn_idx);
                if (proto_obj != null && lval.is_object()) {
                    HObject* lbh = (HObject*)lval.get_heapptr();
                    if (lbh.is_prototype_of(proto_obj)) {
                        ra.set_boolean(true);
                    }
                }
                break;
            }

            if (!rval.is_object()) {
                // TypeError: right-hand side must be an object
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                    HString* msg_val = intern_string(vm, "Right-hand side of instanceof is not an object");
                    TVal msg_tv;
                    msg_tv.set_string(msg_val);
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                    TVal err_val;
                    err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return vm_uncaught_error(vm, &err_val);
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            HObject* rfunc = (HObject*)rval.get_heapptr();
            if (rfunc == null || !rfunc.is_callable()) {
                // TypeError: right-hand side must be callable
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                    HString* msg_val = intern_string(vm, "Right-hand side of instanceof is not callable");
                    TVal msg_tv;
                    msg_tv.set_string(msg_val);
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                    TVal err_val;
                    err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return vm_uncaught_error(vm, &err_val);
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            // ES6 §12.10.4: Check Symbol.hasInstance on the constructor
            if (vm.heap.hasinstance_symbol != null) {
                HString* hasinst_key = vm.heap.hasinstance_symbol;
                TVal? hasinst_val = rfunc.get_prop_proto(hasinst_key);
                if (try hasinst_fn = hasinst_val) {
                    bool hasinst_callable = hasinst_fn.is_lightfunc() ||
                        (hasinst_fn.is_object() && hasinst_fn.get_heapptr() != null &&
                         ((HObject*)hasinst_fn.get_heapptr()).is_callable());
                    if (hasinst_callable) {
                        // Call @@hasInstance with this=rval, arg=lval
                        TVal result = vm.heap.call_fn(vm, hasinst_fn, &lval, 1, rval);
                        if (vm_check_call_fn_error(vm)) return VM_ERROR~;
                        ra.set_boolean(builtins::builtin_to_boolean(&result));
                        break;
                    }
                }
            }

            // §15.3.5.3 step 1: If Type(lval) is not Object → false
            if (!lval.is_object()) {
                break;
            }

            // Get rval.prototype
            HString* proto_key_str = (HString*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE];
            TVal proto_val = get_prop_with_proto(rfunc, proto_key_str);
            if (!proto_val.is_object()) {
                // ES5 §15.3.5.3 step 3: If Type(O) is not Object, throw a TypeError.
                // But gracefully handle missing .prototype by returning false.
                ra.set_boolean(false);
                break;
            }

            HObject* proto_obj = (HObject*)proto_val.get_heapptr();
            HObject* cur = (HObject*)lval.get_heapptr();
            if (cur.is_prototype_of(proto_obj)) {
                ra.set_boolean(true);
            }
            break;
        }

        case Opcode.IN: {
            // ES5 §11.8.7: RelationalExpression in ShiftExpression
            // Right side must be an object; TypeError otherwise.
            // Returns true if the object has a property with the given name
            // (own or inherited — check via [[HasProperty]]).
            //
            // NOTE: Read rb (key) BEFORE writing ra, because ra may alias rb
            // (compiler can emit IN r3, r3, r4 when result overwrites the key).
            if (!rc.is_object()) {
                ra.set_boolean(false);
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                    HString* msg_val = intern_string(vm, "in requires an object");
                    TVal msg_tv;
                    msg_tv.set_string(msg_val);
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                    TVal err_val;
                    err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return vm_uncaught_error(vm, &err_val);
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            HObject* obj = (HObject*)rc.get_heapptr();

            // Fast path: dense array / arguments indexed check (numeric keys)
            if ((obj.get_class() == hobject::ObjClass.ARRAY || obj.get_class() == hobject::ObjClass.ARGUMENTS) && obj.array_part() != null && (rb.is_fastint() || rb.is_number())) {
                long idx_long = rb.is_fastint() ? rb.get_fastint() : (long)rb.get_number();
                if (idx_long >= 0 && idx_long < (long)obj.array_size) {
                    TVal? av = obj.get_array_idx((uint)idx_long);
                    if (try v = av) {
                        ra.set_boolean(true);
                        break;
                    }
                    // Array hole — fall through to prototype chain lookup
                } else {
                    // Index out of bounds — check prototype only
                    void* key = get_prop_key(vm, rb);
                    if (key != null) {
                        ra.set_boolean(obj.prototype != null && obj.prototype.has_prop_proto(key));
                    } else {
                        ra.set_boolean(false);
                    }
                    break;
                }
            }

            // Fast path: dense array with string key that might be an index
            if ((obj.get_class() == hobject::ObjClass.ARRAY || obj.get_class() == hobject::ObjClass.ARGUMENTS) && obj.array_part() != null && rb.is_string()) {
                HString* skey = (HString*)rb.get_heapptr();
                uint skey_idx = skey.array_index();
                if (skey_idx != hstring::ARRIDX_NONE && skey_idx < (uint)obj.array_size) {
                    TVal? av = obj.get_array_idx(skey_idx);
                    if (try v = av) {
                        ra.set_boolean(true);
                        break;
                    }
                }
            }

            void* key = get_prop_key(vm, rb);
            if (key != null) {
                // STRING exotic: integer index keys in [0, clen) are own properties served lazily.
                if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
                    HString* key_hstr = (HString*)key;
                    if (key_hstr != null && key_hstr.is_arridx()) {
                        HString* prim_str = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
                        if (prim_str != null && key_hstr.array_index() < prim_str.char_length()) {
                            ra.set_boolean(true);
                            break;
                        }
                    }
                }
                ra.set_boolean(obj.has_prop_proto(key));
            } else {
                ra.set_boolean(false);
            }
            break;
        }

        // === CONTROL FLOW ===

        case Opcode.JUMP: {
            int sabc = insn.get_sabc();
            int target = (int)((long)(curr_pc - code_base) + (long)sabc);
            if (target < (curr_pc - code_base)) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } }
            curr_pc = code_base + target;
            break;
        }

        case Opcode.IF_TRUE:
            if (is_truthy(ra)) {
                int sbx = insn.get_sbc();
                int target = (int)((long)(curr_pc - code_base) + (long)sbx);
                if (target < (curr_pc - code_base)) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } }
                curr_pc = code_base + target;
            }
            break;

        case Opcode.IF_FALSE:
            if (!is_truthy(ra)) {
                int sbx = insn.get_sbc();
                int target = (int)((long)(curr_pc - code_base) + (long)sbx);
                if (target < (curr_pc - code_base)) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } }
                curr_pc = code_base + target;
            }
            break;

        // === PROPERTY ACCESS ===

        case Opcode.GETPROP:
            if (rb.is_object()) {
                HObject* hobj = (HObject*)rb.get_heapptr();

                // Inline Cache fast path: check shape + key + prop_values pointer
                // NOTE: We use prop_values() (not prop_alloc) because prop_alloc is
                // NULL for objects with ≤4 inline properties, making the check always
                // true for all small objects. prop_values() returns a unique pointer
                // per object even for inline properties.
                if (ic_base != null) {
                    uint pc_off = (uint)(curr_pc - 1 - code_base);
                    hobject::ICEntry* ic = ic_base + pc_off;
                    void* lookup_key = null;
                    if (rc.is_string()) lookup_key = rc.get_heapptr();
                    if (lookup_key != null && ic.key == lookup_key && ic.shape_id == hobj.shape_id) {
                        HObject* ic_owner = ic.proto == null ? hobj : (HObject*)ic.proto;
                        if (ic.cached_prop_alloc == (void*)ic_owner.prop_values()) {
                            // Ultra-fast path: when the IC value is not a heap
                            // pointer (common for fastint/number results), skip
                            // decref/incref/track_heap_store entirely.
                            TVal ic_val = *ic.prop_value_ptr;
                            if (!ic_val.is_heap_allocated()) {
                                *ra = ic_val;
                            } else {
                                vm.heap.tval_copy_ref(ra, &ic_val);
                                track_heap_store(act, ra, (uint)insn.a);
                            }
                            break;
                        }
                    }
                }

                // Fast path: dense array indexed access (a[i] where i is a non-negative integer)
                // Also handles ARGUMENTS exotic objects for arguments[i] access
                if ((hobj.get_class() == hobject::ObjClass.ARRAY || hobj.get_class() == hobject::ObjClass.ARGUMENTS) && hobj.array_part() != null && (rc.is_fastint() || rc.is_number())) {
                    long idx_long = rc.is_fastint() ? rc.get_fastint() : (long)rc.get_number();
                    if (idx_long >= 0 && idx_long < (long)hobj.array_size) {
                        TVal? av = hobj.get_array_idx((uint)idx_long);
                        if (try v = av) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(act, ra, (uint)insn.a);
                            break;
                        }
                        // Array hole — fall through to prototype chain lookup
                    }
                }

                // ARRAY exotic: .length fast path — return array_length directly
                if (hobj.get_class() == hobject::ObjClass.ARRAY && rc.is_string() && rc.get_heapptr() == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                    ra.set_fastint((long)*hobj.array_len_ptr());
                    break;
                }

                void* key = get_prop_key(vm, rc);
                if (key != null) {
                    // ES5 strict mode: arguments.callee throws TypeError.
                    // Strict-only engine: always throws.
                    if (hobj.get_class() == hobject::ObjClass.ARGUMENTS
                        && key == (void*)vm.heap.strs[heap::BuiltinStr.CALLEE]) {
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.type_err_proto;
                            HString* emsg = intern_string(vm, "'callee', 'arguments', and 'arguments.caller' may not be accessed in strict mode");
                            if (emsg != null) {
                                TVal emsg_val; emsg_val.set_string(emsg);
                                HString* ekey = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                err.put_prop(ekey, emsg_val, hobject::PROP_FLAGS_WEC);
                            }
                            TVal err_val; err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                return vm_uncaught_error(vm, &err_val);
                            }
                        } else {
                            return VM_ERROR~;
                        }
                        break;
                    }
                    // ES5 strict mode: function.caller and function.arguments throw TypeError
                    if (hobj.is_callable() && hobj.get_class() == hobject::ObjClass.FUNCTION) {
                        HString* key_hstr = (HString*)key;
                        if (key_hstr != null && (key_hstr.equals("caller") || key_hstr.equals("arguments"))) {
                            HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = vm.heap.type_err_proto;
                                HString* emsg = intern_string(vm, "'caller' and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them");
                                if (emsg != null) {
                                    TVal emsg_val; emsg_val.set_string(emsg);
                                    HString* ekey = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                    err.put_prop(ekey, emsg_val, hobject::PROP_FLAGS_WEC);
                                }
                                TVal err_val; err_val.set_object(err);
                                if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                    return vm_uncaught_error(vm, &err_val);
                                }
                            } else {
                                return VM_ERROR~;
                            }
                            break;
                        }
                    }
                    // STRING exotic: indexed access reads characters lazily from the primitive value.
                    // Handles both fastint/number keys (e.g. s[0]) and array-index string keys
                    // (e.g. s["0"]), avoiding the need to materialise per-character own properties.
                    if (hobj.flags.exotic_stringobj && (*hobj.extra_ptr()).prim.primitive_value.is_string()) {
                        long sidx = -1;
                        if (rc.is_fastint()) {
                            sidx = rc.get_fastint();
                        } else if (rc.is_number()) {
                            double d = rc.get_number();
                            if (d >= 0 && d == (double)(long)d) sidx = (long)d;
                        } else if (rc.is_string()) {
                            // String key that is a canonical array index (cached on HString)
                            HString* key_hstr = (HString*)rc.get_heapptr();
                            if (key_hstr != null && key_hstr.is_arridx()) {
                                sidx = (long)key_hstr.array_index();
                            }
                        }
                        if (sidx >= 0) {
                            HString* prim_str = (HString*)(*hobj.extra_ptr()).prim.primitive_value.get_heapptr();
                            if (sidx < (long)prim_str.char_length()) {
                                uint cp = prim_str.char_at((uint)sidx);
                                char[4] sbuf;
                                uint sblen = hstring::encode_codepoint(cp, sbuf[:4]);
                                HString* interned = intern_string(vm, sbuf[:sblen]);
                                if (interned != null) {
                                    vm.heap.set_reg_string(ra, interned);
                                } else {
                                    return VM_ERROR~;
                                }
                                break;
                            }
                            // Out-of-range index on a string exotic: fall through to own-property
                            // lookup so that explicitly assigned out-of-range slots are still found.
                        }
                    }
                    // Megamorphic cache: try global (shape, key) → offset cache before full chain walk
                    hobject::MegamorphicEntry* mega = hobject::mega_cache_lookup(vm.heap, hobj, key);
                    if (mega != null) {
                        TVal mega_val = *mega.prop_value_ptr;
                        if (!mega_val.is_heap_allocated()) {
                            *ra = mega_val;
                        } else {
                            vm.heap.tval_copy_ref(ra, &mega_val);
                            track_heap_store(act, ra, (uint)insn.a);
                        }
                        break;
                    }
                    hobject::PropLookupResult res = hobj.get_prop_or_accessor_proto(key, true);
                    if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                        TVal obj_val;
                        obj_val.set_object(hobj);
                        if (invoke_getter(vm, &res.acc, &obj_val, (uint)insn.a,
                                          act, &curr_pc, &needs_restart, regs_base)) {
                            regs_base = act.bottom;
                            break;
                        }
                        break;
                        } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
                            vm.heap.tval_copy_ref(ra, &res.data_val);
                            track_heap_store(act, ra, (uint)insn.a);
                            // Populate IC for this site.
                            // Only cache OWN property lookups. Inherited lookups are not cached
                            // because the IC would have no way to detect modifications to
                            // intermediate objects in the prototype chain (e.g. when
                            // B.prototype.foo = ... is set, an IC that previously resolved
                            // b.foo via A.prototype would return a stale value). This matches
                            // the QuickJS approach where the shape itself encodes the proto
                            // and lookups always walk the current chain.
                            if (res.owner == hobj && res.owner != null && ic_base != null) {
                                uint pc_off = (uint)(curr_pc - 1 - code_base);
                                hobject::ICEntry* ic = ic_base + pc_off;
                                int owner_idx = res.owner.find_prop_idx(key);
                                if (owner_idx >= 0) {
                                    ic.shape_id = hobj.shape_id;
                                    ic.proto = null;  // own property
                                    ic.prop_idx = (ushort)owner_idx;
                                    ic.prop_flags = res.owner.get_prop_flags((uint)owner_idx);
                                    if (ic.key != null) { vm.heap.decref((types::HeapHeader*)ic.key); }
                                    ic.key = key;
                                    if (key != null) { ((types::HeapHeader*)key).incref(); }
                                    ic.prop_value_ptr = &res.owner.prop_values()[owner_idx];
                                    ic.cached_prop_alloc = (void*)res.owner.prop_values();
                                    // Also populate megamorphic cache for cross-site benefit
                                    hobject::mega_cache_store(vm.heap, hobj, key, res.owner, owner_idx);
                                }
                            }
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
            } else if (rb.is_null() || rb.is_undefined()) {
                // TypeError: Cannot read properties of null/undefined
                HString* name_hstr = null;
                if (rc.is_string()) {
                    name_hstr = (HString*)rc.get_heapptr();
                }
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len;
                    if (name_hstr != null) {
                        len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "Cannot read properties of %s (reading '%s')",
                                             (rb.is_null() ? "null" : "undefined"),
                                             name_hstr.get_cstr());
                    } else {
                        len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "Cannot read properties of %s",
                                             (rb.is_null() ? "null" : "undefined"));
                    }
                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val;
                    err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return vm_uncaught_error(vm, &err_val);
                    }
                } else {
                    return VM_ERROR~;
                }
            } else if (rb.is_string()) {
                // Check if this is a Symbol (0xFF-prefixed string)
                HString* h_str = (HString*)rb.get_heapptr();
                if (h_str != null && h_str.is_symbol() && vm.heap.symbol_proto != null) {
                    // Auto-box symbol primitive: walk Symbol.prototype chain
                    HString* key = get_prop_key(vm, rc);
                    if (key != null) {
                        TVal? result = vm.heap.symbol_proto.get_prop_proto(key);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(act, ra, (uint)insn.a);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    // Auto-box string primitive
                    HString* str_prim = (HString*)rb.get_heapptr();

                    // Fast path: numeric index → character at index
                    long str_idx = -1;
                    if (rc.is_fastint()) {
                        str_idx = rc.get_fastint();
                    } else if (rc.is_number()) {
                        double d = rc.get_number();
                        if (d >= 0 && d == (double)(long)d) {
                            str_idx = (long)d;
                        }
                    }
                    if (str_idx >= 0 && str_idx < (long)str_prim.char_length()) {
                        uint cp = str_prim.char_at((uint)str_idx);
                        char[4] cbuf;
                        uint cblen = hstring::encode_codepoint(cp, cbuf[:4]);
                        HString* interned = intern_string(vm, cbuf[:cblen]);
                        if (interned != null) {
                            vm.heap.set_reg_string(ra, interned);
                        } else {
                            return VM_ERROR~;
                        }
                        break;
                    }

                    HString* key = get_prop_key(vm, rc);
                    if (key != null) {
                        // Fast path: .length → string character count
                        if (key == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra.set_fastint((long)h_str.char_length());
                            break;
                        }
                        // Slow path: walk String.prototype chain
                        if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto(key);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra, &v);
                                track_heap_store(act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                }
            } else if (rb.is_number() || rb.is_fastint()) {
                // Auto-box number primitive: walk Number.prototype chain
                HString* key = get_prop_key(vm, rc);
                if (key != null && vm.heap.number_proto != null) {
                    TVal? result = vm.heap.number_proto.get_prop_proto(key);
                    if (try v = result) {
                        vm.heap.tval_copy_ref(ra, &v);
                        track_heap_store(act, ra, (uint)insn.a);
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else if (rb.is_boolean()) {
                // Auto-box boolean primitive: walk Boolean.prototype chain
                HString* key = get_prop_key(vm, rc);
                if (key != null && vm.heap.bool_proto != null) {
                    TVal? result = vm.heap.bool_proto.get_prop_proto(key);
                    if (try v = result) {
                        vm.heap.tval_copy_ref(ra, &v);
                        track_heap_store(act, ra, (uint)insn.a);
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else if (rb.is_lightfunc()) {
                // LIGHTFUNC: resolve .name and .length from metadata, other props from Function.prototype
                uint fn_idx = (uint)(usz)rb.get_heapptr();
                HString* key = get_prop_key(vm, rc);
                if (key != null) {
                    if (key.equals("name")) {
                        if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 0)) {
                            builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
                            if (meta.name.len > 0) {
                                HString* name_str = intern_string(vm, meta.name);
                                vm.heap.set_reg_string(ra, name_str);
                            } else {
                                ra.set_undefined();
                            }
                        } else if (vm.heap.function_proto != null) {
                            TVal? result = vm.heap.function_proto.get_prop_proto(key);
                            if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(act, ra, (uint)insn.a); }
                            else { ra.set_undefined(); }
                        } else { ra.set_undefined(); }
                    } else if (key.equals("length")) {
                        if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 1)) {
                            builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
                            if (meta.arity >= 0) {
                                ra.set_number(meta.arity);
                            } else {
                                ra.set_undefined();
                            }
                        } else if (vm.heap.function_proto != null) {
                            TVal? result = vm.heap.function_proto.get_prop_proto(key);
                            if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(act, ra, (uint)insn.a); }
                            else { ra.set_undefined(); }
                        } else { ra.set_undefined(); }
                    } else if (key.equals("prototype")) {
                        if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 2)) {
                            // Resolve .prototype for constructor lightfuncs (Boolean, Number, etc.)
                            HObject* proto_obj = lightfunc_get_proto(vm, fn_idx);
                            if (proto_obj != null) {
                                ra.set_object(proto_obj);
                                track_heap_store(act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
                            }
                        } else if (vm.heap.function_proto != null) {
                            TVal? result = vm.heap.function_proto.get_prop_proto(key);
                            if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(act, ra, (uint)insn.a); }
                            else { ra.set_undefined(); }
                        } else { ra.set_undefined(); }
                    } else if (key.equals("caller") || key.equals("arguments")) {
                        // ES5 strict mode: accessing .caller and .arguments throws TypeError
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.type_err_proto;
                            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                            HString* msg_val = intern_string(vm, "'caller' and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them");
                            TVal msg_tv;
                            msg_tv.set_string(msg_val);
                            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                            TVal err_val;
                            err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                return vm_uncaught_error(vm, &err_val);
                            }
                        } else {
                            return VM_ERROR~;
                        }
                    } else if (vm.heap.function_proto != null) {
                        // Walk Function.prototype for .call, .apply, .bind, etc.
                        TVal? result = vm.heap.function_proto.get_prop_proto(key);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(act, ra, (uint)insn.a);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            break;

        case Opcode.GETPROPC:
            // Fused LDCONST+GETPROP: key comes from constant pool (always a string).
            {
                TVal key_tval = constants[(uint)insn.c];
                HString* key_hstr = (HString*)key_tval.get_heapptr();
                if (rb.is_object()) {
                    HObject* hobj = (HObject*)rb.get_heapptr();

                    // Inline Cache fast path: key is always non-null, skip lookup_key check.
                    if (ic_base != null) {
                        uint pc_off = (uint)(curr_pc - 1 - code_base);
                        hobject::ICEntry* ic = ic_base + pc_off;
                        if (ic.key == (void*)key_hstr && ic.shape_id == hobj.shape_id) {
                            HObject* ic_owner = ic.proto == null ? hobj : (HObject*)ic.proto;
                            if (ic.cached_prop_alloc == (void*)ic_owner.prop_values()) {
                                TVal ic_val = *ic.prop_value_ptr;
                                if (!ic_val.is_heap_allocated()) {
                                    *ra = ic_val;
                                } else {
                                    vm.heap.tval_copy_ref(ra, &ic_val);
                                    track_heap_store(act, ra, (uint)insn.a);
                                }
                                break;
                            }
                        }
                    }

                    // ARRAY exotic: .length fast path
                    if (hobj.get_class() == hobject::ObjClass.ARRAY && (void*)key_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                        ra.set_fastint((long)*hobj.array_len_ptr());
                        break;
                    }

                    void* key = (void*)key_hstr;
                    if (key != null) {
                        // ES5 strict mode: arguments.callee throws TypeError.
                        // Strict-only engine: always throws.
                        if (hobj.get_class() == hobject::ObjClass.ARGUMENTS
                            && key == (void*)vm.heap.strs[heap::BuiltinStr.CALLEE]) {
                            HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = vm.heap.type_err_proto;
                                HString* emsg = intern_string(vm, "'callee', 'arguments', and 'arguments.caller' may not be accessed in strict mode");
                                if (emsg != null) {
                                    TVal emsg_val; emsg_val.set_string(emsg);
                                    HString* ekey = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                    err.put_prop(ekey, emsg_val, hobject::PROP_FLAGS_WEC);
                                }
                                TVal err_val; err_val.set_object(err);
                                if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                    return vm_uncaught_error(vm, &err_val);
                                }
                            } else {
                                return VM_ERROR~;
                            }
                            break;
                        }
                        // ES5 strict mode: function.caller and function.arguments throw TypeError
                        if (hobj.is_callable() && hobj.get_class() == hobject::ObjClass.FUNCTION
                            && (key_hstr.equals("caller") || key_hstr.equals("arguments"))) {
                            HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = vm.heap.type_err_proto;
                                HString* emsg = intern_string(vm, "'caller' and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them");
                                if (emsg != null) {
                                    TVal emsg_val; emsg_val.set_string(emsg);
                                    HString* ekey = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                    err.put_prop(ekey, emsg_val, hobject::PROP_FLAGS_WEC);
                                }
                                TVal err_val; err_val.set_object(err);
                                if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                    return vm_uncaught_error(vm, &err_val);
                                }
                            } else {
                                return VM_ERROR~;
                            }
                            break;
                        }
                        // STRING exotic: string-key indexed access (array-index string keys like "0")
                        if (hobj.flags.exotic_stringobj && (*hobj.extra_ptr()).prim.primitive_value.is_string()) {
                            if (key_hstr != null && key_hstr.is_arridx()) {
                                long sidx = (long)key_hstr.array_index();
                                HString* prim_str = (HString*)(*hobj.extra_ptr()).prim.primitive_value.get_heapptr();
                                if (sidx < (long)prim_str.char_length()) {
                                    uint cp = prim_str.char_at((uint)sidx);
                                    char[4] sbuf;
                                    uint sblen = hstring::encode_codepoint(cp, sbuf[:4]);
                                    HString* interned = intern_string(vm, sbuf[:sblen]);
                                    if (interned != null) {
                                        vm.heap.set_reg_string(ra, interned);
                                    } else {
                                        return VM_ERROR~;
                                    }
                                    break;
                                }
                            }
                        }
                        // Megamorphic cache: try global (shape, key) → offset cache before full chain walk
                        hobject::MegamorphicEntry* mega = hobject::mega_cache_lookup(vm.heap, hobj, key);
                        if (mega != null) {
                            TVal mega_val = *mega.prop_value_ptr;
                            if (!mega_val.is_heap_allocated()) {
                                *ra = mega_val;
                            } else {
                                vm.heap.tval_copy_ref(ra, &mega_val);
                                track_heap_store(act, ra, (uint)insn.a);
                            }
                            break;
                        }
                        hobject::PropLookupResult res = hobj.get_prop_or_accessor_proto(key, true);
                        if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                            TVal obj_val;
                            obj_val.set_object(hobj);
                            if (invoke_getter(vm, &res.acc, &obj_val, (uint)insn.a,
                                              act, &curr_pc, &needs_restart, regs_base)) {
                                regs_base = act.bottom;
                                break;
                            }
                            break;
                        } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
                            vm.heap.tval_copy_ref(ra, &res.data_val);
                            track_heap_store(act, ra, (uint)insn.a);
                            // Populate IC for this site.
                            // Only cache OWN property lookups (see GETPROP comment).
                            if (res.owner == hobj && res.owner != null && ic_base != null) {
                                uint pc_off = (uint)(curr_pc - 1 - code_base);
                                hobject::ICEntry* ic = ic_base + pc_off;
                                int owner_idx = res.owner.find_prop_idx(key);
                                if (owner_idx >= 0) {
                                    ic.shape_id = hobj.shape_id;
                                    ic.proto = null;  // own property
                                    ic.prop_idx = (ushort)owner_idx;
                                    ic.prop_flags = res.owner.get_prop_flags((uint)owner_idx);
                                    if (ic.key != null) { vm.heap.decref((types::HeapHeader*)ic.key); }
                                    ic.key = key;
                                    if (key != null) { ((types::HeapHeader*)key).incref(); }
                                    ic.prop_value_ptr = &res.owner.prop_values()[owner_idx];
                                    ic.cached_prop_alloc = (void*)res.owner.prop_values();
                                    // Upgrade to cached variant now that IC is populated
                                    // Keep A, B, C operands the same, just change the opcode
                                    curr_pc[-1] = bytecode::make_abc(bytecode::Opcode.GETPROPC_CACHED,
                                                                      (uint)insn.a, (uint)insn.b, (uint)insn.c);
                                    // Also populate megamorphic cache for cross-site benefit
                                    hobject::mega_cache_store(vm.heap, hobj, key, res.owner, owner_idx);
                                }
                            }
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else if (rb.is_null() || rb.is_undefined()) {
                    HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        err.prototype = vm.heap.type_err_proto;
                        char[types::ERROR_MSG_BUF] buf;
                        int len;
                        if (key_hstr != null) {
                            len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "Cannot read properties of %s (reading '%s')",
                                                 (rb.is_null() ? "null" : "undefined"),
                                                 key_hstr.get_cstr());
                        } else {
                            len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "Cannot read properties of %s",
                                                 (rb.is_null() ? "null" : "undefined"));
                        }
                        if (len > 0 && len < types::ERROR_MSG_BUF) {
                            HString* msg_str = intern_string(vm, buf[:len]);
                            TVal msg_val;
                            msg_val.set_string(msg_str);
                            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                        }
                        TVal err_val;
                        err_val.set_object(err);
                        if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                            return vm_uncaught_error(vm, &err_val);
                        }
                    } else {
                        return VM_ERROR~;
                    }
                } else if (rb.is_string()) {
                    HString* h_str = (HString*)rb.get_heapptr();
                    if (h_str != null && h_str.is_symbol() && vm.heap.symbol_proto != null) {
                        if (key_hstr != null) {
                            TVal? result = vm.heap.symbol_proto.get_prop_proto((void*)key_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra, &v);
                                track_heap_store(act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        // Auto-box string primitive: constant string key — skip numeric-index fast path
                        if (key_hstr != null) {
                            // Fast path: .length → string character count
                            if ((void*)key_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                                ra.set_fastint((long)h_str.char_length());
                                break;
                            }
                            if (vm.heap.string_proto != null) {
                                TVal? result = vm.heap.string_proto.get_prop_proto((void*)key_hstr);
                                if (try v = result) {
                                    vm.heap.tval_copy_ref(ra, &v);
                                    track_heap_store(act, ra, (uint)insn.a);
                                } else {
                                    ra.set_undefined();
                                }
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            ra.set_undefined();
                        }
                    }
                } else if (rb.is_number() || rb.is_fastint()) {
                    if (key_hstr != null && vm.heap.number_proto != null) {
                        TVal? result = vm.heap.number_proto.get_prop_proto((void*)key_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(act, ra, (uint)insn.a);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else if (rb.is_boolean()) {
                    if (key_hstr != null && vm.heap.bool_proto != null) {
                        TVal? result = vm.heap.bool_proto.get_prop_proto((void*)key_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(act, ra, (uint)insn.a);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else if (rb.is_lightfunc()) {
                    // LIGHTFUNC: resolve .name and .length from metadata, other props from Function.prototype
                    uint fn_idx = (uint)(usz)rb.get_heapptr();
                    if (key_hstr != null) {
                        if (key_hstr.equals("name")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 0)) {
                                builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
                                if (meta.name.len > 0) {
                                    HString* name_str = intern_string(vm, meta.name);
                                    vm.heap.set_reg_string(ra, name_str);
                                } else { ra.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? result = vm.heap.function_proto.get_prop_proto((void*)key_hstr);
                                if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(act, ra, (uint)insn.a); }
                                else { ra.set_undefined(); }
                            } else { ra.set_undefined(); }
                        } else if (key_hstr.equals("length")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 1)) {
                                builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
                                if (meta.arity >= 0) {
                                    ra.set_number(meta.arity);
                                } else { ra.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? result = vm.heap.function_proto.get_prop_proto((void*)key_hstr);
                                if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(act, ra, (uint)insn.a); }
                                else { ra.set_undefined(); }
                            } else { ra.set_undefined(); }
                        } else if (key_hstr.equals("prototype")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 2)) {
                                HObject* proto_obj = lightfunc_get_proto(vm, fn_idx);
                                if (proto_obj != null) {
                                    ra.set_object(proto_obj);
                                    track_heap_store(act, ra, (uint)insn.a);
                                } else { ra.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? result = vm.heap.function_proto.get_prop_proto((void*)key_hstr);
                                if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(act, ra, (uint)insn.a); }
                                else { ra.set_undefined(); }
                            } else { ra.set_undefined(); }
                        } else if (key_hstr.equals("caller") || key_hstr.equals("arguments")) {
                            // ES5 strict mode: accessing .caller and .arguments throws TypeError
                            HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = vm.heap.type_err_proto;
                                HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                HString* msg_val = intern_string(vm, "'caller' and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them");
                                TVal msg_tv;
                                msg_tv.set_string(msg_val);
                                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                                TVal err_val;
                                err_val.set_object(err);
                                if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                    return vm_uncaught_error(vm, &err_val);
                                }
                            } else {
                                return VM_ERROR~;
                            }
                        } else if (vm.heap.function_proto != null) {
                            // Walk Function.prototype for .call, .apply, .bind, etc.
                            TVal? result = vm.heap.function_proto.get_prop_proto((void*)key_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra, &v);
                                track_heap_store(act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            }
            break;

        case Opcode.GETPROPC_CACHED: {
            // Specialized GETPROPC: IC is known warm. Only checks shape_id + prop_alloc.
            // Falls back to GETPROPC if the check fails (shape changed or props reallocated).
            TVal key_tval = constants[(uint)insn.c];
            HString* key_hstr = (HString*)key_tval.get_heapptr();
            if (rb.is_object() && ic_base != null) {
                HObject* hobj = (HObject*)rb.get_heapptr();
                uint pc_off = (uint)(curr_pc - 1 - code_base);
                hobject::ICEntry* ic = ic_base + pc_off;
                if (ic.shape_id == hobj.shape_id) {
                    HObject* ic_owner = ic.proto == null ? hobj : (HObject*)ic.proto;
                    if (ic.cached_prop_alloc == (void*)ic_owner.prop_values()) {
                        TVal ic_val = *ic.prop_value_ptr;
                        if (!ic_val.is_heap_allocated()) {
                            *ra = ic_val;
                        } else {
                            vm.heap.tval_copy_ref(ra, &ic_val);
                            track_heap_store(act, ra, (uint)insn.a);
                        }
                        break;
                    }
                }
            }
            // IC miss or ic_base null: downgrade back to GETPROPC and re-execute
            curr_pc[-1] = bytecode::make_abc(bytecode::Opcode.GETPROPC,
                                            (uint)insn.a, (uint)insn.b, (uint)insn.c);
            curr_pc--;
            continue;
        }

        case Opcode.GETPROPC2: {
            // Fused two-hop property access. Executes GETPROPC twice in one dispatch.
            // Format: insn[i] = GETPROPC2 A=dst_temp, B=src, C=key1
            //         insn[i+1] = (data: A=dst_final, C=key2)
            // After execution, curr_pc advances past insn[i+1] (skips the data slot).

            TVal key1_tval = constants[(uint)insn.c];
            HString* key1_hstr = (HString*)key1_tval.get_heapptr();

            // Read second hop's destination and key from the next instruction slot
            Instruction next_insn = curr_pc[0];  // curr_pc has already advanced past insn
            uint dst2_reg = (uint)next_insn.a;
            TVal key2_tval = constants[(uint)next_insn.c];
            HString* key2_hstr = (HString*)key2_tval.get_heapptr();

            // Advance curr_pc past the data slot
            curr_pc++;

            TVal* ra2 = regs_base + dst2_reg;

            if (rb.is_object()) {
                HObject* hobj1 = (HObject*)rb.get_heapptr();
                uint pc1 = (uint)(curr_pc - 2 - code_base);  // pc of GETPROPC2

                // === Hop 1: hobj1[key1] ===
                TVal mid_val;
                mid_val.set_undefined();

                // IC fast path for hop 1
                if (ic_base != null) {
                    hobject::ICEntry* ic1 = ic_base + pc1;
                    if (ic1.key == (void*)key1_hstr && ic1.shape_id == hobj1.shape_id) {
                        HObject* owner1 = ic1.proto == null ? hobj1 : (HObject*)ic1.proto;
                        if (ic1.cached_prop_alloc == (void*)owner1.prop_values()) {
                            mid_val = *ic1.prop_value_ptr;
                        }
                    }
                }

                // Full lookup for hop 1 if IC miss
                if (mid_val.is_undefined() && key1_hstr != null) {
                    // ARRAY .length fast path
                    if (hobj1.get_class() == hobject::ObjClass.ARRAY
                        && (void*)key1_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                        mid_val.set_fastint((long)*hobj1.array_len_ptr());
                    } else {
                        void* key1 = (void*)key1_hstr;
                        hobject::PropLookupResult r1 = hobj1.get_prop_or_accessor_proto(key1, true);
                        if (r1.kind == hobject::PropLookupKind.PROP_DATA) {
                            mid_val = r1.data_val;
                            // Populate IC1 — only cache OWN property lookups (see GETPROP).
                            if (r1.owner == hobj1 && r1.owner != null && ic_base != null) {
                                hobject::ICEntry* ic1 = ic_base + pc1;
                                int idx1 = r1.owner.find_prop_idx(key1);
                                if (idx1 >= 0) {
                                    ic1.shape_id = hobj1.shape_id;
                                    ic1.proto = null;  // own property
                                    ic1.prop_idx = (ushort)idx1;
                                    if (ic1.key != null) { vm.heap.decref((types::HeapHeader*)ic1.key); }
                                    ic1.key = key1;
                                    if (key1 != null) { ((types::HeapHeader*)key1).incref(); }
                                    ic1.prop_value_ptr = &r1.owner.prop_values()[idx1];
                                    ic1.cached_prop_alloc = (void*)r1.owner.prop_values();
                                }
                            }
                        } else if (r1.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                            // Can't fuse accessors easily — abort
                            mid_val.set_undefined();
                        }
                    }
                }

                // === Hop 2: mid_val[key2] ===
                if (mid_val.is_object()) {
                    HObject* hobj2 = (HObject*)mid_val.get_heapptr();
                    uint pc2 = (uint)(curr_pc - 1 - code_base);  // pc of the data slot

                    // IC fast path for hop 2
                    if (ic_base != null && key2_hstr != null) {
                        hobject::ICEntry* ic2 = ic_base + pc2;
                        if (ic2.key == (void*)key2_hstr && ic2.shape_id == hobj2.shape_id) {
                            HObject* owner2 = ic2.proto == null ? hobj2 : (HObject*)ic2.proto;
                            if (ic2.cached_prop_alloc == (void*)owner2.prop_values()) {
                                TVal ic2_val = *ic2.prop_value_ptr;
                                if (!ic2_val.is_heap_allocated()) {
                                    *ra2 = ic2_val;
                                } else {
                                    vm.heap.tval_copy_ref(ra2, &ic2_val);
                                    track_heap_store(act, ra2, dst2_reg);
                                }
                                // Also store the intermediate result in ra (temp register)
                                if (mid_val.is_heap_allocated()) {
                                    vm.heap.tval_copy_ref(ra, &mid_val);
                                    track_heap_store(act, ra, (uint)insn.a);
                                } else {
                                    *ra = mid_val;
                                }
                                break;
                            }
                        }
                    }

                    // Full lookup for hop 2 if IC miss
                    if (key2_hstr != null) {
                        // ARRAY .length fast path
                        if (hobj2.get_class() == hobject::ObjClass.ARRAY
                            && (void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra2.set_fastint((long)*hobj2.array_len_ptr());
                        } else {
                            void* key2 = (void*)key2_hstr;
                            hobject::PropLookupResult r2 = hobj2.get_prop_or_accessor_proto(key2, true);
                            if (r2.kind == hobject::PropLookupKind.PROP_DATA) {
                                vm.heap.tval_copy_ref(ra2, &r2.data_val);
                                track_heap_store(act, ra2, dst2_reg);
                                // Populate IC2 — only cache OWN property lookups (see GETPROP).
                                if (r2.owner == hobj2 && r2.owner != null && ic_base != null) {
                                    hobject::ICEntry* ic2 = ic_base + pc2;
                                    int idx2 = r2.owner.find_prop_idx(key2);
                                    if (idx2 >= 0) {
                                        ic2.shape_id = hobj2.shape_id;
                                        ic2.proto = null;  // own property
                                        ic2.prop_idx = (ushort)idx2;
                                        if (ic2.key != null) { vm.heap.decref((types::HeapHeader*)ic2.key); }
                                        ic2.key = key2;
                                        if (key2 != null) { ((types::HeapHeader*)key2).incref(); }
                                        ic2.prop_value_ptr = &r2.owner.prop_values()[idx2];
                                        ic2.cached_prop_alloc = (void*)r2.owner.prop_values();
                                    }
                                }
                            } else if (r2.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                                // Can't fuse accessors
                                ra2.set_undefined();
                            } else {
                                ra2.set_undefined();
                            }
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_lightfunc()) {
                    // LIGHTFUNC intermediate: resolve .name/.length/.prototype from metadata,
                    // other props from Function.prototype (mirrors GETPROPC lightfunc handling).
                    uint lf_fn_idx = (uint)(usz)mid_val.get_heapptr();
                    if (key2_hstr != null) {
                        if (key2_hstr.equals("name")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx, 0)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx);
                                if (lf_meta.name.len > 0) {
                                    HString* name_str = intern_string(vm, lf_meta.name);
                                    vm.heap.set_reg_string(ra2, name_str);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("length")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx, 1)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx);
                                if (lf_meta.arity >= 0) {
                                    ra2.set_number(lf_meta.arity);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("prototype")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx, 2)) {
                                HObject* lf_proto = lightfunc_get_proto(vm, lf_fn_idx);
                                if (lf_proto != null) {
                                    ra2.set_object(lf_proto);
                                    track_heap_store(act, ra2, dst2_reg);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (vm.heap.function_proto != null) {
                            TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(act, ra2, dst2_reg); }
                            else { ra2.set_undefined(); }
                        } else { ra2.set_undefined(); }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_string()) {
                    // STRING intermediate: auto-box for hop 2 (mirrors GETPROPC string handling).
                    HString* mid_str = (HString*)mid_val.get_heapptr();
                    if (mid_str != null && mid_str.is_symbol() && vm.heap.symbol_proto != null) {
                        if (key2_hstr != null) {
                            TVal? result = vm.heap.symbol_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra2, &v);
                                track_heap_store(act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        } else {
                            ra2.set_undefined();
                        }
                    } else if (key2_hstr != null) {
                        // .length fast path
                        if ((void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra2.set_fastint((long)mid_str.char_length());
                        } else if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra2, &v);
                                track_heap_store(act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_number() || mid_val.is_fastint()) {
                    // NUMBER intermediate: auto-box for hop 2.
                    if (key2_hstr != null && vm.heap.number_proto != null) {
                        TVal? result = vm.heap.number_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_boolean()) {
                    // BOOLEAN intermediate: auto-box for hop 2.
                    if (key2_hstr != null && vm.heap.bool_proto != null) {
                        TVal? result = vm.heap.bool_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else {
                    ra2.set_undefined();
                }

                // Store intermediate result in ra (temp register)
                if (mid_val.is_heap_allocated()) {
                    vm.heap.tval_copy_ref(ra, &mid_val);
                    track_heap_store(act, ra, (uint)insn.a);
                } else {
                    *ra = mid_val;
                }
            } else if (rb.is_string()) {
                // rb is a string primitive — auto-box for hop 1, then hop 2 on the result.
                TVal mid_val;
                mid_val.set_undefined();
                HString* rb_str = (HString*)rb.get_heapptr();
                if (rb_str != null && key1_hstr != null) {
                    if (rb_str.is_symbol() && vm.heap.symbol_proto != null) {
                        TVal? result = vm.heap.symbol_proto.get_prop_proto((void*)key1_hstr);
                        if (try v = result) { mid_val = v; }
                    } else {
                        if ((void*)key1_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            mid_val.set_fastint((long)rb_str.char_length());
                        } else if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto((void*)key1_hstr);
                            if (try v = result) { mid_val = v; }
                        }
                    }
                }

                // Hop 2: mid_val[key2] (simplified — no IC)
                if (mid_val.is_object()) {
                    HObject* hobj2 = (HObject*)mid_val.get_heapptr();
                    if (hobj2 != null && key2_hstr != null) {
                        if (hobj2.get_class() == hobject::ObjClass.ARRAY
                            && (void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra2.set_fastint((long)*hobj2.array_len_ptr());
                        } else {
                            hobject::PropLookupResult r2 = hobj2.get_prop_or_accessor_proto((void*)key2_hstr, true);
                            if (r2.kind == hobject::PropLookupKind.PROP_DATA) {
                                vm.heap.tval_copy_ref(ra2, &r2.data_val);
                                track_heap_store(act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_string()) {
                    HString* mid_str = (HString*)mid_val.get_heapptr();
                    if (mid_str != null && key2_hstr != null) {
                        if ((void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra2.set_fastint((long)mid_str.char_length());
                        } else if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra2, &v);
                                track_heap_store(act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_number() || mid_val.is_fastint()) {
                    if (key2_hstr != null && vm.heap.number_proto != null) {
                        TVal? result = vm.heap.number_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_boolean()) {
                    if (key2_hstr != null && vm.heap.bool_proto != null) {
                        TVal? result = vm.heap.bool_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else {
                    ra2.set_undefined();
                }

                // Store mid_val in ra
                if (mid_val.is_heap_allocated()) {
                    vm.heap.tval_copy_ref(ra, &mid_val);
                    track_heap_store(act, ra, (uint)insn.a);
                } else {
                    *ra = mid_val;
                }
            } else {
                // rb is not an object or string — both hops fail
                ra.set_undefined();
                ra2.set_undefined();
            }
            break;
        }

        case Opcode.PUTPROP:
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();

                // Fast path: dense array indexed store (a[i] = v where i is a valid array index)
                // ES5 §15.4: array index P satisfies ToString(ToUint32(P))===P && ToUint32(P)≠2^32−1
                // Cap at 2^24 to avoid insane allocations for sparse arrays with huge indices.
                // Guard with array_part() != null — after seal/freeze the array part is
                // abandoned and elements live as named properties with proper flags.
                if ((hobj.get_class() == hobject::ObjClass.ARRAY || hobj.get_class() == hobject::ObjClass.ARGUMENTS)
                    && hobj.array_part() != null
                    && (rb.is_fastint() || rb.is_number())) {
                    long idx_long = rb.is_fastint() ? rb.get_fastint() : (long)rb.get_number();
                    if (idx_long >= 0 && idx_long < 0xFFFFFFFFL && idx_long < 0x1000000L) {
                        uint idx = (uint)idx_long;
                        if (hobj.set_array_idx(idx, *rc)) {
                            // Update .length fast: use array_length field directly (ARRAY only)
                            if (hobj.get_class() == hobject::ObjClass.ARRAY && idx >= *hobj.array_len_ptr()) {
                                *hobj.array_len_ptr() = idx + 1;
                            }
                            break;
                        }
                        // Dense write failed (index beyond capacity cap) — fall through to put_prop.
                    }
                }

                // Inline Cache fast path for own property writes (string keys only)
                if (ic_base != null && rb.is_string()) {
                    uint pc_off = (uint)(curr_pc - 1 - code_base);
                    hobject::ICEntry* ic = ic_base + pc_off;
                    void* wkey = rb.get_heapptr();
                    if (wkey != null && ic.key == wkey && ic.shape_id == hobj.shape_id && ic.proto == null) {
                        if (ic.cached_prop_alloc == (void*)hobj.prop_values()
                            && !ic.prop_flags.is_accessor
                            && ic.prop_flags.writable) {
                            vm.heap.tval_copy_ref(ic.prop_value_ptr, rc);
                            break;
                        }
                    }
                }

                // ARRAY exotic: .length write fast path — update array_length directly
                if (hobj.get_class() == hobject::ObjClass.ARRAY && rb.is_string() && rb.get_heapptr() == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                    // ES5 §15.4.5.1 step 2 (ArraySetLength): validate the new length value
                    // before truncating. ToUint32(v) must equal ToNumber(v), and the result
                    // must be < 2^32. Otherwise throw RangeError.
                    bool length_valid = true;
                    uint new_len = 0;
                    if (rc.is_undefined()) {
                        // Step 2a: undefined value throws TypeError
                        length_valid = true; // signal to throw TypeError below
                        new_len = 0;
                    } else if (rc.is_fastint()) {
                        long v = rc.get_fastint();
                        if (v < 0L || v > 0xFFFFFFFFL) {
                            length_valid = false;
                        } else {
                            new_len = (uint)v;
                        }
                    } else if (rc.is_number()) {
                        double raw = rc.get_number();
                        // NaN, ±Infinity, or non-integer, or negative, or > 2^32-1
                        if (raw != raw || raw < 0.0 || raw > 4294967295.0 || raw != math::floor(raw)) {
                            length_valid = false;
                        } else {
                            new_len = (uint)raw;
                        }
                    } else {
                        // For non-numeric values, fall through to slow path (Put → DefineOwnProperty)
                        // so the regular [[Set]] machinery handles coercion.
                        // We can't throw from here without breaking object property writes.
                        length_valid = true;
                        new_len = 0; // placeholder, will be overwritten by put_prop
                    }
                    if (!length_valid) {
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.range_err_proto;
                            HString* emsg = intern_string(vm, "Invalid array length");
                            if (emsg != null) {
                                TVal emsg_val; emsg_val.set_string(emsg);
                                HString* ekey = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                err.put_prop(ekey, emsg_val, hobject::PROP_FLAGS_WEC);
                            }
                            TVal err_val; err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                return vm_uncaught_error(vm, &err_val);
                            }
                        } else {
                            return VM_ERROR~;
                        }
                        break;
                    }
                    if (rc.is_undefined()) {
                        // TypeError: undefined is not a valid length
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.type_err_proto;
                            HString* emsg = intern_string(vm, "Invalid array length: undefined");
                            if (emsg != null) {
                                TVal emsg_val; emsg_val.set_string(emsg);
                                HString* ekey = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                err.put_prop(ekey, emsg_val, hobject::PROP_FLAGS_WEC);
                            }
                            TVal err_val; err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                return vm_uncaught_error(vm, &err_val);
                            }
                        } else {
                            return VM_ERROR~;
                        }
                        break;
                    }
                    // Only update if the value is a valid number (skip if fell through)
                    if (rc.is_fastint() || rc.is_number()) {
                        *hobj.array_len_ptr() = new_len;
                        // Also update the prop table for spec correctness
                        HString* len_str = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                        int len_slot = hobj.find_prop_idx(len_str);
                        if (len_slot >= 0) {
                            TVal new_len_tv;
                            new_len_tv.set_fastint((long)new_len);
                            TVal* props = hobj.prop_values();
                            vm.heap.tval_copy_ref(&props[len_slot], &new_len_tv);
                        }
                    }
                    break;
                }

                void* key = get_prop_key(vm, rb);
                if (key != null) {
                    // Save the value before ensure_valstack may reallocate
                    TVal put_val = *rc;

                    // Single find_prop_idx call for both existence check and accessor check
                    int exist_idx = hobj.find_prop_idx(key);
                    if (exist_idx >= 0) {
                        TVal* entry = &hobj.prop_values()[exist_idx];
                        hobject::PropFlags exist_flags = hobj.get_prop_flags((uint)exist_idx);
                        if (exist_flags.is_accessor) {
                            // Accessor property — invoke setter
                            TVal setter_fn = hobject::hobject_access_setter(*entry);
                            if (setter_fn.is_object() && setter_fn.get_heapptr() != null) {
                                HObject* setter_obj = (HObject*)setter_fn.get_heapptr();
                                if (setter_obj.is_callable() && (*setter_obj.extra_ptr()).func.comp_func != null) {
                                    CompiledFunction* target = (*setter_obj.extra_ptr()).func.comp_func;

                                    // Stage the call frame above the caller's live registers:
                                    // PUTPROP's A/B/C are arbitrary live locals, so A+1.. cannot
                                    // be used as scratch (unlike GETPROP where A is a fresh temp).
                                    // Note: vm.valstack_top is not reliable here (builtin calls
                                    // may leave it below bottom + num_regs), so use num_regs.
                                    uint callee_reg = act.func != null
                                        ? ((CompiledFunction*)act.func).num_regs
                                        : (uint)(vm.valstack_top - act.bottom);
                                    uint frame_start = callee_reg + 2;
                                    TVal* new_bottom = act.bottom + frame_start;
                                    uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

                                    if (ensure_valstack(vm, needed) && vm.activation_count < MAX_CALLS) {
                                        new_bottom = act.bottom + frame_start;
                                        TVal* caller_regs = act.bottom;

                                        // Raw stores: these slots are above the initialized frame,
                                        // so tval_copy_ref would decref stale garbage. The setter fn
                                        // and object are kept alive by the property entry and ra.
                                        caller_regs[callee_reg] = setter_fn;
                                        TVal obj_tv;
                                        obj_tv.set_object(hobj);
                                        caller_regs[callee_reg + 1] = obj_tv;

                                        Activation* new_act = &vm.activations[vm.activation_count];
                                        vm.activation_count++;
                                        new_act.max_heap_reg = 0;
                                        new_act.caller_valstack_top = vm.valstack_top;

                                        EnvRecord* setter_var_env = (*setter_obj.extra_ptr()).func.var_env;
                                        if (try fv_s = env::env_create_function_scope(vm.heap, (*setter_obj.extra_ptr()).func.var_env)) { setter_var_env = fv_s; }
                                        new_act.parent = act;
                                        new_act.func = target;
                                        new_act.var_env = setter_var_env;
                                        new_act.lex_env = setter_var_env;
                                        new_act.cat = null;
                                        new_act.curr_pc = target.code;
                                        new_act.bottom = new_bottom;
                                        new_act.retval = null;  // setter return value is discarded
                                        new_act.flags = 0;
                                        if (target.has_direct_eval()) {
                                            new_act.flags |= ACT_FLAG_DIRECT_EVAL;
                                        }
                                        vm.heap.tval_copy_ref(&new_act.this_binding, &obj_tv);

                                        TVal* new_regs = new_act.bottom;
                                        libc::memset(new_regs, 0, (usz)target.num_regs * TVal::size);
                                        vm.heap.tval_copy_ref(&new_regs[0], &put_val);

                                        vm.valstack_top = new_regs + target.num_regs;
                                        vm.valstack_bottom = new_act.bottom;

                                        act.curr_pc = curr_pc;

                                        needs_restart = true;
                                        break;
                                    }
                                }
                            }
                        } else if (!exist_flags.writable) {
                            // Strict-only engine: non-writable property assignment always throws.
                            HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = vm.heap.type_err_proto;
                                HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                HString* msg_val = intern_string(vm, "Cannot assign to read only property");
                                TVal msg_tv;
                                msg_tv.set_string(msg_val);
                                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                                TVal err_val;
                                err_val.set_object(err);
                                if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                    return vm_uncaught_error(vm, &err_val);
                                }
                            } else {
                                return VM_ERROR~;
                            }
                            break;
                        } else {
                            // Update value, preserve existing flags
                            vm.heap.tval_copy_ref(entry, &put_val);
                        }
                    } else {
                        // Property doesn't exist: check prototype for accessors
                        hobject::AccessorResult acc = hobj.find_accessor_proto(key, false);
                        if (acc.found && acc.accessor_fn.is_object() && acc.accessor_fn.get_heapptr() != null) {
                            // Invoke setter from prototype
                            HObject* setter_obj = (HObject*)acc.accessor_fn.get_heapptr();
                            if (setter_obj.is_callable() && (*setter_obj.extra_ptr()).func.comp_func != null) {
                                CompiledFunction* target = (*setter_obj.extra_ptr()).func.comp_func;

                                // Stage the call frame above the caller's live registers
                                // (see own-property setter path above).
                                uint callee_reg = act.func != null
                                    ? ((CompiledFunction*)act.func).num_regs
                                    : (uint)(vm.valstack_top - act.bottom);
                                uint frame_start = callee_reg + 2;
                                TVal* new_bottom = act.bottom + frame_start;
                                uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

                                if (ensure_valstack(vm, needed) && vm.activation_count < MAX_CALLS) {
                                    new_bottom = act.bottom + frame_start;
                                    TVal* caller_regs = act.bottom;

                                    caller_regs[callee_reg] = acc.accessor_fn;
                                    TVal obj_tv;
                                    obj_tv.set_object(acc.this_obj);
                                    caller_regs[callee_reg + 1] = obj_tv;

                                    Activation* new_act = &vm.activations[vm.activation_count];
                                    vm.activation_count++;
                                    new_act.max_heap_reg = 0;
                                    new_act.caller_valstack_top = vm.valstack_top;

                                    EnvRecord* setter_var_env = (*setter_obj.extra_ptr()).func.var_env;
                                    if (try fv_s = env::env_create_function_scope(vm.heap, (*setter_obj.extra_ptr()).func.var_env)) { setter_var_env = fv_s; }
                                    new_act.parent = act;
                                    new_act.func = target;
                                    new_act.var_env = setter_var_env;
                                    new_act.lex_env = setter_var_env;
                                    new_act.cat = null;
                                    new_act.curr_pc = target.code;
                                    new_act.bottom = new_bottom;
                                    new_act.retval = null;  // setter return value is discarded
                                    new_act.flags = 0;
                                    if (target.has_direct_eval()) {
                                        new_act.flags |= ACT_FLAG_DIRECT_EVAL;
                                    }
                                    vm.heap.tval_copy_ref(&new_act.this_binding, &obj_tv);

                                    TVal* new_regs = new_act.bottom;
                                    libc::memset(new_regs, 0, (usz)target.num_regs * TVal::size);
                                    vm.heap.tval_copy_ref(&new_regs[0], &put_val);

                                    vm.valstack_top = new_regs + target.num_regs;
                                    vm.valstack_bottom = new_act.bottom;

                                    act.curr_pc = curr_pc;

                                    needs_restart = true;
                                    break;
                                }
                            }
                        } else {
                            // No accessor: insert new property
                            if (hobj.flags.extensible) {
                                hobj.put_prop(key, put_val, hobject::PROP_FLAGS_WEC);
                            } else {
                                // ES5 §9.1.2 step 5b: if O is not extensible, throw TypeError.
                                // Strict-only engine: always throws.
                                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                                if (try err = err_raw) {
                                    err.prototype = vm.heap.type_err_proto;
                                    HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                    HString* msg_val = intern_string(vm, "Cannot add property to non-extensible object");
                                    TVal msg_tv;
                                    msg_tv.set_string(msg_val);
                                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                                    TVal err_val;
                                    err_val.set_object(err);
                                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                        return vm_uncaught_error(vm, &err_val);
                                    }
                                } else {
                                    return VM_ERROR~;
                                }
                            }
                        }
                    }
                }
            } else if (ra.is_null() || ra.is_undefined()) {
                // TypeError: Cannot set properties of null/undefined
                HString* name_hstr = null;
                if (rb.is_string()) {
                    name_hstr = (HString*)rb.get_heapptr();
                }
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len;
                    if (name_hstr != null) {
                        len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "Cannot set properties of %s (setting '%s')",
                                             (ra.is_null() ? "null" : "undefined"),
                                             name_hstr.get_cstr());
                    } else {
                        len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "Cannot set properties of %s",
                                             (ra.is_null() ? "null" : "undefined"));
                    }
                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val;
                    err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return vm_uncaught_error(vm, &err_val);
                    }
                } else {
                    return VM_ERROR~;
                }
            }
            break;

        case Opcode.DELPROP: {
            // ES5 §11.4.1: delete operator
            // A = delete B[C], where B = object, C = property key
            // Returns boolean: true if deleted or not found,
            // false if the property exists and is non-configurable.
            ra.set_boolean(true);

            if (rb.is_object()) {
                HObject* hobj = (HObject*)rb.get_heapptr();
                void* key = get_prop_key(vm, rc);
                if (key != null) {
                    if (!hobj.es_delete_prop(key)) {
                        ra.set_boolean(false);
                        // Strict-only engine: non-configurable delete always throws.
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.type_err_proto;
                            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                            HString* msg_val = intern_string(vm, "Delete failed: property is non-configurable");
                            TVal msg_tv;
                            msg_tv.set_string(msg_val);
                            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                            TVal err_val;
                            err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                return vm_uncaught_error(vm, &err_val);
                            }
                        } else {
                            return VM_ERROR~;
                        }
                    } else {
                        ra.set_boolean(true);
                    }
                }
            } else if (rb.is_lightfunc()) {
                // Handle deletion of virtual properties (name, length, prototype).
                // These are configurable:true per ES5 §15.3.5.1, so delete returns true.
                // Mark as deleted so subsequent GETPROP/hasOwn check the bitset.
                uint fn_idx = (uint)(usz)rb.get_heapptr();
                HString* key = get_prop_key(vm, rc);
                if (key != null) {
                    int bit = heap::lf_key_to_prop_bit(key);
                    if (bit >= 0) {
                        heap::lf_mark_deleted(&vm.heap.lf_deleted_props[0], fn_idx, (uint)bit);
                    }
                }
            }
            // For null, undefined, and other primitives:
            // [[Delete]] on a non-object base always returns true.
            break;
        }

        // === OBJECT / ARRAY CREATION ===

        case Opcode.NEWOBJ: {
            HObject*? new_obj = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
            if (try o = new_obj) {
                o.prototype = vm.heap.object_proto;
                ra.set_object(o);
                track_heap_store(act, ra, (uint)insn.a);
            } else {
                ra.set_undefined();
            }
            break;
        }

        case Opcode.NEWARR: {
            HObject*? new_arr = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (try a = new_arr) {
                a.prototype = vm.heap.array_proto;
                ra.set_object(a);
                track_heap_store(act, ra, (uint)insn.a);
                if (insn.a == 251) {
                }
            } else {
                ra.set_undefined();
            }
            break;
        }

        case Opcode.NEWREGEXP: {
            // A = dest register, BC = constant pool index of "/pattern/flags" string
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal raw_tv = constants[bc];
                if (raw_tv.is_string()) {
                    HString* raw_hs = (HString*)raw_tv.get_heapptr();
                    char[] raw = raw_hs.get_data();
                    usz len = raw.len;

                    // Parse "/pattern/flags" by finding the closing '/'
                    // Flags are only letters, so scan backwards past them
                    usz end_slash = len - 1;
                    while (end_slash > 0 &&
                           ((raw[end_slash] >= 'a' && raw[end_slash] <= 'z') ||
                            (raw[end_slash] >= 'A' && raw[end_slash] <= 'Z'))) {
                        end_slash--;
                    }

                    if (end_slash > 0 && raw[0] == '/' && raw[end_slash] == '/') {
                        char[] pattern_data = raw[1..end_slash - 1];
                        char[] flag_data = {};
                        if (end_slash + 1 < len) {
                            flag_data = raw[end_slash + 1..len - 1];
                        }

                        // Convert JS flags to libregexp flag bits
                        int flags = 0;
                        int js_flags = 0;  // 1=g, 2=i, 4=m, 8=s, 16=u, 32=y
                        for (usz i = 0; i < flag_data.len; i++) {
                            char f = flag_data[i];
                            if (f == 'g') {
                                js_flags |= 1;
                            } else if (f == 'i') {
                                flags |= re_bindings::RE_FLAG_IGNORECASE;
                                js_flags |= 2;
                            } else if (f == 'm') {
                                flags |= re_bindings::RE_FLAG_MULTILINE;
                                js_flags |= 4;
                            } else if (f == 's') {
                                flags |= re_bindings::RE_FLAG_DOTALL;
                                js_flags |= 8;
                            } else if (f == 'u') {
                                js_flags |= 16;
                            } else if (f == 'y') {
                                js_flags |= 32;
                            }
                        }

                        // Compile the regexp
                        // lre_compile requires a null-terminated pattern string
                        char[256] pattern_buf;
                        usz copy_len = pattern_data.len < 255 ? pattern_data.len : 255;
                        libc::memcpy(&pattern_buf, pattern_data.ptr, copy_len);
                        pattern_buf[copy_len] = 0;
                        char[128] error_buf;
                        void* compiled = re_bindings::re_compile(
                            &pattern_buf, copy_len,
                            flags, &error_buf, 128
                        );

                        if (compiled != null) {
                            HObject*? obj_raw = vm.heap.alloc_object(hobject::ObjClass.REGEXP);
                            if (try obj = obj_raw) {
                                obj.prototype = vm.heap.regexp_proto;
                                (*obj.extra_ptr()).regexp.regexp_data = compiled;
                                (*obj.extra_ptr()).regexp.flags = js_flags;
                                // Store pattern string as primitive_value
                                HString* pattern_hs = intern_string(vm, pattern_data);
                                (*obj.extra_ptr()).prim.primitive_value.set_string(pattern_hs);
                                // Set lastIndex (ES5 §15.10.7) — only own data property
                                HString* lastindex_key = intern_string(vm, "lastIndex");
                                TVal lastindex_tv;
                                lastindex_tv.set_fastint(0);
                                obj.put_prop(lastindex_key, lastindex_tv, hobject::PROP_FLAGS_WEC);
                                ra.set_object(obj);
                                track_heap_store(act, ra, (uint)insn.a);
                            } else {
                                // If alloc failed, free the compiled regexp
                                re_bindings::re_free(compiled);
                                ra.set_undefined();
                            }
                        } else {
                            // re_compile failed — still create an empty regexp object
                            // so typeof works correctly
                            HObject*? obj_raw = vm.heap.alloc_object(hobject::ObjClass.REGEXP);
                            if (try obj = obj_raw) {
                                obj.prototype = vm.heap.regexp_proto;
                                (*obj.extra_ptr()).regexp.regexp_data = null;
                                (*obj.extra_ptr()).regexp.flags = js_flags;
                                HString* pattern_hs = intern_string(vm, pattern_data);
                                (*obj.extra_ptr()).prim.primitive_value.set_string(pattern_hs);
                                ra.set_object(obj);
                                track_heap_store(act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
                            }
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            break;
        }

        case Opcode.SETALEN: {
            // A = array register, BC = element count (high-water mark)
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                uint count = insn.get_bc();
                *hobj.array_len_ptr() = count;
                HString* len_str = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                TVal len_val;
                len_val.set_fastint((long)count);
                hobj.put_prop(len_str, len_val, hobject::PROP_FLAGS_WEC);
            }
            break;
        }

        case Opcode.ARRSPRD: {
            // A = target array reg, B = index reg (in/out), C = source reg
            // Uses ES6 iterator protocol (§12.2.5.3 ArrayAccumulation SpreadElement)
            if (!ra.is_object() || ra.get_heapptr() == null) break;
            HObject* target = (HObject*)ra.get_heapptr();
            TVal src_tv = *rc;

            // null/undefined → TypeError: not iterable
            if (src_tv.is_null() || src_tv.is_undefined()) {
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[80] spr_buf;
                    int slen = libc::snprintf(&spr_buf, 80, "Cannot spread %s",
                                              (src_tv.is_null() ? "null" : "undefined"));
                    HString* msg_str = null;
                    if (slen > 0 && slen < 80) {
                        msg_str = intern_string(vm, spr_buf[:slen]);
                    }
                    if (msg_str != null) {
                        TVal msg_val; msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val; err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) return vm_uncaught_error(vm, &err_val);
                } else { return VM_ERROR~; }
                break;
            }

            // Get current target index
            long idx = 0;
            if (rb.is_fastint()) {
                idx = rb.get_fastint();
            } else if (rb.is_number()) {
                idx = (long)rb.get_number();
            }

            // --- Iterator protocol ---
            HString* iter_sym = vm.heap.iterator_symbol;
            TVal iter_method;
            bool has_method = false;
            if (iter_sym != null) {
                TVal? method_opt;
                if (src_tv.is_object() && src_tv.get_heapptr() != null) {
                    method_opt = ((HObject*)src_tv.get_heapptr()).get_prop_proto(iter_sym);
                } else if (src_tv.is_string() && vm.heap.string_proto != null) {
                    method_opt = vm.heap.string_proto.get_prop_proto(iter_sym);
                }
                if (try m = method_opt) {
                    iter_method = m;
                    bool callable = iter_method.is_lightfunc() ||
                        (iter_method.is_object() && iter_method.get_heapptr() != null &&
                         ((HObject*)iter_method.get_heapptr()).is_callable());
                    has_method = callable;
                }
            }
            if (!has_method) {
                HString* type_str = typeof_string(vm, &src_tv);
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] it_buf;
                    int it_len = libc::snprintf(&it_buf, types::ERROR_MSG_BUF, "%s is not iterable",
                                                type_str.get_cstr());
                    if (it_len > 0 && it_len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, it_buf[:it_len]);
                        if (msg_str != null) {
                            TVal msg_val; msg_val.set_string(msg_str);
                            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                        }
                    }
                    TVal err_val; err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) return vm_uncaught_error(vm, &err_val);
                } else { return VM_ERROR~; }
                break;
            }

            // Call @@iterator() with this = source
            TVal iterator = vm.heap.call_fn(vm, iter_method, null, 0, src_tv);
            if (vm_check_call_fn_error(vm)) return VM_ERROR~;
            if (!iterator.is_object() || iterator.get_heapptr() == null) { break; }

            // Loop: next() → {value, done}
            HString* next_key = intern_string(vm, "next");
            HString* done_key = intern_string(vm, "done");
            HString* value_key = intern_string(vm, "value");
            uint k = 0;
            while (vm.heap.call_fn != null) {
                HObject* iter_obj = (HObject*)iterator.get_heapptr();
                TVal? next_opt = iter_obj.get_prop_proto(next_key);
                TVal next_method;
                if (try nm = next_opt) { next_method = nm; } else { break; }
                bool callable = next_method.is_lightfunc() ||
                    (next_method.is_object() && next_method.get_heapptr() != null &&
                     ((HObject*)next_method.get_heapptr()).is_callable());
                if (!callable) { break; }

                TVal result = vm.heap.call_fn(vm, next_method, null, 0, iterator);
                if (vm_check_call_fn_error(vm)) return VM_ERROR~;
                if (!result.is_object() || result.get_heapptr() == null) { break; }

                HObject* result_obj = (HObject*)result.get_heapptr();
                TVal? done_opt = result_obj.get_prop_proto(done_key);
                bool done = false;
                if (try dv = done_opt) { done = builtins::builtin_to_boolean(&dv); }
                if (done) { break; }

                TVal? value_opt = result_obj.get_prop_proto(value_key);
                if (try vv = value_opt) {
                    HString* pk = vm.heap.int_to_hstring(idx + (long)k);
                    if (pk != null) {
                        target.put_prop(pk, vv, hobject::PROP_FLAGS_WEC);
                    }
                    k++;
                } else { break; }
            }
            // Update index register with elements actually inserted
            rb.set_fastint(idx + (long)k);
            break;
        }

        case Opcode.OBJSPRD: {
            // A = target_obj_reg, B = 0 (unused), C = source_reg
            // Copy all own enumerable properties from source to target,
            // matching Object.assign semantics (§19.1.2.2).
            if (!ra.is_object() || ra.get_heapptr() == null) break;
            HObject* target = (HObject*)ra.get_heapptr();
            TVal src_tv = *rc;

            // null/undefined → no-op (Object.assign step 2)
            if (src_tv.is_null() || src_tv.is_undefined()) break;

            // Only objects have own enumerable properties; primitives are no-ops
            if (!src_tv.is_object() || src_tv.get_heapptr() == null) break;
            HObject* source = (HObject*)src_tv.get_heapptr();

            // Copy enumerable own dense array indices (integer-keyed properties)
            if (source.array_part() != null) {
                char[12] digit_buf;
                for (uint i = 0; i < source.array_size; i++) {
                    if (!source.array_part()[i].is_undefined()) {
                        int dlen = libc::snprintf(&digit_buf, 12, "%u", i);
                        if (dlen > 0) {
                            HString* key = intern_string(vm, digit_buf[:(uint)dlen]);
                            if (key != null) {
                                TVal val = source.array_part()[i];
                                if (!target.put_prop((void*)key, val, hobject::PROP_FLAGS_WEC)) {
                                    return VM_ERROR~;
                                }
                            }
                        }
                    }
                }
            }

            // STRING exotic: enumerate character indices via lazy access
            if (source.flags.exotic_stringobj) {
                HString* prim = (HString*)(*source.extra_ptr()).prim.primitive_value.get_heapptr();
                if (prim != null) {
                    for (uint ci = 0; ci < prim.char_length(); ci++) {
                        HString* ik = vm.heap.int_to_hstring((long)ci);
                        if (ik == null) continue;
                        uint cp = prim.char_at(ci);
                        char[4] cbuf;
                        uint cblen = hstring::encode_codepoint(cp, cbuf[:4]);
                        HString* ch_str = intern_string(vm, cbuf[:cblen]);
                        if (ch_str != null) {
                            TVal ch_tv; ch_tv.set_string(ch_str);
                            if (!target.put_prop((void*)ik, ch_tv, hobject::PROP_FLAGS_WEC)) {
                                return VM_ERROR~;
                            }
                        }
                    }
                }
            }

            // Copy own named properties (enumerable only, insertion order)
            for (uint i = 0; i < source.prop_count; i++) {
                void* key = source.prop_key_at(i);
                if (key == null) continue;
                hobject::PropFlags flags = source.get_prop_flags(i);
                if (!flags.enumerable) continue;

                TVal val;
                if (flags.is_accessor) {
                    // Accessor property: invoke the getter ([[Get]] semantics)
                    TVal gs_slot = source.prop_values()[i];
                    TVal getter = hobject::hobject_access_getter(gs_slot);
                    if (getter.is_undefined() || getter.is_null()) continue;
                    // If call_fn is unavailable, skip (shouldn't happen in practice)
                    if (vm.heap.call_fn == null) continue;
                    TVal this_tv;
                    this_tv.set_object(source);
                    val = vm.heap.call_fn(vm, getter, null, 0, this_tv);
                    if (vm.heap.has_error) {
                        vm.heap.has_error = false;
                        continue;
                    }
                } else {
                    // Data property: copy directly
                    val = source.prop_values()[i];
                }

                if (!target.put_prop(key, val, hobject::PROP_FLAGS_WEC)) {
                    return VM_ERROR~;
                }
            }
            break;
        }

        case Opcode.SPREAD_ARG: {
            // A = dest start reg, B = count out reg, C = source reg
            // Uses ES6 iterator protocol (§12.3.5.1 ArgumentListEvaluation SpreadElement)
            TVal src_tv = *rc;

            // null/undefined → TypeError
            if (src_tv.is_null() || src_tv.is_undefined()) {
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[80] spr_buf;
                    int slen = libc::snprintf(&spr_buf, 80, "Cannot spread %s",
                                              (src_tv.is_null() ? "null" : "undefined"));
                    HString* msg_str = null;
                    if (slen > 0 && slen < 80) {
                        msg_str = intern_string(vm, spr_buf[:slen]);
                    }
                    if (msg_str != null) {
                        TVal msg_val; msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val; err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) return vm_uncaught_error(vm, &err_val);
                } else { return VM_ERROR~; }
                break;
            }

            // --- Iterator protocol ---
            HString* iter_sym = vm.heap.iterator_symbol;
            TVal iter_method;
            bool has_method = false;
            if (iter_sym != null) {
                TVal? method_opt;
                if (src_tv.is_object() && src_tv.get_heapptr() != null) {
                    method_opt = ((HObject*)src_tv.get_heapptr()).get_prop_proto(iter_sym);
                } else if (src_tv.is_string() && vm.heap.string_proto != null) {
                    method_opt = vm.heap.string_proto.get_prop_proto(iter_sym);
                }
                if (try m = method_opt) {
                    iter_method = m;
                    bool callable = iter_method.is_lightfunc() ||
                        (iter_method.is_object() && iter_method.get_heapptr() != null &&
                         ((HObject*)iter_method.get_heapptr()).is_callable());
                    has_method = callable;
                }
            }
            if (!has_method) {
                HString* type_str = typeof_string(vm, &src_tv);
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] it_buf;
                    int it_len = libc::snprintf(&it_buf, types::ERROR_MSG_BUF, "%s is not iterable",
                                                type_str.get_cstr());
                    if (it_len > 0 && it_len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, it_buf[:it_len]);
                        if (msg_str != null) {
                            TVal msg_val; msg_val.set_string(msg_str);
                            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                        }
                    }
                    TVal err_val; err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) return vm_uncaught_error(vm, &err_val);
                } else { return VM_ERROR~; }
                break;
            }

            // Call @@iterator() with this = source
            TVal iterator = vm.heap.call_fn(vm, iter_method, null, 0, src_tv);
            if (vm_check_call_fn_error(vm)) return VM_ERROR~;
            if (!iterator.is_object() || iterator.get_heapptr() == null) { break; }

            uint dest_start = insn.a;
            uint count_reg = insn.b;

            // Loop: next() → {value, done}
            HString* next_key = intern_string(vm, "next");
            HString* done_key = intern_string(vm, "done");
            HString* value_key = intern_string(vm, "value");
            uint k = 0;
            while (vm.heap.call_fn != null) {
                HObject* iter_obj = (HObject*)iterator.get_heapptr();
                TVal? next_opt = iter_obj.get_prop_proto(next_key);
                TVal next_method;
                if (try nm = next_opt) { next_method = nm; } else { break; }
                bool callable = next_method.is_lightfunc() ||
                    (next_method.is_object() && next_method.get_heapptr() != null &&
                     ((HObject*)next_method.get_heapptr()).is_callable());
                if (!callable) { break; }

                TVal result = vm.heap.call_fn(vm, next_method, null, 0, iterator);
                if (vm_check_call_fn_error(vm)) return VM_ERROR~;
                if (!result.is_object() || result.get_heapptr() == null) { break; }

                HObject* result_obj = (HObject*)result.get_heapptr();
                TVal? done_opt = result_obj.get_prop_proto(done_key);
                bool done = false;
                if (try dv = done_opt) { done = builtins::builtin_to_boolean(&dv); }
                if (done) { break; }

                TVal? value_opt = result_obj.get_prop_proto(value_key);
                if (try vv = value_opt) {
                    TVal* dest_slot = regs_base + dest_start + k;
                    *dest_slot = vv;
                    k++;
                } else { break; }
            }

            // Store count in output register
            TVal* count_slot = regs_base + count_reg;
            count_slot.set_fastint((long)k);
            break;
        }

        // === FUNCTION CALLS ===
        // Duktape CALL: A=result_reg, B=callee_reg, C=nargs
        // Layout: valstack[base] = callee, valstack[base+1] = this, valstack[base+2..base+1+nargs] = args
        //
        // CALL_S: same layout but nargs is read from valstack[C] at runtime

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
                TVal* nargs_slot = regs_base + insn.c;
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

            TVal* func_slot = regs_base + callee_reg;
            TVal func_val = *func_slot;

            // === Fast path: direct compiled HObject call (most common) ===
            if (func_val.is_object()) {
                HObject* hobj_fast = (HObject*)func_val.get_heapptr();
                if (hobj_fast != null && hobj_fast.is_callable() && hobj_fast.callable_kind() == hobject::CallableKind.COMPILED_FN) {
                    CompiledFunction* target_fast = (*hobj_fast.extra_ptr()).func.comp_func;
                    if (target_fast == null) { regs_base[result_reg].set_undefined(); break; }
                    if (!target_fast.is_generator()) {

                    // Async function: create Promise before entering body
                    HObject* async_prom = null;
                    if (target_fast.is_async()) {
                        HObject*? prom_raw = builtins::promise_create(vm.heap);
                        if (try p = prom_raw) {
                            async_prom = p;
                        } else {
                            regs_base[result_reg].set_undefined();
                            break;
                        }
                    }

                    // New callee frame starts right after func and this in the caller frame
                    uint frame_start = callee_reg + 2;
                    TVal* new_bottom = regs_base + frame_start;
                    uint needed = (uint)(new_bottom - vm.valstack) + target_fast.num_regs;

                    if (!ensure_valstack(vm, needed)) {
                        regs_base[result_reg].set_undefined();
                        break;
                    }

                    regs_base = act.bottom;
                    // Recompute new_bottom after realloc (act.bottom may have moved)
                    new_bottom = regs_base + frame_start;

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
                                if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                    return vm_uncaught_error(vm, &err_val);
                                }
                            } else {
                                return VM_ERROR~;
                            }
                        }
                        break;
                    }

                    // Save the 'this' value before clearing the slot, so that GC
                    // during env creation doesn't follow a stale object pointer
                    // from a previous call in the sliding-window model.
                    TVal saved_this = regs_base[callee_reg + 1];
                    regs_base[callee_reg + 1].set_undefined();

                    Activation* new_act = &vm.activations[vm.activation_count];

                    EnvRecord* fast_var_env;
                    // Skip env allocation when the callee has no local bindings —
                    // the parent's env is sufficient (no var hoisting needed).
                    if (target_fast.needs_env()) {
                        fast_var_env = (*hobj_fast.extra_ptr()).func.var_env;
                        if (try fv_f = env::env_create_function_scope(vm.heap, (*hobj_fast.extra_ptr()).func.var_env)) { fast_var_env = fv_f; }
                    } else {
                        fast_var_env = (*hobj_fast.extra_ptr()).func.var_env;
                    }
                    if (fast_var_env == null) {
                        regs_base[result_reg].set_undefined();
                        break;
                    }
                    new_act.parent = act;
                    new_act.func = target_fast;
                    new_act.var_env = fast_var_env;
                    new_act.lex_env = fast_var_env;
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
                    new_act.retval = regs_base + result_reg;
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
                        TVal* this_src = target_fast.is_arrow() ? &act.this_binding : &saved_this;
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
                    act.curr_pc = curr_pc;

                    // Direct dispatch to new activation (avoid restart overhead)
                    act = new_act;
                    vm.current_func = target_fast;
                    code_base = target_fast.code;
                    code_count = target_fast.code_count;
                    code_end = code_base + code_count;
                    ic_base = (hobject::ICEntry*)target_fast.ic_entries;
                    var_ic_base = (hobject::VarICEntry*)target_fast.var_ic_entries;
                    constants = target_fast.constants;
                    nregs = target_fast.num_regs;
                    curr_pc = act.curr_pc;
                    regs_base = act.bottom;

                    // Create arguments object if the function references 'arguments'
                    if (target_fast.uses_arguments()) {
                        HObject*? args_obj_raw = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
                        if (try args_obj = args_obj_raw) {
                            // Store arguments in dense array_part (avoids O(argc) string key allocs)
                            for (uint ai = 0; ai < nargs; ai++) {
                                args_obj.set_array_idx(ai, regs_base[ai]);
                            }
                            // ES5 §10.6: [[Prototype]] is Object.prototype
                            args_obj.prototype = vm.heap.object_proto;
                            // ES5 §10.6: define 'callee' property (writable, non-enumerable, configurable)
                            HString* callee_key = (HString*)vm.heap.strs[heap::BuiltinStr.CALLEE];
                            if (callee_key != null) {
                                TVal callee_tv;
                                callee_tv.set_object(hobj_fast);
                                args_obj.put_prop(callee_key, callee_tv, hobject::PROP_FLAGS_WC);
                            }
                            // ES5 §10.6: define 'length' property (writable, non-enumerable, configurable)
                            HString* length_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                            if (length_key != null) {
                                TVal length_tv;
                                length_tv.set_fastint((long)nargs);
                                args_obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);
                            }
                            // Declare 'arguments' in the function's var_env
                            HString* args_name = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
                            if (args_name != null) {
                                TVal args_tv;
                                args_tv.set_object(args_obj);
                                env::env_declare(new_act.var_env, args_name, args_tv);
                            }
                        }
                    }

                    continue;
                    }
                }
            }

            if (func_val.is_lightfunc()) {
                uint fn_idx = (uint)(usz)func_val.get_heapptr();

                builtins::BuiltinContext ctx;
                ctx.vm = vm;
                ctx.regs = vm.valstack;
                ctx.base_reg = (ushort)((act.bottom - vm.valstack) + callee_reg + 2);
                ctx.argc = (ushort)nargs;
                ctx.result = regs_base + result_reg;
                ctx.heap = vm.heap;
                ctx.this_val = regs_base[callee_reg + 1];
                ctx.is_constructor = false;
                ctx.needs_re_dispatch = false;
                ctx.re_nargs = 0;
                ctx.global_env = vm.global_env;
                ctx.should_throw = false;
                ctx.callee_obj = null;

                builtins::dispatch_builtin(fn_idx, &ctx);

                if (ctx.should_throw) {
                    if (!vm_throw_value(vm, ctx.throw_value, act, &curr_pc, &needs_restart)) {
                        return vm_uncaught_error(vm, &ctx.throw_value);
                    }
                    break;
                }

                if (ctx.needs_re_dispatch) {
                    // Builtin (.call/.apply/bound) modified the stack — re-dispatch
                    func_val = regs_base[callee_reg];
                    nargs = ctx.re_nargs;
                    // Fall through to OBJECT handling
                } else {
                    break;
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
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return vm_uncaught_error(vm, &err_val);
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
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
                    if (!vm_throw_value(vm, err_val2, act, &curr_pc, &needs_restart)) {
                        return vm_uncaught_error(vm, &err_val2);
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            // Handle bound function objects — dispatch to builtin_bound_call
            if (hobj.callable_kind() == hobject::CallableKind.BOUND_FN) {
                if ((*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = regs_base[callee_reg + 1];
                    ctx.is_constructor = false;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    ctx.callee_obj = hobj;
                    builtins::dispatch_builtin(fn_idx, &ctx);

                    if (ctx.should_throw) {
                        if (!vm_throw_value(vm, ctx.throw_value, act, &curr_pc, &needs_restart)) {
                            return vm_uncaught_error(vm, &ctx.throw_value);
                        }
                        break;
                    }

                    if (ctx.needs_re_dispatch) {
                        func_val = regs_base[callee_reg];
                        nargs = ctx.re_nargs;
                        // Safety: re-dispatch may produce a lightfunc (e.g., bound eval)
                        if (func_val.is_lightfunc()) {
                            uint lf_idx = (uint)(usz)func_val.get_heapptr();
                            builtins::BuiltinContext inner;
                            inner.vm = vm;
                            inner.regs = vm.valstack;
                            inner.base_reg = (ushort)((act.bottom - vm.valstack) + callee_reg + 2);
                            inner.argc = (ushort)nargs;
                            inner.result = regs_base + result_reg;
                            inner.heap = vm.heap;
                            inner.this_val = regs_base[callee_reg + 1];
                            inner.is_constructor = false;
                            inner.needs_re_dispatch = false;
                            inner.re_nargs = 0;
                            inner.global_env = vm.global_env;
                            inner.should_throw = false;
                            inner.callee_obj = null;
                            builtins::dispatch_builtin(lf_idx, &inner);
                            if (inner.should_throw) {
                                if (!vm_throw_value(vm, inner.throw_value, act, &curr_pc, &needs_restart)) {
                                    return vm_uncaught_error(vm, &inner.throw_value);
                                }
                            }
                            break;
                        }
                        if (func_val.is_object()) {
                            hobj = (HObject*)func_val.get_heapptr();
                            // Fall through to compiled function handling below
                        } else {
                            break;
                        }
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            } else if (hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN) {
                if ((*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = regs_base[callee_reg + 1];
                    ctx.is_constructor = false;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    ctx.callee_obj = hobj;
                    builtins::dispatch_builtin(fn_idx, &ctx);

                    if (ctx.should_throw) {
                        if (!vm_throw_value(vm, ctx.throw_value, act, &curr_pc, &needs_restart)) {
                            return vm_uncaught_error(vm, &ctx.throw_value);
                        }
                        break;
                    }

                    if (ctx.needs_re_dispatch) {
                        // Re-dispatch: re-read target from stack
                        func_val = regs_base[callee_reg];
                        nargs = ctx.re_nargs;
                        // Safety: check for lightfunc before casting to HObject*
                        if (func_val.is_lightfunc()) {
                            uint lf_idx = (uint)(usz)func_val.get_heapptr();
                            builtins::BuiltinContext inner;
                            inner.vm = vm;
                            inner.regs = vm.valstack;
                            inner.base_reg = (ushort)((act.bottom - vm.valstack) + callee_reg + 2);
                            inner.argc = (ushort)nargs;
                            inner.result = regs_base + result_reg;
                            inner.heap = vm.heap;
                            inner.this_val = regs_base[callee_reg + 1];
                            inner.is_constructor = false;
                            inner.needs_re_dispatch = false;
                            inner.re_nargs = 0;
                            inner.global_env = vm.global_env;
                            inner.should_throw = false;
                            inner.callee_obj = null;
                            builtins::dispatch_builtin(lf_idx, &inner);
                            if (inner.should_throw) {
                                if (!vm_throw_value(vm, inner.throw_value, act, &curr_pc, &needs_restart)) {
                                    return vm_uncaught_error(vm, &inner.throw_value);
                                }
                            }
                            break;
                        }
                        if (func_val.is_object()) {
                            hobj = (HObject*)func_val.get_heapptr();
                            if ((*hobj.extra_ptr()).func.comp_func != null) {
                                // Continue to compiled function handling below (skip error)
                            } else {
                                break;
                            }
                        } else {
                            break;
                        }
                    } else {
                        break;
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
                        if (!vm_throw_value(vm, err_val2, act, &curr_pc, &needs_restart)) {
                            return vm_uncaught_error(vm, &err_val2);
                        }
                    } else {
                        return VM_ERROR~;
                    }
                    break;
                }
            }

            CompiledFunction* target = null;
            // Safety: hobj may not have a comp_func (e.g., after bound function re-dispatch).
            // Only dereference if hobj is a compiled-function HObject.
            if (hobj != null && (*hobj.extra_ptr()).func.comp_func != null) {
                target = (*hobj.extra_ptr()).func.comp_func;
            } else {
                // Not a compiled function — result should already be set by the handler
                regs_base[result_reg].set_undefined();
                break;
            }

            // === Generator function handling (ES6 §25.3) ===
            HObject* async_prom = null;
            if (target.is_generator()) {
                // Resume path: .next()/.throw()/.return() set heap.resume_gen
                if (vm.heap.resume_gen != null && (CompiledFunction*)vm.heap.resume_gen.func == target) {
                    GeneratorState* gs = vm.heap.resume_gen;

                    if (gs.state == GEN_COMPLETED) {
                        vm.heap.resume_gen = null;
                        regs_base[result_reg].set_undefined();
                        break;
                    }

                    // .throw() on SUSPENDED_START: exception before any body code
                    // (ES6 §25.3.3.4 step 8: resume with abrupt throw completion)
                    if (gs.state == GEN_SUSPENDED_START && gs.resume_kind == THROW) {
                        gs.state = GEN_COMPLETED;
                        vm.heap.resume_gen = null;
                        // Propagate exception to the .throw() caller
                        if (!vm_throw_value(vm, gs.throw_value, act, &curr_pc, &needs_restart)) {
                            vm.has_error = true;
                            vm.heap.has_error = true;
                            if (act.retval != null) {
                                vm.heap.tval_copy_ref(act.retval, &gs.throw_value);
                            }
                        }
                        needs_restart = true;
                        break;
                    }

                    // Set state to EXECUTING
                    gs.state = GEN_EXECUTING;

                    // Calculate register layout
                    uint frame_start_r = callee_reg + 2;
                    TVal* new_bottom_r = regs_base + frame_start_r;
                    uint needed_r = (uint)(new_bottom_r - vm.valstack) + target.num_regs;

                    if (!ensure_valstack(vm, needed_r)) {
                        gs.state = GEN_SUSPENDED_YIELD;
                        regs_base[result_reg].set_undefined();
                        break;
                    }

                    regs_base = act.bottom;
                    // Recompute new_bottom after realloc (act.bottom may have moved)
                    new_bottom_r = regs_base + frame_start_r;

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
                                if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                    return vm_uncaught_error(vm, &err_val);
                                }
                            } else {
                                return VM_ERROR~;
                            }
                        }
                        break;
                    }

                    // Push activation
                    Activation* new_act_r = &vm.activations[vm.activation_count];
                    vm.activation_count++;
                    new_act_r.max_heap_reg = 0;
                    new_act_r.caller_valstack_top = vm.valstack_top;

                    new_act_r.parent = act;
                    new_act_r.func = target;
                    new_act_r.var_env = gs.var_env;
                    new_act_r.lex_env = gs.lex_env;
                    new_act_r.cat = gs.cat;
                    new_act_r.curr_pc = gs.saved_pc;
                    new_act_r.bottom = new_bottom_r;
                    new_act_r.retval = regs_base + result_reg;
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
                    act.curr_pc = curr_pc;

                    needs_restart = true;
                    break;
                }

                // Async initial call: create Promise, fall through to non-generator path
                if (target.is_async()) {
                    HObject*? prom_raw = builtins::promise_create(vm.heap);
                    if (try p = prom_raw) {
                        async_prom = p;
                    } else {
                        regs_base[result_reg].set_undefined();
                        break;
                    }
                    // Don't break — fall through to non-generator path below
                } else {
                // Initial call: create generator object, don't execute body
                // Calculate register layout
                uint frame_start = callee_reg + 2;
                TVal* new_bottom = regs_base + frame_start;
                uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

                if (!ensure_valstack(vm, needed)) {
                    regs_base[result_reg].set_undefined();
                    break;
                }

                regs_base = act.bottom;
                // Recompute new_bottom after realloc (act.bottom may have moved)
                new_bottom = regs_base + frame_start;

                // Allocate GeneratorState
                void* gs_raw = vm.heap.alloc_func(vm.heap.heap_udata, GeneratorState::size);
                if (gs_raw == null) {
                    regs_base[result_reg].set_undefined();
                    break;
                }
                GeneratorState* gs = (GeneratorState*)gs_raw;
                libc::memset(gs_raw, 0, GeneratorState::size);

                gs.state = GEN_SUSPENDED_START;
                gs.func = target;
                gs.num_regs = target.num_regs;
                gs.saved_pc = target.code;
                gs.var_env = (*hobj.extra_ptr()).func.var_env;
                gs.lex_env = (*hobj.extra_ptr()).func.lex_env;
                vm.heap.tval_copy_ref(&gs.this_binding, &regs_base[callee_reg + 1]);

                // Allocate and copy saved registers
                usz regs_bytes = (usz)target.num_regs * TVal::size;
                void* regs_raw;
                if (regs_bytes > 0) {
                    regs_raw = vm.heap.alloc_func(vm.heap.heap_udata, regs_bytes);
                    if (regs_raw == null) {
                        vm.heap.free_func(vm.heap.heap_udata, gs_raw);
                        regs_base[result_reg].set_undefined();
                        break;
                    }
                    libc::memset(regs_raw, 0, regs_bytes);
                } else {
                    regs_raw = null;
                }
                gs.saved_regs = (TVal*)regs_raw;

                // Initialize registers with args (rest = undefined for extra slots)
                TVal* base = new_bottom;
                TVal* old_args = regs_base + callee_reg + 2;
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
                    regs_base[result_reg].set_undefined();
                    break;
                }
                gen_obj.prototype = vm.heap.generator_proto;
                (*gen_obj.extra_ptr()).gen.generator_data = gs;

                // Return generator object as the call result
                TVal* result_slot = regs_base + result_reg;
                result_slot.set_object(gen_obj);
                break;
                } // end else (non-async generator initial call)
            }

            // New callee frame starts right after func and this in the caller frame
            // Layout: callee_reg = func, callee_reg+1 = this, callee_reg+2.. callee_reg+1+nargs = args
            uint frame_start = callee_reg + 2;
            TVal* new_bottom = regs_base + frame_start;
            uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

            if (!ensure_valstack(vm, needed)) {
                regs_base[result_reg].set_undefined();
                break;
            }

            regs_base = act.bottom;
            // Recompute new_bottom after realloc (act.bottom may have moved)
            new_bottom = regs_base + frame_start;

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
                        if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                            return vm_uncaught_error(vm, &err_val);
                        }
                    } else {
                        return VM_ERROR~;
                    }
                }
                break;
            }

            Activation* new_act = &vm.activations[vm.activation_count];
            vm.activation_count++;
            new_act.max_heap_reg = 0;
            new_act.caller_valstack_top = vm.valstack_top;

            EnvRecord* call_var_env2 = (*hobj.extra_ptr()).func.var_env;
            if (target.needs_env()) {
                if (try fv_c2 = env::env_create_function_scope(vm.heap, (*hobj.extra_ptr()).func.var_env)) { call_var_env2 = fv_c2; }
            }
            new_act.parent = act;
            new_act.func = target;
            new_act.var_env = call_var_env2;
            new_act.lex_env = call_var_env2;
            new_act.cat = null;
            new_act.curr_pc = target.code;
            new_act.bottom = new_bottom;
            new_act.retval = regs_base + result_reg;
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
                regs_base[result_reg].set_object(async_prom);
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
                vm.heap.tval_copy_ref(&new_act.this_binding, &act.this_binding);
            } else {
                TVal raw_this = regs_base[callee_reg + 1];
                vm.heap.tval_copy_ref(&new_act.this_binding, &raw_this);
            }

            TVal* new_regs = new_act.bottom;
            uint new_nregs = target.num_regs;

            // Copy args
            TVal* old_args = regs_base + callee_reg + 2;
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
                    // Set missing parameter registers to undefined (for default param checks).
                    // Only formal parameter slots need undefined; temp registers can stay zero.
                    uint formals = (uint)target.num_formals;
                    uint undef_limit = formals < new_nregs ? formals : new_nregs;
                    if (nargs < undef_limit) {
                        for (uint zi = nargs; zi < undef_limit; zi++) {
                            new_regs[zi].set_undefined();
                        }
                    }
                    // Zero remaining registers (temps)
                    if (undef_limit < new_nregs) {
                        libc::memset(&new_regs[undef_limit], 0, (usz)(new_nregs - undef_limit) * TVal::size);
                    }
                }
            }

            vm.valstack_top = new_regs + new_nregs;
            vm.valstack_bottom = new_act.bottom;

            // Save caller resume point before switching activations
            act.curr_pc = curr_pc;

            // Direct dispatch to new activation (avoid restart overhead)
            act = new_act;
            vm.current_func = target;
            code_base = target.code;
            code_count = target.code_count;
            code_end = code_base + code_count;
            ic_base = (hobject::ICEntry*)target.ic_entries;
            var_ic_base = (hobject::VarICEntry*)target.var_ic_entries;
            constants = target.constants;
            nregs = target.num_regs;
            curr_pc = act.curr_pc;
            regs_base = act.bottom;
            continue;
        }

        case Opcode.CALL_PROP:
            ra.set_undefined();
            break;

        case Opcode.SETPROTO: {
            // A.[[Prototype]] = B
            // ABC format: A=obj_reg, B=proto_reg
            if (!ra.is_object() || !rb.is_object()) {
                // Non-object operands — silently ignore or error
                break;
            }
            HObject* obj = (HObject*)ra.get_heapptr();
            HObject* proto = (HObject*)rb.get_heapptr();
            if (obj != null && proto != null) {
                obj.prototype = proto;
            }
            break;
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
                TVal* nargs_slot = regs_base + insn.c;
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

            TVal* super_slot = regs_base + callee_reg;
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
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return vm_uncaught_error(vm, &err_val);
                    }
                }
                break;
            }

            HObject* super_hobj = (HObject*)super_val.get_heapptr();
            if (super_hobj == null || !super_hobj.is_callable()) {
                // TypeError: not callable
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
                    if (!vm_throw_value(vm, err_val2, act, &curr_pc, &needs_restart)) {
                        return vm_uncaught_error(vm, &err_val2);
                    }
                }
                break;
            }

            // Use new.target from the current activation (set by NEW_OBJ)
            HObject* new_target = act.new_target;
            if (new_target == null) {
                // Not in a constructor — new.target is undefined
                // Fall back to simple call behavior
                // This shouldn't normally happen since super() is only valid in constructors
                ra.set_undefined();
                break;
            }

            // Handle builtin super constructors
            if (super_hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN) {
                if ((*super_hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*super_hobj.extra_ptr()).func.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((uint)(act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = regs_base[callee_reg + 1];
                    ctx.is_constructor = true;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    builtins::dispatch_builtin(fn_idx, &ctx);
                }
                break;
            }

            CompiledFunction* super_target = (*super_hobj.extra_ptr()).func.comp_func;

            // Set up activation frame for superclass constructor
            // The 'this' slot should already have new_target (set by caller)
            uint frame_start = callee_reg + 2;
            TVal* new_bottom = regs_base + frame_start;
            uint needed = (uint)(new_bottom - vm.valstack) + super_target.num_regs;

            if (!ensure_valstack(vm, needed)) {
                ra.set_undefined();
                break;
            }

            regs_base = act.bottom;
            // Recompute new_bottom after realloc (act.bottom may have moved)
            new_bottom = regs_base + frame_start;

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
                        if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                            return vm_uncaught_error(vm, &err_val);
                        }
                    } else {
                        return VM_ERROR~;
                    }
                }
                break;
            }

            Activation* new_act = &vm.activations[vm.activation_count];
            vm.activation_count++;
            new_act.max_heap_reg = 0;
            new_act.caller_valstack_top = vm.valstack_top;

            EnvRecord* super_var_env = (*super_hobj.extra_ptr()).func.var_env;
            if (try fv_su = env::env_create_function_scope(vm.heap, (*super_hobj.extra_ptr()).func.var_env)) { super_var_env = fv_su; }
            new_act.parent = act;
            new_act.func = super_target;
            new_act.var_env = super_var_env;
            new_act.lex_env = super_var_env;
            new_act.cat = null;
            new_act.curr_pc = super_target.code;
            new_act.bottom = new_bottom;
            new_act.retval = regs_base + result_reg;
            new_act.flags = ACT_FLAG_CONSTRUCT
                          | (super_target.has_direct_eval() ? ACT_FLAG_DIRECT_EVAL : 0);
            vm.heap.tval_copy_ref(&new_act.this_binding, &regs_base[callee_reg + 1]);
            new_act.new_target = new_target;  // Pass through new.target

            TVal* new_regs = new_act.bottom;
            uint new_nregs = super_target.num_regs;

            // Copy args
            TVal* old_args = regs_base + callee_reg + 2;
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
            act.curr_pc = curr_pc;

            needs_restart = true;
            break;
        }

        case Opcode.NEWTARGET: {
            // A = new.target
            HObject* nt = act.new_target;
            if (nt != null) {
                ra.set_object(nt);
                track_heap_store(act, ra, (uint)insn.a);
            } else {
                ra.set_undefined();
            }
            break;
        }

        case Opcode.NEW_OBJ: {
            // Compiler convention: A=result_reg, B=callee_reg, C=nargs
            uint result_reg = insn.a;
            uint callee_reg = insn.b;
            uint nargs = insn.c;

            TVal* func_slot = regs_base + callee_reg;
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
                        if (!vm_throw_value(vm, err_val_nc, act, &curr_pc, &needs_restart)) {
                            return vm_uncaught_error(vm, &err_val_nc);
                        }
                    } else {
                        return VM_ERROR~;
                    }
                    break;
                }

                builtins::BuiltinContext ctx;
                ctx.vm = vm;
                ctx.regs = vm.valstack;
                ctx.base_reg = (ushort)((uint)(act.bottom - vm.valstack) + callee_reg + 2);
                ctx.argc = (ushort)nargs;
                ctx.result = regs_base + result_reg;
                ctx.heap = vm.heap;
                ctx.this_val = regs_base[callee_reg + 1];
                ctx.is_constructor = true;
                ctx.needs_re_dispatch = false;
                ctx.re_nargs = 0;
                ctx.global_env = vm.global_env;
                ctx.should_throw = false;
                builtins::dispatch_builtin(fn_idx, &ctx);
                if (ctx.should_throw) {
                    if (!vm_throw_value(vm, ctx.throw_value, act, &curr_pc, &needs_restart)) {
                        return vm_uncaught_error(vm, &ctx.throw_value);
                    }
                    break;
                }
                break;
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
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return vm_uncaught_error(vm, &err_val);
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            HObject* hobj = (HObject*)func_val.get_heapptr();
            if (hobj == null || !hobj.is_callable()) {
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
                    if (!vm_throw_value(vm, err_val2, act, &curr_pc, &needs_restart)) {
                        return vm_uncaught_error(vm, &err_val2);
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            // Handle bound function objects — dispatch to builtin_bound_call
            if (hobj.callable_kind() == hobject::CallableKind.BOUND_FN) {
                if ((*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = regs_base[callee_reg + 1];
                    ctx.is_constructor = false;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    ctx.callee_obj = hobj;
                    builtins::dispatch_builtin(fn_idx, &ctx);

                    if (ctx.should_throw) {
                        if (!vm_throw_value(vm, ctx.throw_value, act, &curr_pc, &needs_restart)) {
                            return vm_uncaught_error(vm, &ctx.throw_value);
                        }
                        break;
                    }

                    if (ctx.needs_re_dispatch) {
                        func_val = regs_base[callee_reg];
                        hobj = (HObject*)func_val.get_heapptr();
                        nargs = ctx.re_nargs;
                        // Fall through to compiled function handling below
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            } else if (hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN) {
                if ((*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((uint)(act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = regs_base[callee_reg + 1];
                    ctx.is_constructor = true;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    builtins::dispatch_builtin(fn_idx, &ctx);
                    if (ctx.should_throw) {
                        if (!vm_throw_value(vm, ctx.throw_value, act, &curr_pc, &needs_restart)) {
                            return vm_uncaught_error(vm, &ctx.throw_value);
                        }
                        break;
                    }
                    break;
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
                    if (!vm_throw_value(vm, err_val2, act, &curr_pc, &needs_restart)) {
                        return vm_uncaught_error(vm, &err_val2);
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
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
                    if (!vm_throw_value(vm, err_val3, act, &curr_pc, &needs_restart)) {
                        return vm_uncaught_error(vm, &err_val3);
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            // Step 1: Create new object
            HObject*? new_obj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
            if (catch err = new_obj_raw) {
                regs_base[result_reg].set_undefined();
                break;
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
            vm.heap.tval_copy_ref(&regs_base[callee_reg + 1], &this_tval);
            uint frame_start = callee_reg + 2;
            TVal* new_bottom = regs_base + frame_start;
            uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

            if (!ensure_valstack(vm, needed)) {
                regs_base[result_reg].set_undefined();
                break;
            }

            regs_base = act.bottom;
            // Recompute new_bottom after realloc (act.bottom may have moved)
            new_bottom = regs_base + frame_start;
            func_slot = regs_base + callee_reg;

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
                        if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                            return vm_uncaught_error(vm, &err_val);
                        }
                    } else {
                        return VM_ERROR~;
                    }
                }
                break;
            }

            Activation* new_act = &vm.activations[vm.activation_count];
            vm.activation_count++;
            new_act.max_heap_reg = 0;
            new_act.caller_valstack_top = vm.valstack_top;

            EnvRecord* ctor_var_env = (*hobj.extra_ptr()).func.var_env;
            if (try fv_ct = env::env_create_function_scope(vm.heap, (*hobj.extra_ptr()).func.var_env)) { ctor_var_env = fv_ct; }
            new_act.parent = act;
            new_act.func = target;
            new_act.var_env = ctor_var_env;
            new_act.lex_env = ctor_var_env;
            new_act.cat = null;
            new_act.curr_pc = target.code;
            new_act.bottom = new_bottom;
            new_act.retval = regs_base + result_reg;
            new_act.flags = ACT_FLAG_CONSTRUCT
                          | (target.has_direct_eval() ? ACT_FLAG_DIRECT_EVAL : 0);
            vm.heap.tval_copy_ref(&new_act.this_binding, &this_tval);
            new_act.new_target = hobj;  // constructor function, not instance

            TVal* new_regs2 = new_act.bottom;
            uint new_nregs2 = target.num_regs;

            // Copy args
            TVal* old_args2 = regs_base + callee_reg + 2;
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

            act.curr_pc = curr_pc;
            needs_restart = true;
            break;
        }

        case Opcode.TAILCALL:
            break;

        // === GENERATORS ===

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

                    if (!vm_throw_value(vm, throw_val, act, &curr_pc, &needs_restart, true)) {
                        // No catcher in generator/async function.
                        vm.heap.resume_gen = null;
                        gs_lr.state = GEN_COMPLETED;

                        // For async functions: reject the async Promise and return
                        if (gs_lr.async_promise != null) {
                            HObject* async_prom = (HObject*)gs_lr.async_promise;
                            builtins::promise_settle(async_prom, builtins::PROMISE_REJECTED, &throw_val, vm.heap);
                            builtins::promise_trigger_reactions(async_prom, vm.heap, (void*)vm);
                            // Pop the single activation and return undefined
                            decref_callee_regs(vm, act);
                            vm.activation_count--;
                            TVal undef_val;
                            undef_val.set_undefined();
                            vm.heap.tval_copy_ref(&vm.return_val, &undef_val);
                            return vm.return_val;
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
                                                    &caller_act.curr_pc, &needs_restart)) {
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
                    needs_restart = true;
                    break;
                }

                if (rk == RETURN) {
                    // Inject return: mark generator complete, return to caller
                    TVal ret_val_raw = gs_lr.return_value;
                    gs_lr.state = GEN_COMPLETED;
                    gs_lr.resume_kind = NEXT;
                    vm.heap.resume_gen = null;

                    // Wrap in IteratorResult {value: ret_val, done: true}
                    HObject*? robj_raw2 = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                    TVal ret_val;
                    if (try robj2 = robj_raw2) {
                        robj2.prototype = vm.heap.object_proto;
                        HString* val_key2 = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                        if (val_key2 != null) robj2.put_prop(val_key2, ret_val_raw, hobject::PROP_FLAGS_WEC);
                        HString* done_key2 = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                        TVal done_val2;
                        done_val2.set_boolean(true);
                        if (done_key2 != null) robj2.put_prop(done_key2, done_val2, hobject::PROP_FLAGS_WEC);
                        ret_val.set_object(robj2);
                    } else {
                        ret_val = ret_val_raw;
                    }

                    // Pop the generator activation
                    if (vm.activation_count > 0) {
                        Activation* gen_act = &vm.activations[vm.activation_count - 1];
                        TVal* ret_byteoff = gen_act.retval;
                        vm.activation_count--;
                        if (vm.activation_count > 0) {
                            Activation* caller_act = &vm.activations[vm.activation_count - 1];
                            vm.valstack_bottom = caller_act.bottom;
                            if (caller_act.func != null) {
                                CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;
                                vm.valstack_top = caller_act.bottom + caller_func.num_regs;
                            }

                            if (ret_byteoff != null) {
                                vm.heap.tval_copy_ref(ret_byteoff, &ret_val);
                            }
                        }
                    }
                    needs_restart = true;
                    break;
                }

                // Normal NEXT — load resume value
                vm.heap.tval_copy_ref(&ra[0], &gs_lr.resume_value);
            }
            // If resume_gen is null (e.g., after AWAIT with non-thenable),
            // don't overwrite the register — the value is already correct.
            break;
        }

        case Opcode.AWAIT: {
            // AWAIT A — await the value in register A.
            // If the value is not a thenable, continue (no-op).
            // If the value is a settled Promise, extract the result.
            // If the value is a pending Promise, suspend and resume later.
            TVal await_val = ra[0];

            // Not an object → not a thenable, continue
            if (!await_val.is_object() || await_val.get_heapptr() == null) {
                break;
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
                        break;
                    }
                } else {
                    // Not a thenable (fault)
                    break;
                }
            }

            // Check if it's a Promise
            if (await_obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                uint pstate = builtins::promise_get_state(await_obj, 0);
                if (pstate == builtins::PROMISE_FULFILLED) {
                    // Fulfilled: extract the value into the register
                    TVal result = builtins::promise_get_result(await_obj);
                    vm.heap.tval_copy_ref(&ra[0], &result);
                    break;
                }
                if (pstate == builtins::PROMISE_REJECTED) {
                    // Rejected: throw the rejection reason.
                    // If caught by try/catch, execution continues; otherwise
                    // the error propagates (rejecting the async Promise if applicable).
                    TVal reason = builtins::promise_get_result(await_obj);
                    if (!vm_throw_value(vm, reason, act, &curr_pc, &needs_restart)) {
                        // No catcher — if async, reject the outer Promise
                        if ((act.flags & ACT_FLAG_ASYNC) != 0 && act.async_promise != null) {
                            builtins::promise_settle(act.async_promise, builtins::PROMISE_REJECTED, &reason, vm.heap);
                            builtins::promise_trigger_reactions(act.async_promise, vm.heap, (void*)vm);
                            decref_callee_regs(vm, act);
                            vm.activation_count--;
                            if (vm.activation_count == 0) {
                                TVal undef_val;
                                undef_val.set_undefined();
                                vm.heap.tval_copy_ref(&vm.return_val, &undef_val);
                                return vm.return_val;
                            }
                            act = &vm.activations[vm.activation_count - 1];
                            vm.valstack_bottom = act.bottom;
                            vm.valstack_top = act.caller_valstack_top;
                            CompiledFunction* caller_f = (CompiledFunction*)act.func;
                            if (caller_f != vm.current_func) {
                                vm.current_func = caller_f;
                                code_base = caller_f.code;
                                code_count = caller_f.code_count;
                                code_end = code_base + code_count;
                                constants = caller_f.constants;
                                ic_base = (hobject::ICEntry*)caller_f.ic_entries;
                                var_ic_base = (hobject::VarICEntry*)caller_f.var_ic_entries;
                                nregs = caller_f.num_regs;
                            }
                            curr_pc = act.curr_pc;
                            regs_base = act.bottom;
                        } else {
                            // Not async — propagate error to caller
                            vm.has_error = true;
                            vm.heap.has_error = true;
                        }
                    }
                    needs_restart = true;
                    break;
                }
                // Pending (pstate == 0): fall through to suspension below

                // Pending Promise: suspend the async function
                // 1. Allocate GeneratorState for saving execution state
                void* gs_raw = vm.heap.alloc_func(vm.heap.heap_udata, GeneratorState::size);
                if (gs_raw == null) break;
                GeneratorState* gs = (GeneratorState*)gs_raw;
                libc::memset(gs_raw, 0, GeneratorState::size);

                CompiledFunction* cur_func = (CompiledFunction*)act.func;

                gs.state = GEN_SUSPENDED_YIELD;
                gs.func = act.func;
                gs.num_regs = cur_func.num_regs;
                gs.saved_pc = curr_pc; // PC after AWAIT (points to LOAD_RESUME)
                gs.var_env = act.var_env;
                gs.lex_env = act.lex_env;
                gs.cat = act.cat;
                vm.heap.tval_copy_ref(&gs.this_binding, &act.this_binding);
                gs.async_promise = (void*)act.async_promise;
                usz regs_bytes = (usz)gs.num_regs * TVal::size;
                void* regs_mem = vm.heap.alloc_func(vm.heap.heap_udata, regs_bytes);
                if (regs_mem == null) {
                    vm.heap.free_func(vm.heap.heap_udata, gs_raw);
                    break;
                }
                gs.saved_regs = (TVal*)regs_mem;
                libc::memset(regs_mem, 0, regs_bytes);
                TVal* regs_src = act.bottom;
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
                    vm.heap.free_func(vm.heap.heap_udata, gs.saved_regs);
                    vm.heap.free_func(vm.heap.heap_udata, gs_raw);
                    break;
                }
                HObject* resume_fn = resume_raw;
                (*resume_fn.extra_ptr()).func.builtin_fn_index = (int)builtins::BUILTIN_ASYNC_RESUME;
                (*resume_fn.extra_ptr()).func.var_env = (EnvRecord*)gs;
                TVal resume_tv;
                resume_tv.set_object(resume_fn);

                // 3. Create reject callback (builtin)
                HObject*? reject_raw = vm.heap.alloc_object(hobject::ObjClass.FUNCTION);
                if (catch _e2 = reject_raw) {
                    break;
                }
                HObject* reject_fn = reject_raw;
                (*reject_fn.extra_ptr()).func.builtin_fn_index = (int)builtins::BUILTIN_ASYNC_REJECT;
                (*reject_fn.extra_ptr()).func.var_env = (EnvRecord*)gs;
                TVal reject_tv;
                reject_tv.set_object(reject_fn);

                // 4. Create reaction and add to the pending Promise
                HObject*? rxn_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (catch _e3 = rxn_raw) {
                    break;
                }
                HObject* rxn = rxn_raw;
                rxn.prototype = vm.heap.object_proto;
                HString* ff_key = builtins::builtin_intern_string(vm.heap, "onFulfilled");
                HString* rj_key = builtins::builtin_intern_string(vm.heap, "onRejected");
                if (ff_key != null) rxn.put_prop(ff_key, resume_tv, hobject::PROP_FLAGS_WEC);
                if (rj_key != null) rxn.put_prop(rj_key, reject_tv, hobject::PROP_FLAGS_WEC);
                builtins::promise_add_reaction(await_obj, rxn, vm.heap);

                // 5. Pop activation (suspend the async function)
                decref_callee_regs(vm, act);
                vm.activation_count--;
                if (vm.activation_count == 0) {
                    TVal undef_val2;
                    undef_val2.set_undefined();
                    vm.heap.tval_copy_ref(&vm.return_val, &undef_val2);
                    return vm.return_val;
                }

                // Restore caller state
                if (vm.activation_count > 0) {
                    act = &vm.activations[vm.activation_count - 1];
                    vm.valstack_bottom = act.bottom;
                    vm.valstack_top = act.caller_valstack_top;
                    CompiledFunction* caller_f = (CompiledFunction*)act.func;
                    if (caller_f != vm.current_func) {
                        vm.current_func = caller_f;
                        code_base = caller_f.code;
                        code_count = caller_f.code_count;
                        code_end = code_base + code_count;
                        constants = caller_f.constants;
                        ic_base = (hobject::ICEntry*)caller_f.ic_entries;
                        var_ic_base = (hobject::VarICEntry*)caller_f.var_ic_entries;
                        nregs = caller_f.num_regs;
                    }
                    curr_pc = act.curr_pc;
                    regs_base = act.bottom;
                }
                needs_restart = true;
                break;
            }
            // Non-Promise: continue as-is (TODO: thenable support)
            break;
        }

        case Opcode.YIELD: {
            // YIELD A — suspend generator and return {value: A, done: false}
            // heap.resume_gen was set by the .next()/.throw()/.return() builtin
            if (vm.heap.resume_gen != null) {
                GeneratorState* gs = vm.heap.resume_gen;

                // Save current state
                TVal* regs_base_r = act.bottom;
                for (uint i = 0; i < gs.num_regs; i++) {
                    vm.heap.tval_copy_ref(&gs.saved_regs[i], &regs_base_r[i]);
                }
                gs.saved_pc = curr_pc;  // curr_pc already points past YIELD
                gs.var_env = act.var_env;
                gs.lex_env = act.lex_env;
                gs.cat = act.cat;
                vm.heap.tval_copy_ref(&gs.this_binding, &act.this_binding);
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
                        TVal* ret_byteoff = yield_act.retval;

                        // Write the exception as the result (will be caught by try/catch inside generator)
                        TVal* ret_slot = ret_byteoff;
                        vm.heap.tval_copy_ref(&ret_slot[0], &gs.throw_value);

                        vm.activation_count--;
                        if (vm.activation_count > 0) {
                            Activation* caller_act2 = &vm.activations[vm.activation_count - 1];
                            vm.valstack_bottom = caller_act2.bottom;
                            if (caller_act2.func != null) {
                                CompiledFunction* caller_func2 = (CompiledFunction*)caller_act2.func;
                                vm.valstack_top = caller_act2.bottom + caller_func2.num_regs;
                            }
                        }
                    }
                    needs_restart = true;
                    break;
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
                        TVal* ret_byteoff = yield_act.retval;
                        TVal* ret_slot = ret_byteoff;
                        vm.heap.tval_copy_ref(ret_slot, &wrapped_val);

                        vm.activation_count--;
                        if (vm.activation_count > 0) {
                            Activation* caller_act2 = &vm.activations[vm.activation_count - 1];
                            vm.valstack_bottom = caller_act2.bottom;
                            if (caller_act2.func != null) {
                                CompiledFunction* caller_func2 = (CompiledFunction*)caller_act2.func;
                                vm.valstack_top = caller_act2.bottom + caller_func2.num_regs;
                            }
                        }
                    }
                    needs_restart = true;
                    break;
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
                TVal* ret_byteoff = yield_act.retval;

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

                // Write wrapped result to caller's frame
                TVal* ret_slot = ret_byteoff;
                vm.heap.tval_copy_ref(&ret_slot[0], &wrapped_val);

                vm.activation_count--;
                if (vm.activation_count > 0) {
                    Activation* caller_act2 = &vm.activations[vm.activation_count - 1];
                    vm.valstack_bottom = caller_act2.bottom;
                    if (caller_act2.func != null) {
                        CompiledFunction* caller_func2 = (CompiledFunction*)caller_act2.func;
                        vm.valstack_top = caller_act2.bottom + caller_func2.num_regs;
                    }
                }
            }
            needs_restart = true;
            break;
        }

        case Opcode.YIELD_STAR: {
            // yield* iterable — delegate to another iterable via the ES6 iterator protocol.
            // A = result_reg, B = iterable_reg, C = 0.
            TVal iterable_val = *rb;
            GeneratorState* gs = vm.heap.resume_gen;
            if (gs == null) { ra[0].set_undefined(); break; }

            HObject* iterator = null;
            TVal received_val;
            received_val.set_undefined();
            bool is_resuming = (gs.delegated_iter != null);

            // State machine: YS_CALL_NEXT → call iterator.next().
            // YS_YIELD → suspend and yield the value in `received_val`.
            const uint YS_CALL_NEXT = 0;
            const uint YS_YIELD     = 1;
            uint ys_state = YS_CALL_NEXT;

            if (is_resuming) {
                iterator = (HObject*)gs.delegated_iter;

                if (gs.resume_kind == THROW) {
                    // ES6 §25.3.2.4 step 3.b: call iterator.throw(exception)
                    HString* throw_key = intern_string(vm, "throw");
                    TVal? throw_opt = iterator.get_prop_proto(throw_key);
                    if (catch err = throw_opt) {
                        // No .throw() — propagate the exception
                        gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                        if (!vm_throw_value(vm, gs.throw_value, act, &curr_pc, &needs_restart)) {
                            gs.delegated_iter = null; gs.state = GEN_COMPLETED;
                            if (vm.activation_count > 0) {
                                Activation* a2 = &vm.activations[vm.activation_count - 1];
                                vm.activation_count--;
                                if (vm.activation_count > 0) {
                                    Activation* ca = &vm.activations[vm.activation_count - 1];
                                    vm.valstack_bottom = ca.bottom;
                                    if (ca.func != null) { CompiledFunction* cf = (CompiledFunction*)ca.func; vm.valstack_top = ca.bottom + cf.num_regs; }
                                    TVal* rb2 = a2.retval;
                                    if (rb2 != null) vm.heap.tval_copy_ref(rb2, &gs.throw_value);
                                }
                            }
                            vm.heap.resume_gen = null;
                        }
                        needs_restart = true; break;
                    }
                    TVal thr_method = throw_opt;
                    TVal itv; itv.set_object(iterator);
                    TVal[1] targs; targs[0] = gs.throw_value;
                    TVal tresult = vm.heap.call_fn(vm, thr_method, &targs, 1, itv);
                    if (vm_check_call_fn_error(vm)) return VM_ERROR~;
                    if (!tresult.is_object() || tresult.get_heapptr() == null) {
                        HObject*? er = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try e = er) {
                            e.prototype = vm.heap.type_err_proto;
                            HString* ms = intern_string(vm, "IteratorResult is not an object"); TVal mt; mt.set_string(ms);
                            HString* mk = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE]; e.put_prop(mk, mt, hobject::PROP_FLAGS_WEC);
                            TVal ev; ev.set_object(e);
                            if (!vm_throw_value(vm, ev, act, &curr_pc, &needs_restart)) return vm_uncaught_error(vm, &ev);
                        } else { return VM_ERROR~; }
                        needs_restart = true; break;
                    }
                    HObject* tro = (HObject*)tresult.get_heapptr();
                    HString* dk = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                    HString* vk = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                    TVal? do_ = tro.get_prop_proto(dk); bool td = false; TVal tv; tv.set_undefined();
                    if (try d = do_) td = builtins::builtin_to_boolean(&d);
                    if (try v = tro.get_prop_proto(vk)) tv = v;
                    gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                    if (td) { gs.delegated_iter = null; vm.heap.tval_copy_ref(&ra[0], &tv); break; }
                    received_val = tv; ys_state = YS_YIELD;
                }
                else if (gs.resume_kind == RETURN) {
                    // ES6 §25.3.2.4 step 3.c: call iterator.return(value)
                    HString* ret_key = intern_string(vm, "return");
                    TVal? ret_opt = iterator.get_prop_proto(ret_key);
                    if (catch err = ret_opt) {
                        // No .return() — complete the generator
                        gs.delegated_iter = null; gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                        HObject*? rro = vm.heap.alloc_object(hobject::ObjClass.OBJECT); TVal wrv;
                        if (try ro = rro) {
                            ro.prototype = vm.heap.object_proto;
                            HString* rvk = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                            if (rvk != null) ro.put_prop(rvk, gs.return_value, hobject::PROP_FLAGS_WEC);
                            HString* rdk = (HString*)vm.heap.strs[heap::BuiltinStr.DONE]; TVal rdt; rdt.set_boolean(true);
                            if (rdk != null) ro.put_prop(rdk, rdt, hobject::PROP_FLAGS_WEC); wrv.set_object(ro);
                        } else { wrv = gs.return_value; }
                        if (vm.activation_count > 0) {
                            Activation* ya = &vm.activations[vm.activation_count - 1];
                            vm.heap.tval_copy_ref(ya.retval, &wrv); vm.activation_count--;
                            if (vm.activation_count > 0) {
                                Activation* ca = &vm.activations[vm.activation_count - 1];
                                vm.valstack_bottom = ca.bottom;
                                if (ca.func != null) { CompiledFunction* cf = (CompiledFunction*)ca.func; vm.valstack_top = ca.bottom + cf.num_regs; }
                            }
                        }
                        needs_restart = true; break;
                    }
                    TVal ret_method = ret_opt;
                    TVal itv2; itv2.set_object(iterator);
                    TVal[1] rargs; rargs[0] = gs.return_value;
                    TVal rresult = vm.heap.call_fn(vm, ret_method, &rargs, 1, itv2);
                    if (vm_check_call_fn_error(vm)) return VM_ERROR~;
                    if (!rresult.is_object() || rresult.get_heapptr() == null) {
                        HObject*? er2 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try e2 = er2) {
                            e2.prototype = vm.heap.type_err_proto;
                            HString* ms2 = intern_string(vm, "IteratorResult is not an object"); TVal mt2; mt2.set_string(ms2);
                            HString* mk2 = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE]; e2.put_prop(mk2, mt2, hobject::PROP_FLAGS_WEC);
                            TVal ev2; ev2.set_object(e2);
                            if (!vm_throw_value(vm, ev2, act, &curr_pc, &needs_restart)) return vm_uncaught_error(vm, &ev2);
                        } else { return VM_ERROR~; }
                        needs_restart = true; break;
                    }
                    HObject* rro2 = (HObject*)rresult.get_heapptr();
                    HString* dk2 = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                    HString* vk2 = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                    TVal? do2 = rro2.get_prop_proto(dk2); bool rd = false; TVal rv; rv.set_undefined();
                    if (try d2 = do2) rd = builtins::builtin_to_boolean(&d2);
                    if (try v2 = rro2.get_prop_proto(vk2)) rv = v2;
                    gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                    if (rd) { gs.delegated_iter = null; vm.heap.tval_copy_ref(&ra[0], &rv); break; }
                    received_val = rv; ys_state = YS_YIELD;
                }
                else {
                    // NEXT resume — use resume value for iterator.next()
                    received_val = gs.resume_value; gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                }
            } else {
                // First entry: get iterator from iterable
                HString* iter_sym = vm.heap.iterator_symbol;
                if (iter_sym == null) iter_sym = builtins::ensure_iterator_symbol(vm.heap);
                if (iter_sym == null) {
                    HString* tstr = typeof_string(vm, &iterable_val);
                    HObject*? er3 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try e3 = er3) {
                        e3.prototype = vm.heap.type_err_proto;
                        char[128] buf; int bl = libc::snprintf(&buf, 128, "%s is not iterable", tstr.get_cstr());
                        if (bl > 0 && bl < 128) {
                            HString* ms3 = intern_string(vm, buf[:bl]);
                            if (ms3 != null) {
                                TVal mt3; mt3.set_string(ms3);
                                HString* mk3 = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE]; e3.put_prop(mk3, mt3, hobject::PROP_FLAGS_WEC);
                            }
                        }
                        TVal ev3; ev3.set_object(e3);
                        if (!vm_throw_value(vm, ev3, act, &curr_pc, &needs_restart)) return vm_uncaught_error(vm, &ev3);
                    } else { return VM_ERROR~; }
                    needs_restart = true; break;
                }
                TVal iter_method; bool has_method = false;
                {
                    TVal? mopt;
                    if (iterable_val.is_object() && iterable_val.get_heapptr() != null) {
                        mopt = ((HObject*)iterable_val.get_heapptr()).get_prop_proto(iter_sym);
                    } else if (iterable_val.is_string() && vm.heap.string_proto != null) {
                        mopt = vm.heap.string_proto.get_prop_proto(iter_sym);
                    }
                    if (try m = mopt) {
                        iter_method = m;
                        has_method = iter_method.is_lightfunc() ||
                            (iter_method.is_object() && iter_method.get_heapptr() != null &&
                             ((HObject*)iter_method.get_heapptr()).is_callable());
                    }
                }
                if (!has_method) {
                    HString* tstr2 = typeof_string(vm, &iterable_val);
                    HObject*? er4 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try e4 = er4) {
                        e4.prototype = vm.heap.type_err_proto;
                        char[128] buf2; int bl2 = libc::snprintf(&buf2, 128, "%s is not iterable", tstr2.get_cstr());
                        if (bl2 > 0 && bl2 < 128) {
                            HString* ms4 = intern_string(vm, buf2[:bl2]);
                            if (ms4 != null) {
                                TVal mt4; mt4.set_string(ms4);
                                HString* mk4 = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE]; e4.put_prop(mk4, mt4, hobject::PROP_FLAGS_WEC);
                            }
                        }
                        TVal ev4; ev4.set_object(e4);
                        if (!vm_throw_value(vm, ev4, act, &curr_pc, &needs_restart)) return vm_uncaught_error(vm, &ev4);
                    } else { return VM_ERROR~; }
                    needs_restart = true; break;
                }
                TVal itv3 = vm.heap.call_fn(vm, iter_method, null, 0, iterable_val);
                if (vm_check_call_fn_error(vm)) return VM_ERROR~;
                if (!itv3.is_object() || itv3.get_heapptr() == null) { ra[0].set_undefined(); break; }
                iterator = (HObject*)itv3.get_heapptr();
                gs.delegated_iter = iterator;
            }

            // State YS_CALL_NEXT: call iterator.next(received) and check done
            if (ys_state == YS_CALL_NEXT) {
                HString* nk = intern_string(vm, "next");
                TVal? no = iterator.get_prop_proto(nk);
                if (catch err = no) { ra[0].set_undefined(); break; }
                TVal nm = no;
                TVal itv4; itv4.set_object(iterator);
                TVal[1] nargs; nargs[0] = received_val;
                TVal nres = vm.heap.call_fn(vm, nm, &nargs, 1, itv4);
                if (vm_check_call_fn_error(vm)) return VM_ERROR~;
                if (!nres.is_object() || nres.get_heapptr() == null) {
                    HObject*? er5 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try e5 = er5) {
                        e5.prototype = vm.heap.type_err_proto;
                        HString* ms5 = intern_string(vm, "IteratorResult is not an object"); TVal mt5; mt5.set_string(ms5);
                        HString* mk5 = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE]; e5.put_prop(mk5, mt5, hobject::PROP_FLAGS_WEC);
                        TVal ev5; ev5.set_object(e5);
                        if (!vm_throw_value(vm, ev5, act, &curr_pc, &needs_restart)) return vm_uncaught_error(vm, &ev5);
                    } else { return VM_ERROR~; }
                    needs_restart = true; break;
                }
                HObject* nro = (HObject*)nres.get_heapptr();
                HString* dk3 = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                HString* vk3 = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                TVal? do3 = nro.get_prop_proto(dk3); bool nd = false; TVal nv; nv.set_undefined();
                if (try d3 = do3) nd = builtins::builtin_to_boolean(&d3);
                if (try v3 = nro.get_prop_proto(vk3)) nv = v3;
                if (nd) {
                    gs.delegated_iter = null; gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                    vm.heap.tval_copy_ref(&ra[0], &nv); break;
                }
                received_val = nv; ys_state = YS_YIELD;
            }

            // State YS_YIELD: suspend the generator and yield received_val
            if (ys_state == YS_YIELD) {
                for (uint i = 0; i < gs.num_regs; i++) {
                    vm.heap.tval_copy_ref(&gs.saved_regs[i], &act.bottom[i]);
                }
                gs.saved_pc = curr_pc - 1;
                gs.var_env = act.var_env; gs.lex_env = act.lex_env; gs.cat = act.cat;
                vm.heap.tval_copy_ref(&gs.this_binding, &act.this_binding);
                gs.state = GEN_SUSPENDED_YIELD;
                $if $feature(HEAP_VERIFY):
                    vm.heap.verify_roots("after_yield_star");
                    vm.heap.verify_tval_array(gs.saved_regs, gs.num_regs, "yield_star_saved_regs");
                $endif
                vm.heap.tval_copy_ref(&vm.heap.yield_value, &received_val);
                vm.heap.resume_gen = null; vm.heap.did_yield = true;
                if (vm.activation_count > 0) {
                    Activation* p_act = &vm.activations[vm.activation_count - 1];
                    TVal* p_ret = p_act.retval;
                    HObject*? p_robj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT); TVal p_wrapped;
                    if (try p_robj = p_robj_raw) {
                        p_robj.prototype = vm.heap.object_proto;
                        HString* p_vk = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                        if (p_vk != null) p_robj.put_prop(p_vk, vm.heap.yield_value, hobject::PROP_FLAGS_WEC);
                        HString* p_dk = (HString*)vm.heap.strs[heap::BuiltinStr.DONE]; TVal p_dt; p_dt.set_boolean(false);
                        if (p_dk != null) p_robj.put_prop(p_dk, p_dt, hobject::PROP_FLAGS_WEC); p_wrapped.set_object(p_robj);
                    } else { p_wrapped = vm.heap.yield_value; }
                    vm.heap.tval_copy_ref(&p_ret[0], &p_wrapped);
                    vm.activation_count--;
                    if (vm.activation_count > 0) {
                        Activation* p_caller = &vm.activations[vm.activation_count - 1];
                        vm.valstack_bottom = p_caller.bottom;
                        if (p_caller.func != null) {
                            CompiledFunction* p_cfunc = (CompiledFunction*)p_caller.func;
                            vm.valstack_top = p_caller.bottom + p_cfunc.num_regs;
                        }
                    }
                }
                needs_restart = true;
            }
            break;
        }

        // === RETURNS ===

        case Opcode.RET: {
            // Safe point: run deferred GC before returning to caller
            if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); }
            // Check for active finally catchers: if we're returning through
            // a try-finally, save the return value and jump to the finally
            // handler.  After ENDFINALLY, the saved value will be used.
            Catcher* ret_cat = (Catcher*)act.cat;
            if (ret_cat != null && ret_cat.finally_pc != null) {
                // Save return value
                ret_cat.return_val = *ra;
                // If PENDING_RETURN is already set, we're inside the finally
                // block that was entered due to an earlier return.  Just update
                // the return value and let execution continue normally —
                // ENDFINALLY at the end of the finally block will complete the
                // return with the new value.  Without this check, we'd loop
                // infinitely back to the same finally block.
                if (!(ret_cat.flags & CATCHER_FLAG_PENDING_RETURN)) {
                    ret_cat.flags |= CATCHER_FLAG_PENDING_RETURN;
                    // Jump to finally handler
                    curr_pc = ret_cat.finally_pc;
                    act.curr_pc = curr_pc;
                }
                break;
            }

            // Inline handle_return — eliminates function call overhead on every return.
            TVal val = *ra;
            Activation* callee_act = &vm.activations[vm.activation_count - 1];
            TVal* callee_result = callee_act.retval;

            // Protect the return value: if its only reference lives in a
            // callee register, decref_callee_regs below would free it.
            bool val_pinned = false;
            if (val.is_heap_allocated() && val.get_heapptr() != null) {
                ((HeapHeader*)val.get_heapptr()).incref();
                val_pinned = true;
            }

            // Decref callee registers before popping
            decref_callee_regs(vm, callee_act);

            vm.activation_count--;

            // Async function: settle promise with return value and return the promise
            if ((callee_act.flags & ACT_FLAG_ASYNC) != 0 && callee_act.async_promise != null) {
                builtins::promise_settle(callee_act.async_promise, 1, &val, vm.heap);
                builtins::promise_trigger_reactions(callee_act.async_promise, vm.heap, (void*)vm);
                // Release pin on original return value (promise now holds a ref)
                if (val_pinned) {
                    vm.heap.decref_tval(&val);
                }
                // Replace val with promise; its birth ref (refcount=1) acts as the pin
                val.set_object(callee_act.async_promise);
                val_pinned = true;
            }

            if (vm.activation_count == 0) {
                vm.heap.tval_copy_ref(&vm.return_val, &val);
                if (val_pinned) vm.heap.decref_tval(&val);
                return vm.return_val;
            }
            // Write return value to caller's result register
            if (callee_result != null) {
                // Constructor: if callee returned an object, use it; otherwise use 'this'
                if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
                    if (val.is_object()) {
                        vm.heap.tval_copy_ref(callee_result, &val);
                    } else {
                        vm.heap.tval_copy_ref(callee_result, &callee_act.this_binding);
                    }
                } else {
                    // Fast path: skip refcounting when return value is not a heap ref
                    if (!val.is_heap_allocated()) {
                        if (callee_result.is_heap_allocated()) {
                            vm.heap.decref_tval(callee_result);
                        }
                        *callee_result = val;
                    } else if (val_pinned) {
                        // Transfer the pin reference: decref dst, raw write.
                        vm.heap.decref_tval(callee_result);
                        *callee_result = val;
                        val_pinned = false;
                    } else {
                        vm.heap.tval_copy_ref(callee_result, &val);
                    }
                }
            }
            if (val_pinned) vm.heap.decref_tval(&val);
            // Restore caller state inline — skip outer loop restart.
            act = &vm.activations[vm.activation_count - 1];
            vm.valstack_bottom = act.bottom;
            vm.valstack_top = act.caller_valstack_top;
            CompiledFunction* caller_func = (CompiledFunction*)act.func;
            if (caller_func != vm.current_func) {
                vm.current_func = caller_func;
                code_base = caller_func.code;
                code_count = caller_func.code_count;
                code_end = code_base + code_count;
                constants = caller_func.constants;
                ic_base = (hobject::ICEntry*)caller_func.ic_entries;
                var_ic_base = (hobject::VarICEntry*)caller_func.var_ic_entries;
                nregs = caller_func.num_regs;
            }
            curr_pc = act.curr_pc;
            regs_base = act.bottom;
            continue;
        }

        case Opcode.RETUNDEF: {
            // Safe point: run deferred GC before returning to caller
            if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); }
            // Check for active finally catchers (same as RET)
            Catcher* ret2_cat = (Catcher*)act.cat;
            if (ret2_cat != null && ret2_cat.finally_pc != null) {
                ret2_cat.return_val.set_undefined();
                if (!(ret2_cat.flags & CATCHER_FLAG_PENDING_RETURN)) {
                    ret2_cat.flags |= CATCHER_FLAG_PENDING_RETURN;
                    curr_pc = ret2_cat.finally_pc;
                    act.curr_pc = curr_pc;
                }
                break;
            }

            TVal undef_val;
            undef_val.set_undefined();

            // Inline handle_return — eliminates function call overhead.
            Activation* callee_act = &vm.activations[vm.activation_count - 1];
            TVal* callee_result = callee_act.retval;

            // Decref callee registers before popping
            decref_callee_regs(vm, callee_act);

            vm.activation_count--;

            // Async function: settle promise with undefined, return promise
            bool async_ret = false;
            if ((callee_act.flags & ACT_FLAG_ASYNC) != 0 && callee_act.async_promise != null) {
                builtins::promise_settle(callee_act.async_promise, 1, &undef_val, vm.heap);
                builtins::promise_trigger_reactions(callee_act.async_promise, vm.heap, (void*)vm);
                undef_val.set_object(callee_act.async_promise);
                async_ret = true;
            }

            if (vm.activation_count == 0) {
                vm.heap.tval_copy_ref(&vm.return_val, &undef_val);
                if (async_ret) vm.heap.decref_tval(&undef_val);
                return vm.return_val;
            }
            // Write return value to caller's result register
            if (callee_result != null) {
                // Constructor: return 'this' (the newly created object)
                if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
                    vm.heap.tval_copy_ref(callee_result, &callee_act.this_binding);
                } else {
                    if (callee_result.is_heap_allocated()) {
                        vm.heap.decref_tval(callee_result);
                    }
                    *callee_result = undef_val;
                }
            }
            // Restore caller state inline — skip outer loop restart.
            act = &vm.activations[vm.activation_count - 1];
            vm.valstack_bottom = act.bottom;
            vm.valstack_top = act.caller_valstack_top;
            CompiledFunction* caller_func = (CompiledFunction*)act.func;
            if (caller_func != vm.current_func) {
                vm.current_func = caller_func;
                code_base = caller_func.code;
                code_count = caller_func.code_count;
                code_end = code_base + code_count;
                constants = caller_func.constants;
                ic_base = (hobject::ICEntry*)caller_func.ic_entries;
                var_ic_base = (hobject::VarICEntry*)caller_func.var_ic_entries;
                nregs = caller_func.num_regs;
            }
            curr_pc = act.curr_pc;
            regs_base = act.bottom;
            continue;
        }

        case Opcode.RET_GEN: {
            // Generator return: mark completed, wrap in IteratorResult
            GeneratorState* gs = vm.heap.resume_gen;
            gs.state = GEN_COMPLETED;
            vm.heap.tval_copy_ref(&vm.heap.yield_value, &ra[0]);
            vm.heap.did_yield = false;
            vm.heap.resume_gen = null;

            HObject*? robj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
            TVal wrapped_val;
            if (try robj = robj_raw) {
                robj.prototype = vm.heap.object_proto;
                HString* val_key = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                if (val_key != null) robj.put_prop(val_key, ra[0], hobject::PROP_FLAGS_WEC);
                HString* done_key = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                TVal done_val;
                done_val.set_boolean(true);
                if (done_key != null) robj.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);
                wrapped_val.set_object(robj);
            } else {
                wrapped_val = ra[0];
            }

            Activation* ret_act = &vm.activations[vm.activation_count - 1];
            TVal* ret_byteoff = ret_act.retval;
            TVal* ret_slot = ret_byteoff;
            vm.heap.tval_copy_ref(&ret_slot[0], &wrapped_val);

            vm.activation_count--;
            if (vm.activation_count > 0) {
                Activation* caller_act = &vm.activations[vm.activation_count - 1];
                vm.valstack_bottom = caller_act.bottom;
                if (caller_act.func != null) {
                    CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;
                    vm.valstack_top = caller_act.bottom + caller_func.num_regs;
                }
            }
            needs_restart = true;
            break;
        }

        case Opcode.RETUNDEF_GEN: {
            // Generator return undefined: mark completed
            GeneratorState* gs2 = vm.heap.resume_gen;
            gs2.state = GEN_COMPLETED;
            vm.heap.did_yield = false;
            vm.heap.resume_gen = null;

            // Wrap in IteratorResult {value: undefined, done: true}
            HObject*? robj_raw2 = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
            TVal wrapped_val2;
            if (try robj2 = robj_raw2) {
                robj2.prototype = vm.heap.object_proto;
                HString* val_key2 = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                TVal undef_val2;
                undef_val2.set_undefined();
                if (val_key2 != null) robj2.put_prop(val_key2, undef_val2, hobject::PROP_FLAGS_WEC);
                HString* done_key2 = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                TVal done_val2;
                done_val2.set_boolean(true);
                if (done_key2 != null) robj2.put_prop(done_key2, done_val2, hobject::PROP_FLAGS_WEC);
                wrapped_val2.set_object(robj2);
            } else {
                TVal undef_val2;
                undef_val2.set_undefined();
                wrapped_val2 = undef_val2;
            }

            Activation* ret_act2 = &vm.activations[vm.activation_count - 1];
            TVal* ret_byteoff2 = ret_act2.retval;
            TVal* ret_slot2 = ret_byteoff2;
            vm.heap.tval_copy_ref(&ret_slot2[0], &wrapped_val2);

            vm.activation_count--;
            if (vm.activation_count > 0) {
                Activation* caller_act2 = &vm.activations[vm.activation_count - 1];
                vm.valstack_bottom = caller_act2.bottom;
                if (caller_act2.func != null) {
                    CompiledFunction* caller_func2 = (CompiledFunction*)caller_act2.func;
                    vm.valstack_top = caller_act2.bottom + caller_func2.num_regs;
                }
            }
            needs_restart = true;
            break;
        }

        // === VARIABLE ACCESS ===

        case Opcode.GETVAR: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    // --- Variable IC fast path ---
                    if (var_ic_base != null) {
                        uint pc_off = (uint)(curr_pc - 1 - code_base);
                        hobject::VarICEntry* vic = var_ic_base + pc_off;
                        if (vic.env != null && vic.key == key && vic.search_head == (void*)act.lex_env) {
                            HObject* b = (HObject*)vic.bindings;
                            if (b.shape_id == vic.shape_id
                                && vm.heap.shapes[b.shape_id].generation == vic.generation) {
                                if (b.get_prop_flags(vic.prop_idx).is_accessor) {
                                    // Accessor property: fall through to slow path which invokes getter
                                } else {
                                    TVal v = b.prop_values()[vic.prop_idx];
                                    if (!env::is_tdz_sentinel(&v)) {
                                        vm.heap.tval_copy_ref(ra, &v);
                                        track_heap_store(act, ra, (uint)insn.a);
                                        break;
                                    }
                                    // TDZ: fall through to slow path (error)
                                }
                            }
                            vic.env = null;
                        }
                    }

                    // --- Slow path: full environment chain walk ---
                    bool found = false;
                    EnvRecord* ic_env = null;
                    int ic_prop_idx = -1;

                    // Search lexical environment first (for let/const bindings)
                    EnvRecord* cur = act.lex_env;
                    while (cur != null) {
                        int idx = cur.bindings.find_prop_idx(key);
                        if (idx >= 0) {
                            TVal v_raw = cur.bindings.prop_values()[idx];
                            if (env::is_tdz_sentinel(&v_raw)) {
                                HString* name_hstr = (HString*)key;
                                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                                if (try err = err_raw) {
                                    err.prototype = vm.heap.ref_err_proto;
                                    char[types::ERROR_MSG_BUF] buf;
                                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "Cannot access '%s' before initialization",
                                                             name_hstr.get_cstr());
                                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                                        HString* msg_str = intern_string(vm, buf[:len]);
                                        TVal msg_val;
                                        msg_val.set_string(msg_str);
                                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                                    }
                                    TVal err_val;
                                    err_val.set_object(err);
                                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                        return vm_uncaught_error(vm, &err_val);
                                    }
                                    found = true; // prevent duplicate error
                                } else {
                                    return VM_ERROR~;
                                }
                            } else if (cur.bindings.get_prop_flags((uint)idx).is_accessor) {
                                // Accessor property: invoke getter
                                TVal getter = hobject::hobject_access_getter(v_raw);
                                if (!getter.is_undefined() && !getter.is_null() && vm.heap.call_fn != null) {
                                    TVal this_tv;
                                    this_tv.set_object(cur.bindings);
                                    TVal getter_val = vm.heap.call_fn(vm, getter, null, 0, this_tv);
                                    if (vm.heap.has_error) {
                                        // Propagate error from getter
                                        vm.has_error = true;
                                        return VM_ERROR~;
                                    }
                                    vm.heap.tval_copy_ref(ra, &getter_val);
                                } else {
                                    ra.set_undefined();
                                }
                                track_heap_store(act, ra, (uint)insn.a);
                                found = true;
                                ic_env = cur;
                                ic_prop_idx = idx;
                            } else {
                                vm.heap.tval_copy_ref(ra, &v_raw);
                                track_heap_store(act, ra, (uint)insn.a);
                                found = true;
                                ic_env = cur;
                                ic_prop_idx = idx;
                            }
                            break;
                        }
                        cur = cur.parent;
                    }

                    if (!found && act.lex_env != act.var_env) {
                        // Not in lex_env — search var_env (only needed with `with` blocks)
                        EnvRecord* vcur = act.var_env;
                        while (vcur != null) {
                            int vidx = vcur.bindings.find_prop_idx(key);
                            if (vidx >= 0) {
                                if (vcur.bindings.get_prop_flags((uint)vidx).is_accessor) {
                                    TVal gs_slot = vcur.bindings.prop_values()[vidx];
                                    TVal getter = hobject::hobject_access_getter(gs_slot);
                                    if (!getter.is_undefined() && !getter.is_null() && vm.heap.call_fn != null) {
                                        TVal this_tv;
                                        this_tv.set_object(vcur.bindings);
                                        TVal getter_val = vm.heap.call_fn(vm, getter, null, 0, this_tv);
                                        if (vm.heap.has_error) { vm.has_error = true; return VM_ERROR~; }
                                        vm.heap.tval_copy_ref(ra, &getter_val);
                                    } else {
                                        ra.set_undefined();
                                    }
                                } else {
                                    TVal v2 = vcur.bindings.prop_values()[vidx];
                                    vm.heap.tval_copy_ref(ra, &v2);
                                }
                                track_heap_store(act, ra, (uint)insn.a);
                                found = true;
                                break;
                            }
                            vcur = vcur.parent;
                        }
                    }

                    if (found) {
                        // Populate IC
                        if (var_ic_base != null && ic_env != null) {
                            uint pc_off = (uint)(curr_pc - 1 - code_base);
                            hobject::VarICEntry* vic = var_ic_base + pc_off;
                            vic.env = ic_env;
                            vic.bindings = ic_env.bindings;
                            vic.shape_id = ic_env.bindings.shape_id;
                            vic.generation = vm.heap.shapes[ic_env.bindings.shape_id].generation;
                            vic.prop_idx = (ushort)ic_prop_idx;
                            if (vic.key != null) { vm.heap.decref((types::HeapHeader*)vic.key); }
                            vic.key = key;
                            if (key != null) { ((types::HeapHeader*)key).incref(); }
                            vic.search_head = (void*)act.lex_env;
                        }
                    } else {
                        // ReferenceError: variable not declared
                        HString* name_hstr = (HString*)key;
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.ref_err_proto;
                            char[types::ERROR_MSG_BUF] buf;
                            int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not defined",
                                                     name_hstr.get_cstr());
                            if (len > 0 && len < types::ERROR_MSG_BUF) {
                                HString* msg_str = intern_string(vm, buf[:len]);
                                TVal msg_val;
                                msg_val.set_string(msg_str);
                                HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                            }
                            TVal err_val;
                            err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                return vm_uncaught_error(vm, &err_val);
                            }
                        } else {
                            return VM_ERROR~;
                        }
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            break;
        }

        case Opcode.TYPEOFIDENT: {
            // ES5 §11.4.3: typeof on an unresolvable reference returns "undefined"
            // instead of throwing ReferenceError.
            // ES6: typeof on a TDZ variable THROWS ReferenceError.
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    // --- Variable IC fast path ---
                    if (var_ic_base != null) {
                        uint pc_off = (uint)(curr_pc - 1 - code_base);
                        hobject::VarICEntry* vic = var_ic_base + pc_off;
                        if (vic.env != null && vic.key == key && vic.search_head == (void*)act.lex_env) {
                            HObject* b = (HObject*)vic.bindings;
                            if (b.shape_id == vic.shape_id
                                && vm.heap.shapes[b.shape_id].generation == vic.generation) {
                                // Accessor properties store a getter/setter pair, not the
                                // actual value.  Fall through to slow path which invokes the getter.
                                if (b.get_prop_flags(vic.prop_idx).is_accessor) {
                                    // Invalidate IC — slow path will handle it.
                                } else {
                                    TVal v = b.prop_values()[vic.prop_idx];
                                    if (!env::is_tdz_sentinel(&v)) {
                                        HString* ts = typeof_string(vm, &v);
                                        vm.heap.set_reg_string(ra, ts);
                                        break;
                                    }
                                    // TDZ: fall through to slow path (error)
                                }
                            }
                            vic.env = null;
                        }
                    }

                    // --- Slow path ---
                    bool found = false;
                    EnvRecord* ic_env = null;
                    int ic_prop_idx = -1;

                    // Search lexical environment first (for let/const bindings)
                    EnvRecord* cur = act.lex_env;
                    while (cur != null) {
                        int idx = cur.bindings.find_prop_idx(key);
                        if (idx >= 0) {
                            TVal v_raw = cur.bindings.prop_values()[idx];
                            if (env::is_tdz_sentinel(&v_raw)) {
                                // TDZ: throw ReferenceError (ES6 behavior)
                                HString* name_hstr = (HString*)key;
                                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                                if (try err = err_raw) {
                                    err.prototype = vm.heap.ref_err_proto;
                                    char[types::ERROR_MSG_BUF] buf;
                                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "Cannot access '%s' before initialization",
                                                             name_hstr.get_cstr());
                                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                                        HString* msg_str = intern_string(vm, buf[:len]);
                                        TVal msg_val;
                                        msg_val.set_string(msg_str);
                                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                                    }
                                    TVal err_val;
                                    err_val.set_object(err);
                                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                        return vm_uncaught_error(vm, &err_val);
                                    }
                                } else {
                                    return VM_ERROR~;
                                }
                            } else if (cur.bindings.get_prop_flags((uint)idx).is_accessor) {
                                // Accessor property: invoke getter for typeof
                                TVal getter = hobject::hobject_access_getter(v_raw);
                                if (!getter.is_undefined() && !getter.is_null() && vm.heap.call_fn != null) {
                                    TVal this_tv;
                                    this_tv.set_object(cur.bindings);
                                    TVal getter_val = vm.heap.call_fn(vm, getter, null, 0, this_tv);
                                    if (vm.heap.has_error) {
                                        // Propagate error from getter
                                        vm.has_error = true;
                                        return VM_ERROR~;
                                    }
                                    HString* ts = typeof_string(vm, &getter_val);
                                    vm.heap.set_reg_string(ra, ts);
                                } else {
                                    // No getter → typeof returns "undefined"
                                    HString* ts = (HString*)vm.heap.strs[heap::BuiltinStr.UNDEFINED];
                                    vm.heap.set_reg_string(ra, ts);
                                }
                                found = true;
                                ic_env = cur;
                                ic_prop_idx = idx;
                            } else {
                                HString* ts = typeof_string(vm, &v_raw);
                                vm.heap.set_reg_string(ra, ts);
                                found = true;
                                ic_env = cur;
                                ic_prop_idx = idx;
                            }
                            break;
                        }
                        cur = cur.parent;
                    }

                    if (!found) {
                        // Not in lex_env — search var_env
                        EnvRecord* vcur2 = act.var_env;
                        while (vcur2 != null) {
                            int vidx2 = vcur2.bindings.find_prop_idx(key);
                            if (vidx2 >= 0) {
                                if (vcur2.bindings.get_prop_flags((uint)vidx2).is_accessor) {
                                    TVal gs_slot2 = vcur2.bindings.prop_values()[vidx2];
                                    TVal getter2 = hobject::hobject_access_getter(gs_slot2);
                                    if (!getter2.is_undefined() && !getter2.is_null() && vm.heap.call_fn != null) {
                                        TVal this_tv2;
                                        this_tv2.set_object(vcur2.bindings);
                                        TVal getter_val2 = vm.heap.call_fn(vm, getter2, null, 0, this_tv2);
                                        if (vm.heap.has_error) { vm.has_error = true; return VM_ERROR~; }
                                        HString* ts2 = typeof_string(vm, &getter_val2);
                                        vm.heap.set_reg_string(ra, ts2);
                                    } else {
                                        HString* ts2 = (HString*)vm.heap.strs[heap::BuiltinStr.UNDEFINED];
                                        vm.heap.set_reg_string(ra, ts2);
                                    }
                                } else {
                                    TVal v2 = vcur2.bindings.prop_values()[vidx2];
                                    HString* ts = typeof_string(vm, &v2);
                                    vm.heap.set_reg_string(ra, ts);
                                }
                                found = true;
                                break;
                            }
                            vcur2 = vcur2.parent;
                        }
                        if (!found) {
                            // Unresolvable reference → "undefined" (no error)
                            HString* ts = (HString*)vm.heap.strs[heap::BuiltinStr.UNDEFINED];
                            vm.heap.set_reg_string(ra, ts);
                        }
                    }

                    // Populate IC (skip for unresolvable — no env to cache)
                    if (found && var_ic_base != null && ic_env != null) {
                        uint pc_off = (uint)(curr_pc - 1 - code_base);
                        hobject::VarICEntry* vic = var_ic_base + pc_off;
                        vic.env = ic_env;
                        vic.bindings = ic_env.bindings;
                        vic.shape_id = ic_env.bindings.shape_id;
                        vic.generation = vm.heap.shapes[ic_env.bindings.shape_id].generation;
                        vic.prop_idx = (ushort)ic_prop_idx;
                        if (vic.key != null) { vm.heap.decref((types::HeapHeader*)vic.key); }
                        vic.key = key;
                        if (key != null) { ((types::HeapHeader*)key).incref(); }
                        vic.search_head = (void*)act.lex_env;
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            break;
        }

        case Opcode.PUTVAR: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();
                    // Combined single-walk: check lex_env, writability, and update in one pass
                    int put_result = env::env_try_put_lex(act.lex_env, key, *ra);
                    if (put_result == -1) {
                        // Const violation — throw TypeError
                        HString* name_hstr = (HString*)key;
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.type_err_proto;
                            char[types::ERROR_MSG_BUF] buf;
                            int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "Assignment to constant variable '%s'",
                                                     name_hstr.get_cstr());
                            if (len > 0 && len < types::ERROR_MSG_BUF) {
                                HString* msg_str = intern_string(vm, buf[:len]);
                                TVal msg_val;
                                msg_val.set_string(msg_str);
                                HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                            }
                            TVal err_val;
                            err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                return vm_uncaught_error(vm, &err_val);
                            }
                        } else {
                            return VM_ERROR~;
                        }
                        break;
                    } else if (put_result == 0) {
                        // Not in lex_env — fall through to var_env
                        env::env_put(act.var_env, key, *ra);
                    }
                    // put_result == 1: already updated in lex_env
                    // Release ra's ref — the binding now owns the reference.
                    // Without this, ra holds a stale ref into the next iteration,
                    // causing strings to leak (not reach rc=0 on binding overwrite).
                    vm.heap.decref_tval(ra);
                    ra.set_undefined();
                }
            }
            break;
        }

        case Opcode.DECLVAR: {
            // Declare a `var` binding in the immediate var_env only (no chain walk).
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    // --- VarIC fast path: skip find_prop_idx on repeat calls ---
                    if (var_ic_base != null) {
                        uint pc_off = (uint)(curr_pc - 1 - code_base);
                        hobject::VarICEntry* vic = var_ic_base + pc_off;
                        if (vic.env == (void*)act.var_env && vic.key == key) {
                            HObject* b = (HObject*)vic.bindings;
                            if (b != null && b.shape_id == vic.shape_id
                                && vm.heap.shapes[b.shape_id].generation == vic.generation) {
                                // Direct write — skip find_prop_idx + put_prop overhead
                                TVal* pv = &b.prop_values()[vic.prop_idx];
                                if (hobject::_active_heap != null && pv.is_string()) {
                                    ((heap::Heap*)hobject::_active_heap).decref_tval(pv);
                                }
                                *pv = *ra;
                                if (hobject::_active_heap != null && ra.is_string()) {
                                    void* ptr = ra.get_heapptr();
                                    if (ptr != null) ((types::HeapHeader*)ptr).incref();
                                }
                                break;
                            }
                            vic.env = null;
                        }
                    }

                    // --- Slow path: full env_declare ---
                    env::env_declare(act.var_env, key, *ra);

                    // Populate VarIC for next time
                    if (var_ic_base != null) {
                        uint pc_off = (uint)(curr_pc - 1 - code_base);
                        hobject::VarICEntry* vic = var_ic_base + pc_off;
                        HObject* b = act.var_env.bindings;
                        if (b != null) {
                            int idx = b.find_prop_idx(key);
                            if (idx >= 0) {
                                vic.env = (void*)act.var_env;
                                vic.bindings = (void*)b;
                                vic.shape_id = b.shape_id;
                                vic.generation = vm.heap.shapes[b.shape_id].generation;
                                vic.prop_idx = (ushort)idx;
                                vic.key = key;
                                vic.search_head = null;
                            }
                        }
                    }
                }
            }
            break;
        }

        case Opcode.PUTLEX: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();
                    env::env_declare_lex(act.lex_env, key, *ra);
                }
            }
            break;
        }

        case Opcode.PUTLEX_C: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();
                    act.lex_env.bindings.put_prop(key, *ra, hobject::PROP_FLAGS_EC);
                }
            }
            break;
        }

        case Opcode.INITTZ: {
            // Store the TDZ sentinel for a variable name in the current
            // lexical environment.  This marks the binding as uninitialized
            // so that GETVAR throws a ReferenceError (temporal dead zone)
            // if the variable is accessed before its PUTLEX/PUTLEX_C.
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();
                    TVal tdz = env::tdz_sentinel();
                    act.lex_env.bindings.put_prop(key, tdz, hobject::PROP_FLAGS_WEC);
                }
            }
            break;
        }

        case Opcode.DELVAR:
            ra.set_boolean(true);
            break;

        // === CLOSURES ===

        case Opcode.CLOSURE: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.inner_count) {
                CompiledFunction* template = vm.current_func.inner_funcs[bc];

                HObject*? func_obj_raw = vm.heap.alloc_object(hobject::ObjClass.FUNCTION);
                if (try func_obj = func_obj_raw) {
                    // Generator function objects inherit from GeneratorFunction.prototype,
                    // all other functions inherit from Function.prototype (ES6 §25.2.3).
                    if (template.is_generator() && vm.heap.generator_func_proto != null) {
                        func_obj.prototype = vm.heap.generator_func_proto;
                    } else {
                        func_obj.prototype = vm.heap.function_proto;
                    }
                    func_obj.flags.callable = true;
                    func_obj.flags.constructable = template.is_constructable();
                    (*func_obj.extra_ptr()).func.comp_func = template;
                    (*func_obj.extra_ptr()).func.var_env = act.var_env;
                    (*func_obj.extra_ptr()).func.lex_env = act.lex_env;

                    // Set .name property (ES6 §14.1.20: non-writable, non-enumerable, configurable)
                    // Always set name — anonymous functions get "" per spec
                    char[] name_data = template.get_name();
                    HString* name_hstr;
                    if (name_data.len > 0) {
                        name_hstr = intern_string(vm, name_data);
                    } else {
                        name_hstr = (HString*)vm.heap.strs[heap::BuiltinStr.EMPTY];
                    }
                    if (name_hstr != null) {
                        TVal name_tv;
                        name_tv.set_string(name_hstr);
                        func_obj.put_prop((HString*)vm.heap.strs[heap::BuiltinStr.NAME], name_tv, hobject::PROP_FLAGS_NWC);
                    }

                    // Set .length property (ES5 §15.3.5.1: non-writable, non-enumerable, configurable)
                    HString* len_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    TVal len_val;
                    len_val.set_fastint((long)template.num_formals);
                    func_obj.put_prop(len_key, len_val, hobject::PROP_FLAGS_NWC);

                    // Arrow functions don't get a .prototype property (ES6 §14.2.16)
                    if (!template.is_arrow()) {
                        // ES5 §13.2: create .prototype property (plain object with .constructor)
                        HObject*? proto_obj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                        if (try proto_obj = proto_obj_raw) {
                            if (template.is_generator() && vm.heap.generator_proto != null) {
                                // Generator function .prototype inherits from Generator.prototype
                                proto_obj.prototype = vm.heap.generator_proto;
                                // .constructor is inherited from Generator.prototype,
                                // no need to set it here.
                            } else {
                                proto_obj.prototype = vm.heap.object_proto;
                                // Set .constructor on the prototype object
                                HString* constr_key = (HString*)vm.heap.strs[heap::BuiltinStr.CONSTRUCTOR];
                                TVal constr_val;
                                constr_val.set_object(func_obj);
                                proto_obj.put_prop(constr_key, constr_val, hobject::PROP_FLAGS_WEC);
                            }
                            // Set .prototype on the function
                            HString* proto_key = (HString*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE];
                            TVal proto_tv;
                            proto_tv.set_object(proto_obj);
                            func_obj.put_prop(proto_key, proto_tv, hobject::PROP_FLAGS_WEC);
                        }
                    }

                    ra.set_object(func_obj);
                    track_heap_store(act, ra, (uint)insn.a);
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            break;
        }

        case Opcode.GETBOUND: {
            uint bc = insn.get_bc();
            // Constants[bc] = FASTINT depth, constants[bc+1] = STRING name
            if (bc + 1 < vm.current_func.const_count) {
                TVal depth_val = constants[bc];
                TVal name_val = constants[bc + 1];
                if ((depth_val.is_fastint() || depth_val.is_number()) && name_val.is_string()) {
                    uint depth = (uint)(depth_val.is_fastint() ? depth_val.get_fastint() : (long)depth_val.get_number());
                    void* key = name_val.get_heapptr();
                    TVal? result = env::env_get_at_depth(act.lex_env, depth, key);
                    if (try v = result) {
                        vm.heap.tval_copy_ref(ra, &v);
                        track_heap_store(act, ra, (uint)insn.a);
                    } else {
                        // Also check var_env if different
                        if (act.lex_env != act.var_env) {
                            result = env::env_get_at_depth(act.var_env, depth, key);
                            if (try v2 = result) {
                                vm.heap.tval_copy_ref(ra, &v2);
                                track_heap_store(act, ra, (uint)insn.a);
                                break;
                            }
                        }
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            break;
        }

        // === ITEraTOR ===

        case Opcode.INITFOR: {
            // ra = object to enumerate, rb = iter_state (output)
            // null/undefined → skip loop (rb = null marker)
            if (ra.is_null() || ra.is_undefined()) {
                rb.set_null();
                break;
            }

            // Get the object (ToObject for primitives)
            HObject* obj;
            if (ra.is_object()) {
                obj = (HObject*)ra.get_heapptr();
            } else if (ra.is_boolean()) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.BOOLEAN);
                if (catch _err = wrapped) { rb.set_null(); break; }
                obj = wrapped;
                obj.prototype = vm.heap.bool_proto;
                (*obj.extra_ptr()).prim.primitive_value.set_boolean(ra.get_boolean());
            } else if (ra.is_string()) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.STRING);
                if (catch _err = wrapped) { rb.set_null(); break; }
                obj = wrapped;
                obj.flags.exotic_stringobj = true;
                obj.prototype = vm.heap.string_proto;
                HString* prim_str = (HString*)ra.get_heapptr();
                (*obj.extra_ptr()).prim.primitive_value.set_string(prim_str);
                // Set .length own property (ES5 §15.5.5.1) — non-writable, non-enumerable, non-configurable.
                // Indexed character properties are served lazily via exotic_stringobj during enumeration.
                HString* len_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                TVal len_tv;
                len_tv.set_fastint((long)prim_str.char_length());
                obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC);
            } else if (ra.is_number() || ra.is_fastint()) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.NUMBER);
                if (catch _err = wrapped) { rb.set_null(); break; }
                obj = wrapped;
                obj.prototype = vm.heap.number_proto;
                vm.heap.tval_copy_ref(&(*obj.extra_ptr()).prim.primitive_value, ra);
            } else {
                rb.set_null();
                break;
            }

            // Collect enumerable keys
            ForInState* state = collect_forin_keys(vm, obj);
            if (state == null) {
                rb.set_null();
                break;
            }
            rb.set_pointer(state);
            break;
        }

        case Opcode.NEXTFOR: {
            // ra = iter_var (output key), rb = has_next (output bool)
            // rc = iter_state (input ForInState*)
            ForInState* state = (ForInState*)rc.get_heapptr();
            if (state == null || state.index >= state.count) {
                // No more keys — clean up and signal done
                if (state != null) {
                    vm.heap.free_func(vm.heap.heap_udata, state.keys);
                    vm.heap.free_func(vm.heap.heap_udata, state);
                }
                rb.set_boolean(false);
                ra.set_undefined();
                break;
            }

            // Return the next key
            vm.heap.set_reg_string(ra, state.keys[state.index]);
            state.index++;
            rb.set_boolean(true);
            break;
        }

        // === EXCEPTION HANDLING ===

        case Opcode.TRY: {
            // Encoding: A = flags (bit0=catch, bit1=finally)
            //           BC = catch_offset (from TRY PC to CATCH instruction)
            // The next instruction word stores finally_offset in its BC field.
            uint flags = insn.a;
            uint catch_offset = insn.get_bc();

            // Read the jump slot (next instruction word) for finally_offset
            Instruction jump_slot = *curr_pc;
            curr_pc++;
            act.curr_pc = curr_pc;
            uint finally_offset = jump_slot.get_bc(); // BC field stores finally offset

            // Compute absolute handler PCs
            Instruction* base_pc = curr_pc - 2; // back to TRY instruction
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
            cat.parent = (Catcher*)act.cat;
            cat.flags = flags;
            cat.thrown_val.set_undefined();
            cat.catch_pc = catch_pc;
            cat.finally_pc = finally_pc;

            act.cat = (void*)cat;
            break;
        }

        case Opcode.ENDTRY: {
            // Pop the catcher (normal exit from try block)
            Catcher* cat = (Catcher*)act.cat;
            if (cat != null) {
                act.cat = (void*)cat.parent;
                vm.heap.free_func(vm.heap.heap_udata, cat);
            }
            break;
        }

        case Opcode.THROW: {
            TVal thrown_val = *ra;
            if (!vm_throw_value(vm, thrown_val, act, &curr_pc, &needs_restart)) {
                vm.has_error = true;
                vm.heap.has_error = true;
                vm.heap.tval_copy_ref(&vm.heap.error_value, &thrown_val);
                vm.heap.tval_copy_ref(&vm.return_val, &thrown_val);
                return VM_ERROR~;
            }
            break;
        }

        case Opcode.CATCH: {
            // Read the thrown exception from the nearest catcher
            Catcher* cat = (Catcher*)act.cat;
            if (cat != null) {
                vm.heap.tval_copy_ref(ra, &cat.thrown_val);
                track_heap_store(act, ra, (uint)insn.a);

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
                    act.cat = (void*)cat.parent;
                    vm.heap.free_func(vm.heap.heap_udata, cat);
                }
            } else {
                ra.set_undefined();
            }
            break;
        }

        case Opcode.FINALLY:
            // No-op marker — the catcher's finally_pc points here.
            // When entered via normal fall-through (after catch or via jump),
            // there may or may not be a catcher on the chain.
            // Mark the catcher as "in finally" so that vm_throw_value skips it
            // if a throw occurs inside the finally block (prevents infinite loop).
            {
                Catcher* fin_cat = (Catcher*)act.cat;
                if (fin_cat != null) {
                    fin_cat.flags |= CATCHER_FLAG_IN_FINALLY;
                }
            }
            break;

        case Opcode.ENDFINALLY: {
            Catcher* cat = (Catcher*)act.cat;
            if (cat != null && (cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0) {
                // Save pending state before freeing the catcher
                bool has_pending_exc = (!cat.thrown_val.is_undefined());
                TVal pending_exc_val = cat.thrown_val;
                bool has_pending_ret = (cat.flags & CATCHER_FLAG_PENDING_RETURN) != 0;
                TVal saved_ret_val = cat.return_val;
                bool has_pending_break = (cat.flags & CATCHER_FLAG_PENDING_BREAK) != 0;
                bool has_pending_continue = (cat.flags & CATCHER_FLAG_PENDING_CONTINUE) != 0;
                Instruction* saved_pending_pc = cat.pending_pc;
                Catcher* parent_cat = (Catcher*)cat.parent;

                // Pop the finally catcher
                act.cat = (void*)parent_cat;
                vm.heap.free_func(vm.heap.heap_udata, cat);

                if (has_pending_ret) {
                    // Check if the parent catcher also has a finally — if so,
                    // propagate the pending return through it before completing.
                    if (parent_cat != null && parent_cat.finally_pc != null
                        && (parent_cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0) {
                        parent_cat.return_val = saved_ret_val;
                        parent_cat.flags |= CATCHER_FLAG_PENDING_RETURN;
                        curr_pc = parent_cat.finally_pc;
                        act.curr_pc = curr_pc;
                        break;
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
                    if (val_pinned) vm.heap.decref_tval(&val);
                    act = &vm.activations[vm.activation_count - 1];
                    vm.valstack_bottom = act.bottom;
                    vm.valstack_top = act.caller_valstack_top;
                    CompiledFunction* caller_func = (CompiledFunction*)act.func;
                    if (caller_func != vm.current_func) {
                        vm.current_func = caller_func;
                        code_base = caller_func.code;
                        code_count = caller_func.code_count;
                        code_end = code_base + code_count;
                        constants = caller_func.constants;
                        ic_base = (hobject::ICEntry*)caller_func.ic_entries;
                        var_ic_base = (hobject::VarICEntry*)caller_func.var_ic_entries;
                        nregs = caller_func.num_regs;
                    }
                    curr_pc = act.curr_pc;
                    regs_base = act.bottom;
                    break;
                }

                if (has_pending_break || has_pending_continue) {
                    // Check if the parent catcher also has a finally — if so,
                    // propagate the pending break/continue through it first.
                    if (parent_cat != null && parent_cat.finally_pc != null
                        && (parent_cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0) {
                        parent_cat.pending_pc = saved_pending_pc;
                        if (has_pending_break) {
                            parent_cat.flags |= CATCHER_FLAG_PENDING_BREAK;
                        } else {
                            parent_cat.flags |= CATCHER_FLAG_PENDING_CONTINUE;
                        }
                        curr_pc = parent_cat.finally_pc;
                        act.curr_pc = curr_pc;
                        break;
                    }
                    // All finally blocks have run — complete the break/continue
                    // by jumping to the saved target.
                    curr_pc = saved_pending_pc;
                    act.curr_pc = curr_pc;
                    break;
                }

                if (has_pending_exc) {
                    // Re-throw the pending exception
                    if (!vm_throw_value(vm, pending_exc_val, act, &curr_pc, &needs_restart)) {
                        return vm_uncaught_error(vm, &pending_exc_val);
                    }
                }
            }
            break;
        }

        // === MISC ===

        case Opcode.NOP:
            break;

        case Opcode.DEBUGGER:
            break;

        case Opcode.BREAK:
        case Opcode.CONTINUE: {
            // Compute the jump target from the signed 24-bit offset
            int sabc = insn.get_sabc();
            int target = (int)((long)(curr_pc - code_base) + (long)sabc);
            Instruction* target_pc = code_base + target;

            // Check if any active catcher has a finally handler that
            // would be bypassed by this jump.  If so, save the target
            // and redirect to the finally handler.
            Catcher* bc_cat = (Catcher*)act.cat;
            if (bc_cat != null && bc_cat.finally_pc != null
                && (bc_cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0) {
                // Save the pending jump target and flag on the catcher
                bc_cat.pending_pc = target_pc;
                if (insn.op == Opcode.BREAK) {
                    bc_cat.flags |= CATCHER_FLAG_PENDING_BREAK;
                } else {
                    bc_cat.flags |= CATCHER_FLAG_PENDING_CONTINUE;
                }
                // Jump to the finally handler
                curr_pc = bc_cat.finally_pc;
                act.curr_pc = curr_pc;
                break;
            }
            // No active finally handler — jump directly to target
            if (target < (curr_pc - code_base)) {
                if (--vm.heap.bwd_gc_budget == 0) {
                    if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); }
                    vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL;
                }
            }
            curr_pc = target_pc;
            break;
        }

        case Opcode.INITGET: {
            // A=object, B=key, C=getter_function
            // Define a getter accessor property on object A with key B.
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                void* key = get_prop_key(vm, rb);
                TVal getter_val = *rc;
                if (key != null && hobj != null) {
                    // Check if property already exists as accessor
                    int idx = hobj.find_prop_idx(key);
                    TVal* initget_props = hobj.prop_values();
                    if (idx >= 0 && hobj.get_prop_flags((uint)idx).is_accessor) {
                        // Update existing accessor's getter
                        hobject::hobject_set_access_getter(initget_props[idx], getter_val, vm.heap);
                    } else {
                        // Create new accessor property
                        TVal undef;
                        undef.set_undefined();
                        hobj.put_prop(key, hobject::hobject_create_accessors(vm.heap, getter_val, undef), hobject::PROP_FLAGS_ACCESSOR);
                    }
                }
            }
            break;
        }

        case Opcode.INITSET: {
            // A=object, B=key, C=setter_function
            // Define a setter accessor property on object A with key B.
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                void* key = get_prop_key(vm, rb);
                TVal setter_val = *rc;
                if (key != null && hobj != null) {
                    // Check if property already exists as accessor
                    int idx = hobj.find_prop_idx(key);
                    TVal* initset_props = hobj.prop_values();
                    if (idx >= 0 && hobj.get_prop_flags((uint)idx).is_accessor) {
                        // Update existing accessor's setter
                        hobject::hobject_set_access_setter(initset_props[idx], setter_val, vm.heap);
                    } else {
                        // Create new accessor property
                        TVal undef;
                        undef.set_undefined();
                        hobj.put_prop(key, hobject::hobject_create_accessors(vm.heap, undef, setter_val), hobject::PROP_FLAGS_ACCESSOR);
                    }
                }
            }
            break;
        }

        case Opcode.INITSETI:
            break;

        case Opcode.CSVARI:
            break;

        // === WITH STATEMENT REMOVED IN STRICT-ONLY MODE ===

        case Opcode.PUSH_LEX: {
            // Push a new declarative environment record onto act.lex_env.
            EnvRecord*? env_raw = env::env_create_declarative(vm.heap, act.lex_env);
            if (try new_env = env_raw) {
                act.lex_env = new_env;
            } else {
                return VM_ERROR~;
            }
            break;
        }

        case Opcode.POP_LEX: {
            // Pop the current lexical environment from the scope chain.
            if (act.lex_env != null && act.lex_env.parent != null) {
                act.lex_env = act.lex_env.parent;
            }
            break;
        }

        case Opcode.REQUIRE_OBJ: {
            // Throw TypeError if the value in register A is null or undefined.
            // Used for object destructuring pattern null/undefined check.
            if (ra.is_null() || ra.is_undefined()) {
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF,
                        "Cannot destructure '%s'",
                        (ra.is_null() ? "null" : "undefined"));
                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_tv;
                    err_tv.set_object(err);
                    if (!vm_throw_value(vm, err_tv, act, &curr_pc, &needs_restart)) {
                        return vm_uncaught_error(vm, &err_tv);
                    }
                }
            }
            break;
        }

        default:
            return VM_ERROR~;
        }
    }
    }
    return vm.return_val;
}
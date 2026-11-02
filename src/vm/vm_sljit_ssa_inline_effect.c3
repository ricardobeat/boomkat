module boomkat::vm;

import boomkat::bytecode;
import boomkat::compiler;
import boomkat::heap;
import boomkat::hobject;
import boomkat::env;
import boomkat::types;

// This first effectful consumer expands a straight-line numeric/store prefix.
// Other callee control or helper operations leave at their child PC; they do
// not disqualify the caller or replay an already committed callee effect.
fn bool ssa_effect_inline_op(Opcode op) @feat(SLJIT) {
    switch (op) {
        case NOP: case LDREG: case LDINT: case LDCONST:
        case LDUNDEF: case LDNULL: case LDTRUE: case LDFALSE:
        case ADD: case ADD_FUSED: case ADDI: case SUB: case SUBI:
        case MUL: case MULI: case DIV: case UNM:
        case GETPROPC: case GETPROPC_CACHED: case PUTPROPC:
        case RET: case RETUNDEF: return true;
        default: return false;
    }
}

fn CompiledFunction* ssa_effect_inline_target(SsaGraph* g, DecodedBytecode view) @feat(SLJIT) {
    DecodedInsn ins = view.insn;
    if (ins.op == Opcode.CALL_VAR || ins.op == Opcode.CALL_GLOBAL) {
        if (view.payload_pc >= g.cf.var_ic_count) return null;
        return function_inline_binding(g.cf, view.payload_pc, g.heap);
    }
    int callee = ssa_alias(g, g.current[ins.b]);
    if (callee < 0) return null;
    SsaValue value = g.values[callee];
    if (value.op == HELPER) {
        DecodedBytecode source = ssa_decoded_view(g, value.pc);
        if (source.insn.op == Opcode.GETVAR || source.insn.op == Opcode.GETGLOBAL) {
            if (source.payload_pc >= g.cf.var_ic_count) return null;
            return function_inline_binding(g.cf, source.payload_pc, g.heap);
        }
    }
    if (value.op == CONST_BOXED) {
        TVal boxed;
        if (!ssa_decode_boxed_bits((ulong)value.imm, &boxed)) return null;
        if (boxed.is_object() && boxed.get_heapptr() != null) {
            HObject* function = boxed.get_heapptr();
            if (function.is_callable() && !function.is_bound() && !function.is_proxy()
                && function.callable_kind() == CallableKind.COMPILED_FN) return function.extra.func.comp_func;
        }
    }
    return null;
}

fn SsaFrameId ssa_effect_child_frame(SsaGraph* g, CompiledFunction* function, SsaFrameId parent,
    DecodedBytecode call, int callee, int receiver, uint pc, int* mapped, compiler::RegSet* live) @feat(SLJIT) {
    return ssa_frame_capture_child(g, function, parent, call.pc, call.insn.a, callee, receiver,
        pc, mapped, function.num_regs, live == null ? null : live.words, live == null ? 0 : live.word_count);
}

fn int ssa_effect_inline_call(SsaGraph* g, DecodedBytecode call) @feat(SLJIT) {
    if (!g.recoverable || !function_call_op(call.insn.op)) return -1;
    CompiledFunction* target = ssa_effect_inline_target(g, call);
    bool fused = call.insn.op == Opcode.CALL_VAR || call.insn.op == Opcode.CALL_GLOBAL;
    uint base = fused ? call.insn.a : call.insn.b;
    uint argc = fused ? call.insn.b : call.insn.c;
    if (target == null || target == g.cf || !target.call_flags.lean_call || !target.call_flags.ignores_this
        || target.needs_env() || target.capture_count != 0 || target.is_class_ctor()
        || target.arguments_in_reg() || target.uses_arguments() || target.call_flags.rest_length_only
        || target.realm != g.cf.realm
        || argc != target.num_formals || target.code_count < 2 || target.code_count > g.budget.max_words
        || target.num_regs == 0 || target.num_regs > 65536) return -1;
    for (uint pc = 0; pc < target.code_count;) {
        DecodedBytecode view = bytecode::decode_bytecode(target.code, target.code_count, pc);
        if (!view.valid || !ssa_decoded_registers_fit(target, view)
            || (view.insn.op == Opcode.LDCONST && view.insn.get_bc() >= target.const_count)) return -1;
        pc = view.next_pc;
    }
    // Inspect the admitted prefix before changing the graph. Warm own-slot
    // feedback is only a hypothesis; ACCESS_FIELD emits the actual guards.
    bool effect;
    for (uint pc = 0; pc < target.code_count;) {
        DecodedBytecode view = bytecode::decode_bytecode(target.code, target.code_count, pc);
        if (!view.valid) return -1;
        if (!ssa_effect_inline_op(view.insn.op)) break;
        if (view.insn.op == Opcode.GETPROPC || view.insn.op == Opcode.GETPROPC_CACHED || view.insn.op == Opcode.PUTPROPC) {
            SsaFieldAccess access;
            if (!ssa_access_field_spec(g.heap, g.cf, view, &access, target)) return -1;
        }
        if (view.insn.op == Opcode.PUTPROPC) effect = true;
        if (view.insn.op == Opcode.RET || view.insn.op == Opcode.RETUNDEF) break;
        pc = view.next_pc;
    }
    if (!effect) return -1;
    usz bytes = (usz)target.code_count * (compiler::DecodedCfgNode::size + uint::size);
    if (!ssa_persistent_reserve(g, bytes)) return -1;
    defer ssa_persistent_release(g, bytes);
    compiler::DecodedCfg cfg;
    compiler::DecodedCfgBudget budget = { g.budget.max_words, g.budget.max_instructions, bytes };
    if (!compiler::bytecode_cfg_build(&cfg, target.code, target.code_count, g.heap, null, true,
            budget, null, &ssa_cfg_extra_reads, target)) return -1;
    defer compiler::bytecode_cfg_free(&cfg);
    uint words = (target.num_regs + 31) / 32;
    uint count = cfg.instruction_count;
    compiler::RegSet* sets = ssa_storage_alloc(g, (usz)count * 2, compiler::RegSet::size);
    uint* storage = ssa_storage_alloc(g, ((usz)count * 2 + 1) * words, uint::size);
    int* mapped = ssa_storage_alloc(g, target.num_regs, int::size);
    if (g.failed) return -1;
    for (uint i = 0; i < count * 2; i++) sets[i] = { storage + (usz)i * words, words };
    compiler::RegSet scratch = { storage + (usz)count * 2 * words, words };
    if (!compiler::bytecode_cfg_liveness(&cfg, sets, sets + count, &scratch, true, false, &ssa_cfg_charge_work, g)) return -1;
    SsaFrameId parent = ssa_frame_at_pc(g, call.pc);
    int callee;
    if (fused) {
        callee = ssa_value(g, HELPER, BOXED, -1, -1, (long)SsaHelperKind.RESOLVE_CALLEE.ordinal);
        ssa_result(g, callee, call.insn.a, call.pc);
        g.values[callee].before_frame = parent;
    } else { callee = g.current[base]; }
    ssa_use(g, callee);
    int check = ssa_value(g, CHECKFN, BOXED, callee, -1, (long)target);
    g.values[check].before_frame = parent;
    int reserve = ssa_value(g, HELPER, BOXED, callee, -1, (long)SsaHelperKind.INLINE_RESERVE.ordinal);
    g.values[reserve].inline_target = target;
    g.values[reserve].before_frame = parent;
    g.values[reserve].target = (int)target.num_regs + (int)FRAME_SCRATCH_SLOTS;
    g.values[reserve].fallto = 1;
    int undefined = ssa_value(g, CONST_BOXED, BOXED, -1, -1, (long)(types::TAG_UNDEFINED << 48));
    int call_receiver = call.insn.op == Opcode.CALL ? g.current[base + 1] : undefined;
    for (uint reg = 0; reg < target.num_regs; reg++) mapped[reg] = undefined;
    for (uint reg = 0; reg < argc; reg++) mapped[reg] = g.current[base + 2 + reg];
    int result = undefined;
    bool returned;
    g.plan.ssa_deopt_chain = &ssa_inline_materialize_chain;
    defer g.current_pc = call.pc;
    for (uint index = 0; index < count; index++) {
        DecodedBytecode view = cfg.nodes[index].view;
        DecodedInsn ins = view.insn;
        g.current_pc = view.pc;
        SsaFrameId before = ssa_effect_child_frame(g, target, parent, call, callee, call_receiver,
            view.pc, mapped, &sets[count + index]);
        if (g.failed) return -1;
        uint first = g.value_count;
        if (!ssa_effect_inline_op(ins.op)) {
            int exit = ssa_value(g, EXIT, BOXED, -1, -1, 0);
            g.values[exit].before_frame = before;
            break;
        }
        switch (ins.op) {
            case NOP: break;
            case LDREG: mapped[ins.a] = mapped[ins.b]; break;
            case LDUNDEF: mapped[ins.a] = undefined; break;
            case LDNULL: case LDTRUE: case LDFALSE:
                {
                    TVal value;
                    if (ins.op == Opcode.LDNULL) { value.set_null(); }
                    else { value.set_boolean(ins.op == Opcode.LDTRUE); }
                    mapped[ins.a] = ssa_value(g, CONST_BOXED, BOXED, -1, -1, (long)loop_bits(value));
                    break;
                }
            case LDINT:
                {
                    long value = ins.get_sbc();
                    mapped[ins.a] = value >= -2147483648L && value <= 2147483647L
                        ? ssa_value(g, CONST_I, INT32, -1, -1, value)
                        : ssa_value(g, CONST_F, F64, -1, -1, (long)bitcast((double)value, ulong));
                    break;
                }
            case LDCONST:
                mapped[ins.a] = ssa_value(g, CONST_BOXED, BOXED, -1, -1, (long)loop_bits(target.constants[ins.get_bc()]));
                break;
            case GETPROPC: case GETPROPC_CACHED: case PUTPROPC:
                {
                    SsaFieldAccess spec;
                    if (!ssa_access_field_spec(g.heap, g.cf, view, &spec, target)) { g.failed = true; return -1; }
                    SsaFieldAccess* access = ssa_storage_alloc(g, 1, SsaFieldAccess::size);
                    if (access == null) return -1;
                    *access = spec;
                    int receiver = ssa_convert(g, mapped[spec.write ? ins.a : ins.b], BOXED, false);
                    ssa_use(g, receiver);
                    int address = ssa_value(g, ACCESS_FIELD, RAW, receiver, -1, 0);
                    g.values[address].field_access = access;
                    ssa_use(g, address);
                    if (spec.write) {
                        int stored = ssa_convert(g, mapped[ins.b], BOXED, false);
                        ssa_use(g, stored);
                        ssa_value(g, ACCESS_STORE, BOXED, address, stored, (long)ObjClass.OBJECT.ordinal);
                    } else { mapped[ins.a] = ssa_value(g, ACCESS_LOAD, BOXED, address, -1, (long)ObjClass.OBJECT.ordinal); }
                    break;
                }
            case RET: case RETUNDEF:
                result = ins.op == Opcode.RET ? mapped[ins.a] : undefined;
                returned = true;
                break;
            default:
                {
                    int left = ssa_convert(g, mapped[ins.b], F64, false);
                    int right;
                    if (ins.op == Opcode.ADDI || ins.op == Opcode.SUBI || ins.op == Opcode.MULI) {
                        right = ssa_value(g, CONST_F, F64, -1, -1,
                            (long)bitcast((double)bytecode::imm_value(ins.op, ins.c), ulong));
                    } else if (ins.op != Opcode.UNM) { right = ssa_convert(g, mapped[ins.c], F64, false); }
                    ssa_use(g, left);
                    if (ins.op != Opcode.UNM) ssa_use(g, right);
                    SsaOp op = ins.op == Opcode.SUB || ins.op == Opcode.SUBI ? SUB
                        : ins.op == Opcode.MUL || ins.op == Opcode.MULI ? MUL
                        : ins.op == Opcode.DIV ? DIV : ins.op == Opcode.UNM ? NEG : ADD;
                    mapped[ins.a] = ssa_value(g, op, F64, left, ins.op == Opcode.UNM ? -1 : right, 0);
                    break;
                }
        }
        for (uint value = first; value < g.value_count; value++) g.values[value].before_frame = before;
        if (returned) break;
    }
    // A marker belongs to the completed caller call, not to the preflight or
    // one of the child's coincidentally equal numeric PCs.
    ssa_use(g, result);
    g.current_pc = call.pc;
    int marker = ssa_value(g, COPY, g.values[result].rep, result, -1, 0);
    ssa_result(g, marker, call.insn.a, call.pc);
    g.values[marker].before_frame = parent;
    g.current[call.insn.a] = marker;
    if (call.insn.op != Opcode.CALL && base + 1 != call.insn.a) g.current[base + 1] = undefined;
    g.values[marker].after_frame = ssa_frame_capture(g, call.next_pc, g.current, g.reg_count,
        call.next_pc <= g.plan.end ? g.recovery_live[call.next_pc - g.plan.begin].words : null, g.reg_words);
    g.plan.ssa_inline_sites++;
    return marker;
}

// Boxed chain values have already been anchored by the common deopt bridge.
// Preflight reserved all slots before any inlined effect; this construction
// uses the normal activation initializer and owning VM publication operations.
fn Instruction* ssa_inline_materialize_chain(SsaExecution* execution, SsaDeoptSite* site) @feat(SLJIT) {
    ColdCtx* cold = execution.cold;
    $if $feat(SLJIT_STATS): execution.plan.ssa_inline_recoveries++; $endif
    Vm* vm = cold.vm;
    Heap* h = cold.heap;
    uint depth;
    SsaDeoptFrame* root = site.frame;
    while (root.parent != null) { depth++; root = root.parent; }
    assert(root.function == execution.function && depth <= vm.activation_capacity - vm.activation_count);
    execution.output_count = 0;
    foreach (i, entry : root.entries[:root.count]) {
        execution.outputs[i].reg = entry.reg;
        bool read = ssa_deopt_read(execution, entry.location, &execution.outputs[i].value);
        assert(read);
    }
    execution.output_count = root.count;
    bool published = ssa_execution_publish(execution);
    assert(published);
    for (uint level = depth; level > 0; level--) {
        SsaDeoptFrame* frame = site.frame;
        for (uint up = 1; up < level; up++) frame = frame.parent;
        TVal callee, receiver;
        bool callee_read = ssa_deopt_read(execution, frame.callee, &callee);
        bool receiver_read = ssa_deopt_read(execution, frame.receiver, &receiver);
        assert(callee_read && receiver_read);
        HObject* function = callee.get_heapptr();
        CompiledFunction* target = frame.function;
        assert(callee.is_object() && function != null && function.extra.func.comp_func == target);
        Activation* caller = cold.act;
        DecodedBytecode call = bytecode::decode_bytecode((Instruction*)((CompiledFunction*)caller.func).code,
            ((CompiledFunction*)caller.func).code_count, frame.callsite_pc);
        assert(call.valid && frame.return_reg < ((CompiledFunction*)caller.func).num_regs);
        TVal* bottom = callback_frame_top(vm);
        assert(bottom + target.num_regs + FRAME_SCRATCH_SLOTS <= vm.valstack_end);
        zero_regs_undefined(bottom, 0, target.num_regs + FRAME_SCRATCH_SLOTS);
        caller.curr_pc = ((CompiledFunction*)caller.func).code + call.next_pc;
        if (call.insn.op != Opcode.CALL) {
            uint base = call.insn.op == Opcode.CALL_UNDEF_THIS ? call.insn.b : call.insn.a;
            h.set_reg_undefined(caller.bottom + base + 1);
        }
        Activation* act = activation_begin(vm, callee);
        if (callee.is_refcounted()) ((HeapHeader*)function).incref();
        act.parent = caller;
        act.func = target;
        act.var_env = function.extra.func.var_env;
        EnvRecord* lex = function.extra.func.lex_env;
        act.lex_env = lex != null && lex.flags.is_declarative ? lex : act.var_env;
        act.cat = null;
        act.curr_pc = target.code + frame.pc;
        act.bottom = bottom;
        act.retval = caller.bottom + frame.return_reg;
        act.flags = ACT_FLAG_CALLEE_OWNED;
        act.this_binding.set_undefined();
        act.set_this_owned(h, receiver);
        foreach (entry : frame.entries[:frame.count]) {
            TVal value;
            bool read = ssa_deopt_read(execution, entry.location, &value);
            assert(entry.reg < target.num_regs && read);
            h.tval_copy_ref(bottom + entry.reg, &value);
            track_heap_store(act, bottom + entry.reg, entry.reg);
        }
        h.shade_root_env(act.var_env);
        h.shade_root_env(act.lex_env);
        publish_frame_top(vm, bottom, target.num_regs, target.num_regs);
        vm.valstack_bottom = bottom;
        vm.current_func = target;
        cold.act = act;
    }
    cold.capture_refs = null;
    if (cold.regs_base_ptr != null) *cold.regs_base_ptr = cold.act.bottom;
    CompiledFunction* current = vm.current_func;
    cold.code_base = current.code;
    cold.ic_base = current.ic_entries;
    cold.var_ic_base = current.var_ic_entries;
    th_bind_ic_bias(cold, current.code, current.ic_entries, current.var_ic_entries);
    return cold.act.curr_pc;
}

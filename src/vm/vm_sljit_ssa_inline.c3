module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import boomkat::types;
import boomkat::hstring;

fn int ssa_inline_global(SsaGraph* g, CompiledFunction* cf, uint pc) @feat(SLJIT) {
    if (!g.inplace || cf.var_ic_entries == null || cf.code[pc].op != Opcode.GETGLOBAL) return -1;
    VarICEntry* ic = (VarICEntry*)cf.var_ic_entries + pc;
    if (ic.slot_ptr == null || ic.recycle_epoch != g.heap.shape_recycle_epoch || ic.prop_flags.is_accessor) return -1;
    for (uint i = 0; i < g.plan.binding_count; i++) {
        CompiledFunction* source = g.plan.binding_functions[i] != null ? g.plan.binding_functions[i] : g.cf;
        uint site = g.plan.bindings[i];
        if (source == cf && site == pc) return (int)i;
        if (source.realm != cf.realm || source.var_ic_entries == null || source.code[site].op != Opcode.GETGLOBAL) continue;
        VarICEntry* prior = (VarICEntry*)source.var_ic_entries + site;
        if (prior.slot_ptr == ic.slot_ptr && prior.recycle_epoch == ic.recycle_epoch && !prior.prop_flags.is_accessor) return (int)i;
    }
    if (g.plan.binding_count == LOOP_BINDINGS) return -1;
    uint id = g.plan.binding_count++;
    g.plan.bindings[id] = pc;
    g.plan.binding_functions[id] = cf;
    return (int)id;
}

fn ICEntry ssa_inline_field(CompiledFunction* cf, uint pc, Heap* h) @feat(SLJIT) {
    ICEntry ic = ((ICEntry*)cf.ic_entries)[pc];
    if (ic.key.borrow() != null || cf.code[pc].op != Opcode.GETTHISC) return ic;
    HString* key = cf.constants[cf.code[pc].c].get_heapptr();
    for (uint i = 0; i < cf.code_count; i++) {
        if (cf.code[i].op != Opcode.GETTHISC) continue;
        ICEntry prior = ((ICEntry*)cf.ic_entries)[i];
        if (prior.key.borrow() == null || prior.has_proto) continue;
        Shape* shape = h.get_shape(prior.shape_id);
        PropFlags flags;
        int slot = function_shape_slot(shape, key, &flags);
        if (slot < 0 || flags.is_accessor) continue;
        ic.shape_id = prior.shape_id;
        ic.shape_gen = prior.shape_gen;
        ic.prop_idx = (uint)slot;
        ic.prop_flags = flags;
        ic.key = (hstring::StringRef)key;
        return ic;
    }
    return ic;
}

// Expand a guarded leaf directly into the caller graph. All guards belong to
// the call bytecode, so a miss precedes execution of the callee's semantics.
fn int ssa_inline_call(SsaGraph* g, Instruction ins, uint pos) @feat(SLJIT) {
    bool fused = ins.op == Opcode.CALL_GLOBAL || ins.op == Opcode.CALL_VAR;
    uint base = fused ? ins.a : ins.b;
    uint nargs = fused ? ins.b : ins.c;
    CompiledFunction* callee_fn = function_inline_ssa_candidate(g.cf, pos, g.heap, g.inplace);
    if (callee_fn == null || (!fused && g.current[base] < 0) || nargs > 8) {
        g.failed = true;
        return -1;
    }
    // The site can be rebound, so the live callee must still be
    // the compiled body that was expanded here.
    int callee;
    if (fused) {
        int binding = (int)g.plan.binding_at[pos - g.plan.begin] - 1;
        if (binding < 0) return -1;
        callee = ssa_value(g, BINDING, BOXED, -1, -1, binding);
    } else { callee = g.current[base]; }
    ssa_use(g, callee);
    ssa_use(g, ssa_value(g, CHECKFN, BOXED, callee, -1, (long)callee_fn));
    int[LOOP_REGS] mapped;
    for (uint i = 0; i < LOOP_REGS; i++) mapped[i] = -1;
    for (uint i = 0; i < nargs; i++) {
        int arg = g.current[base + 2 + i];
        if (arg < 0) {
            g.failed = true;
            return -1;
        }
        ssa_use(g, arg);
        mapped[i] = arg;
    }
    int receiver = -1;
    if (!fused && g.current[base + 1] >= 0) {
        receiver = g.current[base + 1];
        ssa_use(g, receiver);
    }
    int result = -1;
    int predicate = -1;
    int fallthrough = -1;
    uint branch_target;
    int[LOOP_REGS] branch_values;
    for (uint ci_pos = 0; ci_pos < callee_fn.code_count && result < 0; ci_pos++) {
        Instruction ci = callee_fn.code[ci_pos];
        int target = loop_target(ci, ci_pos);
        if (target >= 0) {
            bool immediate = ci.op >= Opcode.JMP_NLTI;
            if (predicate >= 0 || !ssa_comparison_op(ci.op) || ci.b >= LOOP_REGS || (!immediate && ci.c >= LOOP_REGS)) return -1;
            int left = mapped[ci.b];
            int right = immediate ? ssa_value(g, CONST_I, INT32, -1, -1, (long)(ichar)ci.c) : mapped[ci.c];
            if (left < 0 || right < 0) return -1;
            SsaRep rep = g.values[left].rep == INT32 && g.values[right].rep == INT32 ? INT32 : F64;
            left = ssa_convert(g, left, rep, false);
            right = ssa_convert(g, right, rep, false);
            ssa_use(g, left);
            ssa_use(g, right);
            predicate = ssa_value(g, COMPARE, BOXED, left, right, 0);
            g.values[predicate].branch_op = ci.op;
            branch_target = (uint)target;
            branch_values = mapped;
            continue;
        }
        if (ci.a >= LOOP_REGS) {
            g.failed = true;
            return -1;
        }
        switch (ci.op) {
            case NOP: continue;
            case RET:
                {
                    if (predicate < 0) { result = mapped[ci.a]; continue; }
                    if (fallthrough < 0) {
                        fallthrough = mapped[ci.a];
                        if (fallthrough < 0) return -1;
                        mapped = branch_values;
                        ci_pos = branch_target - 1;
                        continue;
                    }
                    int taken = mapped[ci.a];
                    if (taken < 0) return -1;
                    SsaRep rep = g.values[taken].rep == g.values[fallthrough].rep ? g.values[taken].rep : BOXED;
                    taken = ssa_convert(g, taken, rep, false);
                    fallthrough = ssa_convert(g, fallthrough, rep, false);
                    ssa_use(g, predicate);
                    ssa_use(g, taken);
                    ssa_use(g, fallthrough);
                    result = ssa_value(g, SELECT, rep, predicate, taken, fallthrough);
                    continue;
                }
            case GETGLOBAL:
                {
                    int binding = ssa_inline_global(g, callee_fn, ci_pos);
                    if (binding < 0) return -1;
                    mapped[ci.a] = ssa_value(g, BINDING, BOXED, -1, -1, binding);
                    continue;
                }
            case LDINT:

                {
                    long immediate = ci.get_sbc();
                    mapped[ci.a] = ssa_value(g, CONST_I, INT32, -1, 0, immediate);
                    continue;
                }
            case LDCONST:

                {
                    if (ci.get_bc() >= callee_fn.const_count) {
                        g.failed = true;
                        return -1;
                    }
                    TVal constant = callee_fn.constants[ci.get_bc()];
                    if (!constant.is_fastint() && !constant.is_number()) {
                        g.failed = true;
                        return -1;
                    }
                    if (constant.is_fastint() && constant.get_fastint() >= -2147483648L
                        && constant.get_fastint() <= 2147483647L) {
                        mapped[ci.a] = ssa_value(g, CONST_I, INT32, -1, 0, constant.get_fastint());
                        continue;
                    }
                    double number = constant.get_number_or_fastint();
                    mapped[ci.a] = ssa_value(g, CONST_F, F64, -1, 0, (long)bitcast(number, ulong));
                    continue;
                }
            case LDTHIS:
                if (receiver < 0) {
                    g.failed = true;
                    return -1;
                }
                mapped[ci.a] = ssa_convert(g, receiver, BOXED, false);
                continue;
            case LDREG:
                if (ci.b >= LOOP_REGS || mapped[ci.b] < 0) {
                    g.failed = true;
                    return -1;
                }
                mapped[ci.a] = mapped[ci.b];
                continue;
            case UNP:
                if (ci.b >= LOOP_REGS || mapped[ci.b] < 0) return -1;
                mapped[ci.a] = ssa_convert(g, mapped[ci.b], F64, false);
                continue;
            case UNM:
            case ADD:
            case ADD_FUSED:
            case SUB:
            case MUL:
            case DIV:
            case ADDI:
            case SUBI:
            case MULI:
            case BAND:
            case BOR:
            case BXOR:
            case SHL:
            case SHR:
            case USHR:
            case BANDI:
            case BORI:
            case BXORI:
            case SHLI:
            case SHRI:
            case USHRI:
            case BNOT:
                {
                    bool binary = ssa_scalar_binary(ci.op);
                    if (ci.b >= LOOP_REGS || (binary && ci.c >= LOOP_REGS)) return -1;
                    int value = ssa_scalar(g, ci.op, mapped[ci.b], binary ? mapped[ci.c] : -1,
                        (long)(ichar)ci.c);
                    if (value < 0) return -1;
                    mapped[ci.a] = value;
                    continue;
                }
            case GETPROPC:
            case GETPROPC_CACHED:
            case GETTHISC:

                {
                    bool on_receiver = ci.op == Opcode.GETTHISC;
                    if (!on_receiver && (ci.b >= LOOP_REGS || mapped[ci.b] < 0)) {
                        g.failed = true;
                        return -1;
                    }
                    if (callee_fn.ic_entries == null) {
                        g.failed = true;
                        return -1;
                    }
                    ICEntry inferred = ssa_inline_field(callee_fn, ci_pos, g.heap);
                    ICEntry* ic = &inferred;
                    Shape* layout = g.heap.get_shape(ic.shape_id);
                    if (layout == null || layout.dict || layout.generation != ic.shape_gen || ic.key.borrow() == null
                        || ic.has_proto || ic.prop_flags.is_accessor) {
                        g.failed = true;
                        return -1;
                    }
                    int receiver_value = on_receiver ? ssa_convert(g, receiver, BOXED, false)
                        : mapped[ci.b];
                    if (receiver_value < 0) {
                        g.failed = true;
                        return -1;
                    }
                    ssa_use(g, receiver_value);
                    int memory = loop_memory_shape_layout(
                        g.plan,
                        ic.shape_id,
                        ic.shape_gen,
                        (int)ic.prop_idx,
                        false
                    );
                    if (memory < 0) {
                        g.failed = true;
                        return -1;
                    }
                    if (g.direct_fields) {
                        g.plan.memory[memory].integers = ic.read_rep == 1;
                        receiver_value = ssa_field_storage(g, (uint)memory, receiver_value);
                        ssa_use(g, receiver_value);
                    }
                    mapped[ci.a] = ssa_value(g, LOAD, g.plan.memory[memory].integers ? INT32 : BOXED, receiver_value, -1, (long)memory);
                    continue;
                }
            default:
                g.failed = true;
                return -1;
        }
    }
    if (result < 0) {
        g.failed = true;
        return -1;
    }
    ssa_use(g, result);
    // Preserve the callee result's representation. Loop joins request any
    // required widening; boxing here hides that information from the fixpoint.
    int nv = ssa_value(g, COPY, g.values[result].rep, result, -1, 0);
    ssa_result(g, nv, ins.a, pos);
    return nv;
}

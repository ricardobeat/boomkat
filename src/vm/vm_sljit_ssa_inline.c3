module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import boomkat::types;

// Expand a guarded leaf directly into the caller graph. All guards belong to
// the call bytecode, so a miss precedes execution of the callee's semantics.
fn int ssa_inline_call(SsaGraph* g, Instruction ins, uint pos) @feat(SLJIT) {
    bool fused = ins.op == Opcode.CALL_GLOBAL || ins.op == Opcode.CALL_VAR;
    uint base = fused ? ins.a : ins.b;
    uint nargs = fused ? ins.b : ins.c;
    CompiledFunction* callee_fn = function_inline_ssa_candidate(g.cf, pos, g.heap);
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
    for (uint ci_pos = 0; ci_pos < callee_fn.code_count && result < 0; ci_pos++) {
        Instruction ci = callee_fn.code[ci_pos];
        if (ci.a >= LOOP_REGS) {
            g.failed = true;
            return -1;
        }
        switch (ci.op) {
            case NOP: continue;
            case RET: result = mapped[ci.a]; continue;
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
                    ICEntry* ic   = (ICEntry*)callee_fn.ic_entries + ci_pos;
                    Shape* layout = g.heap.get_shape(ic.shape_id);
                    if (layout == null || layout.generation != ic.shape_gen) {
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
                    mapped[ci.a] = ssa_value(g, LOAD, BOXED, receiver_value, -1, (long)memory);
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

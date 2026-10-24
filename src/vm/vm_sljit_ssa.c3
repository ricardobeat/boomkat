module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::builtins;
import boomkat::jit;
import std::core::mem;
import std::io;

// SSA for the numeric loop tier. Bytecode registers become SSA values with
// loop phis at the header; definitions are renamed, representations are
// selected from uses, and exits reconstruct the interpreter's register slots.
// Unsupported loops fall back to the straight-line loop emitter.
// The SSA pipeline is complete but stays opt-in until the long-run
// differential mismatch in am3-style loops is resolved.
const bool SSA_ENABLED    = true;
const uint SSA_MAX_VALUES = 512;
const uint SSA_MAX_SPILL  = 128;
const uint SSA_HOMES      = 8;
const uint SSA_GPR_HOMES  = 7;
const uint SSA_EXITS      = 128;
const uint SSA_CSE        = 64;

enum SsaRep : char {
    BOXED,
    INT32,
    F64
}

enum SsaOp : char {
    ARG,
    PHI,
    CONST_I,
    CONST_F,
    COPY,
    ADD,
    SUB,
    MUL,
    DIV,
    BAND,
    BOR,
    BXOR,
    SHL,
    SHR,
    USHR,
    BNOT,
    NEG,
    TO_INT,
    TO_INDEX,
    TO_F64,
    BOX_I,
    BOX_F,
    LOAD,
    STORE
}

struct SsaValue @feat(SLJIT) {
    SsaOp op;
    SsaRep rep;
    int a;
    int b;
    long imm;
    uint def;
    uint last;
    uint pc;
    int dst_reg;
    int home;
    uint spill;
    int arg_reg;
}

struct SsaExit @feat(SLJIT) {
    void* jump;
    uint pc;
    int[LOOP_REGS] regs;
}

struct SsaGraph @feat(SLJIT) {
    LoopPlan* plan;
    CompiledFunction* cf;
    SsaValue[SSA_MAX_VALUES] values;
    int[SSA_MAX_VALUES * 3] conv;
    uint value_count;
    uint stamp;
    uint current_pc;
    uint spill_count;
    bool failed;
    int[LOOP_REGS] current;
    int[LOOP_REGS] header;
    int[LOOP_REGS] phi;
    int[LOOP_REGS] arg;
    SsaRep[LOOP_REGS] rep;
    bool[LOOP_REGS] int_reg;
    int cmp_lhs;
    int cmp_rhs;
    long cmp_imm;
    Opcode cmp_op;
    SsaExit[SSA_EXITS] exits;
    uint exit_count;
    // Memories whose source register is not written by the loop keep the same
    // descriptor for the whole run, so their guards can be checked once.
    bool[LOOP_MEMORY] invariant;
    int[SSA_CSE] cse_memory;
    int[SSA_CSE] cse_index;
    int[SSA_CSE] cse_value;
}

fn long ssa_spill_offset(uint slot) @feat(SLJIT) {
    LoopState state;
    return (char*)&state.ssa_spill - (char*)&state + (long)slot * double::size;
}
fn int ssa_value(SsaGraph* g, SsaOp op, SsaRep rep, int a, int b, long imm) @feat(SLJIT) {
    if (g.value_count == SSA_MAX_VALUES) {
        g.failed = true;
        return 0;
    }
    uint index = g.value_count++;
    g.values[index].op = op;
    g.values[index].rep = rep;
    g.values[index].a = a;
    g.values[index].b = b;
    g.values[index].imm = imm;
    g.values[index].def = g.stamp;
    g.values[index].last = g.stamp;
    g.values[index].arg_reg = -1;
    g.values[index].dst_reg = -1;
    g.values[index].pc = g.current_pc;
    g.stamp++;
    return (int)index;
}
fn void ssa_use(SsaGraph* g, int value) @feat(SLJIT) {
    if (value < 0 || value >= (int)g.value_count) {
        g.failed = true;
        return;
    }
    if (g.stamp > g.values[value].last) g.values[value].last = g.stamp;
}
fn void ssa_result(SsaGraph* g, int value, uint reg, uint pc) @feat(SLJIT) {
    g.values[value].dst_reg = (int)reg;
    g.values[value].pc = pc;
}
fn int ssa_convert(SsaGraph* g, int value, SsaRep rep, bool exact) @feat(SLJIT) {
    if (value < 0) {
        g.failed = true;
        return 0;
    }
    SsaRep from = g.values[value].rep;
    if (from == rep && (!exact || rep != INT32)) return value;
    if (from == rep && exact) return value;
    uint key = (uint)value * 3 + (uint)rep;
    if (g.conv[key] != 0) return g.conv[key] - 1;
    SsaOp op;
    if (rep == F64) {
        op = from == BOXED ? TO_F64 : (from == INT32 ? TO_F64 : COPY);
    } else if (rep == INT32) {
        if (from == BOXED) {
            op = exact ? TO_INDEX : TO_INT;
        } else if (from == F64) {
            op = exact ? TO_INDEX : TO_INT;
        } else {
            op = COPY;
        }
    } else {
        op = from == F64 ? BOX_F : BOX_I;
    }
    ssa_use(g, value);
    int result = ssa_value(g, op, rep, value, 0, 0);
    g.conv[key] = (int)(result + 1);
    return result;
}
fn bool ssa_numeric_rep(SsaRep rep) @feat(SLJIT) => rep == INT32 || rep == F64;

fn bool ssa_loop_eligible(LoopPlan* plan, CompiledFunction* cf) @feat(SLJIT) {
    if (!SSA_ENABLED) return false;
    for (uint i = 0; i < plan.memory_count; i++) {
        LoopMemoryKind kind = plan.memory[i].kind;
        if (kind == ASCII || kind == INTRINSIC) return false;
    }
    for (uint pos = plan.begin; pos <= plan.end; pos++) {
        Instruction ins = cf.code[pos];
        int target      = loop_target(ins, pos);
        if (target >= 0) {
            if (pos != plan.end || target != (int)plan.begin) return false;
            continue;
        }
        switch (ins.op) {
            case LDREG:
            case LDINT:
            case LDCONST:
            case TONUMERIC:
            case INC:
            case INC_LT:
            case DEC:
            case ADD:
            case ADD_FUSED:
            case ADDI:
            case SUB:
            case SUBI:
            case MUL:
            case MULI:
            case DIV:
            case BAND:
            case BOR:
            case BXOR:
            case SHL:
            case SHR:
            case USHR:
            case BNOT:
            case BANDI:
            case BORI:
            case BXORI:
            case SHLI:
            case SHRI:
            case USHRI:
                continue;
            case GETPROP:
            case GETPROP_CACHE:
            case PUTPROP:
                if (plan.memory_at[pos - plan.begin] == 0) return false;
                continue;
            default: return false;
        }
    }
    return true;
}

// Determine representations from uses before renaming. Counters and indices
// stay integers; arithmetic carries F64 values; pure memory bases are ignored.
fn void ssa_infer(
    SsaGraph* g,
    bool[LOOP_REGS]* read,
    bool[LOOP_REGS]* value_read,
    bool[LOOP_REGS]* written,
    bool[LOOP_REGS]* live_in,
    bool[LOOP_REGS]* base,
    bool[LOOP_REGS]* int_need,
    bool[LOOP_REGS]* f64_need
) @feat(SLJIT) {
    CompiledFunction* cf = g.cf;
    LoopPlan* plan       = g.plan;
    bool[LOOP_REGS] assigned;
    for (uint pos = plan.begin; pos <= plan.end; pos++) {
        Instruction ins = cf.code[pos];
        if (pos == plan.end && loop_target(ins, pos) >= 0) {
            (*read)[ins.b] = true;
            (*value_read)[ins.b] = true;
            if (!assigned[ins.b]) (*live_in)[ins.b] = true;
            (*int_need)[ins.b] = true;
            if (ins.op < Opcode.JMP_NLTI) {
                (*read)[ins.c] = true;
                (*value_read)[ins.c] = true;
                if (!assigned[ins.c]) (*live_in)[ins.c] = true;
                (*int_need)[ins.c] = true;
            }
            continue;
        }
        bool writes = true;
        switch (ins.op) {
            case LDREG:
                (*read)[ins.b] = true;
                (*value_read)[ins.b] = true;
                if (!assigned[ins.b]) (*live_in)[ins.b] = true;
                break;
            case LDINT:
            case LDCONST:
                break;
            case GETPROP:
            case GETPROP_CACHE:
                (*read)[ins.c] = true;
                (*value_read)[ins.c] = true;
                if (!assigned[ins.c]) (*live_in)[ins.c] = true;
                (*base)[ins.b] = true;
                (*read)[ins.b] = true;
                (*int_need)[ins.c] = true;
                break;
            case PUTPROP:
                (*read)[ins.b] = true;
                (*value_read)[ins.b] = true;
                (*read)[ins.c] = true;
                (*value_read)[ins.c] = true;
                if (!assigned[ins.b]) (*live_in)[ins.b] = true;
                if (!assigned[ins.c]) (*live_in)[ins.c] = true;
                (*base)[ins.a] = true;
                (*read)[ins.a] = true;
                (*int_need)[ins.b] = true;
                writes = false;
                break;
            case TONUMERIC:
            case INC:
            case INC_LT:
            case DEC:
                (*read)[ins.a] = true;
                (*value_read)[ins.a] = true;
                if (!assigned[ins.a]) (*live_in)[ins.a] = true;
                if (ins.op != Opcode.TONUMERIC) (*int_need)[ins.a] = true;
                break;
            case BAND:
            case BOR:
            case BXOR:
            case SHL:
            case SHR:
            case USHR:
                (*read)[ins.b] = true;
                (*read)[ins.c] = true;
                (*value_read)[ins.b] = true;
                (*value_read)[ins.c] = true;
                if (!assigned[ins.b]) (*live_in)[ins.b] = true;
                if (!assigned[ins.c]) (*live_in)[ins.c] = true;
                (*int_need)[ins.b] = true;
                (*int_need)[ins.c] = true;
                break;
            case BANDI:
            case BORI:
            case BXORI:
            case SHLI:
            case SHRI:
            case USHRI:
            case BNOT:
                (*read)[ins.b] = true;
                (*value_read)[ins.b] = true;
                if (!assigned[ins.b]) (*live_in)[ins.b] = true;
                (*int_need)[ins.b] = true;
                break;
            case ADD:
            case ADD_FUSED:
            case SUB:
            case MUL:
            case DIV:
                (*read)[ins.b] = true;
                (*read)[ins.c] = true;
                (*value_read)[ins.b] = true;
                (*value_read)[ins.c] = true;
                if (!assigned[ins.b]) (*live_in)[ins.b] = true;
                if (!assigned[ins.c]) (*live_in)[ins.c] = true;
                (*f64_need)[ins.b] = true;
                (*f64_need)[ins.c] = true;
                break;
            case ADDI:
            case SUBI:
            case MULI:
                (*read)[ins.b] = true;
                (*value_read)[ins.b] = true;
                if (!assigned[ins.b]) (*live_in)[ins.b] = true;
                (*f64_need)[ins.b] = true;
                break;
            default: break;
        }
        if (writes) {
            (*written)[ins.a] = true;
            assigned[ins.a] = true;
        }
    }
}
fn SsaRep ssa_rep_for(bool int_need, bool f64_need, bool numeric_only) @feat(SLJIT) {
    if (f64_need) return F64;
    if (int_need) return INT32;
    return numeric_only ? INT32 : BOXED;
}

// Conservative may-analysis for integer-valued registers. A register is
// integer when every definition in the loop is an integer-producing operation
// whose operands are themselves integer registers. Bitwise operations always
// produce an int32 regardless of their inputs.
fn bool ssa_op_is_int(SsaGraph* g, Instruction ins, uint pos, bool[LOOP_REGS]* int_reg) @feat(SLJIT) {
    CompiledFunction* cf = g.cf;
    LoopPlan* plan       = g.plan;
    switch (ins.op) {
        case LDINT: return true;
        case LDCONST:

            {
                if (ins.get_bc() >= cf.const_count) return false;
                TVal value = cf.constants[ins.get_bc()];
                if (!value.is_fastint()) return false;
                long integer = value.get_fastint();
                return integer >= -2147483648L && integer <= 2147483647L;
            }
        case BAND:
        case BOR:
        case BXOR:
        case SHL:
        case SHR:
        case USHR:
        case BNOT:
        case BANDI:
        case BORI:
        case BXORI:
        case SHLI:
        case SHRI:
        case USHRI:
            return true;
        case LDREG:
        case TONUMERIC: return (*int_reg)[ins.b];
        case INC:
        case INC_LT:
        case DEC: return (*int_reg)[ins.a];
        case ADD:
        case ADD_FUSED:
        case SUB:
        case MUL:
            return (*int_reg)[ins.b] && (*int_reg)[ins.c];
        case ADDI:
        case SUBI:
        case MULI: return (*int_reg)[ins.b];
        case GETPROP:
        case GETPROP_CACHE:

            {
                uint memory = plan.memory_at[pos - plan.begin];
                if (memory == 0) return false;
                LoopMemorySpec spec = plan.memory[memory - 1];
                return spec.kind != DENSE && spec.cls < FLOAT32ARRAY && spec.cls != UINT32ARRAY;
            }
        default: return false;
    }
}
fn void ssa_int_fixpoint(SsaGraph* g) @feat(SLJIT) {
    CompiledFunction* cf = g.cf;
    LoopPlan* plan       = g.plan;
    bool[LOOP_REGS] assigned;
    bool[LOOP_REGS] int_reg;
    for (uint i = 0; i < LOOP_REGS; i++) int_reg[i] = true;
    for (uint pos = plan.begin; pos <= plan.end; pos++) {
        Instruction ins = cf.code[pos];
        if (loop_target(ins, pos) >= 0) continue;
        if (ins.op == Opcode.PUTPROP) continue;
        bool writes = true;
        switch (ins.op) {
            case LDREG:
            case LDINT:
            case LDCONST:
            case TONUMERIC:
            case INC:
            case INC_LT:
            case DEC:
            case ADD:
            case ADD_FUSED:
            case ADDI:
            case SUB:
            case SUBI:
            case MUL:
            case MULI:
            case DIV:
            case BAND:
            case BOR:
            case BXOR:
            case SHL:
            case SHR:
            case USHR:
            case BNOT:
            case BANDI:
            case BORI:
            case BXORI:
            case SHLI:
            case SHRI:
            case USHRI:
            case GETPROP:
            case GETPROP_CACHE: break;
            default: writes = false; break;
        }
        if (!writes) continue;
        assigned[ins.a] = true;
        if (!ssa_op_is_int(g, ins, pos, &int_reg)) int_reg[ins.a] = false;
    }
    for (uint i = 0; i < LOOP_REGS; i++) if (!assigned[i]) int_reg[i] = false;
    bool changed = true;
    while (changed) {
        changed = false;
        for (uint pos = plan.begin; pos <= plan.end; pos++) {
            Instruction ins = cf.code[pos];
            if (loop_target(ins, pos) >= 0) continue;
            bool writes = true;
            switch (ins.op) {
                case LDREG:
                case LDINT:
                case LDCONST:
                case TONUMERIC:
                case INC:
                case INC_LT:
                case DEC:
                case ADD:
                case ADD_FUSED:
                case ADDI:
                case SUB:
                case SUBI:
                case MUL:
                case MULI:
                case DIV:
                case BAND:
                case BOR:
                case BXOR:
                case SHL:
                case SHR:
                case USHR:
                case BNOT:
                case BANDI:
                case BORI:
                case BXORI:
                case SHLI:
                case SHRI:
                case USHRI:
                case GETPROP:
                case GETPROP_CACHE: break;
                default: writes = false; break;
            }
            if (!writes) continue;
            if (int_reg[ins.a] && !ssa_op_is_int(g, ins, pos, &int_reg)) {
                int_reg[ins.a] = false;
                changed = true;
            }
        }
    }
    for (uint i = 0; i < LOOP_REGS; i++) g.int_reg[i] = int_reg[i];
}

fn bool ssa_build(SsaGraph* g) @feat(SLJIT) {
    CompiledFunction* cf = g.cf;
    LoopPlan* plan       = g.plan;
    bool[LOOP_REGS] read;
    bool[LOOP_REGS] value_read;
    bool[LOOP_REGS] written;
    bool[LOOP_REGS] live_in;
    bool[LOOP_REGS] base;
    bool[LOOP_REGS] int_need;
    bool[LOOP_REGS] f64_need;
    ssa_infer(g, &read, &value_read, &written, &live_in, &base, &int_need, &f64_need);
    ssa_int_fixpoint(g);
    for (uint i = 0; i < LOOP_REGS; i++) {
        g.current[i] = -1;
        g.phi[i] = -1;
        g.arg[i] = -1;
        g.rep[i] = (g.plan.ssa_double & (1UL << i)) != 0 ? F64
            : g.int_reg[i] ? INT32
            : ssa_rep_for(int_need[i], f64_need[i], written[i]);
    }
    for (uint i = 0; i < SSA_MAX_VALUES * 3; i++) g.conv[i] = 0;
    // Header values. Written registers get a phi; read-only numeric inputs get
    // an argument. Pure memory bases need no value.
    // Registers written in the loop but not read before their first in-loop
    // definition still need their final value published when the loop exits
    // and later code reads them. They become loop-carried phis for that
    // reason alone; nothing else about them is loop-carried.
    bool[LOOP_REGS] exit_live;
    for (uint pos = plan.end + 1; pos < cf.code_count; pos++) {
        Instruction after = cf.code[pos];
        if (after.a < LOOP_REGS) exit_live[after.a] = true;
        if (after.b < LOOP_REGS) exit_live[after.b] = true;
        if (after.c < LOOP_REGS) exit_live[after.c] = true;
    }
    g.current_pc = plan.begin;
    for (uint reg = 0; reg < cf.num_regs && reg < LOOP_REGS; reg++) {
        if (written[reg] && (live_in[reg] || exit_live[reg])) {
            int phi = ssa_value(g, PHI, g.rep[reg], -1, 0, 0);
            g.phi[reg] = phi;
            g.values[phi].arg_reg = (int)reg;
            g.current[reg] = phi;
        } else if (!written[reg] && value_read[reg]) {
            int arg = ssa_value(g, ARG, g.rep[reg], -1, 0, 0);
            g.values[arg].arg_reg = (int)reg;
            g.arg[reg] = arg;
            g.current[reg] = arg;
        }
    }
    for (uint reg = 0; reg < LOOP_REGS; reg++) g.header[reg] = g.current[reg];
    for (uint pos = plan.begin; pos <= plan.end; pos++) {
        Instruction ins = cf.code[pos];
        uint at         = pos - plan.begin;
        g.current_pc = pos;
        int target = loop_target(ins, pos);
        if (target >= 0) {
            if (pos != plan.end) {
                g.failed = true;
                return false;
            }
            int lhs =  g.current[ins.b];
            int rhs = -1;
            if (ins.op < Opcode.JMP_NLTI) rhs = g.current[ins.c];
            if (lhs < 0) {
                g.failed = true;
                return false;
            }
            bool integer = g.values[lhs].rep == INT32 && (rhs < 0 || g.values[rhs].rep == INT32);
            if (integer) {
                g.cmp_lhs = ssa_convert(g, lhs, INT32, false);
                g.cmp_rhs = rhs >= 0 ? ssa_convert(g, rhs, INT32, false) : -1;
            } else {
                g.cmp_lhs = ssa_convert(g, lhs, F64, false);
                g.cmp_rhs = rhs >= 0 ? ssa_convert(g, rhs, F64, false) : -1;
            }
            ssa_use(g, g.cmp_lhs);
            if (g.cmp_rhs >= 0) ssa_use(g, g.cmp_rhs);
            g.cmp_imm = ins.op >= Opcode.JMP_NLTI ? (long)(ichar)ins.c : 0;
            g.cmp_op = ins.op;
            continue;
        }
        switch (ins.op) {
            case LDREG:
            case TONUMERIC:

                {
                    if (g.current[ins.b] < 0) {
                        g.failed = true;
                        return false;
                    }
                    int src = g.current[ins.b];
                    ssa_use(g, src);
                    int copy = ssa_value(g, COPY, g.values[src].rep, src, 0, 0);
                    ssa_result(g, copy, ins.a, pos);
                    g.current[ins.a] = copy;
                    break;
                }
            case LDINT:

                {
                    long value = ins.get_sbc();
                    SsaRep rep = value >= -2147483648L && value <= 2147483647L ? INT32 : F64;



                    {
                        int nv = ssa_value(g, rep == INT32 ? CONST_I : CONST_F, rep, -1, 0, value);
                        ssa_result(g, nv, ins.a, pos);
                        g.current[ins.a] = nv;
                    }
                    break;
                }
            case LDCONST:

                {
                    if (ins.get_bc() >= cf.const_count) {
                        g.failed = true;
                        return false;
                    }
                    TVal value = cf.constants[ins.get_bc()];
                    if (!value.is_fastint() && !value.is_number()) {
                        g.failed = true;
                        return false;
                    }
                    double number = value.get_number_or_fastint();
                    if (value.is_fastint()) {
                        long integer = value.get_fastint();
                        if (integer >= -2147483648L && integer <= 2147483647L) {

                            {
                                int nv = ssa_value(g, CONST_I, INT32, -1, 0, integer);
                                ssa_result(g, nv, ins.a, pos);
                                g.current[ins.a] = nv;
                            }
                            break;
                        }
                    }



                    {
                        int nv = ssa_value(g, CONST_F, F64, -1, 0, (long)bitcast(number, ulong));
                        ssa_result(g, nv, ins.a, pos);
                        g.current[ins.a] = nv;
                    }
                    break;
                }
            case GETPROP:
            case GETPROP_CACHE:

                {
                    uint memory = (uint)plan.memory_at[at] - 1;
                    if (memory >= plan.memory_count || g.current[ins.c] < 0) {
                        g.failed = true;
                        return false;
                    }
                    int index = ssa_convert(g, g.current[ins.c], INT32, true);
                    ssa_use(g, index);
                    LoopMemorySpec spec = plan.memory[memory];
                    SsaRep rep          = spec.kind == DENSE ? BOXED : (spec.cls >= FLOAT32ARRAY ? F64 : INT32);



                    {
                        int nv = ssa_value(g, LOAD, rep, index, -1, memory);
                        ssa_result(g, nv, ins.a, pos);
                        g.current[ins.a] = nv;
                    }
                    break;
                }
            case PUTPROP:

                {
                    uint memory = (uint)plan.memory_at[at] - 1;
                    if (memory >= plan.memory_count || g.current[ins.b] < 0 || g.current[ins.c] < 0) {
                        g.failed = true;
                        return false;
                    }
                    int index           = ssa_convert(g, g.current[ins.b], INT32, true);
                    LoopMemorySpec spec = plan.memory[memory];
                    int value;
                    if (spec.kind == DENSE) {
                        value = ssa_convert(g, g.current[ins.c], BOXED, false);
                    } else if (spec.cls >= FLOAT32ARRAY) {
                        value = ssa_convert(g, g.current[ins.c], F64, false);
                    } else {
                        value = ssa_convert(g, g.current[ins.c], INT32, false);
                    }
                    ssa_use(g, index);
                    ssa_use(g, value);
                    ssa_value(g, STORE, BOXED, index, value, memory);
                    break;
                }
            case INC:
            case INC_LT:
            case DEC:

                {
                    if (g.current[ins.a] < 0) {
                        g.failed = true;
                        return false;
                    }
                    // A double counter increments in place: JavaScript numbers
                    // are doubles, so this is exact and needs no int round trip.
                    bool integer = g.values[g.current[ins.a]].rep != F64;
                    SsaRep rep   = integer ? INT32 : F64;
                    int value    = ssa_convert(g, g.current[ins.a], rep, integer);
                    ssa_use(g, value);



                    {
                        int nv = ssa_value(g, ins.op == Opcode.DEC ? SUB : ADD, rep, value, -1, 1);
                        ssa_result(g, nv, ins.a, pos);
                        g.current[ins.a] = nv;
                    }
                    break;
                }
            case ADD:
            case ADD_FUSED:
            case SUB:
            case MUL:
            case DIV:

                {
                    int left  = g.current[ins.b];
                    int right = g.current[ins.c];
                    if (left < 0 || right < 0) {
                        g.failed = true;
                        return false;
                    }
                    SsaOp op     = ins.op == Opcode.ADD || ins.op == Opcode.ADD_FUSED ? ADD
                        : ins.op == Opcode.SUB ? SUB
                        : ins.op == Opcode.MUL ? MUL
                        : DIV;
                    // Integer arithmetic stays in GPRs with overflow exits
                    // instead of round-tripping through doubles.
                    bool integer = op != DIV && g.values[left].rep == INT32 && g.values[right].rep == INT32;
                    SsaRep rep   = integer ? INT32 : F64;
                    left = ssa_convert(g, left, rep, integer);
                    right = ssa_convert(g, right, rep, integer);
                    ssa_use(g, left);
                    ssa_use(g, right);



                    {
                        int nv = ssa_value(g, op, rep, left, right, 0);
                        ssa_result(g, nv, ins.a, pos);
                        g.current[ins.a] = nv;
                    }
                    break;
                }
            case ADDI:
            case SUBI:
            case MULI:

                {
                    int left = g.current[ins.b];
                    if (left < 0) {
                        g.failed = true;
                        return false;
                    }
                    SsaOp op     = ins.op == Opcode.SUBI ? SUB : ins.op == Opcode.MULI ? MUL : ADD;
                    bool integer = g.values[left].rep == INT32;
                    SsaRep rep   = integer ? INT32 : F64;
                    left = ssa_convert(g, left, rep, integer);
                    ssa_use(g, left);



                    {
                        int nv = ssa_value(g, op, rep, left, -1, (long)(ichar)ins.c);
                        ssa_result(g, nv, ins.a, pos);
                        g.current[ins.a] = nv;
                    }
                    break;
                }
            case BAND:
            case BOR:
            case BXOR:
            case SHL:
            case SHR:
            case USHR:

                {
                    int left  = g.current[ins.b];
                    int right = g.current[ins.c];
                    if (left < 0 || right < 0) {
                        g.failed = true;
                        return false;
                    }
                    left = ssa_convert(g, left, INT32, false);
                    right = ssa_convert(g, right, INT32, false);
                    ssa_use(g, left);
                    ssa_use(g, right);
                    SsaOp op = ins.op == Opcode.BAND ? BAND
                        : ins.op == Opcode.BOR ? BOR
                        : ins.op == Opcode.BXOR ? BXOR
                        : ins.op == Opcode.SHL ? SHL
                        : ins.op == Opcode.SHR ? SHR
                        : USHR;



                    {
                        int nv = ssa_value(g, op, INT32, left, right, 0);
                        ssa_result(g, nv, ins.a, pos);
                        g.current[ins.a] = nv;
                    }
                    break;
                }
            case BANDI:
            case BORI:
            case BXORI:
            case SHLI:
            case SHRI:
            case USHRI:

                {
                    int left = g.current[ins.b];
                    if (left < 0) {
                        g.failed = true;
                        return false;
                    }
                    left = ssa_convert(g, left, INT32, false);
                    ssa_use(g, left);
                    SsaOp op = ins.op == Opcode.BANDI ? BAND
                        : ins.op == Opcode.BORI ? BOR
                        : ins.op == Opcode.BXORI ? BXOR
                        : ins.op == Opcode.SHLI ? SHL
                        : ins.op == Opcode.SHRI ? SHR
                        : USHR;



                    {
                        int nv = ssa_value(g, op, INT32, left, -1, (long)(ichar)ins.c);
                        ssa_result(g, nv, ins.a, pos);
                        g.current[ins.a] = nv;
                    }
                    break;
                }
            case BNOT:

                {
                    int value = g.current[ins.b];
                    if (value < 0) {
                        g.failed = true;
                        return false;
                    }
                    value = ssa_convert(g, value, INT32, false);
                    ssa_use(g, value);



                    {
                        int nv = ssa_value(g, BNOT, INT32, value, -1, 0);
                        ssa_result(g, nv, ins.a, pos);
                        g.current[ins.a] = nv;
                    }
                    break;
                }
            default:
                g.failed = true;
                return false;
        }
    }
    for (uint i = 0; i < plan.memory_count && i < LOOP_MEMORY; i++) {
        uint source = plan.memory[i].source;
        g.invariant[i] = !written[source];
    }
    // Values defined before the loop are live across the backedge, so their
    // ranges must extend through the latch rather than ending at the last
    // static use inside one iteration.
    for (uint i = 0; i < g.value_count; i++) {
        if (g.values[i].op == ARG) g.values[i].last = g.stamp;
    }
    // Latch inputs for loop phis.
    g.current_pc = plan.end;
    for (uint reg = 0; reg < cf.num_regs && reg < LOOP_REGS; reg++) {
        if (g.phi[reg] < 0) continue;
        int value = g.current[reg];
        if (value < 0) {
            g.failed = true;
            return false;
        }
        value = ssa_convert(g, value, g.values[g.phi[reg]].rep, false);
        g.values[g.phi[reg]].a = value;
        ssa_use(g, value);
        g.values[g.phi[reg]].last = g.stamp;
    }
    return !g.failed;
}

// Redundant load elimination for the single basic block. A load whose memory
// and index value repeat since the last store to that memory becomes a copy of
// the earlier result.
fn void ssa_cse(SsaGraph* g) @feat(SLJIT) {
    uint count;
    for (uint i = 0; i < g.value_count; i++) {
        SsaValue* value = &g.values[i];
        if (value.op == LOAD) {
            int found = -1;
            for (uint k = 0; k < count; k++) {
                if (g.cse_memory[k] == (int)value.imm && g.cse_index[k] == value.a) {
                    found = g.cse_value[k];
                    break;
                }
            }
            if (found >= 0) {
                value.op = COPY;
                value.a = found;
                value.b = 0;
                value.imm = 0;
                if (g.values[found].last < value.last) g.values[found].last = value.last;
            } else if (count < SSA_CSE) {
                g.cse_memory[count] = (int)value.imm;
                g.cse_index[count] = value.a;
                g.cse_value[count] = (int)i;
                count++;
            }
        } else if (value.op == STORE) {
            uint kept;
            for (uint k = 0; k < count; k++) {
                if (g.cse_memory[k] == (int)value.imm) continue;
                g.cse_memory[kept] = g.cse_memory[k];
                g.cse_index[kept] = g.cse_index[k];
                g.cse_value[kept] = g.cse_value[k];
                kept++;
            }
            count = kept;
        }
    }
}

// Greedy home assignment over the flat definition order. Loop phis are live
// across the backedge; other values are released at their last use.
fn bool ssa_same_class(SsaRep a, SsaRep b) @feat(SLJIT) => (a == F64) == (b == F64);
fn int ssa_gpr_home(uint slot) @feat(SLJIT) => slot < 4 ? jit::reg_r((int)slot + 4) : jit::reg_s((int)slot - 2);

// Copies are pure aliases of their source: both hold the same value, so the
// allocator coalesces them onto one home and codegen drops the move.
fn int ssa_alias(SsaGraph* g, int value) @feat(SLJIT) {
    uint guard;
    while (value >= 0 && guard++ < SSA_MAX_VALUES && g.values[value].op == COPY) value = g.values[value].a;
    return value;
}
fn void ssa_allocate(SsaGraph* g) @feat(SLJIT) {
    for (uint i = 0; i < g.value_count; i++) {
        if (g.values[i].op != COPY) continue;
        int root = ssa_alias(g, (int)i);
        if (root < 0 || root == (int)i) continue;
        if (g.values[root].last < g.values[i].last) g.values[root].last = g.values[i].last;
    }
    // Phis are live across the whole loop and are placed first.
    for (uint i = 0; i < g.value_count; i++) {
        SsaValue* value = &g.values[i];
        value.home = 0;
        if (value.op != PHI) continue;
        uint homes = value.rep == F64 ? SSA_HOMES : SSA_GPR_HOMES;
        for (uint s = 0; s < homes; s++) {
            int home = value.rep == F64 ? 3 + (int)s : ssa_gpr_home(s);
            bool used;
            for (uint j = 0; j < i; j++) {
                SsaValue other = g.values[j];
                if (other.home == 0) continue;
                if (ssa_same_class(other.rep, value.rep) && other.home == home) {
                    used = true;
                    break;
                }
            }
            if (!used) {
                value.home = home;
                break;
            }
        }
        if (value.home == 0) value.spill = g.spill_count++;
    }
    for (uint i = 0; i < g.value_count; i++) {
        SsaValue* value = &g.values[i];
        if (value.op == PHI || value.op == COPY) continue;
        uint homes = value.rep == F64 ? SSA_HOMES : SSA_GPR_HOMES;
        for (uint s = 0; s < homes; s++) {
            int home  = value.rep == F64 ? 3 + (int)s : ssa_gpr_home(s);
            bool free = true;
            for (uint j = 0; j < g.value_count; j++) {
                if (j == i) continue;
                SsaValue other = g.values[j];
                if (other.home != home || !ssa_same_class(other.rep, value.rep)) continue;
                if (other.def <= value.last && value.def <= other.last) {
                    free = false;
                    break;
                }
            }
            if (free) {
                value.home = home;
                break;
            }
        }
        if (value.home == 0) value.spill = g.spill_count++;
    }
    for (uint i = 0; i < g.value_count; i++) {
        if (g.values[i].op != COPY) continue;
        int root = ssa_alias(g, (int)i);
        if (root < 0 || root == (int)i) continue;
        g.values[i].home = g.values[root].home;
        g.values[i].spill = g.values[root].spill;
    }
}
struct SsaEmitter @feat(SLJIT) {
    TemplateEmitter e;
    SsaGraph* g;
    LoopPlan* plan;
    CompiledFunction* cf;
    int state;
    int budget;
    int dirty;
    ulong dirty_mask;
    int[LOOP_REGS] live;
    uint at_def;
    uint pc;
    void* header;
    int length_home;
}

fn void SsaEmitter.gpr(&self, int value, int dst) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    if (v.home != 0) {
        self.e.mov(dst, 0, v.home, 0);
    } else {
        self.e.mov(dst, 0, jit::SLJIT_MEM | self.state, ssa_spill_offset(v.spill));
    }
}
fn void SsaEmitter.load_fpr(&self, int value, int dst) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    if (v.home != 0) {
        if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_MOV_F64, dst, 0, v.home, 0) != 0) self.e.failed = true;
    } else {
        self.e.mov(jit::reg_r(0), 0, jit::SLJIT_MEM | self.state, ssa_spill_offset(v.spill));
        if (jit::sljit_emit_fcopy(
            self.e.compiler,
            jit::SLJIT_COPY_TO_F64,
            dst,
            jit::reg_r(0)
        ) != 0) self.e.failed = true;
    }
}
fn void SsaEmitter.store_gpr(&self, int value, int src) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    if (v.home != 0) {
        self.e.mov(v.home, 0, src, 0);
    } else {
        self.e.mov(jit::SLJIT_MEM | self.state, ssa_spill_offset(v.spill), src, 0);
    }
}
fn void SsaEmitter.store_fpr(&self, int value, int src) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    if (v.home != 0) {
        if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_MOV_F64, v.home, 0, src, 0) != 0) self.e.failed = true;
    } else {
        if (jit::sljit_emit_fcopy(
            self.e.compiler,
            jit::SLJIT_COPY_FROM_F64,
            src,
            jit::reg_r(0)
        ) != 0) self.e.failed = true;
        self.e.mov(jit::SLJIT_MEM | self.state, ssa_spill_offset(v.spill), jit::reg_r(0), 0);
    }
}
// Register holding an integer or boxed value, spilling into `scratch` only
// when the value has no home. Returning the home directly lets operations
// consume operands in place instead of copying them through a scratch pair.
fn int SsaEmitter.gpr_slot(&self, int value, int scratch) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    if (v.home != 0) return v.home;
    self.e.mov(scratch, 0, jit::SLJIT_MEM | self.state, ssa_spill_offset(v.spill));
    return scratch;
}
fn int SsaEmitter.fpr_slot(&self, int value, int scratch) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    if (v.home != 0) return v.home;
    self.load_fpr(value, scratch);
    return scratch;
}
fn void SsaEmitter.snapshot_none(&self, void* jump, uint pc) @feat(SLJIT) {
    if (self.g.exit_count == SSA_EXITS) {
        self.e.failed = true;
        return;
    }
    SsaExit* item = &self.g.exits[self.g.exit_count++];
    item.jump = jump;
    item.pc = pc;
    for (uint i = 0; i < LOOP_REGS; i++) item.regs[i] = -1;
}
fn void SsaEmitter.snapshot_phis(&self, void* jump, uint pc) @feat(SLJIT) {
    if (self.g.exit_count == SSA_EXITS) {
        self.e.failed = true;
        return;
    }
    SsaExit* item = &self.g.exits[self.g.exit_count++];
    item.jump = jump;
    item.pc = pc;
    for (uint i = 0; i < LOOP_REGS; i++) item.regs[i] = self.g.phi[i];
}
fn void SsaEmitter.snapshot(&self, void* jump, uint pc) @feat(SLJIT) {
    if (self.g.exit_count == SSA_EXITS) {
        self.e.failed = true;
        return;
    }
    SsaExit* item = &self.g.exits[self.g.exit_count++];
    item.jump = jump;
    item.pc = pc;
    for (uint i = 0; i < LOOP_REGS; i++) {
        int value = self.live[i];
        // Values whose last use precedes the failing operation need not be
        // reconstructed at the resume point.
        if (value >= 0 && self.g.values[value].last < self.at_def) value = -1;
        item.regs[i] = value;
    }
}
fn void SsaEmitter.guard(&self, int condition, int left, long lw, int right, long rw, uint pc) @feat(SLJIT) {
    self.snapshot(self.e.cmp(condition, left, lw, right, rw), pc);
}
fn void SsaEmitter.box_gpr(&self, int reg) @feat(SLJIT) {
    self.e.op(jit::SLJIT_AND, reg, reg, 0, jit::SLJIT_IMM, 0x0000FFFFFFFFFFFF);
    self.e.op(jit::SLJIT_OR, reg, reg, 0, jit::SLJIT_IMM, (long)(types::TAG_FASTINT << 48));
}
fn void SsaEmitter.bits_fpr(&self, int freg, int dst) @feat(SLJIT) {
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_FROM_F64, freg, dst) != 0) self.e.failed = true;
}
fn void SsaEmitter.number(&self, int reg, int freg, uint pc) @feat(SLJIT) {
    int r3 = jit::reg_r(3);
    self.e.op(jit::SLJIT_LSHR, r3, reg, 0, jit::SLJIT_IMM, 48);
    self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
    void* floating = self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT);
    self.e.op(jit::SLJIT_SHL, reg, reg, 0, jit::SLJIT_IMM, 16);
    self.e.op(jit::SLJIT_ASHR, reg, reg, 0, jit::SLJIT_IMM, 16);
    if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_F64_FROM_SW, freg, 0, reg, 0) != 0) self.e.failed = true;
    void* done = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
    self.e.bind(floating);
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, freg, reg) != 0) self.e.failed = true;
    self.e.bind(done);
}
// Sign-extend a boxed fastint into `dst` and exit when the value does not fit
// in int32, keeping INT32 values plain and range-checked.
// Sign-extend a boxed fastint into `dst` and exit when the value does not fit
// in int32, keeping INT32 values plain and range-checked.
fn void SsaEmitter.unbox_fastint(&self, int reg, int dst, uint pc) @feat(SLJIT) {
    int r3 = jit::reg_r(3);
    self.e.mov(r3, 0, reg, 0, jit::SLJIT_MOV_S32);
    self.e.op(jit::SLJIT_SHL, dst, reg, 0, jit::SLJIT_IMM, 16);
    self.e.op(jit::SLJIT_ASHR, dst, dst, 0, jit::SLJIT_IMM, 16);
    self.guard(jit::SLJIT_NOT_EQUAL, dst, 0, r3, 0, pc);
}
fn void SsaEmitter.int32(&self, int reg, int dst, uint pc) @feat(SLJIT) {
    int r1 = jit::reg_r(1);
    int r3 = jit::reg_r(3);
    self.e.op(jit::SLJIT_LSHR, r3, reg, 0, jit::SLJIT_IMM, 48);
    void* integer = self.e.cmp(jit::SLJIT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT);
    self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
    self.e.op(jit::SLJIT_AND, r3, reg, 0, jit::SLJIT_IMM, 0x7FFFFFFFFFFFFFFFL);
    self.guard(jit::SLJIT_GREATER_EQUAL, r3, 0, jit::SLJIT_IMM, 0x41E0000000000000L, pc);
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 1, reg) != 0) self.e.failed = true;
    if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_SW_FROM_F64, dst, 0, 1, 0) != 0) self.e.failed = true;
    void* done = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
    self.e.bind(integer);
    self.unbox_fastint(reg, r1, pc);
    self.e.mov(dst, 0, r1, 0);
    self.e.bind(done);
}
// Exact integral conversion used by counters and indices. The value must be
// an integer inside int32 and must not be -0; anything else exits.
fn void SsaEmitter.exact_int(&self, int reg, int dst, uint pc) @feat(SLJIT) {
    int r1 = jit::reg_r(1);
    int r3 = jit::reg_r(3);
    self.e.op(jit::SLJIT_LSHR, r3, reg, 0, jit::SLJIT_IMM, 48);
    void* integer = self.e.cmp(jit::SLJIT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT);
    self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 1, reg) != 0) self.e.failed = true;
    self.guard(jit::SLJIT_UNORDERED, 1, 0, 1, 0, pc);
    self.e.mov(r1, 0, jit::SLJIT_IMM, (long)bitcast(-2147483648.0, ulong));
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r1) != 0) self.e.failed = true;
    self.guard(jit::SLJIT_ORDERED_LESS, 1, 0, 2, 0, pc);
    self.e.mov(r1, 0, jit::SLJIT_IMM, (long)bitcast(2147483648.0, ulong));
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r1) != 0) self.e.failed = true;
    self.guard(jit::SLJIT_ORDERED_GREATER_EQUAL, 1, 0, 2, 0, pc);
    self.e.op(jit::SLJIT_SHL, r3, reg, 0, jit::SLJIT_IMM, 1);
    void* nonzero = self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, jit::SLJIT_IMM, 0);
    self.guard(jit::SLJIT_SIG_LESS, reg, 0, jit::SLJIT_IMM, 0, pc);
    self.e.bind(nonzero);
    if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_SW_FROM_F64, dst, 0, 1, 0) != 0) self.e.failed = true;
    if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_F64_FROM_SW, 1, 0, dst, 0) != 0) self.e.failed = true;
    self.guard(jit::SLJIT_ORDERED_NOT_EQUAL, 1, 0, 1, 0, pc);
    void* done = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
    self.e.bind(integer);
    self.unbox_fastint(reg, r1, pc);
    self.e.mov(dst, 0, r1, 0);
    self.e.bind(done);
}
fn long ssa_memory_offset(uint memory, uint field) @feat(SLJIT) => loop_memory_offset(memory, field);

fn void SsaEmitter.header_guards(&self) @feat(SLJIT) {
    int r0 = jit::reg_r(0);
    for (uint memory = 0; memory < self.plan.memory_count && memory < LOOP_MEMORY; memory++) {
        if (!self.g.invariant[memory]) continue;
        uint source = self.plan.memory[memory].source;
        self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, loop_value_offset(source));
        void* jump = self.e.cmp(
            jit::SLJIT_NOT_EQUAL,
            r0,
            0,
            jit::SLJIT_MEM | self.state,
            loop_memory_offset(memory, 0)
        );
        self.snapshot_none(jump, self.plan.begin);
        if (memory == 0) {
            self.length_home = jit::reg_s(5);
            self.e.mov(self.length_home, 0, jit::SLJIT_MEM | self.state, loop_memory_offset(memory, 2));
        }
    }
}
fn void SsaEmitter.prologue(&self) @feat(SLJIT) {
    int r0 = jit::reg_r(0);
    for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
        int value = self.g.phi[reg] >= 0 ? self.g.phi[reg] : self.g.arg[reg];
        if (value < 0) continue;
        SsaRep rep = self.g.values[value].rep;
        self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, loop_value_offset(reg));
        if (rep == INT32) {
            self.exact_int(r0, r0, self.plan.begin);
            self.store_gpr(value, r0);
        } else if (rep == F64) {
            self.number(r0, 1, self.plan.begin);
            self.store_fpr(value, 1);
        } else {
            self.store_gpr(value, r0);
        }
    }
}

fn void SsaEmitter.output(&self, int value, uint pc) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    int r0     = jit::reg_r(0);
    if (v.rep == F64) {
        self.load_fpr(value, 1);
        self.bits_fpr(1, r0);
    } else if (v.rep == INT32) {
        self.gpr(value, r0);
        self.box_gpr(r0);
    } else {
        self.gpr(value, r0);
    }
}

fn void SsaEmitter.body(&self) @feat(SLJIT) {
    int r0  = jit::reg_r(0);
    int r1  = jit::reg_r(1);
    int r2  = jit::reg_r(2);
    int r3  = jit::reg_r(3);
    int imm = jit::SLJIT_IMM;
    int mem = jit::SLJIT_MEM;
    for (uint i = 0; i < self.g.value_count; i++) {
        SsaValue v = self.g.values[i];
        self.at_def = v.def;
        self.pc = v.pc;
        switch (v.op) {
            case ARG:
            case PHI: break;
            case COPY:

                {
                    if (v.rep == F64) {
                        self.load_fpr(v.a, 1);
                        self.store_fpr((int)i, 1);
                    } else {
                        self.gpr(v.a, r0);
                        self.store_gpr((int)i, r0);
                    }
                    break;
                }
            case CONST_I:

                {
                    int dst = v.home != 0 ? v.home : r0;
                    self.e.mov(dst, 0, imm, v.imm);
                    if (v.home == 0) self.store_gpr((int)i, dst);
                    break;
                }
            case CONST_F:

                {
                    int dst = v.home != 0 ? v.home : 1;
                    self.e.mov(r0, 0, imm, v.imm);
                    if (jit::sljit_emit_fcopy(
                        self.e.compiler,
                        jit::SLJIT_COPY_TO_F64,
                        dst,
                        r0
                    ) != 0) self.e.failed = true;
                    if (v.home == 0) self.store_fpr((int)i, dst);
                    break;
                }
            case ADD:
            case SUB:
            case MUL:
            case DIV:

                {
                    if (v.rep == INT32) {
                        int dst     = v.home != 0 ? v.home : r0;
                        int left    = self.gpr_slot(v.a, r0);
                        int right   = imm;
                        long rightw = v.imm;
                        if (v.b >= 0) {
                            right = self.gpr_slot(v.b, r1);
                            rightw = 0;
                        }
                        self.e.op(
                            v.op == SUB ? jit::SLJIT_SUB : v.op == MUL ? jit::SLJIT_MUL : jit::SLJIT_ADD,
                            dst,
                            left,
                            0,
                            right,
                            rightw
                        );
                        self.guard(jit::SLJIT_SIG_LESS, dst, 0, imm, -2147483648L, self.pc);
                        self.guard(jit::SLJIT_SIG_GREATER, dst, 0, imm, 2147483647L, self.pc);
                        self.e.mov(dst, 0, dst, 0, jit::SLJIT_MOV_S32);
                        if (v.home == 0) self.store_gpr((int)i, dst);
                        break;
                    }
                    int dst   = v.home != 0 ? v.home : 1;
                    int left  = self.fpr_slot(v.a, 1);
                    int right = 2;
                    if (v.b >= 0) {
                        right = self.fpr_slot(v.b, 2);
                    } else {
                        self.e.mov(r0, 0, imm, (long)bitcast((double)v.imm, ulong));
                        if (jit::sljit_emit_fcopy(
                            self.e.compiler,
                            jit::SLJIT_COPY_TO_F64,
                            2,
                            r0
                        ) != 0) self.e.failed = true;
                    }
                    int op = v.op == ADD ? jit::SLJIT_ADD_F64
                        : v.op == SUB ? jit::SLJIT_SUB_F64
                        : v.op == MUL ? jit::SLJIT_MUL_F64
                        : jit::SLJIT_DIV_F64;
                    if (jit::sljit_emit_fop2(self.e.compiler, op, dst, 0, left, 0, right, 0) != 0) self.e.failed = true;
                    if (v.home == 0) self.store_fpr((int)i, dst);
                    break;
                }
            case BAND:
            case BOR:
            case BXOR:
            case SHL:
            case SHR:
            case USHR:
            case BNOT:

                {
                    int dst  = v.home != 0 ? v.home : r0;
                    int left = self.gpr_slot(v.a, r0);
                    if (v.op == BNOT) {
                        self.e.op(jit::SLJIT_XOR, dst, left, 0, imm, -1);
                    } else {
                        int right   = imm;
                        long rightw = v.imm;
                        if (v.b >= 0) {
                            right = self.gpr_slot(v.b, r1);
                            rightw = 0;
                        }
                        if (v.op == BAND) {
                            self.e.op(jit::SLJIT_AND, dst, left, 0, right, rightw);
                        } else if (v.op == BOR) {
                            self.e.op(jit::SLJIT_OR, dst, left, 0, right, rightw);
                        } else if (v.op == BXOR) {
                            self.e.op(jit::SLJIT_XOR, dst, left, 0, right, rightw);
                        } else {
                            // The mask must not modify a live operand home.
                            if (!(right == r1)) {
                                if (right == imm) {
                                    self.e.mov(r1, 0, imm, v.imm);
                                } else {
                                    self.e.mov(r1, 0, right, 0);
                                }
                            }
                            self.e.op(jit::SLJIT_AND, r1, r1, 0, imm, 31);
                            int source = left;
                            if (v.op == USHR) {
                                self.e.mov(dst, 0, left, 0, jit::SLJIT_MOV_U32);
                                source = dst;
                            }
                            self.e.op(
                                v.op == SHL ? jit::SLJIT_SHL : (v.op == SHR ? jit::SLJIT_ASHR : jit::SLJIT_LSHR),
                                dst,
                                source,
                                0,
                                r1,
                                0
                            );
                        }
                    }
                    self.e.mov(dst, 0, dst, 0, jit::SLJIT_MOV_S32);
                    if (v.home == 0) self.store_gpr((int)i, dst);
                    break;
                }
            case NEG:

                {
                    int dst  = v.home != 0 ? v.home : 1;
                    int left = self.fpr_slot(v.a, 1);
                    if (jit::sljit_emit_fop1(
                        self.e.compiler,
                        jit::SLJIT_NEG_F64,
                        dst,
                        0,
                        left,
                        0
                    ) != 0) self.e.failed = true;
                    if (v.home == 0) self.store_fpr((int)i, dst);
                    break;
                }
            case TO_INT:

                {
                    SsaValue from = self.g.values[v.a];
                    int dst       = v.home != 0 ? v.home : r0;
                    if (from.rep == BOXED) {
                        self.gpr(v.a, r0);
                        self.int32(r0, dst, self.pc);
                    } else if (from.rep == F64) {
                        self.load_fpr(v.a, 1);
                        self.trunc_int_f64(1, dst, self.pc);
                    } else {
                        self.e.mov(dst, 0, self.gpr_slot(v.a, r0), 0);
                    }
                    if (v.home == 0) self.store_gpr((int)i, dst);
                    break;
                }
            case TO_INDEX:

                {
                    SsaValue from = self.g.values[v.a];
                    int dst       = v.home != 0 ? v.home : r0;
                    if (from.rep == BOXED) {
                        self.gpr(v.a, r0);
                        self.exact_int(r0, dst, self.pc);
                    } else if (from.rep == F64) {
                        self.load_fpr(v.a, 1);
                        self.exact_int_f64(1, dst, self.pc);
                    } else {
                        self.e.mov(dst, 0, self.gpr_slot(v.a, r0), 0);
                        self.e.mov(dst, 0, dst, 0, jit::SLJIT_MOV_S32);
                    }
                    if (v.home == 0) self.store_gpr((int)i, dst);
                    break;
                }
            case TO_F64:

                {
                    SsaValue from = self.g.values[v.a];
                    int dst       = v.home != 0 ? v.home : 1;
                    if (from.rep == BOXED) {
                        self.gpr(v.a, r0);
                        self.number(r0, dst, self.pc);
                    } else if (from.rep == INT32) {
                        self.gpr(v.a, r0);
                        if (jit::sljit_emit_fop1(
                            self.e.compiler,
                            jit::SLJIT_CONV_F64_FROM_SW,
                            dst,
                            0,
                            r0,
                            0
                        ) != 0) self.e.failed = true;
                    } else {
                        int left = self.fpr_slot(v.a, 1);
                        if (left != dst && jit::sljit_emit_fop1(
                            self.e.compiler,
                            jit::SLJIT_MOV_F64,
                            dst,
                            0,
                            left,
                            0
                        ) != 0) self.e.failed = true;
                    }
                    if (v.home == 0) self.store_fpr((int)i, dst);
                    break;
                }
            case BOX_I:

                {
                    self.gpr(v.a, r0);
                    self.box_gpr(r0);
                    self.store_gpr((int)i, r0);
                    break;
                }
            case BOX_F:

                {
                    int dst  = v.home != 0 ? v.home : r0;
                    int left = self.fpr_slot(v.a, 1);
                    self.bits_fpr(left, dst);
                    if (v.home == 0) self.store_gpr((int)i, dst);
                    break;
                }
            case LOAD:

                {
                    uint memory = (uint)v.imm;
                    self.load(memory, v.a, (int)i, v.rep);
                    break;
                }
            case STORE:

                {
                    uint memory = (uint)v.imm;
                    self.store(memory, v.a, v.b);
                    break;
                }
        }
        if (v.dst_reg >= 0) self.live[v.dst_reg] = (int)i;
    }
}

fn void SsaEmitter.exact_int_f64(&self, int freg, int dst, uint pc) @feat(SLJIT) {
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    self.guard(jit::SLJIT_UNORDERED, freg, 0, freg, 0, pc);
    self.e.mov(r1, 0, jit::SLJIT_IMM, (long)bitcast(-2147483648.0, ulong));
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r1) != 0) self.e.failed = true;
    self.guard(jit::SLJIT_ORDERED_LESS, freg, 0, 2, 0, pc);
    self.e.mov(r1, 0, jit::SLJIT_IMM, (long)bitcast(2147483648.0, ulong));
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r1) != 0) self.e.failed = true;
    self.guard(jit::SLJIT_ORDERED_GREATER_EQUAL, freg, 0, 2, 0, pc);
    if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_SW_FROM_F64, dst, 0, freg, 0) != 0) self.e.failed = true;
    if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_F64_FROM_SW, 2, 0, dst, 0) != 0) self.e.failed = true;
    void* equal = jit::sljit_emit_fcmp(self.e.compiler, jit::SLJIT_ORDERED_EQUAL, freg, 0, 2, 0);
    self.snapshot(jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP), pc);
    self.e.bind(equal);
    self.e.mov(dst, 0, dst, 0, jit::SLJIT_MOV_S32);
}

fn void SsaEmitter.memory_guard(&self, uint source, uint memory, uint pc) @feat(SLJIT) {
    if (memory < LOOP_MEMORY && self.g.invariant[memory]) return;
    int r0 = jit::reg_r(0);
    self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, loop_value_offset(source));
    self.guard(jit::SLJIT_NOT_EQUAL, r0, 0, jit::SLJIT_MEM | self.state, loop_memory_offset(memory, 0), pc);
}
fn void SsaEmitter.index(&self, int value, uint memory, uint pc) @feat(SLJIT) {
    int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2);
    self.gpr(value, r1);
    // The first memory keeps its length in a saved register for the whole
    // loop, so bounds checks are a register comparison.
    if (memory == 0 && self.length_home != 0) {
        self.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, self.length_home, 0, pc);
    } else {
        self.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, jit::SLJIT_MEM | self.state, loop_memory_offset(memory, 2), pc);
    }
    uint shift = self.plan.memory[memory].kind == DENSE ? 3 : builtins::ta_elem_shift(self.plan.memory[memory].cls);
    if (shift != 0) self.e.op(jit::SLJIT_SHL, r1, r1, 0, jit::SLJIT_IMM, shift);
    self.e.mov(r2, 0, jit::SLJIT_MEM | self.state, loop_memory_offset(memory, 1));
    self.e.op(jit::SLJIT_ADD, r2, r2, 0, r1, 0);
}
fn void SsaEmitter.load(&self, uint memory, int index, int dst_value, SsaRep rep) @feat(SLJIT) {
    LoopMemorySpec spec = self.plan.memory[memory];
    uint pc             = self.pc;
    self.memory_guard(spec.source, memory, pc);
    self.index(index, memory, pc);
    int r0 = jit::reg_r(0);
    int r2 = jit::reg_r(2);
    int r3 = jit::reg_r(3);
    if (spec.kind == DENSE) {
        int dst = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : r0;
        self.e.mov(dst, 0, jit::SLJIT_MEM | r2, 0);
        self.e.op(jit::SLJIT_LSHR, r3, dst, 0, jit::SLJIT_IMM, 48);
        self.guard(jit::SLJIT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_UNDEFINED, pc);
        if (self.g.values[dst_value].home == 0) self.store_gpr(dst_value, dst);
    } else if (spec.cls >= FLOAT32ARRAY) {
        bool small = spec.cls == FLOAT32ARRAY;
        int dst    = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : 1;
        if (jit::sljit_emit_fop1(
            self.e.compiler,
            jit::SLJIT_MOV_F64 | (small ? jit::SLJIT_32 : 0),
            dst,
            0,
            jit::SLJIT_MEM | r2,
            0
        ) != 0) self.e.failed = true;
        if (small && jit::sljit_emit_fop1(
            self.e.compiler,
            jit::SLJIT_CONV_F64_FROM_F32,
            dst,
            0,
            dst,
            0
        ) != 0) self.e.failed = true;
        if (self.g.values[dst_value].home == 0) self.store_fpr(dst_value, dst);
    } else {
        int dst = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : r0;
        self.e.mov(dst, 0, jit::SLJIT_MEM | r2, 0, loop_load_op(spec.cls));
        if (self.g.values[dst_value].home == 0) self.store_gpr(dst_value, dst);
    }
}
fn void SsaEmitter.store(&self, uint memory, int index, int value) @feat(SLJIT) {
    for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
        int live = self.live[reg];
        if (live >= 0 && self.g.values[live].rep == BOXED && self.g.values[live].op == LOAD
            && self.g.values[live].last >= self.at_def) {
            self.e.failed = true;
        }
    }
    LoopMemorySpec spec = self.plan.memory[memory];
    uint pc             = self.pc;
    self.memory_guard(spec.source, memory, pc);
    self.index(index, memory, pc);
    int r0       = jit::reg_r(0);
    int r2       = jit::reg_r(2);
    int r3       = jit::reg_r(3);
    SsaValue src = self.g.values[value];
    if (spec.kind == DENSE) {
        self.e.mov(r0, 0, jit::SLJIT_MEM | r2, 0);
        self.e.op(jit::SLJIT_LSHR, r3, r0, 0, jit::SLJIT_IMM, 48);
        self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
        self.gpr(value, r0);
        self.e.op(jit::SLJIT_LSHR, r3, r0, 0, jit::SLJIT_IMM, 48);
        self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
        self.e.mov(jit::SLJIT_MEM | r2, 0, r0, 0);
    } else if (spec.cls >= FLOAT32ARRAY) {
        self.load_fpr(value, 1);
        bool small = spec.cls == FLOAT32ARRAY;
        if (small && jit::sljit_emit_fop1(
            self.e.compiler,
            jit::SLJIT_CONV_F64_FROM_F32 | jit::SLJIT_32,
            1,
            0,
            1,
            0
        ) != 0) self.e.failed = true;
        if (jit::sljit_emit_fop1(
            self.e.compiler,
            jit::SLJIT_MOV_F64 | (small ? jit::SLJIT_32 : 0),
            jit::SLJIT_MEM | r2,
            0,
            1,
            0
        ) != 0) self.e.failed = true;
    } else {
        self.gpr(value, r0);
        self.e.mov(jit::SLJIT_MEM | r2, 0, r0, 0, loop_load_op(spec.cls));
    }
}

fn void SsaEmitter.publish(&self, int[LOOP_REGS]* regs, uint pc) @feat(SLJIT) {
    int r0      = jit::reg_r(0);
    LoopState layout;
    ulong dirty = self.dirty_mask;
    for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
        int value = (*regs)[reg];
        if (value < 0) continue;
        self.output(value, pc);
        self.e.mov(jit::SLJIT_MEM | self.state, loop_value_offset(reg), r0, 0);
        dirty |= 1UL << reg;
    }
    self.e.mov(jit::SLJIT_MEM | self.state, (char*)&layout.dirty - (char*)&layout, jit::SLJIT_IMM, (long)dirty);
    self.e.mov(jit::SLJIT_MEM | self.state, (char*)&layout.budget - (char*)&layout, self.budget, 0);
    self.e.mov(r0, 0, jit::SLJIT_IMM, (long)pc);
    if (jit::sljit_emit_return(self.e.compiler, jit::SLJIT_MOV, r0, 0) != 0) self.e.failed = true;
}
fn void SsaEmitter.exit_stubs(&self) @feat(SLJIT) {
    for (uint i = 0; i < self.g.exit_count; i++) {
        SsaExit* item = &self.g.exits[i];
        self.e.bind(item.jump);
        self.publish(&item.regs, item.pc);
    }
}
fn void SsaEmitter.latch(&self) @feat(SLJIT) {
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    // Direct copies are safe when no source home is also a phi destination.
    // Otherwise the copies go through private spill slots so cycles in the
    // header locations never clobber a source.
    bool cycle;
    for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
        int phi = self.g.phi[reg];
        if (phi < 0) continue;
        int src  = self.g.values[phi].a;
        int home = self.g.values[src].home;
        if (home == 0) continue;
        for (uint other = 0; other < self.cf.num_regs && other < LOOP_REGS; other++) {
            int dst = self.g.phi[other];
            if (dst < 0) continue;
            if (self.g.values[dst].home == home) {
                cycle = true;
                break;
            }
        }
    }
    if (!cycle) {
        for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
            int phi = self.g.phi[reg];
            if (phi < 0) continue;
            int src     = self.g.values[phi].a;
            SsaValue sv = self.g.values[src];
            SsaValue pv = self.g.values[phi];
            if (sv.rep == F64) {
                if (sv.home != 0 && pv.home != 0) {
                    if (jit::sljit_emit_fop1(
                        self.e.compiler,
                        jit::SLJIT_MOV_F64,
                        pv.home,
                        0,
                        sv.home,
                        0
                    ) != 0) self.e.failed = true;
                } else {
                    self.load_fpr(src, 1);
                    self.store_fpr(phi, 1);
                }
            } else if (sv.home != 0 && pv.home != 0) {
                self.e.mov(pv.home, 0, sv.home, 0);
            } else {
                self.gpr(src, r0);
                self.store_gpr(phi, r0);
            }
        }
    } else {
        uint temp = self.g.spill_count;
        for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
            int phi = self.g.phi[reg];
            if (phi < 0) continue;
            int src     = self.g.values[phi].a;
            SsaValue sv = self.g.values[src];
            if (sv.rep == F64) {
                self.load_fpr(src, 1);
                self.bits_fpr(1, r0);
            } else {
                self.gpr(src, r0);
            }
            self.e.mov(jit::SLJIT_MEM | self.state, ssa_spill_offset(temp), r0, 0);
            temp++;
        }
        temp = self.g.spill_count;
        for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
            int phi = self.g.phi[reg];
            if (phi < 0) continue;
            SsaValue pv = self.g.values[phi];
            self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, ssa_spill_offset(temp));
            temp++;
            if (pv.rep == F64) {
                if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 1, r0) != 0) self.e.failed = true;
                self.store_fpr(phi, 1);
            } else {
                self.store_gpr(phi, r0);
            }
        }
    }
    // A failed budget polls the interpreter at the backedge; post-body values
    // are published, not the edge copies.
    self.at_def = self.g.stamp;
    self.snapshot_phis(self.e.cmp(jit::SLJIT_LESS_EQUAL, self.budget, 0, jit::SLJIT_IMM, 1), self.plan.end);
    self.e.op(jit::SLJIT_SUB, self.budget, self.budget, 0, jit::SLJIT_IMM, 1);
    int r2       = jit::reg_r(2);
    SsaValue lhs = self.g.values[self.g.cmp_lhs];
    if (lhs.rep == INT32) {
        self.gpr(self.g.cmp_lhs, r0);
        if (self.g.cmp_rhs >= 0) {
            self.gpr(self.g.cmp_rhs, r1);
        } else {
            self.e.mov(r1, 0, jit::SLJIT_IMM, self.g.cmp_imm);
        }
        void* taken = self.e.cmp(loop_condition(self.g.cmp_op), r0, 0, r1, 0);
        if (taken == null) {
            self.e.failed = true;
        } else {
            jit::sljit_set_label(taken, self.header);
        }
    } else {
        self.load_fpr(self.g.cmp_lhs, 1);
        if (self.g.cmp_rhs >= 0) {
            self.load_fpr(self.g.cmp_rhs, 2);
        } else {
            self.e.mov(r0, 0, jit::SLJIT_IMM, (long)bitcast((double)self.g.cmp_imm, ulong));
            if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r0) != 0) self.e.failed = true;
        }
        uint index         = self.g.cmp_op >= Opcode.JMP_NLTI ? self.g.cmp_op.ordinal - Opcode.JMP_NLTI.ordinal
            : self.g.cmp_op.ordinal - Opcode.JMP_NLT.ordinal;
        int[10] conditions = { 27, 34, 29, 32, 26, 35, 28, 33, 24, 25 };
        void* taken        = jit::sljit_emit_fcmp(self.e.compiler, conditions[index], 1, 0, 2, 0);
        if (taken == null) {
            self.e.failed = true;
        } else {
            jit::sljit_set_label(taken, self.header);
        }
    }
    r2 = r2;
}
fn LoopNative ssa_loop_emit(LoopPlan* plan, CompiledFunction* cf, Heap* h) @feat(SLJIT) {
    SsaGraph* graph = (SsaGraph*)h.alloc_func(h.heap_udata, SsaGraph::size);
    if (graph == null) return null;
    defer h.free_func(h.heap_udata, graph);
    mem::clear(graph, (sz)SsaGraph::size);
    graph.plan = plan;
    graph.cf = cf;
    if (!ssa_build(graph)) return null;
    ssa_cse(graph);
    ssa_allocate(graph);
    uint phi_count;
    for (uint reg = 0; reg < cf.num_regs && reg < LOOP_REGS; reg++) if (graph.phi[reg] >= 0) phi_count++;
    if (graph.spill_count + phi_count > SSA_MAX_SPILL) return null;
    SsaEmitter self    = { .g = graph, .plan = plan, .cf = cf };
    TemplateEmitter* e = &self.e;
    e.compiler = jit::sljit_create_compiler(null);
    if (e.compiler == null) return null;
    defer jit::sljit_free_compiler(e.compiler);
    if (jit::sljit_emit_enter(e.compiler, 0, jit::SLJIT_ARGS2WWW, 8 | (10 << 8), 6, 0) != 0) return null;
    int r0 = jit::reg_r(0);
    self.state = jit::reg_s(0);
    self.budget = jit::reg_s(1);
    self.dirty = jit::reg_s(2);
    self.at_def = 0;
    for (uint i = 0; i < LOOP_REGS; i++) self.live[i] = graph.header[i];
    e.mov(self.state, 0, r0, 0);
    e.mov(self.budget, 0, jit::reg_r(1), 0);
    e.mov(self.dirty, 0, jit::SLJIT_IMM, 0);
    // Prologue guards must not publish anything: the interpreter resumes at
    // the loop header with its original frame.
    int saved_count = (int)graph.exit_count;
    self.header_guards();
    self.prologue();
    for (uint i = (uint)saved_count; i < graph.exit_count; i++) {
        for (uint reg = 0; reg < LOOP_REGS; reg++) graph.exits[i].regs[reg] = -1;
    }
    self.header = e.label();
    self.body();
    self.latch();
    // Normal completion falls through the backedge condition.
    self.at_def = graph.stamp;
    int[LOOP_REGS] final;
    for (uint rr = 0; rr < LOOP_REGS; rr++) final[rr] = graph.phi[rr];
    self.publish(&final, plan.end + 1);
    self.exit_stubs();
    if (e.failed) return null;
    LoopNative native = (LoopNative)jit::sljit_generate_code(e.compiler, 0, null);
    if (native != null) plan.code_bytes = jit::sljit_shim_code_size(e.compiler);
    return native;
}

fn void SsaEmitter.trunc_int_f64(&self, int freg, int dst, uint pc) @feat(SLJIT) {
    int r1          = jit::reg_r(1);
    void* unordered = jit::sljit_emit_fcmp(self.e.compiler, jit::SLJIT_UNORDERED, freg, 0, freg, 0);
    self.snapshot(unordered, pc);
    self.e.mov(r1, 0, jit::SLJIT_IMM, (long)bitcast(-2147483648.0, ulong));
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r1) != 0) self.e.failed = true;
    self.snapshot(jit::sljit_emit_fcmp(self.e.compiler, jit::SLJIT_ORDERED_LESS, freg, 0, 2, 0), pc);
    self.e.mov(r1, 0, jit::SLJIT_IMM, (long)bitcast(2147483648.0, ulong));
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r1) != 0) self.e.failed = true;
    self.snapshot(jit::sljit_emit_fcmp(self.e.compiler, jit::SLJIT_ORDERED_GREATER_EQUAL, freg, 0, 2, 0), pc);
    if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_SW_FROM_F64, dst, 0, freg, 0) != 0) self.e.failed = true;
    self.e.mov(dst, 0, dst, 0, jit::SLJIT_MOV_S32);
}
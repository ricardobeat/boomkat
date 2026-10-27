module boomkat::vm;

import boomkat::bytecode;
import boomkat::compiler;
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
// Keep an opt-out for differential measurements of the straight-line tier.
const bool SSA_ENABLED    = !$feat(SLJIT_NO_SSA);
const uint SSA_MAX_VALUES = 512;
const uint SSA_MAX_SPILL  = 128;
const uint SSA_HOMES      = 8;
const uint SSA_GPR_HOMES  = 7;
const uint SSA_EXITS      = 128;
const uint SSA_CSE        = 64;
const uint SSA_BLOCKS     = 16;
const uint SSA_JOINS      = 16;

enum SsaRep : char {
    BOXED,
    INT32,
    F64
}

enum SsaOp : char {
    ARG,
    PHI,
    BINDING,
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
    STORE,
    // Identity guard: the value must be a function whose compiled body is the
    // one the call was expanded from.
    CHECKFN,
    // A value merged from several arms at a join. Its home holds whichever
    // incoming value the path took.
    JOIN,
    // A conditional branch inside the body: the arms of an if.
    BRANCH,
    // An unconditional branch inside the body: the end of an arm.
    GOTO
}

struct SsaValue @feat(SLJIT) {
    SsaOp op;
    SsaRep rep;
    int a;
    int b;
    long imm;
    uint def;
    uint alloc_begin;
    uint last;
    uint pc;
    int dst_reg;
    int home;
    uint spill;
    int arg_reg;
    // A branch names the block it leaves and the block its other arm takes.
    int block;
    int target;
    int fallto;
    Opcode branch_op;
}

// One basic block of the loop body. The blocks partition the body in
// bytecode order, so a block's fall-through successor is the next one.
struct SsaBlock @feat(SLJIT) {
    uint begin;
    uint end;
    uint succ0;
    uint succ1;
    uint pred_count;
    uint[4] preds;
    uint branch_pc;
    bool conditional;
    bool jump;
}

// A block with more than one predecessor: the registers its predecessors
// disagree about are merged here.
struct SsaJoin @feat(SLJIT) {
    uint block;
    uint pred_count;
    uint[4] preds;
    int[LOOP_REGS] phi;
    int[LOOP_REGS][4] incoming;
}

struct SsaExit @feat(SLJIT) {
    void* jump;
    uint pc;
    int[LOOP_REGS] regs;
}

struct SsaGraph @feat(SLJIT) {
    LoopPlan* plan;
    CompiledFunction* cf;
    Heap* heap;
    SsaValue[SSA_MAX_VALUES] values;
    int[SSA_MAX_VALUES * 4] conv;
    uint value_count;
    uint stamp;
    uint current_pc;
    uint current_block;
    uint spill_count;
    bool failed;
    int[LOOP_REGS] current;
    int[LOOP_REGS] header;
    // Interpreter state before each bytecode, including values whose only
    // remaining use is recovery after a guard. IR-use liveness is insufficient.
    int[LOOP_REGS][LOOP_OPS + 1] frames;
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
    // Element reads whose every consumer converts to a number: the tag guard
    // that rejects a non-number also rules out a hole, so the store that
    // follows such a read into the same slot needs no second check.
    bool[SSA_MAX_VALUES] numeric_load;
    // Registers whose loop-carried value arrives as an exact double: keeping
    // them in the wider representation removes an exact conversion from every
    // backedge and lets the loop test compare doubles directly.
    ulong force_f64;
    int[SSA_CSE] cse_memory;
    int[SSA_CSE] cse_index;
    int[SSA_CSE] cse_value;
    // The body's block graph and the joins between its arms.
    SsaBlock[SSA_BLOCKS] blocks;
    uint block_count;
    uint[SSA_BLOCKS] dominators;
    SsaJoin[SSA_JOINS] joins;
    uint join_count;
    // The register state at the end of each block.
    int[LOOP_REGS][SSA_BLOCKS] block_exit;
    // The values each block owns, in the order they were built.
    uint[SSA_BLOCKS] block_first;
    uint[SSA_BLOCKS] block_last;
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
    g.values[index].block = (int)g.current_block;
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
    // ToInt32 truncates/wraps; an exact array index must retain its own guard.
    uint key = (uint)value * 4 + (exact && rep == INT32 ? 3 : (uint)rep);
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
// The comparison branches the tier can turn into a native test. The other
// branch forms pack their operand into the offset field.
fn bool ssa_comparison_op(Opcode op) @feat(SLJIT) {
    return (op >= Opcode.JMP_NLT && op <= Opcode.JMP_SNEQ)
        || (op >= Opcode.JMP_NLTI && op <= Opcode.JMP_SNEQI);
}

// Split the body into basic blocks at the forward branch targets. A block
// ends at the branch that leaves it, or at the start of the next block, so
// the blocks partition the body in bytecode order and a block's fall-through
// successor is the next one.
fn bool ssa_split_blocks(SsaGraph* g) @feat(SLJIT) {
    CompiledFunction* cf = g.cf;
    LoopPlan* plan = g.plan;
    // A block starts at the body's head, after a conditional branch (the arm
    // that falls through) and at the target of a forward branch.
    uint[SSA_BLOCKS] starts;
    uint count = 0;
    starts[count++] = plan.begin;
    for (uint pos = plan.begin; pos <= plan.end; pos++) {
        Instruction ins = cf.code[pos];
        int target = loop_target(ins, pos);
        if (target < 0) continue;
        if (target == (int)plan.begin) continue;
        // A branch inside the body must move forward and stay inside it.
        if (target <= (int)pos || target > (int)plan.end) return false;
        if (ins.op != Opcode.JUMP && pos + 1 <= plan.end) {
            bool found = false;
            for (uint i = 0; i < count; i++) {
                if (starts[i] == pos + 1) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (count == SSA_BLOCKS) return false;
                uint at = count;
                while (at > 0 && starts[at - 1] > pos + 1) {
                    starts[at] = starts[at - 1];
                    at--;
                }
                starts[at] = pos + 1;
                count++;
            }
        }
        bool found = false;
        for (uint i = 0; i < count; i++) {
            if (starts[i] == (uint)target) {
                found = true;
                break;
            }
        }
        if (found) continue;
        if (count == SSA_BLOCKS) return false;
        uint at = count;
        while (at > 0 && starts[at - 1] > (uint)target) {
            starts[at] = starts[at - 1];
            at--;
        }
        starts[at] = (uint)target;
        count++;
    }
    g.block_count = count;
    for (uint i = 0; i < count; i++) {
        SsaBlock* block = &g.blocks[i];
        block.begin = starts[i];
        uint limit = i + 1 < count ? starts[i + 1] - 1 : plan.end;
        uint e = starts[i];
        while (e <= limit && loop_target(cf.code[e], e) < 0) e++;
        block.branch_pc = e <= limit ? e : 0;
        block.end = block.branch_pc != 0 ? e : limit;
        block.conditional = false;
        block.jump = false;
        block.succ0 = 0;
        block.succ1 = 0;
        if (block.branch_pc != 0) {
            Instruction ins = cf.code[block.branch_pc];
            if (ins.op == Opcode.JUMP) {
                block.jump = true;
            } else {
                block.conditional = true;
            }
        }
    }
    // Resolve the edges now that every block start is known.
    for (uint i = 0; i < count; i++) {
        SsaBlock* block = &g.blocks[i];
        if (block.branch_pc == 0) {
            block.succ0 = i + 1 < count ? i + 1 : 0;
            continue;
        }
        Instruction ins = cf.code[block.branch_pc];
        int target = loop_target(ins, block.branch_pc);
        if (block.jump) {
            block.succ0 = 0;
            for (uint j = 0; j < count; j++) {
                if (g.blocks[j].begin == (uint)target) {
                    block.succ0 = j;
                    break;
                }
            }
            continue;
        }
        // A conditional branch: the arm that falls through is the next block,
        // the other one is the block the target names.
        block.succ0 = i + 1 < count ? i + 1 : 0;
        block.succ1 = 0;
        for (uint j = 0; j < count; j++) {
            if (g.blocks[j].begin == (uint)target) {
                block.succ1 = j;
                break;
            }
        }
    }
    // The last block ends at the backedge, which the latch owns.
    g.blocks[count - 1].succ0 = 0;
    g.blocks[count - 1].succ1 = 0;
    // Collect the predecessors.
    for (uint i = 0; i < count; i++) {
        SsaBlock* block = &g.blocks[i];
        block.pred_count = 0;
        for (uint j = 0; j < count; j++) {
            SsaBlock* from = &g.blocks[j];
            if (from.succ0 == i || from.succ1 == i) {
                if (block.pred_count == block.preds.len) return false;
                block.preds[block.pred_count++] = j;
            }
        }
    }
    return true;
}

// The block a bytecode position belongs to.
fn int ssa_block_of(SsaGraph* g, uint pc) @feat(SLJIT) {
    for (uint i = 0; i < g.block_count; i++) {
        if (g.blocks[i].begin <= pc && pc <= g.blocks[i].end) return (int)i;
    }
    return -1;
}

fn bool ssa_loop_eligible(LoopPlan* plan, CompiledFunction* cf, Heap* h) @feat(SLJIT) {
    // Unsupported graphs retain the straight-line loop implementation.
    if (!SSA_ENABLED || plan.memory_count > LOOP_MEMORY) return false;
    for (uint i = 0; i < plan.memory_count; i++) {
        LoopMemoryKind kind = plan.memory[i].kind;
        if (kind == ASCII || kind == INTRINSIC) return false;
    }
    for (uint pos = plan.begin; pos <= plan.end; pos++) {
        Instruction ins = cf.code[pos];
        int target      = loop_target(ins, pos);
        if (target >= 0) {
            if (pos == plan.end) {
                if (target != (int)plan.begin) return false;
                // The backedge must compare two values. A truthiness test names
                // its operand in the branch's offset field, not in a register.
                if (!ssa_comparison_op(ins.op)) return false;
                continue;
            }
            // An arm's branch: a comparison, a truthiness test, or the jump
            // that ends an arm. A branch that leaves the body is not
            // supported.
            if (target <= (int)pos || target > (int)plan.end) return false;
            if (ins.op == Opcode.IF_TRUE || ins.op == Opcode.IF_FALSE) continue;
            if (ins.op == Opcode.JUMP) continue;
            if (!ssa_comparison_op(ins.op)) return false;
            continue;
        }
        switch (ins.op) {
            case GETCAP:
            case GETVAR:
            case GETGLOBAL:
                if (plan.binding_at[pos - plan.begin] == 0) return false;
                continue;
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
            case GETPROPC:
            case GETPROPC_CACHED:
            case GETTHISC:

                {
                    uint at = pos - plan.begin;
                    if (plan.memory_at[at] == 0 || plan.intrinsic_at[at] != 0) return false;
                    LoopMemoryKind kind = plan.memory[(uint)plan.memory_at[at] - 1].kind;
                    if (kind != FIELD && kind != SHAPE_FIELD) return false;
                    continue;
                }
            case CALL:
            case CALL_UNDEF_THIS:
                // Expanded in place, so the callee body must be a leaf.
                if (plan.memory_at[pos - plan.begin] != 0) return false;
                if (function_inline_ssa_candidate(cf, pos, h) == null) return false;
                continue;
            default:
                return false;
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
        if (loop_target(ins, pos) >= 0) {
            // A comparison branch reads two numbers; a truthiness test reads
            // one value and does not use it as a number.
            bool comparison = ssa_comparison_op(ins.op);
            uint left      = comparison ? ins.b : ins.a;
            uint right     = comparison ? ins.c : left;
            if (comparison && ins.op >= Opcode.JMP_NLTI) right = left;
            if (left < LOOP_REGS) {
                (*read)[left] = true;
                (*value_read)[left] = true;
                if (!assigned[left]) (*live_in)[left] = true;
                if (comparison) (*int_need)[left] = true;
            }
            if (right < LOOP_REGS && right != left) {
                (*read)[right] = true;
                (*value_read)[right] = true;
                if (!assigned[right]) (*live_in)[right] = true;
                if (comparison) (*int_need)[right] = true;
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
            case GETCAP:
            case GETVAR:
            case GETGLOBAL:
            case LDINT:
            case LDCONST:
                break;
            case CALL:
            case CALL_UNDEF_THIS:

                {
                    if (ins.b + 1 + ins.c >= cf.num_regs) return;
                    for (uint i = 0; i <= ins.c + 1; i++) {
                        uint reg = ins.b + i;
                        (*read)[reg] = true;
                        (*value_read)[reg] = true;
                        if (!assigned[reg]) (*live_in)[reg] = true;
                    }
                    writes = false;
                }
                break;
            case GETPROPC:
            case GETPROPC_CACHED:
            case GETTHISC:
                if (plan.memory_at[pos - plan.begin] != 0
                    && plan.memory[(uint)plan.memory_at[pos - plan.begin] - 1].kind == SHAPE_FIELD
                    && ins.op != Opcode.GETTHISC) {
                    (*read)[ins.b] = true;
                    (*value_read)[ins.b] = true;
                    if (!assigned[ins.b]) (*live_in)[ins.b] = true;
                }
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
                if (spec.kind == FIELD || spec.kind == SHAPE_FIELD) return false;
                return spec.kind != DENSE && spec.cls < FLOAT32ARRAY && spec.cls != UINT32ARRAY;
            }
        default: return false;
    }
}
fn void ssa_int_fixpoint(SsaGraph* g) @feat(SLJIT) {
    CompiledFunction* cf = g.cf;
    LoopPlan* plan = g.plan;
    bool[LOOP_REGS] assigned;
    bool[LOOP_REGS] int_reg;
    for (uint i = 0; i < LOOP_REGS; i++) int_reg[i] = true;
    bool changed = true;
    while (changed) {
        changed = false;
        for (uint pos = plan.begin; pos <= plan.end; pos++) {
            Instruction ins = cf.code[pos];
            uint[8] words;
            compiler::RegSet writes = { .words = &words[0], .word_count = 8 };
            compiler::register_may_writes(ins, &writes);
            bool integer = ssa_op_is_int(g, ins, pos, &int_reg);
            for (uint reg = 0; reg < LOOP_REGS; reg++) {
                if (!writes.test(reg)) continue;
                assigned[reg] = true;
                if (int_reg[reg] && (reg != ins.a || !integer)) {
                    int_reg[reg] = false;
                    changed = true;
                }
            }
        }
        for (uint reg = 0; reg < LOOP_REGS; reg++) {
            if (!assigned[reg] && int_reg[reg]) {
                int_reg[reg] = false;
                changed = true;
            }
        }
    }
    for (uint i = 0; i < LOOP_REGS; i++) g.int_reg[i] = int_reg[i];
}

// Enter a block: its register state is the merge of its predecessors' states.
// Where the predecessors disagree, the join holds a value each of them
// writes before it arrives.
fn bool ssa_enter_block(SsaGraph* g, uint b) @feat(SLJIT) {
    SsaBlock* block = &g.blocks[b];
    if (b == 0) return true;
    if (block.pred_count == 0) return true;
    if (block.pred_count == 1) {
        uint pred = block.preds[0];
        for (uint reg = 0; reg < LOOP_REGS; reg++) g.current[reg] = g.block_exit[pred][reg];
        return true;
    }
    if (g.join_count == SSA_JOINS) return false;
    uint index = g.join_count++;
    SsaJoin* join = &g.joins[index];
    join.block = b;
    join.pred_count = block.pred_count;
    for (uint p = 0; p < block.pred_count; p++) {
        join.preds[p] = block.preds[p];
        for (uint reg = 0; reg < LOOP_REGS; reg++) join.incoming[p][reg] = -1;
    }
    for (uint reg = 0; reg < LOOP_REGS; reg++) join.phi[reg] = -1;
    for (uint reg = 0; reg < LOOP_REGS; reg++) {
        int first = g.block_exit[block.preds[0]][reg];
        bool differ = false;
        for (uint p = 1; p < block.pred_count; p++) {
            if (g.block_exit[block.preds[p]][reg] != first) {
                differ = true;
                break;
            }
        }
        if (!differ) {
            g.current[reg] = first;
            continue;
        }
        // A register that one path never wrote has no value to merge. Such a
        // register is dead: a live one has a value before the loop, which the
        // header keeps in a phi.
        bool missing = false;
        for (uint p = 0; p < block.pred_count; p++) {
            if (g.block_exit[block.preds[p]][reg] < 0) missing = true;
        }
        if (missing) {
            g.current[reg] = -1;
            continue;
        }
        // Join representations without narrowing a predecessor. Integer and
        // double arms merge as F64; an arbitrary tagged arm keeps the join boxed.
        SsaRep rep = g.values[first].rep;
        for (uint p = 1; p < block.pred_count; p++) {
            SsaRep incoming = g.values[g.block_exit[block.preds[p]][reg]].rep;
            if (rep != incoming) rep = ssa_numeric_rep(rep) && ssa_numeric_rep(incoming) ? F64 : BOXED;
        }
        int phi = ssa_value(g, JOIN, rep, (int)index, (int)reg, 0);
        ssa_result(g, phi, (uint)reg, block.begin);
        join.phi[reg] = phi;
        for (uint p = 0; p < block.pred_count; p++) {
            int incoming = g.block_exit[block.preds[p]][reg];
            join.incoming[p][reg] = incoming;
            // The incoming value lives until the join copies it, so its range
            // reaches past the join and keeps it out of the phi's home.
            ssa_use(g, incoming);
        }
        ssa_use(g, phi);
        g.current[reg] = phi;
    }
    return true;
}

// An arm's branch: the condition it tests and the two blocks it reaches.
fn bool ssa_arm_branch(SsaGraph* g, uint b, uint pos, Instruction ins) @feat(SLJIT) {
    SsaBlock* block = &g.blocks[b];
    int lhs;
    int rhs = -1;
    long imm = 0;
    Opcode op = (Opcode)0;
    if (ins.op == Opcode.JUMP) {
        // The end of an arm: the block continues at the target.
        int value = ssa_value(g, GOTO, INT32, -1, -1, 0);
        g.values[value].block = (int)b;
        g.values[value].target = (int)block.succ0;
        g.values[value].fallto = 0;
        g.values[value].pc = pos;
        return true;
    }
    if (ins.op == Opcode.IF_TRUE || ins.op == Opcode.IF_FALSE) {
        // The truthiness of a value. An integer reads its own value; a boxed
        // one must be a boolean, whose payload is the value.
        if (ins.a >= LOOP_REGS) return false;
        lhs = g.current[ins.a];
        if (lhs < 0) return false;
        SsaRep rep = g.values[lhs].rep;
        if (rep != INT32 && rep != BOXED) return false;
        imm = ins.op == Opcode.IF_TRUE ? 1 : 0;
    } else {
        if (ins.b >= LOOP_REGS || ins.c >= LOOP_REGS) return false;
        lhs = g.current[ins.b];
        if (lhs < 0) return false;
        if (ins.op >= Opcode.JMP_NLTI) {
            imm = (long)(ichar)ins.c;
        } else {
            rhs = g.current[ins.c];
            if (rhs < 0) return false;
        }
        op = ins.op;
        // Branch operands must use one register class, just like the latch
        // comparison. A body expression can widen even when its peer is int32.
        bool integer = g.values[lhs].rep == INT32 && (rhs < 0 || g.values[rhs].rep == INT32);
        SsaRep rep = integer ? INT32 : F64;
        lhs = ssa_convert(g, lhs, rep, false);
        if (rhs >= 0) rhs = ssa_convert(g, rhs, rep, false);
    }
    int value = ssa_value(g, BRANCH, INT32, lhs, rhs, imm);
    g.values[value].block = (int)b;
    g.values[value].target = (int)block.succ1;
    g.values[value].fallto = (int)block.succ0;
    g.values[value].branch_op = op;
    g.values[value].pc = pos;
    ssa_use(g, lhs);
    if (rhs >= 0) ssa_use(g, rhs);
    return true;
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
        // A register the loop rewrites but never uses as a number holds an
        // arbitrary value, not an integer.
        g.rep[i] = ((g.plan.ssa_double | g.force_f64) & (1UL << i)) != 0 ? F64
            : g.int_reg[i] ? INT32
            : ssa_rep_for(int_need[i], f64_need[i], false);
    }
    foreach (&entry : g.conv) *entry = 0;
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
            // Recovery-only inputs can hold any value on entry. Their old
            // contents are overwritten before use, so imposing the body's
            // numeric representation here creates a spurious entry guard.
            SsaRep rep = live_in[reg] ? g.rep[reg] : BOXED;
            int phi = ssa_value(g, PHI, rep, -1, 0, 0);
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
    // The body may hold arms: a forward branch splits it into blocks, and a
    // join merges the states its arms leave behind.
    if (!ssa_split_blocks(g)) {
        g.failed = true;
        return false;
    }
    for (uint b = 0; b < g.block_count; b++) {
    g.current_block = b;
    // A conversion emitted in one arm need not execute on another arm.
    foreach (&entry : g.conv) *entry = 0;
    if (!ssa_enter_block(g, b)) {
        g.failed = true;
        return false;
    }
    g.block_first[b] = g.value_count;
    SsaBlock* block = &g.blocks[b];
    for (uint pos = block.begin; pos <= block.end; pos++) {
        Instruction ins = cf.code[pos];
        uint at         = pos - plan.begin;
        g.frames[at] = g.current;
        // Conversions can consume a bytecode operand before a later guard in
        // the same operation. Keep the original value until that operation
        // commits, so replay observes the exact pre-instruction frame.
        defer foreach (value : g.frames[at]) if (value >= 0) ssa_use(g, value);
        g.current_pc = pos;
        int target = loop_target(ins, pos);
        if (target >= 0) {
            if (pos != plan.end) {
                if (!ssa_arm_branch(g, b, pos, ins)) {
                    g.failed = true;
        return false;
                }
                continue;
            }
            if (!ssa_comparison_op(ins.op)) {
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
            case GETCAP:
            case GETVAR:
            case GETGLOBAL:
                {
                    int binding = (int)plan.binding_at[pos - plan.begin] - 1;
                    int value = ssa_value(g, BINDING, BOXED, -1, -1, binding);
                    ssa_result(g, value, ins.a, pos);
                    g.current[ins.a] = value;
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
            case CALL:
            case CALL_UNDEF_THIS:

                {
                    CompiledFunction* callee_fn = function_inline_ssa_candidate(cf, pos, g.heap);
                    if (callee_fn == null || g.current[ins.b] < 0 || ins.c > 8) {
                        g.failed = true;
        return false;
                    }
                    // The site can be rebound, so the live callee must still be
                    // the compiled body that was expanded here.
                    int callee = g.current[ins.b];
                    ssa_use(g, callee);
                    ssa_use(g, ssa_value(g, CHECKFN, BOXED, callee, -1, (long)callee_fn));
                    int[LOOP_REGS] mapped;
                    for (uint i = 0; i < LOOP_REGS; i++) mapped[i] = -1;
                    for (uint i = 0; i < ins.c; i++) {
                        int arg = g.current[ins.b + 2 + i];
                        if (arg < 0) {
                            g.failed = true;
        return false;
                        }
                        ssa_use(g, arg);
                        mapped[i] = arg;
                    }
                    int receiver = -1;
                    if (g.current[ins.b + 1] >= 0) {
                        receiver = g.current[ins.b + 1];
                        ssa_use(g, receiver);
                    }
                    int result;
                    for (uint ci_pos = 0; ci_pos < callee_fn.code_count; ci_pos++) {
                        Instruction ci = callee_fn.code[ci_pos];
                        if (ci.a >= LOOP_REGS) {
                            g.failed = true;
        return false;
                        }
                        switch (ci.op) {
                            case NOP: continue;
                            case RET: result = mapped[ci.a]; continue;
                            case LDINT:

                                {
                                    long immediate = ci.get_sbc();
                                    mapped[ci.a] = ssa_value(
                                        g,
                                        CONST_F,
                                        F64,
                                        -1,
                                        0,
                                        (long)bitcast((double)immediate, ulong)
                                    );
                                    continue;
                                }
                            case LDCONST:

                                {
                                    if (ci.get_bc() >= callee_fn.const_count) {
                                        g.failed = true;
        return false;
                                    }
                                    TVal constant = callee_fn.constants[ci.get_bc()];
                                    if (!constant.is_fastint() && !constant.is_number()) {
                                        g.failed = true;
        return false;
                                    }
                                    double number = constant.get_number_or_fastint();
                                    mapped[ci.a] = ssa_value(g, CONST_F, F64, -1, 0, (long)bitcast(number, ulong));
                                    continue;
                                }
                            case LDTHIS:
                                if (receiver < 0) {
                                    g.failed = true;
        return false;
                                }
                                mapped[ci.a] = ssa_convert(g, receiver, BOXED, false);
                                continue;
                            case LDREG:
                            case UNP:
                                if (ci.b >= LOOP_REGS || mapped[ci.b] < 0) {
                                    g.failed = true;
        return false;
                                }
                                mapped[ci.a] = mapped[ci.b];
                                continue;
                            case UNM:

                                {
                                    if (ci.b >= LOOP_REGS || mapped[ci.b] < 0) {
                                        g.failed = true;
        return false;
                                    }
                                    int operand = ssa_convert(g, mapped[ci.b], F64, false);
                                    ssa_use(g, operand);
                                    mapped[ci.a] = ssa_value(g, NEG, F64, operand, -1, 0);
                                    continue;
                                }
                            case ADD:
                            case ADD_FUSED:
                            case SUB:
                            case MUL:
                            case DIV:

                                {
                                    if (ci.b >= LOOP_REGS || ci.c >= LOOP_REGS || mapped[ci.b] < 0
                                        || mapped[ci.c] < 0) {
                                        g.failed = true;
        return false;
                                    }
                                    int left  = ssa_convert(g, mapped[ci.b], F64, false);
                                    int right = ssa_convert(g, mapped[ci.c], F64, false);
                                    ssa_use(g, left);
                                    ssa_use(g, right);
                                    SsaOp op = ci.op == Opcode.ADD || ci.op == Opcode.ADD_FUSED ? ADD
                                        : (ci.op == Opcode.SUB ? SUB : (ci.op == Opcode.MUL ? MUL : DIV));
                                    mapped[ci.a] = ssa_value(g, op, F64, left, right, 0);
                                    continue;
                                }
                            case ADDI:
                            case SUBI:
                            case MULI:

                                {
                                    if (ci.b >= LOOP_REGS || mapped[ci.b] < 0) {
                                        g.failed = true;
        return false;
                                    }
                                    int left = ssa_convert(g, mapped[ci.b], F64, false);
                                    int immediate = ssa_value(
                                        g,
                                        CONST_F,
                                        F64,
                                        -1,
                                        0,
                                        (long)bitcast((double)(ichar)ci.c, ulong)
                                    );
                                    ssa_use(g, left);
                                    ssa_use(g, immediate);
                                    SsaOp op = ci.op == Opcode.ADDI ? ADD : (ci.op == Opcode.SUBI ? SUB : MUL);
                                    mapped[ci.a] = ssa_value(g, op, F64, left, immediate, 0);
                                    continue;
                                }
                            case GETPROPC:
                            case GETPROPC_CACHED:
                            case GETTHISC:

                                {
                                    bool on_receiver = ci.op == Opcode.GETTHISC;
                                    if (!on_receiver && (ci.b >= LOOP_REGS || mapped[ci.b] < 0)) {
                                        g.failed = true;
        return false;
                                    }
                                    if (callee_fn.ic_entries == null) {
                                        g.failed = true;
        return false;
                                    }
                                    ICEntry* ic   = (ICEntry*)callee_fn.ic_entries + ci_pos;
                                    Shape* layout = g.heap.get_shape(ic.shape_id);
                                    if (layout == null || layout.generation != ic.shape_gen) {
                                        g.failed = true;
        return false;
                                    }
                                    int receiver_value = on_receiver ? ssa_convert(g, receiver, BOXED, false)
                                        : mapped[ci.b];
                                    if (receiver_value < 0) {
                                        g.failed = true;
        return false;
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
        return false;
                                    }
                                    mapped[ci.a] = ssa_value(g, LOAD, BOXED, receiver_value, -1, (long)memory);
                                    continue;
                                }
                            default:
                                g.failed = true;
        return false;
                        }
                    }
                    if (result < 0) {
                        g.failed = true;
        return false;
                    }
                    ssa_use(g, result);
                    int nv = ssa_convert(g, result, g.rep[ins.a], false);
                    ssa_result(g, nv, ins.a, pos);
                    g.current[ins.a] = nv;
                    break;
                }
            case GETPROPC:
            case GETPROPC_CACHED:
            case GETTHISC:

                {
                    uint memory = (uint)plan.memory_at[at] - 1;
                    if (memory >= plan.memory_count) {
                        g.failed = true;
        return false;
                    }
                    LoopMemorySpec spec =  plan.memory[memory];
                    int base_value      = -1;
                    if (spec.kind == SHAPE_FIELD) {
                        base_value = g.current[ins.b];
                        if (base_value < 0) {
                            g.failed = true;
        return false;
                        }
                        ssa_use(g, base_value);
                    }
                    int nv = ssa_value(g, LOAD, spec.doubles ? F64 : BOXED, base_value, -1, (long)memory);
                    ssa_result(g, nv, ins.a, pos);
                    g.current[ins.a] = nv;
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
                    SsaRep rep          = spec.doubles ? F64
                        : (spec.kind == DENSE ? BOXED : (spec.cls >= FLOAT32ARRAY ? F64 : INT32));



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
                    if (spec.doubles) {
                        // Every element is an ordinary double, so store one
                        // instead of boxing the number.
                        value = ssa_convert(g, g.current[ins.c], F64, false);
                    } else if (spec.kind == DENSE) {
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
    g.block_last[b] = g.value_count;
    for (uint reg = 0; reg < LOOP_REGS; reg++) g.block_exit[b][reg] = g.current[reg];
    }
    for (uint i = 0; i < plan.memory_count && i < LOOP_MEMORY; i++) {
        uint source = plan.memory[i].source;
        // Binding/this descriptors are invocation-local inputs, not registers.
        g.invariant[i] = source >= LOOP_REGS || !written[source];
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
        if (live_in[reg] && g.values[value].rep == F64 && g.values[g.phi[reg]].rep != F64) g.force_f64 |= 1UL << reg;
        value = ssa_convert(g, value, g.values[g.phi[reg]].rep, false);
        g.values[g.phi[reg]].a = value;
        ssa_use(g, value);
        g.values[g.phi[reg]].last = g.stamp;
    }
    // Representation conversions on backedges are executable IR too. Keep
    // them in the final block before parallel copies, and retain recovery
    // operands through any guards they emit at the backedge bytecode.
    g.block_last[g.block_count - 1] = g.value_count;
    foreach (value : g.frames[plan.end - plan.begin]) if (value >= 0) ssa_use(g, value);
    for (uint i = 0; i < g.value_count; i++) {
        if (g.values[i].op == ARG || g.values[i].op == PHI) g.values[i].last = g.stamp;
    }
    return !g.failed;
}

// Forward body edges form a DAG (the latch owns the only backedge). Reuse a
// load only if its definition dominates this use, and no possibly aliased
// store intervenes. Distinct memory descriptors do not prove disjoint objects.
fn void ssa_cse(SsaGraph* g) @feat(SLJIT) {
    for (uint b = 0; b < g.block_count; b++) {
        uint mask = b == 0 || g.blocks[b].pred_count == 0 ? 0 : uint::max;
        if (b != 0) for (uint p = 0; p < g.blocks[b].pred_count; p++) {
            mask &= g.dominators[g.blocks[b].preds[p]];
        }
        g.dominators[b] = mask | (1U << b);
    }
    uint count;
    for (uint i = 0; i < g.value_count; i++) {
        SsaValue* value = &g.values[i];
        if (value.op == LOAD) {
            int found = -1;
            for (uint k = 0; k < count; k++) {
                SsaValue prior = g.values[g.cse_value[k]];
                if (g.cse_memory[k] == (int)value.imm && g.cse_index[k] == value.a
                    && prior.rep == value.rep
                    && (g.dominators[value.block] & (1U << (uint)prior.block)) != 0) {
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
            count = 0;
        }
    }
}

// A dense element read whose only consumers are numeric conversions cannot
// carry a heap reference or a hole past them.
fn void ssa_numeric_loads(SsaGraph* g) @feat(SLJIT) {
    for (uint i = 0; i < g.value_count; i++) {
        SsaValue v = g.values[i];
        if (v.op != LOAD) continue;
        if (g.plan.memory[v.imm].kind != DENSE && g.plan.memory[v.imm].kind != FIELD
            && g.plan.memory[v.imm].kind != SHAPE_FIELD) continue;
        if (g.plan.memory[v.imm].doubles) {
            g.numeric_load[i] = true;
            continue;
        }
        bool numeric = true;
        for (uint j = 0; j < g.value_count && numeric; j++) {
            SsaValue u = g.values[j];
            if (u.a != (int)i && u.b != (int)i) continue;
            switch (u.op) {
                case TO_F64:
                case TO_INT:
                case TO_INDEX:
                case BOX_F:
                case BOX_I: break;
                default: numeric = false; break;
            }
        }
        g.numeric_load[i] = numeric;
    }
}

// Greedy home assignment over the flat definition order. Loop phis are live
// across the backedge; other values are released at their last use.
fn bool ssa_same_class(SsaRep a, SsaRep b) @feat(SLJIT) => (a == F64) == (b == F64);
fn bool ssa_same_location(SsaValue a, SsaValue b) @feat(SLJIT) {
    if (!ssa_same_class(a.rep, b.rep)) return false;
    if (a.home != 0 || b.home != 0) return a.home != 0 && a.home == b.home;
    return a.spill == b.spill;
}
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
        SsaValue* value = &g.values[i];
        value.alloc_begin = value.def;
        if (value.op != JOIN) continue;
        SsaJoin* join = &g.joins[value.a];
        // An edge writes the join before the successor's first instruction.
        // Its interval starts at the earliest incoming copy, not at the JOIN
        // node. Inclusive interference keeps every incoming source intact.
        for (uint p = 0; p < join.pred_count; p++) {
            uint last = g.block_last[join.preds[p]];
            if (last == 0) continue;
            uint edge = g.values[last - 1].def;
            if (edge < value.alloc_begin) value.alloc_begin = edge;
        }
    }
    for (uint i = 0; i < g.value_count; i++) {
        if (g.values[i].op != COPY) continue;
        int root = ssa_alias(g, (int)i);
        if (root < 0 || root == (int)i) continue;
        if (g.values[root].last < g.values[i].last) g.values[root].last = g.values[i].last;
    }
    // Loop phis live across the backedge. Ordinary joins use bounded intervals
    // and may reuse homes once an earlier join has died.
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
                if (other.alloc_begin <= value.last && value.alloc_begin <= other.last) {
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
    int base_home;
    int[2] memory_length;
    int[2] memory_base;
    // The address of the last element access, when it was computed for the
    // same memory and index value. A load and the store that follows it in
    // one iteration share it instead of recomputing base plus offset.
    int addr_memory;
    int addr_value;
    int addr_reg;
    bool addr_numeric_load;
    // The label of each block, and the jumps that reach them.
    void*[SSA_BLOCKS] block_label;
    void*[64] pending_jump;
    uint[64] pending_target;
    uint pending_count;
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
        item.regs[i] = self.g.frames[pc - self.plan.begin][i];
    }
}
fn void SsaEmitter.guard(&self, int condition, int left, long lw, int right, long rw, uint pc) @feat(SLJIT) {
    self.snapshot(self.e.cmp(condition, left, lw, right, rw), pc);
}
fn void SsaEmitter.float_guard(&self, int condition, int left, long lw, int right, long rw, uint pc) @feat(SLJIT) {
    void* jump = jit::sljit_emit_fcmp(self.e.compiler, condition, left, lw, right, rw);
    if (jump == null) { self.e.failed = true; return; }
    self.snapshot(jump, pc);
}
fn void SsaEmitter.box_gpr(&self, int reg) @feat(SLJIT) {
    self.e.op(jit::SLJIT_AND, reg, reg, 0, jit::SLJIT_IMM, 0x0000FFFFFFFFFFFF);
    self.e.op(jit::SLJIT_OR, reg, reg, 0, jit::SLJIT_IMM, (long)(types::TAG_FASTINT << 48));
}
fn void SsaEmitter.bits_fpr(&self, int freg, int dst) @feat(SLJIT) {
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_FROM_F64, freg, dst) != 0) self.e.failed = true;
    self.e.op(jit::SLJIT_LSHR, jit::reg_r(3), dst, 0, jit::SLJIT_IMM, 48);
    void* ordinary = self.e.cmp(jit::SLJIT_LESS, jit::reg_r(3), 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT);
    self.e.mov(dst, 0, jit::SLJIT_IMM, 0x7FF8000000000000L);
    self.e.bind(ordinary);
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
    self.float_guard(jit::SLJIT_UNORDERED, 1, 0, 1, 0, pc);
    self.e.mov(r1, 0, jit::SLJIT_IMM, (long)bitcast(-2147483648.0, ulong));
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r1) != 0) self.e.failed = true;
    self.float_guard(jit::SLJIT_ORDERED_LESS, 1, 0, 2, 0, pc);
    self.e.mov(r1, 0, jit::SLJIT_IMM, (long)bitcast(2147483648.0, ulong));
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r1) != 0) self.e.failed = true;
    self.float_guard(jit::SLJIT_ORDERED_GREATER_EQUAL, 1, 0, 2, 0, pc);
    self.e.op(jit::SLJIT_SHL, r3, reg, 0, jit::SLJIT_IMM, 1);
    void* nonzero = self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, jit::SLJIT_IMM, 0);
    self.guard(jit::SLJIT_SIG_LESS, reg, 0, jit::SLJIT_IMM, 0, pc);
    self.e.bind(nonzero);
    if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_SW_FROM_F64, dst, 0, 1, 0) != 0) self.e.failed = true;
    if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_F64_FROM_SW, 2, 0, dst, 0) != 0) self.e.failed = true;
    self.float_guard(jit::SLJIT_ORDERED_NOT_EQUAL, 1, 0, 2, 0, pc);
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
        if (source < LOOP_REGS) {
            self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, loop_value_offset(source));
            void* jump = self.e.cmp(jit::SLJIT_NOT_EQUAL, r0, 0,
                jit::SLJIT_MEM | self.state, loop_memory_offset(memory, 0));
            self.snapshot_none(jump, self.plan.begin);
        }
        // The descriptor of an invariant memory cannot change during the run,
        // so its data pointer and length stay in registers instead of being
        // reloaded for every element access.
        if (memory < 2) {
            self.memory_length[memory] = jit::reg_s(5 + (int)memory * 2);
            self.memory_base[memory] = jit::reg_s(6 + (int)memory * 2);
            self.e.mov(self.memory_length[memory], 0, jit::SLJIT_MEM | self.state, loop_memory_offset(memory, 2));
            self.e.mov(self.memory_base[memory], 0, jit::SLJIT_MEM | self.state, loop_memory_offset(memory, 1));
            if (memory == 0) {
                self.length_home = self.memory_length[0];
                self.base_home = self.memory_base[0];
            }
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
    TemplateEmitter* e = &self.e;
    self.addr_reg = 0;
    for (uint b = 0; b < self.g.block_count; b++) {
        self.addr_reg = 0;
        self.live = self.g.frames[self.g.blocks[b].begin - self.plan.begin];
        self.block_label[b] = e.label();
        uint first = self.g.block_first[b];
        uint last  = self.g.block_last[b];
        for (uint i = first; i < last; i++) {
        SsaValue v = self.g.values[i];
        self.at_def = v.def;
        self.pc = v.pc;
        if (v.op != LOAD && v.op != STORE) self.addr_reg = 0;
        switch (v.op) {
            case ARG:
            case PHI: break;
            case BINDING:
                {
                    // loop_prepare snapshots bindings before entering native code.
                    LoopState layout;
                    long offset = (char*)&layout.bindings[(uint)v.imm] - (char*)&layout;
                    self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, offset);
                    self.store_gpr((int)i, r0);
                    break;
                }
            case COPY:

                {
                    SsaValue from = self.g.values[v.a];
                    if (v.home != 0 && from.home == v.home) break;
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
                        if (v.op == MUL) self.e.op(jit::SLJIT_OR, r3, left, 0, right, rightw);
                        self.e.op(
                            v.op == SUB ? jit::SLJIT_SUB : v.op == MUL ? jit::SLJIT_MUL : jit::SLJIT_ADD,
                            dst,
                            left,
                            0,
                            right,
                            rightw
                        );
                        if (v.op == MUL) {
                            void* nonzero = self.e.cmp(jit::SLJIT_NOT_EQUAL, dst, 0, imm, 0);
                            self.guard(jit::SLJIT_SIG_LESS, r3, 0, imm, 0, self.pc);
                            self.e.bind(nonzero);
                        }
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
                    if (v.op == USHR) self.guard(jit::SLJIT_GREATER, dst, 0, imm, 2147483647L, self.pc);
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
            case CHECKFN:

                {
                    int rr0      = jit::reg_r(0);
                    int rr1      = jit::reg_r(1);
                    int rr3      = jit::reg_r(3);
                    int imm2     = jit::SLJIT_IMM;
                    HObject object;
                    HObjectExtra extra;
                    long address = (char*)&object.extra - (char*)&object
                        + ((char*)&extra.func.comp_func - (char*)&extra);
                    self.gpr(v.a, rr0);
                    self.e.op(jit::SLJIT_LSHR, rr3, rr0, 0, imm2, 48);
                    self.guard(jit::SLJIT_NOT_EQUAL, rr3, 0, imm2, (long)types::TAG_OBJECT, self.pc);
                    self.e.op(jit::SLJIT_AND, rr0, rr0, 0, imm2, (long)types::NANBOX_PAYLOAD_MASK);
                    self.guard(jit::SLJIT_EQUAL, rr0, 0, imm2, 0, self.pc);
                    self.e.mov(rr1, 0, jit::SLJIT_MEM | rr0, address);
                    self.guard(jit::SLJIT_NOT_EQUAL, rr1, 0, imm2, v.imm, self.pc);
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
            case JOIN: break;
            case BRANCH: self.branch((int)i); break;
            case GOTO: self.goto_block((int)i); break;
        }
        if (v.dst_reg >= 0) self.live[v.dst_reg] = (int)i;
        }
        // A block without a branch hands its state to the block that follows
        // it, so the join's values are written on that path too.
        if (self.g.blocks[b].branch_pc == 0 && b + 1 < self.g.block_count) {
            self.join_copies(b, b + 1);
        }
    }
}

// Copy the values a join merges into the phi's home. Each predecessor
// writes the home before it arrives, so the path that reaches the join
// carries its own value.
fn void SsaEmitter.join_copies(&self, uint block, uint succ) @feat(SLJIT) {
    if (succ >= self.g.block_count) return;
    TemplateEmitter* e = &self.e;
    int r0 = jit::reg_r(0);
    for (uint j = 0; j < self.g.join_count; j++) {
        SsaJoin* join = &self.g.joins[j];
        if (join.block != succ) continue;
        for (uint p = 0; p < join.pred_count; p++) {
            if (join.preds[p] != block) continue;
            for (uint reg = 0; reg < LOOP_REGS; reg++) {
                int phi = join.phi[reg];
                if (phi < 0) continue;
                int incoming = join.incoming[p][reg];
                if (incoming < 0) continue;
                SsaValue pv = self.g.values[phi];
                SsaValue sv = self.g.values[incoming];
                // The merged values may differ in representation, so the copy
                // converts the incoming value to the phi's.
                if (pv.rep == F64) {
                    if (sv.rep == F64) {
                        if (sv.home != 0 && pv.home != 0) {
                            if (jit::sljit_emit_fop1(
                                e.compiler,
                                jit::SLJIT_MOV_F64,
                                pv.home,
                                0,
                                sv.home,
                                0
                            ) != 0) e.failed = true;
                        } else {
                            self.load_fpr(incoming, 1);
                            self.store_fpr(phi, 1);
                        }
                    } else {
                        int dst = pv.home != 0 ? pv.home : 1;
                        if (sv.rep == INT32) {
                            int src = self.gpr_slot(incoming, r0);
                            if (jit::sljit_emit_fop1(
                                e.compiler,
                                jit::SLJIT_CONV_F64_FROM_SW,
                                dst,
                                0,
                                src,
                                0
                            ) != 0) e.failed = true;
                        } else {
                            self.gpr(incoming, r0);
                            self.number(r0, dst, self.pc);
                        }
                        if (pv.home == 0) self.store_fpr(phi, dst);
                    }
                } else if (pv.rep == BOXED) {
                    if (sv.rep == BOXED) {
                        if (sv.home != 0 && pv.home != 0) {
                            e.mov(pv.home, 0, sv.home, 0);
                        } else {
                            self.gpr(incoming, r0);
                            self.store_gpr(phi, r0);
                        }
                    } else if (sv.rep == INT32) {
                        int dst = pv.home != 0 ? pv.home : r0;
                        self.gpr(incoming, r0);
                        self.box_gpr(r0);
                        if (dst != r0) e.mov(dst, 0, r0, 0);
                        if (pv.home == 0) self.store_gpr(phi, dst);
                    } else {
                        int src = self.fpr_slot(incoming, 1);
                        int dst = pv.home != 0 ? pv.home : r0;
                        self.bits_fpr(src, dst);
                        if (pv.home == 0) self.store_gpr(phi, dst);
                    }
                } else {
                    if (sv.rep == INT32) {
                        if (sv.home != 0 && pv.home != 0) {
                            e.mov(pv.home, 0, sv.home, 0);
                        } else {
                            self.gpr(incoming, r0);
                            self.store_gpr(phi, r0);
                        }
                    } else {
                        int dst = pv.home != 0 ? pv.home : r0;
                        if (sv.rep == F64) {
                            self.load_fpr(incoming, 1);
                            self.trunc_int_f64(1, dst, self.pc);
                        } else {
                            self.gpr(incoming, r0);
                            self.exact_int(r0, dst, self.pc);
                        }
                        if (pv.home == 0) self.store_gpr(phi, dst);
                    }
                }
            }
        }
    }
}

// An arm's branch: the condition decides which block the loop continues in.
fn void SsaEmitter.branch(&self, int value) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    TemplateEmitter* e = &self.e;
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2);
    int r3 = jit::reg_r(3);
    int imm = jit::SLJIT_IMM;
    void* taken;
    if ((int)v.branch_op == 0) {
        // The truthiness of the condition's value.
        if (self.g.values[v.a].rep == INT32) {
            int src = self.gpr_slot(v.a, r0);
            e.op(jit::SLJIT_SUB, r1, src, 0, imm, 0);
            taken = e.cmp(v.imm != 0 ? jit::SLJIT_NOT_EQUAL : jit::SLJIT_EQUAL, r1, 0, imm, 0);
        } else {
            // A boxed boolean carries its value in the payload.
            self.gpr(v.a, r0);
            e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
            self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_BOOLEAN, self.pc);
            e.op(jit::SLJIT_AND, r1, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
            taken = e.cmp(v.imm != 0 ? jit::SLJIT_NOT_EQUAL : jit::SLJIT_EQUAL, r1, 0, imm, 0);
        }
    } else {
        SsaValue lhs = self.g.values[v.a];
        if (lhs.rep == INT32) {
            int left = self.gpr_slot(v.a, r0);
            int right;
            if (v.b >= 0) {
                right = self.gpr_slot(v.b, r1);
            } else {
                e.mov(r1, 0, imm, v.imm);
                right = r1;
            }
            taken = e.cmp(loop_condition(v.branch_op), left, 0, right, 0);
        } else {
            self.load_fpr(v.a, 1);
            if (v.b >= 0) {
                self.load_fpr(v.b, 2);
            } else {
                e.mov(r0, 0, imm, (long)bitcast((double)v.imm, ulong));
                if (jit::sljit_emit_fcopy(e.compiler, jit::SLJIT_COPY_TO_F64, 2, r0) != 0) e.failed = true;
            }
            taken = jit::sljit_emit_fcmp(e.compiler, loop_float_condition(v.branch_op), 1, 0, 2, 0);
        }
    }
    if (taken == null) {
        e.failed = true;
        return;
    }
    // The arm that falls through, then the arm the branch takes.
    self.join_copies((uint)v.block, (uint)v.fallto);
    void* fall = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(taken);
    self.join_copies((uint)v.block, (uint)v.target);
    void* target = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    if (self.pending_count + 2 > (uint)self.pending_jump.len) {
        e.failed = true;
        return;
    }
    self.pending_jump[self.pending_count] = fall;
    self.pending_target[self.pending_count] = (uint)v.fallto;
    self.pending_count++;
    self.pending_jump[self.pending_count] = target;
    self.pending_target[self.pending_count] = (uint)v.target;
    self.pending_count++;
}

// The end of an arm: the block continues at the block the jump names.
fn void SsaEmitter.goto_block(&self, int value) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    self.join_copies((uint)v.block, (uint)v.target);
    void* jump = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
    if (jump == null || self.pending_count + 1 > (uint)self.pending_jump.len) {
        self.e.failed = true;
        return;
    }
    self.pending_jump[self.pending_count] = jump;
    self.pending_target[self.pending_count] = (uint)v.target;
    self.pending_count++;
}

// Bind the jumps that reach a block to the label it starts at.
fn void SsaEmitter.resolve_blocks(&self) @feat(SLJIT) {
    for (uint i = 0; i < self.pending_count; i++) {
        uint target = self.pending_target[i];
        if (target >= self.g.block_count) {
            self.e.failed = true;
            continue;
        }
        void* label = self.block_label[target];
        if (label == null) {
            self.e.failed = true;
            continue;
        }
        jit::sljit_set_label(self.pending_jump[i], label);
    }
}

fn void SsaEmitter.exact_int_f64(&self, int freg, int dst, uint pc) @feat(SLJIT) {
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    self.float_guard(jit::SLJIT_UNORDERED, freg, 0, freg, 0, pc);
    self.e.mov(r1, 0, jit::SLJIT_IMM, (long)bitcast(-2147483648.0, ulong));
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r1) != 0) self.e.failed = true;
    self.float_guard(jit::SLJIT_ORDERED_LESS, freg, 0, 2, 0, pc);
    self.e.mov(r1, 0, jit::SLJIT_IMM, (long)bitcast(2147483648.0, ulong));
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r1) != 0) self.e.failed = true;
    self.float_guard(jit::SLJIT_ORDERED_GREATER_EQUAL, freg, 0, 2, 0, pc);
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
    int r1  = jit::reg_r(1);
    int r2  = jit::reg_r(2);
    // Separate bytecode loads of one index become different copies of it; the
    // allocator coalesces them, so compare the copy chains' common root.
    int key = ssa_alias(self.g, value);
    if (self.addr_reg != 0 && self.addr_memory == (int)memory && self.addr_value == key) {
        // r2 still holds this address: nothing emitted between two accesses
        // through one index value writes it.
        return;
    }
    self.addr_memory = (int)memory;
    self.addr_value = key;
    self.addr_reg = r2;
    self.addr_numeric_load = false;
    self.gpr(value, r1);
    // The first memory keeps its length in a saved register for the whole
    // loop, so bounds checks are a register comparison.
    if (memory < 2 && self.memory_length[memory] != 0) {
        self.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, self.memory_length[memory], 0, pc);
    } else {
        self.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, jit::SLJIT_MEM | self.state, loop_memory_offset(memory, 2), pc);
    }
    uint shift = self.plan.memory[memory].kind == DENSE ? 3 : builtins::ta_elem_shift(self.plan.memory[memory].cls);
    if (shift != 0) self.e.op(jit::SLJIT_SHL, r1, r1, 0, jit::SLJIT_IMM, shift);
    if (memory < 2 && self.memory_base[memory] != 0) {
        self.e.op(jit::SLJIT_ADD, r2, self.memory_base[memory], 0, r1, 0);
    } else {
        self.e.mov(r2, 0, jit::SLJIT_MEM | self.state, loop_memory_offset(memory, 1));
        self.e.op(jit::SLJIT_ADD, r2, r2, 0, r1, 0);
    }
}
fn void SsaEmitter.load(&self, uint memory, int index, int dst_value, SsaRep rep) @feat(SLJIT) {
    LoopMemorySpec spec = self.plan.memory[memory];
    uint pc             = self.pc;
    if (spec.kind == SHAPE_FIELD) {
        int r0  = jit::reg_r(0);
        int r1  = jit::reg_r(1);
        int r2  = jit::reg_r(2);
        int r3  = jit::reg_r(3);
        int imm = jit::SLJIT_IMM;
        self.gpr(index, r0);
        self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
        self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
        self.e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
        self.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, pc);
        HObject obj;
        long shape_offset = (char*)&obj.shape_id - (char*)&obj;
        long alloc_offset = (char*)&obj.prop_alloc - (char*)&obj;
        self.e.mov(r2, 0, jit::SLJIT_MEM | r0, shape_offset, jit::SLJIT_MOV_U32);
        self.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (long)spec.shape, pc);
        self.e.mov(r1, 0, jit::SLJIT_MEM | r0, alloc_offset);
        void* allocated = self.e.cmp(jit::SLJIT_NOT_EQUAL, r1, 0, imm, 0);
        self.e.op(jit::SLJIT_ADD, r1, r0, 0, imm, HObjectBase::size);
        self.e.bind(allocated);
        self.e.mov(r0, 0, jit::SLJIT_MEM | r1, (long)spec.slot * 8);
        if (spec.doubles) {
            int dst = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : 1;
            self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
            self.guard(jit::SLJIT_GREATER_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT, pc);
            if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, dst, r0) != 0) self.e.failed = true;
            if (self.g.values[dst_value].home == 0) self.store_fpr(dst_value, dst);
            self.addr_numeric_load = true;
        } else {
            int dst = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : r0;
            if (dst != r0) self.e.mov(dst, 0, r0, 0);
            if (self.g.values[dst_value].home == 0) self.store_gpr(dst_value, dst);
        }
        return;
    }
    if (spec.kind == FIELD) {
        int r1 = jit::reg_r(1);
        int r0 = jit::reg_r(0);
        int r3 = jit::reg_r(3);
        self.e.mov(r1, 0, jit::SLJIT_MEM | self.state, loop_memory_offset(memory, 1));
        if (spec.doubles) {
            int dst = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : 1;
            self.e.mov(r0, 0, jit::SLJIT_MEM | r1, 0);
            self.e.op(jit::SLJIT_LSHR, r3, r0, 0, jit::SLJIT_IMM, 48);
            self.guard(jit::SLJIT_GREATER_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
            if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, dst, r0) != 0) self.e.failed = true;
            if (self.g.values[dst_value].home == 0) self.store_fpr(dst_value, dst);
        } else {
            int dst = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : r0;
            self.e.mov(dst, 0, jit::SLJIT_MEM | r1, 0);
            if (self.g.values[dst_value].home == 0) self.store_gpr(dst_value, dst);
        }
        return;
    }
    self.memory_guard(spec.source, memory, pc);
    self.index(index, memory, pc);
    int r0 = jit::reg_r(0);
    int r2 = jit::reg_r(2);
    int r3 = jit::reg_r(3);
    if (spec.doubles) {
        // Fastest element read: an ordinary double is already its own bits, so
        // one guard replaces the tag test, the representation branch and the
        // conversion. Anything else exits and the interpreter reruns the loop.
        int dst = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : 1;
        self.e.mov(r0, 0, jit::SLJIT_MEM | r2, 0);
        self.e.op(jit::SLJIT_LSHR, r3, r0, 0, jit::SLJIT_IMM, 48);
        self.guard(jit::SLJIT_GREATER_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
        if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, dst, r0) != 0) self.e.failed = true;
        if (self.g.values[dst_value].home == 0) self.store_fpr(dst_value, dst);
        self.addr_numeric_load = true;
    } else if (spec.kind == DENSE) {
        int dst = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : r0;
        self.e.mov(dst, 0, jit::SLJIT_MEM | r2, 0);
        if (self.g.numeric_load[dst_value]) {
            // Every consumer rejects a non-number, which also covers a hole,
            // and the stored value can then never hold a heap reference.
            self.e.op(jit::SLJIT_LSHR, r3, dst, 0, jit::SLJIT_IMM, 48);
            self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
            self.addr_numeric_load = true;
        } else if (rep == BOXED) {
            self.e.op(jit::SLJIT_LSHR, r3, dst, 0, jit::SLJIT_IMM, 48);
            self.guard(jit::SLJIT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_UNDEFINED, pc);
        }
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
        int live = ssa_alias(self.g, self.live[reg]);
        if (live >= 0 && self.g.values[live].rep == BOXED && self.g.values[live].op == LOAD
            && self.g.values[live].last >= self.at_def) {
            // Dense numeric loads guard their tag at the read itself, so no
            // borrowed heap reference survives the write. Other boxed loads
            // still need the fallback, including aliases introduced by CSE.
            uint source = (uint)self.g.values[live].imm;
            if (self.plan.memory[source].kind != DENSE || !self.g.numeric_load[live]) self.e.failed = true;
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
    if (spec.doubles) {
        // The element being replaced must also be numeric: checking
        // that is both the reference-release test and the invariant guard. An
        // earlier numeric read of this exact slot already proved it.
        if (!self.addr_numeric_load) {
            self.e.mov(r0, 0, jit::SLJIT_MEM | r2, 0);
            self.e.op(jit::SLJIT_LSHR, r3, r0, 0, jit::SLJIT_IMM, 48);
            self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
        }
        self.load_fpr(value, 1);
        self.bits_fpr(1, r0);
        self.e.mov(jit::SLJIT_MEM | r2, 0, r0, 0);
        return;
    }
    if (spec.kind == DENSE) {
        // A numeric read of this exact slot earlier in the iteration already
        // proved the stored value holds no reference to release.
        if (!(self.addr_reg != 0 && self.addr_numeric_load && self.addr_memory == (int)memory)) {
            self.e.mov(r0, 0, jit::SLJIT_MEM | r2, 0);
            self.e.op(jit::SLJIT_LSHR, r3, r0, 0, jit::SLJIT_IMM, 48);
            self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
        }
        self.gpr(value, r0);
        // BOX_I and BOX_F produce a fastint or an ordinary double, so the
        // stored value needs no tag check.
        if (src.op != BOX_I && src.op != BOX_F) {
            self.e.op(jit::SLJIT_LSHR, r3, r0, 0, jit::SLJIT_IMM, 48);
            self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
        }
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
    void*[SSA_EXITS] labels;
    for (uint i = 0; i < self.g.exit_count; i++) {
        SsaExit* item = &self.g.exits[i];
        // Several guards in one bytecode recover the same frame from fixed
        // SSA homes. Share their materialization and return sequence; matching
        // only the PC would be insufficient for header versus body exits.
        for (uint prior = 0; prior < i; prior++) {
            SsaExit* candidate = &self.g.exits[prior];
            if (candidate.pc != item.pc) continue;
            bool same = true;
            for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
                if (candidate.regs[reg] != item.regs[reg]) { same = false; break; }
            }
            if (same) { labels[i] = labels[prior]; break; }
        }
        if (labels[i] != null) {
            jit::sljit_set_label(item.jump, labels[i]);
            continue;
        }
        labels[i] = self.e.label();
        jit::sljit_set_label(item.jump, labels[i]);
        self.publish(&item.regs, item.pc);
    }
}
fn void SsaEmitter.latch(&self) @feat(SLJIT) {
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    // A postfix comparison may still read a header value whose home the phi
    // copies replace (while (count-- > 0)). Save the predicate before copies.
    bool[2] saved_predicate;
    uint predicate = self.g.spill_count;
    foreach (phi : self.g.phi) if (phi >= 0) predicate++;
    for (uint operand = 0; operand < 2; operand++) {
        int value = operand == 0 ? self.g.cmp_lhs : self.g.cmp_rhs;
        if (value < 0) continue;
        foreach (phi : self.g.phi) {
            if (phi < 0) continue;
            SsaValue dest = self.g.values[phi];
            if (ssa_same_location(dest, self.g.values[value])
                && !ssa_same_location(dest, self.g.values[dest.a])) saved_predicate[operand] = true;
        }
        if (!saved_predicate[operand]) continue;
        if (self.g.values[value].rep == F64) { self.load_fpr(value, 1); self.bits_fpr(1, r0); }
        else { self.gpr(value, r0); }
        self.e.mov(jit::SLJIT_MEM | self.state, ssa_spill_offset(predicate + operand), r0, 0);
    }
    // Parallel copies include spill slots as well as register homes. A spill
    // is not a temporary: another pending phi may still need its old value.
    bool[LOOP_REGS] pending;
    uint remaining;
    for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
        int phi = self.g.phi[reg];
        if (phi < 0) continue;
        if (ssa_same_location(self.g.values[phi], self.g.values[self.g.values[phi].a])) continue;
        pending[reg] = true;
        remaining++;
    }
    while (remaining > 0) {
        bool progress;
        for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
            if (!pending[reg]) continue;
            int phi = self.g.phi[reg];
            SsaValue dest = self.g.values[phi];
            bool blocked;
            for (uint other = 0; other < self.cf.num_regs && other < LOOP_REGS; other++) {
                if (!pending[other] || other == reg) continue;
                int source = self.g.values[self.g.phi[other]].a;
                if (ssa_same_location(dest, self.g.values[source])) { blocked = true; break; }
            }
            if (blocked) continue;
            int source = dest.a;
            SsaValue src = self.g.values[source];
            if (dest.home != 0 && src.home != 0) {
                if (dest.rep == F64) {
                    if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_MOV_F64,
                        dest.home, 0, src.home, 0) != 0) self.e.failed = true;
                } else { self.e.mov(dest.home, 0, src.home, 0); }
            } else if (dest.rep == F64) { self.load_fpr(source, 1); self.store_fpr(phi, 1); }
            else { self.gpr(source, r0); self.store_gpr(phi, r0); }
            pending[reg] = false;
            remaining--;
            progress = true;
        }
        if (!progress) break;
    }
    // Break all remaining cycles before mutating any destination.
    uint temp = self.g.spill_count;
    for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
        if (!pending[reg]) continue;
        int source = self.g.values[self.g.phi[reg]].a;
        if (self.g.values[source].rep == F64) {
            self.load_fpr(source, 1); self.bits_fpr(1, r0);
        } else { self.gpr(source, r0); }
        self.e.mov(jit::SLJIT_MEM | self.state, ssa_spill_offset(temp++), r0, 0);
    }
    temp = self.g.spill_count;
    for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
        if (!pending[reg]) continue;
        int phi = self.g.phi[reg];
        self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, ssa_spill_offset(temp++));
        if (self.g.values[phi].rep == F64) {
            if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 1, r0) != 0) self.e.failed = true;
            self.store_fpr(phi, 1);
        } else { self.store_gpr(phi, r0); }
    }
    // A failed budget polls the interpreter at the backedge; post-body values
    // are published, not the edge copies.
    self.at_def = self.g.stamp;
    self.snapshot_phis(self.e.cmp(jit::SLJIT_LESS_EQUAL, self.budget, 0, jit::SLJIT_IMM, 1), self.plan.end);
    self.e.op(jit::SLJIT_SUB, self.budget, self.budget, 0, jit::SLJIT_IMM, 1);
    int r2       = jit::reg_r(2);
    SsaValue lhs = self.g.values[self.g.cmp_lhs];
    if (lhs.rep == INT32) {
        int left = r0;
        if (saved_predicate[0]) { self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, ssa_spill_offset(predicate)); }
        else { left = self.gpr_slot(self.g.cmp_lhs, r0); }
        int right;
        if (self.g.cmp_rhs >= 0) {
            if (saved_predicate[1]) {
                self.e.mov(r1, 0, jit::SLJIT_MEM | self.state, ssa_spill_offset(predicate + 1));
                right = r1;
            } else { right = self.gpr_slot(self.g.cmp_rhs, r1); }
        } else {
            self.e.mov(r1, 0, jit::SLJIT_IMM, self.g.cmp_imm);
            right = r1;
        }
        void* taken = self.e.cmp(loop_condition(self.g.cmp_op), left, 0, right, 0);
        if (taken == null) {
            self.e.failed = true;
        } else {
            jit::sljit_set_label(taken, self.header);
        }
    } else {
        if (saved_predicate[0]) {
            self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, ssa_spill_offset(predicate));
            if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 1, r0) != 0) self.e.failed = true;
        } else { self.load_fpr(self.g.cmp_lhs, 1); }
        if (self.g.cmp_rhs >= 0) {
            if (saved_predicate[1]) {
                self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, ssa_spill_offset(predicate + 1));
                if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r0) != 0) self.e.failed = true;
            } else { self.load_fpr(self.g.cmp_rhs, 2); }
        } else {
            self.e.mov(r0, 0, jit::SLJIT_IMM, (long)bitcast((double)self.g.cmp_imm, ulong));
            if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r0) != 0) self.e.failed = true;
        }
        void* taken        = jit::sljit_emit_fcmp(self.e.compiler, loop_float_condition(self.g.cmp_op), 1, 0, 2, 0);
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
    graph.heap = h;
    if (!ssa_build(graph)) return null;
    // A register can gain a double representation only after its definitions
    // are built, so rebuild the graph when the first pass asks for one.
    for (uint round = 0; round < 3 && graph.force_f64 != 0; round++) {
        ulong forced = graph.force_f64;
        mem::clear(graph, (sz)SsaGraph::size);
        graph.plan = plan;
        graph.cf = cf;
        graph.heap = h;
        graph.force_f64 |= forced;
        if (!ssa_build(graph)) return null;
        if (graph.force_f64 == forced) break;
    }
    ssa_cse(graph);
    ssa_numeric_loads(graph);
    ssa_allocate(graph);
    uint phi_count;
    for (uint reg = 0; reg < cf.num_regs && reg < LOOP_REGS; reg++) if (graph.phi[reg] >= 0) phi_count++;
    if (graph.spill_count + phi_count + 2 > SSA_MAX_SPILL) return null;
    SsaEmitter self    = { .g = graph, .plan = plan, .cf = cf };
    TemplateEmitter* e = &self.e;
    e.compiler = jit::sljit_create_compiler(null);
    if (e.compiler == null) return null;
    defer jit::sljit_free_compiler(e.compiler);
    if (jit::sljit_emit_enter(e.compiler, 0, jit::SLJIT_ARGS2WWW_R, 8 | (10 << 8), 9, 0) != 0) return null;
    int r0 = jit::reg_r(0);
    self.state = jit::reg_s(0);
    self.budget = jit::reg_s(1);
    self.dirty = jit::reg_s(2);
    self.at_def = 0;
    for (uint i = 0; i < LOOP_REGS; i++) self.live[i] = graph.header[i];
    e.mov(self.state, 0, r0, 0);
    e.mov(self.budget, 0, jit::reg_r(1), 0);
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
    self.resolve_blocks();
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

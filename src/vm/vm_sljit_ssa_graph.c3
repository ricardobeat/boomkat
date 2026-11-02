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

// Bytecode analysis and SSA graph construction.

// Shared SSA for numeric loops and single-pass function regions. Bytecode
// registers become SSA values; loops add header phis. Representations are
// selected from uses, and exits reconstruct the interpreter's register slots.
// Unsupported loops fall back to the straight-line loop emitter.
// Keep an opt-out for differential measurements of the straight-line tier.
const ulong SSA_REFUSED = types::TAG_POISON << 48;
const uint SSA_ENTRY_BAIL = uint::max;
const bool SSA_ENABLED    = !$feat(SLJIT_NO_SSA);
// General cyclic graphs compile a whole function body, including backedges.
// Disable at build time to compare against the straight-line tier.
const bool SSA_CYCLIC     = !$feat(SLJIT_NO_SSA_CYCLIC);
// A loop region may compile its nested loops as one cyclic graph. That measured
// slower before whole-function cyclic SSA existed; with it, Navier-Stokes drops
// about 9% in paired mini runs and the rest of the panel is unchanged.
const bool SSA_CYCLIC_REGIONS = true;
const uint SSA_MAX_SPILL  = 128;
const uint SSA_HOMES      = 8;
const uint SSA_CSE        = 64;

enum SsaRep : char {
    BOXED,
    INT32,
    F64,
    RAW
}

enum SsaOp : char {
    NOP,
    ARG,
    RECEIVER,
    STORAGE,
    PROTO_STORAGE,
    PHI,
    BINDING,
    FRESH_BINDING,
    CONST_I,
    CONST_F,
    // A boxed constant: null, undefined or a boolean. The payload holds the
    // NaN-boxed bits.
    CONST_BOXED,
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
    // Scalable accesses use SSA receivers and indices, never LoopMemory slots.
    ACCESS_ADDRESS,
    ACCESS_FIELD,
    ACCESS_LOAD,
    ACCESS_STORE,
    // Identity guard: the value must be a function whose compiled body is the
    // one the call was expanded from.
    CHECKFN,
    CHECKPROTO,
    CHECKSHAPE,
    CHECKWRITE,
    COMPARE,
    SELECT,
    // A value merged from several arms at a join. Its home holds whichever
    // incoming value the path took.
    JOIN,
    // A conditional branch inside the body: the arms of an if.
    BRANCH,
    // An unconditional branch inside the body: the end of an arm.
    GOTO,
    RETURN,
    // Publish the pre-bytecode frame and resume that unperformed operation.
    EXIT,
    // A published-frame, collecting/reentrant operation with an internal
    // native successor. Unlike EXIT, its effect runs before native resumes.
    HELPER
}

fn bool ssa_has_result(SsaOp op) @feat(SLJIT) {
    switch (op) {
        case NOP: case STORE: case ACCESS_STORE: case CHECKFN: case CHECKPROTO: case CHECKSHAPE: case CHECKWRITE: case BRANCH: case GOTO: case RETURN: case EXIT: return false;
        default: return true;
    }
}

struct SsaValue @feat(SLJIT) {
    SsaHelperSite* helper;
    SsaFieldAccess* field_access;
    SsaBindingSite* binding_site;
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
    bool watched_method;
    uint proof_bits;
    // A branch names the block it leaves and the block its other arm takes.
    int block;
    int target;
    int fallto;
    CompiledFunction* inline_target;
    SsaFrameId before_frame;
    SsaFrameId after_frame;
    int schedule_prev;
    int schedule_next;
    int schedule_block;
    Opcode branch_op;
}

// One basic block of the loop body. The blocks partition the body in
// bytecode order, so a block's fall-through successor is the next one.
struct SsaBlock @feat(SLJIT) {
    SsaEdgeState edge_state;
    bool edge_ready;
    uint begin;
    uint end;
    uint succ0;
    uint succ1;
    uint pred_count;
    uint* preds;
    uint branch_pc; // uint::max when the block has no branch
    bool conditional;
    bool jump;
    bool returns;
    bool external;
    bool synthetic; // import/preheader: no bytecode executes here
    bool preheader;
    uint loop_header;
    int first_value;
    int last_value;
}

// A block with more than one predecessor: the registers its predecessors
// disagree about are merged here.
struct SsaJoin @feat(SLJIT) {
    uint block;
    uint pred_count;
    uint* preds;
    int* phi;
    int** incoming;
    // A loop header at the body's entry has no bytecode predecessor for its
    // forward edge. The entry state plays that role and is copied before the
    // header label.
    bool entry;
    int* entry_incoming;
}

struct SsaExit @feat(SLJIT) {
    void* jump;
    uint pc;
    SsaFrameId frame;
}

// Reserve R0..R3 for emission and S0/S1 for state and budget. Homes and
// optional descriptor caches must fit the target's actual register file.
struct SsaRegisterBudget @feat(SLJIT) {
    uint scratches;
    uint saveds;
    uint scratch_homes;
    uint saved_homes;
    uint saved_first;
}
fn SsaRegisterBudget ssa_register_budget(bool direct = false) @feat(SLJIT) {
    uint saveds = (uint)jit::sljit_shim_info(1);
    uint limit = direct ? 6 : 9;
    if (saveds > limit) saveds = limit;
    uint scratches = (uint)jit::sljit_shim_info(0) - saveds;
    if (scratches > 8) scratches = 8;
    uint scratch_homes = scratches > 4 ? scratches - 4 : 0;
    uint first = direct ? 3 : 2;
    uint saved_homes = direct ? 2 : saveds > first ? saveds - first : 0;
    if (saved_homes > 3) saved_homes = 3;
    return { scratches, saveds, scratch_homes, saved_homes, first };
}

struct SsaGraph @feat(SLJIT) {
    LoopPlan* plan;
    CompiledFunction* cf;
    Heap* heap;
    SsaBudget budget;
    compiler::DecodedCfg decoded;
    SsaStorageChunk* storage;
    usz storage_bytes;
    usz persistent_bytes;
    ulong work;
    SsaFrame* frame_table;
    uint frame_count;
    uint frame_capacity;
    SsaFrameEntry* recovery_entries;
    uint recovery_count;
    uint recovery_capacity;
    SsaDeoptHome* deopt_homes;
    uint deopt_home_count;
    SsaDeoptFrame** deopt_frames;
    SsaSafepoint* safepoints;
    uint safepoint_count;
    uint safepoint_capacity;
    SsaValue failed_value; // safe sink for builders unwinding an admission/allocation failure
    SsaValue* values;
    uint value_capacity;
    int* conv;
    uint value_count;
    uint reg_count;
    uint reg_words;
    uint stamp;
    uint current_pc;
    uint current_block;
    uint spill_count;
    bool failed;
    bool schedule_ready;
    bool single_pass;
    bool cyclic;
    compiler::RegSet* cyclic_live;
    uint* cyclic_order;
    bool* block_built;
    bool direct;
    bool inplace;
    bool direct_fields;
    bool callee_entry;
    bool recoverable;
    uint inline_base;
    uint inline_depth;
    uint fpr_homes;
    uint result_reg;
    SsaRegisterBudget registers;
    int* current;
    int* header;
    // Interpreter state before each bytecode, including values whose only
    // remaining use is recovery after a guard. IR-use liveness is insufficient.
    SsaFrameId* frames;
    // Registers semantically observable when recovery resumes this bytecode.
    // Only recoverable whole-function graphs populate these canonical masks.
    compiler::RegSet* recovery_live;
    int* phi;
    int* arg;
    SsaRep* rep;
    bool* int_reg;
    int cmp_lhs;
    int cmp_rhs;
    long cmp_imm;
    Opcode cmp_op;
    SsaExit* exits;
    uint exit_capacity;
    uint exit_count;
    // Memories whose source register is not written by the loop keep the same
    // descriptor for the whole run, so their guards can be checked once.
    bool[LOOP_MEMORY] invariant;
    // Element reads whose every consumer converts to a number: the tag guard
    // that rejects a non-number also rules out a hole, so the store that
    // follows such a read into the same slot needs no second check.
    bool* numeric_load;
    // Registers whose loop-carried value arrives as an exact double: keeping
    // them in the wider representation removes an exact conversion from every
    // backedge and lets the loop test compare doubles directly.
    compiler::RegSet force_f64;
    int[SSA_CSE] cse_memory;
    int[SSA_CSE] cse_index;
    int[SSA_CSE] cse_value;
    // The body's block graph and the joins between its arms.
    SsaBlock* blocks;
    uint block_capacity;
    uint block_count;
    uint* dominators;
    uint dominator_words;
    SsaJoin* joins;
    uint join_count;
    // The register state at the end of each block.
    SsaFrameId* block_exit;
    // The values each block owns, in the order they were built.
    uint* block_first;
    uint* block_last;
}

fn long ssa_spill_offset(uint slot) @feat(SLJIT) {
    LoopState state;
    return (char*)&state.ssa_spill - (char*)&state + (long)slot * double::size;
}
fn int ssa_value(SsaGraph* g, SsaOp op, SsaRep rep, int a, int b, long imm) @feat(SLJIT) {
    if (!ssa_reserve_values(g, g.value_count + 1)) return 0;
    uint index = g.value_count++;
    g.values[index].proof_bits = 0;
    g.values[index].op = op;
    g.values[index].rep = rep;
    g.values[index].a = a;
    g.values[index].b = b;
    g.values[index].imm = imm;
    g.values[index].def = g.stamp;
    g.values[index].last = g.stamp;
    g.values[index].schedule_prev = -1;
    g.values[index].schedule_next = -1;
    g.values[index].schedule_block = -1;
    g.values[index].before_frame = SSA_NO_FRAME;
    g.values[index].after_frame = SSA_NO_FRAME;
    g.values[index].arg_reg = -1;
    g.values[index].dst_reg = -1;
    g.values[index].pc = g.current_pc;
    g.values[index].block = (int)g.current_block;
    g.stamp++;
    if (g.schedule_ready && op != ARG && op != PHI && op != JOIN) ssa_schedule_append(g, g.current_block, (int)index);
    return (int)index;
}
fn void ssa_use(SsaGraph* g, int value) @feat(SLJIT) {
    if (g.failed) return;
    if (value < 0 || value >= (int)g.value_count) {
        g.failed = true;
        return;
    }
    if (g.stamp > g.values[value].last) g.values[value].last = g.stamp;
}
fn void ssa_result(SsaGraph* g, int value, uint reg, uint pc) @feat(SLJIT) {
    if (g.failed) return;
    g.values[value].dst_reg = (int)reg;
    g.values[value].pc = pc;
}
fn int ssa_convert(SsaGraph* g, int value, SsaRep rep, bool exact) @feat(SLJIT) {
    if (g.failed) return 0;
    if (value < 0) {
        g.failed = true;
        return 0;
    }
    SsaRep from = g.values[value].rep;
    if (from == RAW || rep == RAW) { g.failed = true; return 0; }
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
    return (op >= Opcode.JMP_NLT && op <= Opcode.JMP_NEQ) || (op >= Opcode.JMP_NLTI && op <= Opcode.JMP_SNEQI);
}

// Split the body into basic blocks at the forward branch targets. A block
// ends at the branch that leaves it, or at the start of the next block, so
// the blocks partition the body in bytecode order and a block's fall-through
// successor is the next one.
fn bool ssa_add_block_start(SsaGraph* g, uint* starts, uint* count, uint pc) @feat(SLJIT) {
    for (uint i = 0; i < *count; i++) if (starts[i] == pc) return true;
    if (*count == g.block_capacity) return false;
    uint at = *count;
    while (at > 0 && starts[at - 1] > pc) {
        starts[at] = starts[at - 1];
        at--;
    }
    starts[at] = pc;
    (*count)++;
    return true;
}

fn bool ssa_split_blocks(SsaGraph* g) @feat(SLJIT) {
    if (g.recoverable) return ssa_split_recoverable(g);
    CompiledFunction* cf = g.cf;
    LoopPlan* plan = g.plan;
    uint* starts = (uint*)ssa_storage_alloc(g, g.block_capacity, uint::size);
    if (g.failed) return false;
    uint count;
    if (!ssa_add_block_start(g, starts, &count, plan.begin)) return false;
    for (uint pos = plan.begin; pos <= plan.end; pos++) {
        Instruction ins = cf.code[pos];
        int target = loop_target(ins, pos);
        if (target < 0) continue;
        if (!g.single_pass && target == (int)plan.begin) continue;
        if (target < (int)plan.begin || target > (int)plan.end) return false;
        if (target <= (int)pos && !g.cyclic) return false;
        if (ins.op != Opcode.JUMP && pos < plan.end
            && !ssa_add_block_start(g, starts, &count, pos + 1)) return false;
        if (!ssa_add_block_start(g, starts, &count, (uint)target)) return false;
    }
    g.block_count = count;
    for (uint i = 0; i < count; i++) {
        SsaBlock* block = &g.blocks[i];
        block.begin = starts[i];
        uint limit = i + 1 < count ? starts[i + 1] - 1 : plan.end;
        uint e     = starts[i];
        while (e <= limit && loop_target(cf.code[e], e) < 0
            && !(plan.ssa_function != null && (cf.code[e].op == Opcode.RET || cf.code[e].op == Opcode.RETUNDEF))) e++;
        block.returns = e <= limit && (cf.code[e].op == Opcode.RET || cf.code[e].op == Opcode.RETUNDEF);
        block.branch_pc = e <= limit && !block.returns ? e : uint::max;
        block.end = e <= limit ? e : limit;
        block.conditional = false;
        block.jump = false;
        block.succ0 = SSA_NO_BLOCK;
        block.succ1 = SSA_NO_BLOCK;
        if (block.branch_pc != uint::max) {
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
        if (block.returns) {
            block.succ0 = SSA_NO_BLOCK;
            block.succ1 = SSA_NO_BLOCK;
            continue;
        }
        if (block.branch_pc == uint::max) {
            block.succ0 = i + 1 < count ? i + 1 : SSA_NO_BLOCK;
            continue;
        }
        Instruction ins = cf.code[block.branch_pc];
        int target      = loop_target(ins, block.branch_pc);
        if (block.jump) {
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
        block.succ0 = i + 1 < count ? i + 1 : SSA_NO_BLOCK;
        for (uint j = 0; j < count; j++) {
            if (g.blocks[j].begin == (uint)target) {
                block.succ1 = j;
                break;
            }
        }
    }
    // The last block ends at the backedge, which the latch owns.
    if (!g.cyclic) {
        g.blocks[count - 1].succ0 = g.single_pass ? SSA_NO_BLOCK : 0;
        g.blocks[count - 1].succ1 = g.single_pass ? SSA_NO_BLOCK : 0;
    }
    if (!ssa_collect_predecessors(g)) return false;
    return true;
}

// The block a bytecode position belongs to.
fn int ssa_block_of(SsaGraph* g, uint pc) @feat(SLJIT) {
    for (uint i = 0; i < g.block_count; i++) {
        if (g.blocks[i].begin <= pc && pc <= g.blocks[i].end) return (int)i;
    }
    return -1;
}

fn bool ssa_cyclic_liveness(SsaGraph* g) @feat(SLJIT) {
    if (!compiler::moveelim_roles_ready) compiler::moveelim_init_roles();
    bool* reachable = (bool*)ssa_storage_alloc(g, g.block_count, bool::size);
    bool* scheduled = (bool*)ssa_storage_alloc(g, g.block_count, bool::size);
    if (g.failed) return false;
    reachable[0] = !g.recoverable;
    if (g.recoverable) for (uint b = 0; b < g.block_count; b++) {
        if (g.blocks[b].external) reachable[b] = true;
    }
    bool changed = true;
    while (changed) {
        if (!ssa_charge_work(g, (usz)g.block_count + (usz)g.value_count)) return false;
        changed = false;
        for (uint b = 0; b < g.block_count; b++) {
            if (!reachable[b]) continue;
            SsaBlock block = g.blocks[b];
            if (block.succ0 < g.block_count && !reachable[block.succ0]) { reachable[block.succ0] = true; changed = true; }
            if (block.succ1 < g.block_count && !reachable[block.succ1]) { reachable[block.succ1] = true; changed = true; }
        }
    }
    for (uint b = 0; b < g.block_count; b++) if (!reachable[b]) return false;
    for (uint n = 0; n < g.block_count; n++) {
        bool found;
        // Imports are independent definitions, not a bytecode-order suffix.
        // Build every root before merging any ordinary predecessor state.
        if (g.recoverable) for (uint b = 0; b < g.block_count; b++) {
            if (scheduled[b] || !g.blocks[b].external) continue;
            g.cyclic_order[n] = b;
            scheduled[b] = true;
            found = true;
            break;
        }
        if (found) continue;
        for (uint b = 0; b < g.block_count; b++) {
            if (scheduled[b]) continue;
            bool ready = g.recoverable ? g.blocks[b].external : b == 0;
            for (uint p = 0; p < g.blocks[b].pred_count && !ready; p++) ready = scheduled[g.blocks[b].preds[p]];
            if (!ready) continue;
            g.cyclic_order[n] = b;
            scheduled[b] = true;
            found = true;
            break;
        }
        if (!found) return false;
    }
    if (g.recoverable) return true; // canonical decoded CFG supplied liveness
    uint* live = (uint*)ssa_storage_alloc(g, (usz)g.block_count * 2, uint::size);
    if (g.failed) return false;
    uint[2] words;
    compiler::RegSet set = { .words = &words[0], .word_count = 2 };
    changed = true;
    while (changed) {
        if (!ssa_charge_work(g, (usz)g.block_count + (usz)g.value_count)) return false;
        changed = false;
        uint b = g.block_count;
        while (b > 0) {
            b--;
            SsaBlock* block = &g.blocks[b];
            set.clear();
            if (block.succ0 < g.block_count) {
                words[0] |= live[(usz)(block.succ0) * 2 + 0]; words[1] |= live[(usz)(block.succ0) * 2 + 1];
            }
            if (block.succ1 < g.block_count) {
                words[0] |= live[(usz)(block.succ1) * 2 + 0]; words[1] |= live[(usz)(block.succ1) * 2 + 1];
            }
            // Native control returns to the VM at CALL, but locals still live
            // across that call belong in its recovery frame. Preserve the
            // semantic fallthrough edge for liveness only.
            if (g.recoverable && function_call_op(g.cf.code[block.end].op)) {
                int after_call = ssa_block_of(g, block.end + 1);
                if (after_call >= 0) {
                    words[0] |= live[(usz)(after_call) * 2 + 0]; words[1] |= live[(usz)(after_call) * 2 + 1];
                }
            }
            uint pc = block.end + 1;
            while (pc > block.begin) {
                Instruction ins = g.cf.code[--pc];
                uint def;
                if (compiler::moveelim_get_def(ins, &def)) set.unset(def);
                compiler::moveelim_add_uses(ins, &set, true);
            }
            if (live[(usz)(b) * 2 + 0] != words[0] || live[(usz)(b) * 2 + 1] != words[1]) {
                live[(usz)(b) * 2 + 0] = words[0]; live[(usz)(b) * 2 + 1] = words[1]; changed = true;
            }
        }
    }
    for (uint b = 0; b < g.block_count; b++) {
        g.cyclic_live[b].words[0] = live[(usz)b * 2];
        if (g.reg_words > 1) g.cyclic_live[b].words[1] = live[(usz)b * 2 + 1];
    }
    return true;
}

fn bool ssa_loop_eligible(LoopPlan* plan, CompiledFunction* cf, Heap* h) @feat(SLJIT) {
    // Unsupported graphs retain the straight-line loop implementation.
    if (!SSA_ENABLED || plan.memory_count > LOOP_MEMORY) return false;
    if (!plan.ssa_recoverable && plan.end - plan.begin >= SSA_SPAN) return false;
    for (uint i = 0; i < plan.memory_count; i++) {
        LoopMemoryKind kind = plan.memory[i].kind;
        if (kind == ASCII || kind == INTRINSIC) return false;
    }
    for (uint pos = plan.begin; pos <= plan.end;) {
        DecodedBytecode view = bytecode::decode_bytecode(cf.code, cf.code_count, pos);
        if (!view.valid) return false;
        defer pos = view.next_pc;
        DecodedInsn ins = view.insn;
        int target      = ssa_decoded_target(view);
        if (target >= 0) {
            if (pos == plan.end) {
                if (target != (int)plan.begin) return false;
                // The backedge must compare two values. A truthiness test names
                // its operand in the branch's offset field, not in a register.
                if (!ssa_comparison_op(ins.op) && ins.op != Opcode.IF_TRUE && ins.op != Opcode.IF_FALSE) return false;
                continue;
            }
            // An arm's branch: a comparison, a truthiness test, or the jump
            // that ends an arm. A branch that leaves the body is not
            // supported. A nested loop may branch back inside the body.
            if (target <= (int)pos) {
                if (!SSA_CYCLIC || !SSA_CYCLIC_REGIONS || target <= (int)plan.begin) return false;
            } else if (target > (int)plan.end) return false;
            if (ins.op == Opcode.IF_TRUE || ins.op == Opcode.IF_FALSE) continue;
            if (ins.op == Opcode.JUMP) continue;
            if (!ssa_comparison_op(ins.op)) return false;
            continue;
        }
        switch (ins.op) {
            case LDTHIS:
                if (plan.ssa_function == null) return false;
                continue;
            case RET:
            case RETUNDEF:
                if (plan.ssa_function == null) return false;
                continue;
            case PUTTHISC:
            case PUTPROPC:
                if (!plan.ssa_commit || (!plan.ssa_recoverable && pos + 1 != plan.end)) return false;
                continue;
            case GETCAP:
            case GETVAR:
            case GETGLOBAL:
                if (ssa_binding_site(plan, pos - plan.begin) == 0) return false;
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
            case LT: case LE: case GT: case GE:
            case EQ: case NEQ: case SEQ: case SNEQ:
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
                if (ssa_memory_site(plan, pos - plan.begin) == 0) return false;
                continue;
            case GETPROPC:
            case GETPROPC_CACHED:
            case GETTHISC:

                {
                    uint at = pos - plan.begin;
                    if (ssa_memory_site(plan, at) == 0 && plan.ssa_recoverable) continue;
                    if (ssa_memory_site(plan, at) == 0 || ssa_intrinsic_site(plan, at) != 0) return false;
                    LoopMemoryKind kind = plan.memory[(uint)ssa_memory_site(plan, at) - 1].kind;
                    if (kind != FIELD && kind != SHAPE_FIELD && kind != PROTO_FIELD) return false;
                    continue;
                }
            case CALL:
            case CALL_UNDEF_THIS:
            case CALL_GLOBAL:
            case CALL_VAR:
                // Expanded in place, so the callee body must be a leaf.
                if (ssa_memory_site(plan, pos - plan.begin) != 0) return false;
                if (!plan.ssa_recoverable && function_inline_ssa_candidate(cf, pos, h, plan.ssa_function != null) == null) return false;
                continue;
            case NEWOBJ:
            case NEWOBJ_SHAPE:
            case NEWARR:
            case NEWARR_CONST:
            case CLOSURE:
            case NEWCELLS: case GETCELL: case SETCELL: case MOVECELL:
                if (!plan.ssa_recoverable) return false;
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
    bool* read,
    bool* value_read,
    bool* written,
    bool* live_in,
    bool* base,
    bool* int_need,
    bool* f64_need
) @feat(SLJIT) {
    CompiledFunction* cf = g.cf;
    LoopPlan* plan       = g.plan;
    bool* assigned = (bool*)ssa_storage_alloc(g, g.reg_count, bool::size);
    bool* boolean_literal = (bool*)ssa_storage_alloc(g, g.reg_count, bool::size);
    if (g.failed) return;
    for (uint pos = plan.begin; pos <= plan.end;) {
        DecodedBytecode view = ssa_decoded_view(g, pos);
        if (!view.valid) { g.failed = true; return; }
        defer pos = view.next_pc;
        DecodedInsn ins = view.insn;
        // This is only a representation preference. Runtime guards and the
        // SSA definition still prove the boolean comparison itself. Keep the
        // hint within straight-line definitions; calls/control can import a
        // different value for the same physical bytecode register.
        bool boolean_result = ins.op == Opcode.LDTRUE || ins.op == Opcode.LDFALSE
            || (ins.op == Opcode.LDREG && boolean_literal[ins.b]);
        if (ssa_decoded_target(view) >= 0) {
            if (!ssa_charge_work(g, g.reg_count)) return;
            mem::clear(boolean_literal, (sz)g.reg_count * bool::size);
            // An unconditional jump carries an offset in A, not a register.
            if (ins.op == Opcode.JUMP) continue;
            // A comparison branch reads two numbers; a truthiness test reads
            // one value and does not use it as a number.
            bool comparison = ssa_comparison_op(ins.op);
            uint left       = comparison ? ins.b : ins.a;
            uint right      = comparison ? ins.c : left;
            if (comparison && ins.op >= Opcode.JMP_NLTI) right = left;
            if (left < g.reg_count) {
                read[left] = true;
                value_read[left] = true;
                if (!assigned[left]) live_in[left] = true;
                if (comparison) int_need[left] = true;
            }
            if (right < g.reg_count && right != left) {
                read[right] = true;
                value_read[right] = true;
                if (!assigned[right]) live_in[right] = true;
                if (comparison) int_need[right] = true;
            }
            continue;
        }
        bool writes = true;
        switch (ins.op) {
            case PUTTHISC:
            case RET:
                read[ins.a] = true;
                value_read[ins.a] = true;
                if (!assigned[ins.a]) live_in[ins.a] = true;
                writes = false;
                break;
            case PUTPROPC:
                read[ins.a] = true;
                value_read[ins.a] = true;
                if (!assigned[ins.a]) live_in[ins.a] = true;
                read[ins.b] = true;
                value_read[ins.b] = true;
                if (!assigned[ins.b]) live_in[ins.b] = true;
                writes = false;
                break;
            case RETUNDEF:
                writes = false;
                break;
            case LDREG:
                read[ins.b] = true;
                value_read[ins.b] = true;
                if (!assigned[ins.b]) live_in[ins.b] = true;
                break;
            case GETCAP:
            case GETVAR:
            case GETGLOBAL:
            case LDINT:
            case LDCONST:
            case NEWOBJ:
            case NEWOBJ_SHAPE:
            case NEWARR:
            case NEWARR_CONST:
            case CLOSURE:
                break;
            case CALL:
            case CALL_UNDEF_THIS:
            case CALL_GLOBAL:
            case CALL_VAR:

                {
                    bool fused = ins.op == Opcode.CALL_GLOBAL || ins.op == Opcode.CALL_VAR;
                    uint call_base = fused ? ins.a : ins.b;
                    uint nargs = fused ? ins.b : ins.c;
                    if (call_base + 1 + nargs >= cf.num_regs) return;
                    for (uint i = fused ? 2 : 0; i <= nargs + 1; i++) {
                        uint reg = call_base + i;
                        read[reg] = true;
                        value_read[reg] = true;
                        if (!assigned[reg]) live_in[reg] = true;
                    }

                }
                break;
            case GETPROPC:
            case GETPROPC_CACHED:
            case GETTHISC:
                if (g.direct_fields && ssa_memory_site(plan, pos - plan.begin) != 0) {
                    LoopMemorySpec spec = plan.memory[(uint)ssa_memory_site(plan, pos - plan.begin) - 1];
                    if (spec.kind == FIELD && spec.source < LOOP_REGS) {
                        uint source = spec.source;
                        read[source] = true;
                        value_read[source] = true;
                        if (!assigned[source]) live_in[source] = true;
                    }
                }
                if (ssa_memory_site(plan, pos - plan.begin) != 0
                    && (plan.memory[(uint)ssa_memory_site(plan, pos - plan.begin) - 1].kind == SHAPE_FIELD
                        || plan.memory[(uint)ssa_memory_site(plan, pos - plan.begin) - 1].kind == PROTO_FIELD)
                    && ins.op != Opcode.GETTHISC) {
                    read[ins.b] = true;
                    value_read[ins.b] = true;
                    if (!assigned[ins.b]) live_in[ins.b] = true;
                }
                break;
            case GETPROP:
            case GETPROP_CACHE:
                read[ins.c] = true;
                value_read[ins.c] = true;
                if (!assigned[ins.c]) live_in[ins.c] = true;
                base[ins.b] = true;
                read[ins.b] = true;
                int_need[ins.c] = true;
                break;
            case PUTPROP:
                read[ins.b] = true;
                value_read[ins.b] = true;
                read[ins.c] = true;
                value_read[ins.c] = true;
                if (!assigned[ins.b]) live_in[ins.b] = true;
                if (!assigned[ins.c]) live_in[ins.c] = true;
                base[ins.a] = true;
                read[ins.a] = true;
                int_need[ins.b] = true;
                writes = false;
                break;
            case TONUMERIC:
            case INC:
            case INC_LT:
            case DEC:
                read[ins.a] = true;
                value_read[ins.a] = true;
                if (!assigned[ins.a]) live_in[ins.a] = true;
                if (ins.op != Opcode.TONUMERIC) int_need[ins.a] = true;
                break;
            case BAND:
            case BOR:
            case BXOR:
            case SHL:
            case SHR:
            case USHR:
                read[ins.b] = true;
                read[ins.c] = true;
                value_read[ins.b] = true;
                value_read[ins.c] = true;
                if (!assigned[ins.b]) live_in[ins.b] = true;
                if (!assigned[ins.c]) live_in[ins.c] = true;
                int_need[ins.b] = true;
                int_need[ins.c] = true;
                break;
            case BANDI:
            case BORI:
            case BXORI:
            case SHLI:
            case SHRI:
            case USHRI:
            case BNOT:
                read[ins.b] = true;
                value_read[ins.b] = true;
                if (!assigned[ins.b]) live_in[ins.b] = true;
                int_need[ins.b] = true;
                break;
            case ADD:
            case ADD_FUSED:
            case SUB:
            case MUL:
            case DIV:
            case LT: case LE: case GT: case GE:
            case EQ: case NEQ: case SEQ: case SNEQ:
                read[ins.b] = true;
                read[ins.c] = true;
                value_read[ins.b] = true;
                value_read[ins.c] = true;
                if (!assigned[ins.b]) live_in[ins.b] = true;
                if (!assigned[ins.c]) live_in[ins.c] = true;
                bool equality = ins.op == Opcode.EQ || ins.op == Opcode.NEQ
                    || ins.op == Opcode.SEQ || ins.op == Opcode.SNEQ;
                if (!equality || (!boolean_literal[ins.b] && !boolean_literal[ins.c])) {
                    f64_need[ins.b] = true;
                    f64_need[ins.c] = true;
                }
                break;
            case ADDI:
            case SUBI:
            case MULI:
                read[ins.b] = true;
                value_read[ins.b] = true;
                if (!assigned[ins.b]) live_in[ins.b] = true;
                f64_need[ins.b] = true;
                break;
            default: break;
        }
        if (ssa_decoded_helper_op(ins.op)) {
            if (!ssa_charge_work(g, g.reg_count)) return;
            mem::clear(boolean_literal, (sz)g.reg_count * bool::size);
        }
        if (writes) {
            written[ins.a] = true;
            assigned[ins.a] = true;
            boolean_literal[ins.a] = boolean_result;
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
fn bool ssa_op_is_int(SsaGraph* g, DecodedInsn ins, uint pos, bool* int_reg) @feat(SLJIT) {
    CompiledFunction* cf = g.cf;
    LoopPlan* plan       = g.plan;
    switch (ins.op) {
        case GETCAP: return ssa_binding_integer_feedback(g, ssa_decoded_view(g, pos));
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
        case TONUMERIC: return int_reg[ins.b];
        case INC:
        case INC_LT:
        case DEC: return int_reg[ins.a];
        case ADD:
        case ADD_FUSED:
        case SUB:
        case MUL:
            return int_reg[ins.b] && int_reg[ins.c];
        case ADDI:
        case SUBI:
        case MULI: return int_reg[ins.b];
        case GETPROP:
        case GETPROP_CACHE:

            {
                uint memory = ssa_memory_site(plan, pos - plan.begin);
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
    LoopPlan* plan       = g.plan;
    bool* assigned = (bool*)ssa_storage_alloc(g, g.reg_count, bool::size);
    if (g.failed) return;
    bool* int_reg = (bool*)ssa_storage_alloc(g, g.reg_count, bool::size);
    if (g.failed) return;
    for (uint i = 0; i < g.reg_count; i++) int_reg[i] = true;
    uint* words = (uint*)ssa_storage_alloc(g, g.reg_words, uint::size);
    if (g.failed) return;
    compiler::RegSet writes = { .words = words, .word_count = g.reg_words };
    bool changed = true;
    while (changed) {
        if (!ssa_charge_work(g, (usz)(plan.end - plan.begin + 1) * (usz)(g.reg_count + 1))) return;
        changed = false;
        for (uint pos = plan.begin; pos <= plan.end;) {
            DecodedBytecode view = ssa_decoded_view(g, pos);
            if (!view.valid) { g.failed = true; return; }
            defer pos = view.next_pc;
            DecodedInsn ins = view.insn;
            writes.clear();
            compiler::register_decoded_may_writes(ins, &writes);
            bool integer = ssa_op_is_int(g, ins, pos, int_reg);
            for (uint reg = 0; reg < g.reg_count; reg++) {
                if (!writes.test(reg)) continue;
                assigned[reg] = true;
                if (int_reg[reg] && (reg != ins.a || !integer)) {
                    int_reg[reg] = false;
                    changed = true;
                }
            }
        }
        for (uint reg = 0; reg < g.reg_count; reg++) {
            if (!assigned[reg] && int_reg[reg]) {
                int_reg[reg] = false;
                changed = true;
            }
        }
    }
    for (uint i = 0; i < g.reg_count; i++) g.int_reg[i] = int_reg[i];
}

// A loop header reached from a block that has not been built yet: the
// backedge carries values from later in the body. The header keeps one phi
// per register live at its entry. Forward edges are bound now; backedge
// inputs are bound once every block has been built.
fn bool ssa_cyclic_header(SsaGraph* g, uint b) @feat(SLJIT) {
    SsaBlock* block = &g.blocks[b];
    if (g.join_count == g.block_capacity) return false;
    uint index = g.join_count++;
    SsaJoin* join = &g.joins[index];
    join.block = b;
    join.pred_count = block.pred_count;
    if (!ssa_join_storage(g, join, block)) return false;
    join.entry = g.recoverable ? block.external : b == 0;
    for (uint p = 0; p < block.pred_count; p++) {
        join.preds[p] = block.preds[p];
        for (uint reg = 0; reg < g.reg_count; reg++) join.incoming[p][reg] = -1;
    }
    for (uint reg = 0; reg < g.reg_count; reg++) {
        join.phi[reg] = -1;
        join.entry_incoming[reg] = join.entry ? (g.recoverable ? g.header[reg] : g.current[reg]) : -1;
        g.current[reg] = -1;
        if (!g.cyclic_live[b].test(reg)) continue;
        bool available = join.entry && join.entry_incoming[reg] >= 0;
        if (available) ssa_use(g, join.entry_incoming[reg]);
        for (uint p = 0; p < block.pred_count; p++) {
            uint pred = block.preds[p];
            if (!g.block_built[pred]) continue;
            int incoming = ssa_frame_lookup(g, g.block_exit[pred], reg);
            if (incoming < 0) return false;
            join.incoming[p][reg] = incoming;
            ssa_use(g, incoming);
            available = true;
        }
        if (!available) return false;
        int phi = ssa_value(g, JOIN, g.rep[reg], (int)index, (int)reg, 0);
        ssa_result(g, phi, reg, block.begin);
        join.phi[reg] = phi;
        g.current[reg] = phi;
    }
    return true;
}

// Enter a block: its register state is the merge of its predecessors' states.
// Where the predecessors disagree, the join holds a value each of them
// writes before it arrives.
fn bool ssa_enter_block(SsaGraph* g, uint b) @feat(SLJIT) {
    SsaBlock* block = &g.blocks[b];
    if (g.recoverable && (block.external || block.preheader)) return ssa_cyclic_header(g, b);
    if (block.pred_count == 0) return true;
    // A loop region's own header already has its phis.
    if (!g.recoverable && !g.single_pass && b == 0) return true;
    if (g.cyclic) {
        bool cyclic_header;
        for (uint p = 0; p < block.pred_count; p++) {
            if (!g.block_built[block.preds[p]]) cyclic_header = true;
        }
        if (cyclic_header) return ssa_cyclic_header(g, b);
    }
    if (!g.recoverable && b == 0) return true;
    if (block.pred_count == 1) {
        uint pred = block.preds[0];
        ssa_frame_restore(g, g.block_exit[pred], g.current, g.reg_count);
        return true;
    }
    if (g.join_count == g.block_capacity) return false;
    uint index    = g.join_count++;
    SsaJoin* join = &g.joins[index];
    join.block = b;
    join.pred_count = block.pred_count;
    if (!ssa_join_storage(g, join, block)) return false;
    for (uint p = 0; p < block.pred_count; p++) {
        join.preds[p] = block.preds[p];
        for (uint reg = 0; reg < g.reg_count; reg++) join.incoming[p][reg] = -1;
    }
    for (uint reg = 0; reg < g.reg_count; reg++) join.phi[reg] = -1;
    for (uint reg = 0; reg < g.reg_count; reg++) {
        if (g.recoverable && !g.cyclic_live[b].test(reg)) {
            g.current[reg] = -1;
            continue;
        }
        int first   = ssa_frame_lookup(g, g.block_exit[block.preds[0]], reg);
        bool differ = false;
        for (uint p = 1; p < block.pred_count; p++) {
            if (ssa_frame_lookup(g, g.block_exit[block.preds[p]], reg) != first) {
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
            if (ssa_frame_lookup(g, g.block_exit[block.preds[p]], reg) < 0) missing = true;
        }
        if (missing) {
            g.current[reg] = -1;
            continue;
        }
        // Join representations without narrowing a predecessor. Integer and
        // double arms merge as F64; an arbitrary tagged arm keeps the join boxed.
        SsaRep rep = g.values[first].rep;
        for (uint p = 1; p < block.pred_count; p++) {
            SsaRep incoming = g.values[ssa_frame_lookup(g, g.block_exit[block.preds[p]], reg)].rep;
            if (rep != incoming) rep = ssa_numeric_rep(rep) && ssa_numeric_rep(incoming) ? F64 : BOXED;
        }
        int phi = ssa_value(g, JOIN, rep, (int)index, (int)reg, 0);
        ssa_result(g, phi, (uint)reg, block.begin);
        join.phi[reg] = phi;
        for (uint p = 0; p < block.pred_count; p++) {
            int incoming = ssa_frame_lookup(g, g.block_exit[block.preds[p]], reg);
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
fn bool ssa_arm_branch(SsaGraph* g, uint b, uint pos, DecodedInsn ins) @feat(SLJIT) {
    SsaBlock* block =  &g.blocks[b];
    int lhs;
    int rhs         = -1;
    long imm        =  0;
    Opcode op       =  (Opcode)0;
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
        // Preserve boxed predicates for native truth tests and exact recovery
        // of representations that still need the interpreter.
        if (ins.a >= g.reg_count) return false;
        lhs = g.current[ins.a];
        if (lhs < 0) return false;
        SsaRep rep = g.values[lhs].rep;
        if (rep != INT32 && rep != BOXED) return false;
        imm = ins.op == Opcode.IF_TRUE ? 1 : 0;
    } else if (ins.op == Opcode.JMP_NULL || ins.op == Opcode.JMP_NNULL) {
        // A nullish test inspects the boxed tag directly; no conversion or
        // numeric operand is involved.
        if (ins.b >= g.reg_count) return false;
        lhs = g.current[ins.b];
        if (lhs < 0) return false;
        lhs = ssa_convert(g, lhs, BOXED, false);
        op = ins.op;
    } else {
        if (ins.b >= g.reg_count || ins.c >= g.reg_count) return false;
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
        SsaRep rep   = integer ? INT32 : F64;
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

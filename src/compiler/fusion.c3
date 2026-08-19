// Declarative superinstruction-fusion framework.
//
// A fusion collapses a short instruction sequence that shares a scratch
// register into a single superinstruction baking the scratch value in as
// an immediate or index.
//
// Shared driver run_fusion_rule handles NOP-skipping, jump-target guards,
// and dead-after-liveness scans.
//
// Pass ordering in finish():
//   1. GETVAR+INC/DEC+PUTVAR -> INC_VAR/DEC_VAR (run_fusion3_rule)
//   2. LDCONST+GETPROP -> GETPROPC (run_fusion_rule)
//   3. compare+IF_FALSE/IF_TRUE -> JMP_N*/JMP_*/JMP_SEQ/JMP_SNEQ (run_cmp_branch_fusion)
//   4. copy-propagation (LDREG rT=rX substitution)
//   5. LDINT+ADD/SUB -> ADDI/SUBI (run_fusion_rule)
module boomkat::compiler;

import boomkat::bytecode;
import boomkat::types;

// Result of matching a fusion trigger+consumer pair.
struct FusionMatch {
    bool   matched;
    Opcode rewrite_op;   // opcode to install at consumer slot
    uint   dest_reg;     // destination register of rewritten instruction
    uint   src_reg;      // surviving source register operand
    uint   imm;          // immediate baked into rewritten instruction
}

// Trigger predicate: checks whether an instruction introduces a fusable scratch value.
alias FusionTriggerFn = fn FusionMatch(Instruction trigger, void* ctx);

// Consumer predicate: checks whether the candidate consumes the trigger's scratch register.
alias FusionConsumerFn = fn FusionMatch(Instruction trigger, Instruction consumer, uint scratch_reg, void* ctx);

// Declarative fusion rule: {trigger predicate, consumer predicate}.
struct FusionRule {
    FusionTriggerFn  trigger;
    FusionConsumerFn consumer;
}

// True if ABC-format instruction ins reads reg in one of its register operands.
fn bool fusion_abc_reads_reg(Instruction ins, uint reg) {
    switch (ins.op) {
        case Opcode.CALL_VAR:
        case Opcode.CALL_GLOBAL:
            // A = result/callee register, B = argc, C = name-constant index.
            // Neither B nor C is a register.
            return false;
        case Opcode.GETPROPC:
            // A = dst, B = src register, C = key-constant index.
            return (uint)ins.b == reg;
        default:
            return (uint)ins.b == reg || (uint)ins.c == reg;
    }
}

// Scan forward from start and report whether reg is read before being overwritten.
//
// Inside a conditional branch's skip window, writes are not treated as kills
// because the branch may skip past them at runtime.
// WIDE_SABC and WIDE_ABC (JUMP/BREAK/CONTINUE) pack a 24-bit branch offset across
// A/B/C, so field A is the low byte of the offset, not a destination register.
fn bool fusion_reg_live_from(Instruction* code, uint code_count, uint start, uint reg) {
    int join_pc = -1;
    for (uint j = start; j < code_count; j++) {
        Instruction jns = code[j];
        Opcode jop = jns.op;
        if (jop == Opcode.IF_TRUE || jop == Opcode.IF_FALSE) {
            if ((uint)jns.a == reg) { return true; }
            int t = fusion_conditional_branch_target(code, j);
            if (t > join_pc) { join_pc = t; }
            continue;
        }
        if (bytecode::get_op_format(jop) == OpFormat.ABC) {
            if (fusion_abc_reads_reg(jns, reg)) { return true; }
        }
        int bt = fusion_conditional_branch_target(code, j);
        if (bt > join_pc) { join_pc = bt; }
        OpFormat jfmt_w = bytecode::get_op_format(jop);
        if ((int)j >= join_pc && jfmt_w != OpFormat.WIDE_SABC && jfmt_w != OpFormat.WIDE_ABC) {
            if ((uint)jns.a == reg) { return false; }
        }
    }
    return false;
}

// If code[j] is a conditional branch, return the target slot it can skip to; otherwise -1.
fn int fusion_conditional_branch_target(Instruction* code, uint j) {
    Instruction ins = code[j];
    int off;
    switch (ins.op) {
        case Opcode.IF_TRUE:
        case Opcode.IF_FALSE:
            off = ins.get_sbc();
        case Opcode.JMP_NLT:
        case Opcode.JMP_NLE:
        case Opcode.JMP_NGT:
        case Opcode.JMP_NGE:
        case Opcode.JMP_LT:
        case Opcode.JMP_LE:
        case Opcode.JMP_GT:
        case Opcode.JMP_GE:
        case Opcode.JMP_SEQ:
        case Opcode.JMP_SNEQ:
            off = (int)(ichar)ins.a;
        case Opcode.JMP_LT_G:
            return (int)j + 2 + (int)(ichar)ins.a;
        default:
            return -1;
    }
    return (int)j + 1 + off;
}

// Mark every instruction slot reachable by a branch, loop exit, or exception handler.
fn void build_jump_targets(Instruction* code, uint code_count, bool* jump_targets) {
    for (uint i = 0; i < code_count; i++) { jump_targets[i] = false; }
    for (uint i = 0; i < code_count; i++) {
        Instruction ins = code[i];
        switch (ins.op) {
            case Opcode.JUMP:
            case Opcode.BREAK:
            case Opcode.CONTINUE: {
                int off = ins.get_sabc();
                int tgt = (int)i + 1 + off;
                if (tgt >= 0 && (uint)tgt < code_count) { jump_targets[tgt] = true; }
            }
            case Opcode.IF_TRUE:
            case Opcode.IF_FALSE: {
                int off = ins.get_sbc();
                int tgt = (int)i + 1 + off;
                if (tgt >= 0 && (uint)tgt < code_count) { jump_targets[tgt] = true; }
            }
            case Opcode.JMP_NLT:
            case Opcode.JMP_NLE:
            case Opcode.JMP_NGT:
            case Opcode.JMP_NGE:
            case Opcode.JMP_LT:
            case Opcode.JMP_LE:
            case Opcode.JMP_GT:
            case Opcode.JMP_GE:
            case Opcode.JMP_SEQ:
            case Opcode.JMP_SNEQ: {
                int off = (int)(ichar)ins.a;
                int tgt = (int)i + 1 + off;
                if (tgt >= 0 && (uint)tgt < code_count) { jump_targets[tgt] = true; }
            }
            case Opcode.JMP_LT_G: {
                int off = (int)(ichar)ins.a;
                int tgt = (int)i + 2 + off;
                if (tgt >= 0 && (uint)tgt < code_count) { jump_targets[tgt] = true; }
            }
            case Opcode.TRY: {
                uint catch_off = ins.get_bc();
                uint catch_tgt = i + catch_off;
                if (catch_tgt < code_count) { jump_targets[catch_tgt] = true; }
                if (i + 1 < code_count) {
                    uint finally_off = code[i + 1].get_bc();
                    if (finally_off != 0) {
                        uint finally_tgt = i + finally_off;
                        if (finally_tgt < code_count) { jump_targets[finally_tgt] = true; }
                    }
                }
            }
            default: {}
        }
    }
}

// Run one fusion rule over the instruction stream.
// Skips NOPs between trigger and consumer, checks jump targets and scratch-register liveness.
fn void run_fusion_rule(Instruction* code, uint code_count, bool* jump_targets, FusionRule rule, void* ctx = null) {
    build_jump_targets(code, code_count, jump_targets);

    for (uint i = 0; i < code_count; i++) {
        FusionMatch tm = rule.trigger(code[i], ctx);
        if (!tm.matched) { continue; }

        // Any slot from just after the trigger through the consumer being a
        // jump target means control can reach the consumer without having
        // executed the trigger (a NOP in between is fallthrough into the
        // consumer, so it is exactly as unsafe as the consumer itself).
        uint k = i + 1;
        while (k < code_count && code[k].op == Opcode.NOP) { k++; }
        if (k >= code_count) { continue; }

        bool reachable_without_trigger = false;
        for (uint j = i + 1; j <= k; j++) {
            if (jump_targets[j]) { reachable_without_trigger = true; break; }
        }
        if (reachable_without_trigger) { continue; }

        FusionMatch cm = rule.consumer(code[i], code[k], tm.dest_reg, ctx);
        if (!cm.matched) { continue; }

        if (fusion_reg_live_from(code, code_count, k + 1, tm.dest_reg)) { continue; }

        code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
        code[k] = bytecode::make_abc(cm.rewrite_op, cm.dest_reg, cm.src_reg, cm.imm);
    }
}

// ============================================================================
// Rule: LDINT rK, imm  +  ADD/SUB rD = rX, rY  ->  NOP + ADDI/SUBI rD = rS, imm
// ============================================================================
// ADD and SUB fold only when rK is the right-hand source: the folded form
// is always `rS <op> imm`.
// `+` is not commutative in JS because either operand may coerce to string.
// `imm + rS` is left as LDINT+ADD to preserve operand evaluation order.

fn FusionMatch fusion_addi_subi_trigger(Instruction trigger, void* ctx) {
    FusionMatch m;
    if (trigger.op != Opcode.LDINT) { return m; }
    int imm = trigger.get_sbc();
    if (imm < -128 || imm > 127) { return m; }
    m.matched  = true;
    m.dest_reg = (uint)trigger.a;      // rK: the scratch register holding the literal
    m.imm      = (uint)(ichar)imm;
    return m;
}

fn FusionMatch fusion_addi_subi_consumer(Instruction trigger, Instruction consumer, uint rK, void* ctx) {
    FusionMatch m;
    bool is_add = consumer.op == Opcode.ADD;
    bool is_sub = consumer.op == Opcode.SUB;
    if (!is_add && !is_sub) { return m; }

    uint rD = (uint)consumer.a;
    uint rX = (uint)consumer.b;
    uint rY = (uint)consumer.c;

    // Both operators need `rX <op> rK`: the immediate must be the right-hand
    // source, because that is the only order ADDI/SUBI can express.
    if (rY != rK || rX == rK) { return m; }
    uint rS = rX;

    m.matched    = true;
    m.rewrite_op = is_sub ? Opcode.SUBI : Opcode.ADDI;
    m.dest_reg   = rD;
    m.src_reg    = rS;
    // Re-decode the immediate directly rather than threading it through
    // FusionMatch.dest_reg's caller, trigger.get_sbc() was already
    // range-checked to [-128,127] by fusion_addi_subi_trigger.
    m.imm        = (uint)(ichar)trigger.get_sbc();
    return m;
}

const FusionRule FUSION_ADDI_SUBI = {
    .trigger  = &fusion_addi_subi_trigger,
    .consumer = &fusion_addi_subi_consumer,
};

// Run the declarative ADDI/SUBI fusion over code[0..code_count).
fn void fuse_addi_subi(Instruction* code, uint code_count, bool* jump_targets) {
    run_fusion_rule(code, code_count, jump_targets, FUSION_ADDI_SUBI);
}

// ============================================================================
// Rule: LDCONST rK, idx  +  GETPROP ra = rb, rK  ->  NOP + GETPROPC ra = rb, idx
// ============================================================================

fn FusionMatch fusion_getpropc_trigger(Instruction trigger, void* ctx) {
    FusionMatch m;
    if (trigger.op != Opcode.LDCONST) { return m; }
    uint idx = trigger.get_bc();
    if (idx > 255) { return m; }
    TVal* constants = (TVal*)ctx;
    if (!constants[idx].is_string()) { return m; }
    m.matched  = true;
    m.dest_reg = (uint)trigger.a;   // rK: scratch register holding key
    m.imm      = idx;
    return m;
}

fn FusionMatch fusion_getpropc_consumer(Instruction trigger, Instruction consumer, uint rK, void* ctx) {
    FusionMatch m;
    if (consumer.op != Opcode.GETPROP) { return m; }
    if ((uint)consumer.c != rK) { return m; }

    m.matched    = true;
    m.rewrite_op = Opcode.GETPROPC;
    m.dest_reg   = (uint)consumer.a;
    m.src_reg    = (uint)consumer.b;
    m.imm        = trigger.get_bc();
    return m;
}

const FusionRule FUSION_GETPROPC = {
    .trigger  = &fusion_getpropc_trigger,
    .consumer = &fusion_getpropc_consumer,
};

// Run the declarative GETPROPC fusion over code[0..code_count).
fn void fuse_getpropc(Instruction* code, uint code_count, bool* jump_targets, TVal* constants) {
    run_fusion_rule(code, code_count, jump_targets, FUSION_GETPROPC, (void*)constants);
}

// ============================================================================
// 3-slot fusion driver: fixed physically-adjacent triple, middle slot rewrite
// ============================================================================

// Result of matching a 3-slot fusion window.
struct Fusion3Match {
    bool   matched;
    Opcode rewrite_op;   // opcode to install at the middle slot
    uint   reg;          // shared register (dest_reg field of the rewrite)
    uint   imm;          // immediate baked into the rewrite (e.g. a name index)
}

// Given three physically-adjacent instructions, report whether they fuse.
alias Fusion3MatchFn = fn Fusion3Match(Instruction slot0, Instruction slot1, Instruction slot2, void* ctx);

struct Fusion3Rule {
    Fusion3MatchFn match;
}

// Run one 3-slot fusion rule over the instruction stream.
fn void run_fusion3_rule(Instruction* code, uint code_count, Fusion3Rule rule, void* ctx = null) {
    if (code_count < 3) { return; }
    for (uint i = 0; i + 2 < code_count; i++) {
        Fusion3Match m = rule.match(code[i], code[i + 1], code[i + 2], ctx);
        if (!m.matched) { continue; }

        code[i]     = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
        code[i + 1] = bytecode::make_a_bc(m.rewrite_op, m.reg, m.imm);
        code[i + 2] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
    }
}

// ============================================================================
// Rule: GETVAR r,name + INC/DEC r + PUTVAR r,name  ->  NOP + INC_VAR/DEC_VAR r,name + NOP
// ============================================================================

fn Fusion3Match fusion_inc_dec_var_match(Instruction slot0, Instruction slot1, Instruction slot2, void* ctx) {
    Fusion3Match m;
    if (slot0.op != Opcode.GETVAR) { return m; }
    if (slot1.op != Opcode.INC && slot1.op != Opcode.DEC) { return m; }
    if (slot2.op != Opcode.PUTVAR) { return m; }

    uint reg_a = (uint)slot0.a;
    if ((uint)slot1.a != reg_a || (uint)slot2.a != reg_a) { return m; }

    uint name0 = slot0.get_bc();
    uint name2 = slot2.get_bc();
    uint const_count = *((uint*)ctx);
    if (name0 != name2 || name0 >= const_count) { return m; }

    m.matched    = true;
    m.rewrite_op = (slot1.op == Opcode.INC) ? Opcode.INC_VAR : Opcode.DEC_VAR;
    m.reg        = reg_a;
    m.imm        = name0;
    return m;
}

const Fusion3Rule FUSION_INC_DEC_VAR = {
    .match = &fusion_inc_dec_var_match,
};

// Run the declarative INC_VAR/DEC_VAR fusion over code[0..code_count).
fn void fuse_inc_dec_var(Instruction* code, uint code_count, uint const_count) {
    run_fusion3_rule(code, code_count, FUSION_INC_DEC_VAR, (void*)&const_count);
}

// ============================================================================
// Jump-aware fusion driver: compare + IF_FALSE/IF_TRUE -> fused compare-branch
// ============================================================================
//
// This is the jump-fusing driver, structurally distinct from the two
// register-baking drivers above. It rewrites the compare slot into a fused
// compare-and-branch and NOPs the branch slot, which means it must reason
// about control flow (jump targets, branch offsets, both post-branch paths),
// not just a dying scratch register. It owns, once, all the machinery the
// original hand-written pass re-derived inline:
//   - a whole-function jump-target bitset (a fusion is illegal when the branch
//     slot is itself a jump target)
//   - dual-path liveness: the compare-result register must be dead on BOTH the
//     fall-through and the taken-branch path (after fusion the compare is gone,
//     so a later read of its result register would see a stale value)
//   - the bridge correction (B23/B26/B28): when the branch chains into another
//     forward IF_FALSE/IF_TRUE (an `&&`/`||` continuation), the fused offset
//     must reach past it; a *backward* continuation is a loop back-edge and
//     must NOT be treated as a bridge
//   - the short-circuit skip guard (B27): a branch whose target is preceded by
//     an LDREG writing the result register is materializing the operator's
//     value; fusing would drop it
//   - alias preservation: when the result register aliases a compare operand,
//     the taken-branch path legitimately keeps the pre-compare value
//   - signed-8-bit offset fit
//
// A rule is pure data: the compare opcode it triggers on, and the fused op to
// install for each branch direction. Relational (LT/LE/GT/GE) and strict
// equality (SEQ/SNEQ) rules share every line of the driver, adding a compare
// form is a table entry, not a new hand-written scan.
//
// NOT included: loose EQ/NEQ. Those coerce operands via abstract_eq, which can
// call user code and throw; a fused branch would have to replicate the
// needs_restart/throw dance and is deliberately out of scope here.

// Compare to branch fusion rule.
struct CmpBranchRule {
    Opcode cmp_op;
    Opcode fused_if_false;
    Opcode fused_if_true;
}

// Compare to branch fusion table.
const CmpBranchRule[8] CMP_BRANCH_RULES = {
    { Opcode.LT,   Opcode.JMP_NLT,  Opcode.JMP_LT   },
    { Opcode.LE,   Opcode.JMP_NLE,  Opcode.JMP_LE   },
    { Opcode.GT,   Opcode.JMP_NGT,  Opcode.JMP_GT   },
    { Opcode.GE,   Opcode.JMP_NGE,  Opcode.JMP_GE   },
    { Opcode.SEQ,  Opcode.JMP_SNEQ, Opcode.JMP_SEQ  },
    { Opcode.SNEQ, Opcode.JMP_SEQ,  Opcode.JMP_SNEQ },
    { Opcode.EQ,   Opcode.NOP,      Opcode.NOP      },  // not fused: loose equality coersions can throw
    { Opcode.NEQ,  Opcode.NOP,      Opcode.NOP      },  // not fused
};

// Look up the fused opcode for a (compare, branch-direction) pair.
fn Opcode cmp_branch_fused_op(Opcode cmp_op, bool is_if_false) {
    foreach (&rule : CMP_BRANCH_RULES) {
        if (rule.cmp_op == cmp_op) {
            Opcode fused = is_if_false ? rule.fused_if_false : rule.fused_if_true;
            return fused;
        }
    }
    return Opcode.NOP;
}

// Scan basic-block-local range [start, code_count) and report whether reg is read before being overwritten.
fn bool cmp_result_live_from(Instruction* code, uint code_count, bool* jump_targets,
                             uint start, uint reg, bool skip_first_target) {
    int join_pc = -1;
    for (uint j = start; j < code_count; j++) {
        if (jump_targets[j] && !(skip_first_target && j == start)) {
            Instruction tj = code[j];
            Opcode top = tj.op;
            if (top == Opcode.IF_TRUE || top == Opcode.IF_FALSE) {
                if ((uint)tj.a == reg) { return true; }
            } else if (bytecode::get_op_format(top) == OpFormat.ABC) {
                if (fusion_abc_reads_reg(tj, reg)) { return true; }
            }
            continue;
        }
        Instruction jns = code[j];
        Opcode jop = jns.op;
        if (jop == Opcode.RET || jop == Opcode.RETUNDEF
            || jop == Opcode.RET_GEN || jop == Opcode.RETUNDEF_GEN
            || jop == Opcode.THROW || jop == Opcode.JUMP) {
            return false;
        }
        if (jop == Opcode.IF_TRUE || jop == Opcode.IF_FALSE) {
            if ((uint)jns.a == reg) { return true; }
            int t = fusion_conditional_branch_target(code, j);
            if (t > join_pc) { join_pc = t; }
            continue;
        }
        OpFormat jfmt = bytecode::get_op_format(jop);
        if (jfmt == OpFormat.ABC) {
            if (fusion_abc_reads_reg(jns, reg)) { return true; }
        }
        int bt = fusion_conditional_branch_target(code, j);
        if (bt > join_pc) { join_pc = bt; }
        if ((int)j >= join_pc && jfmt != OpFormat.WIDE_SABC && jfmt != OpFormat.WIDE_ABC) {
            if ((uint)jns.a == reg) { return false; }
        }
    }
    return false;
}

// Run all compare to branch fusions over code[0..code_count).
fn void run_cmp_branch_fusion(Instruction* code, uint code_count, bool* jump_targets) {
    if (code_count < 2) { return; }

    build_jump_targets(code, code_count, jump_targets);

    for (uint i = 0; i + 1 < code_count; i++) {
        Opcode cmp_op = code[i].op;
        bool is_if_false = (code[i + 1].op == Opcode.IF_FALSE);
        bool is_if_true  = (code[i + 1].op == Opcode.IF_TRUE);
        if (!is_if_false && !is_if_true) { continue; }

        Opcode fused_op = cmp_branch_fused_op(cmp_op, is_if_false);
        if (fused_op == Opcode.NOP) { continue; }

        uint rA = (uint)code[i].a;
        if ((uint)code[i + 1].a != rA) { continue; }

        if (jump_targets[i + 1]) { continue; }

        int sbx = code[i + 1].get_sbc();

        // Bridge correction: if target is a forward IF_FALSE/IF_TRUE on rA, extend past it.
        int bridge_sbx = 0;
        uint bridge_slot = (uint)((int)i + 2 + sbx);
        if (bridge_slot < code_count) {
            Opcode bop = code[bridge_slot].op;
            if ((bop == Opcode.IF_FALSE || bop == Opcode.IF_TRUE)
                && (uint)code[bridge_slot].a == rA) {
                int cand = code[bridge_slot].get_sbc();
                if (cand > 0) { bridge_sbx = cand; }
            }
        }

        // Short-circuit skip guard: if preceding instruction is LDREG writing rA, do not fuse.
        uint skip_tgt = (uint)((int)i + 2 + sbx + bridge_sbx + (bridge_sbx != 0 ? 1 : 0));
        if (skip_tgt >= 1 && skip_tgt < code_count) {
            Instruction ti = code[skip_tgt - 1];
            if (ti.op == Opcode.LDREG && (uint)ti.a == rA) { continue; }
        }
        int fused_off = sbx + 1 + bridge_sbx + (bridge_sbx != 0 ? 1 : 0);

        // Fall-through path: rA must be dead from i+2.
        if (cmp_result_live_from(code, code_count, jump_targets, i + 2, rA, false)) { continue; }

        // Taken-branch path: rA must be dead from branch target, unless rA aliases a
        // source register (preserving the operand value). If the target is an IF_TRUE/
        // IF_FALSE reading rA, it expects the boolean compare result rather than the
        // operand value, so the alias exception does not apply.
        uint rB = (uint)code[i].b;
        uint rC = (uint)code[i].c;
        bool ra_aliases_src = (rA == rB || rA == rC);
        int tgt_raw = (int)i + 2 + sbx;
        if (tgt_raw >= 0 && (uint)tgt_raw < code_count) {
            Instruction tgt_insn = code[(uint)tgt_raw];
            bool tgt_is_bool_branch = (tgt_insn.op == Opcode.IF_TRUE || tgt_insn.op == Opcode.IF_FALSE)
                && (uint)tgt_insn.a == rA;
            if (tgt_is_bool_branch) { continue; }
            if (!ra_aliases_src) {
                if (cmp_result_live_from(code, code_count, jump_targets, (uint)tgt_raw, rA, true)) { continue; }
            }
        }

        if (fused_off < -128 || fused_off > 127) { continue; }

        code[i]     = bytecode::make_abc(fused_op, (uint)(char)fused_off, rB, rC);
        code[i + 1] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
    }
}

// Fuse GETGLOBAL_PRIM + PUTGLOBAL_PRIM into a two-word MOVE_GG superinstruction.
// Word 1: MOVE_GG, BC = dst name. Word 2: kept NOP, BC = src name.
fn void run_move_gg_fusion(Instruction* code, uint code_count, bool* jump_targets) {
    if (code_count < 2) { return; }

    build_jump_targets(code, code_count, jump_targets);

    for (uint i = 0; i + 1 < code_count; i++) {
        if (code[i].op != Opcode.GETGLOBAL_PRIM) { continue; }
        if (code[i + 1].op != Opcode.PUTGLOBAL_PRIM) { continue; }

        uint rX = (uint)code[i].a;
        if ((uint)code[i + 1].a != rX) { continue; }

        // The second word must not be a jump target.
        if (jump_targets[i + 1]) { continue; }

        // rX must be dead after the pair.
        if (fusion_reg_live_from(code, code_count, i + 2, rX)) { continue; }

        uint dst_name = code[i + 1].get_bc();
        uint src_name = code[i].get_bc();

        code[i]     = bytecode::make_a_bc(Opcode.MOVE_GG, 0, dst_name);
        code[i + 1] = bytecode::make_a_bc(Opcode.NOP, 0, src_name);
    }
}

// Fuse GETGLOBAL_PRIM + JMP_LT into a two-word JMP_LT_G superinstruction.
// Word 1: JMP_LT_G, A = offset, B = surviving register operand.
// Word 2: kept NOP, BC = global name index.
fn void run_jmp_lt_g_fusion(Instruction* code, uint code_count, bool* jump_targets) {
    if (code_count < 2) { return; }

    build_jump_targets(code, code_count, jump_targets);

    for (uint i = 0; i + 1 < code_count; i++) {
        if (code[i].op != Opcode.GETGLOBAL_PRIM) { continue; }
        if (code[i + 1].op != Opcode.JMP_LT) { continue; }

        uint rX = (uint)code[i].a;
        if ((uint)code[i + 1].c != rX) { continue; }
        if ((uint)code[i + 1].b == rX) { continue; }

        if (jump_targets[i + 1]) { continue; }

        int off = (int)(ichar)code[i + 1].a;

        if (fusion_reg_live_from(code, code_count, i + 2, rX)) { continue; }
        int tgt = (int)i + 2 + off;
        if (tgt < 0 || (uint)tgt >= code_count) { continue; }
        if (fusion_reg_live_from(code, code_count, (uint)tgt, rX)) { continue; }

        uint name_idx = code[i].get_bc();

        code[i]     = bytecode::make_abc(Opcode.JMP_LT_G, (uint)(char)(ichar)off,
                                         (uint)code[i + 1].b, 0);
        code[i + 1] = bytecode::make_a_bc(Opcode.NOP, 0, name_idx);
    }
}

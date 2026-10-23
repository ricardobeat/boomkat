// Declarative superinstruction-fusion framework.
//
// A fusion collapses a short instruction sequence that shares a scratch
// register into one superinstruction that bakes the scratch value in as an
// immediate or index, freeing the register and saving a dispatch. The shared
// driver `run_fusion_rule` provides the NOP-skipping that finds the consumer,
// the jump-target guard, and the dead-after-liveness scan that proves the
// scratch register can be discarded.
//
// Fusion rules keyed on a scratch register produced by LDINT/LDCONST/etc. must
// run AFTER copy-propagation. Copy-propagation NOPs out the LDREG moves the
// parser emits between a literal load and its use, so until they are gone the
// consumer is not adjacent and the rule finds no match. See FUSION_PHASE_NOTE
// for the order of every fusion-shaped pass.
module boomkat::compiler;

import boomkat::bytecode;
import boomkat::types;

// FUSION_PHASE_NOTE: order of the fusion-shaped passes in CompilerContext.finish().
//
//   1. GETVAR+INC/DEC+PUTVAR -> INC_VAR/DEC_VAR   (FUSION_INC_DEC_VAR; no scratch
//      register, so order-independent)
//   2. LDCONST+GETPROP -> GETPROPC                (FUSION_GETPROPC; the store form
//      LDCONST+PUTPROP -> PUTPROPC is FUSION_PUTPROPC; order-independent)
//   3. compare+IF_FALSE/IF_TRUE -> JMP_N*/JMP_*/JMP_SEQ/JMP_SNEQ
//      (order-independent and declarative, in this file: run_cmp_branch_fusion,
//      a distinct jump-aware driver using the caller's jump-target bitset
//      and dual-path liveness, with bridge/short-circuit corrections,
//      table-driven over the compare form (CMP_BRANCH_RULES). The same
//      driver folds LNOT + IF_TRUE/IF_FALSE into the inverted branch.)
//   4. copy-propagation (LDREG rT=rX substitution), MUST run before any
//      rule whose trigger's consumer may be separated from it by a
//      parser-emitted LDREG move (rule 5 depends on this). Hand-written,
//      deliberately: pure copy-prop/DCE, not a superinstruction fusion
//      (no new opcode is ever installed).
//   5. LDINT+binop / LDINT+JMP_* -> <op>I immediate forms (declarative, this file)
//   6. LDNULL/LDUNDEF + JMP_EQ/JMP_NEQ -> JMP_NULL/JMP_NNULL (declarative,
//      this file: FUSION_NULL_BRANCH; runs after rule 5, on the branches rule 3
//      produced)
//
// Rule 4 and the dead-LDREG-before-INC/DEC DCE pass are the only hand-written
// passes left in context.c3. See plans/058-fusion-rule-framework.md for why.

// Result of matching a fusion's trigger+consumer pair, produced by a
// rule's `match_consumer` callback.
struct FusionMatch {
    bool   matched;
    Opcode rewrite_op;   // opcode to install at the consumer's slot
    uint   dest_reg;     // destination register of the rewritten instruction
    uint   src_reg;      // surviving source register (register operand)
    uint   imm;          // immediate baked into the rewritten instruction (raw bc bits)
}

// A trigger predicate: does this instruction introduce a fusable scratch
// value (e.g. an in-range LDINT), and what register/immediate does it
// carry? Returning `matched = false` skips this instruction as a trigger.
// `ctx` is an opaque per-rule pointer threaded through unchanged from
// `run_fusion_rule`'s caller (e.g. the constant pool, for rules whose
// guard depends on more than the raw instruction bits); rules that don't
// need it simply ignore the parameter.
alias FusionTriggerFn = fn FusionMatch(Instruction trigger, void* ctx);

// A consumer predicate: given the already-validated trigger and a
// candidate consumer instruction (the next non-NOP instruction after the
// trigger), does it consume the trigger's scratch register in a fusable
// way? On match, fills in rewrite_op/dest_reg/src_reg/imm.
alias FusionConsumerFn = fn FusionMatch(Instruction trigger, Instruction consumer, uint scratch_reg, void* ctx);

// One declarative fusion rule: {trigger predicate, consumer predicate}.
// The shared driver (`run_fusion_rule`) owns NOP-skipping, the jump-target
// guard and the dead-after-liveness scan; the rule only supplies the
// opcode-specific matching/rewrite logic.
struct FusionRule {
    FusionTriggerFn  trigger;
    FusionConsumerFn consumer;
    // Let the consumer sit up to FUSION_GAP_MAX instructions past the trigger,
    // behind straight-line instructions that never touch the scratch register.
    bool             gap;
}

// The longest run of transparent instructions a gap rule looks across.
const uint FUSION_GAP_MAX = 6;

// Can a gap rule's scan pass over `ins` while `reg` is held by its trigger? It
// must be straight-line code with no branch, and must neither read nor write
// `reg`. The listed opcodes all write their A register and read no register
// outside the ABC b and c fields, which is what makes the check below exact.
// Both gap rules' triggers are plain loads (a constant, or a `this` that cannot
// change), so moving one past a call that runs arbitrary code is safe.
fn bool fusion_transparent(Instruction ins, uint reg) {
    switch (ins.op) {
        case Opcode.GETGLOBAL:
        case Opcode.GETVAR:
        case Opcode.LDINT:
        case Opcode.LDCONST:
        case Opcode.LDUNDEF:
        case Opcode.LDNULL:
        case Opcode.LDTRUE:
        case Opcode.LDFALSE:
        case Opcode.LDTHIS:
        case Opcode.GETTHISC:
            return (uint)ins.a != reg;
        case Opcode.CALL:
        case Opcode.CALL_UNDEF_THIS:
            // The callee's frame slides over the registers from B up, so only
            // a register below the call window survives it.
            return (uint)ins.a != reg && reg < (uint)ins.b;
        case Opcode.LDREG:
        case Opcode.ADD:
        case Opcode.SUB:
        case Opcode.MUL:
        case Opcode.DIV:
        case Opcode.MOD:
        case Opcode.ADDI:
        case Opcode.SUBI:
        case Opcode.GETPROP:
        case Opcode.GETPROPC:
            return (uint)ins.a != reg && !fusion_abc_reads_reg(ins, reg);
        default:
            return false;
    }
}

// Does ABC-format instruction `ins` read `reg`, or conservatively pin it as
// live across an operand pattern this scan cannot model exactly?
//
// Not every ABC field is a register. CALL_VAR/CALL_GLOBAL encode B as an
// argument count and C as a name-constant index, and GETPROPC encodes C as a
// constant index. Comparing those raw values to a register number gives a
// false "live", which is safe but blocks fusion.
fn bool fusion_abc_reads_reg(Instruction ins, uint reg) {
    switch (ins.op) {
        case Opcode.SPREAD_PROJECTION:
            return reg == (uint)ins.b || reg == (uint)ins.a || reg == (uint)ins.a + 1;
        case Opcode.ARRAY_PATTERN_GUARD:
            return true;
        case Opcode.CLASS_SCALAR_GUARD:
            return reg >= (uint)ins.a && reg <= (uint)ins.a + 1 + (uint)ins.b;
        case Opcode.INIT_SLOT:
            return (uint)ins.a == reg || (uint)ins.c == reg;
        case Opcode.DESTRUCT_ARRAY_FAST:
            // A is the source register. B..B+C-1 are conditional outputs;
            // treating them as live here is a conservative barrier because
            // the opcode can refuse before writing any of them.
            return (uint)ins.a == reg
                || (ins.c > 0 && reg >= (uint)ins.b
                    && reg < (uint)ins.b + (uint)ins.c);
        case Opcode.DESTRUCT_ARRAY_REST_FAST:
            // A is the source; B..B+C are conditional outputs, including
            // the rest array in the final slot.
            return (uint)ins.a == reg
                || (reg >= (uint)ins.b && reg <= (uint)ins.b + (uint)ins.c);
        case Opcode.ITER_ENTRY_FAST:
            return reg == (uint)ins.b || reg == (uint)ins.c
                || reg == (uint)ins.a || reg == (uint)ins.a + 1;
        case Opcode.CALL_VAR:
        case Opcode.CALL_GLOBAL:
            // A = result/callee register, B = argc, C = name-constant index
            // (vm_calls.c3: `nargs = insn.b` and the callee resolves by name for
            // these two forms). Neither B nor C is a register, so neither can
            // make `reg` live. The arguments themselves sit in the contiguous
            // block ABOVE A and are written by the preceding argument-setup
            // instructions, which the scan sees in their own right; a scratch
            // register still live into that block is caught there. NOTE: CALL_S
            // is deliberately NOT in this carve-out, it decodes C as a
            // register (`ds.regs_base + insn.c`).
            return false;
        case Opcode.GETPROPC:
            // A = dst, B = src register, C = key-constant index.
            return (uint)ins.b == reg;
        case Opcode.LDREG:
        case Opcode.UNP:
        case Opcode.UNM:
        case Opcode.BNOT:
        case Opcode.LNOT:
        case Opcode.TYPEOF:
        case Opcode.VOID:
        case Opcode.TONUMERIC:
            // `A = op B`; C is unused and encoded 0.
            return (uint)ins.b == reg;
        case Opcode.CALL:
        case Opcode.TAILCALL_CALL:
            // A = result, B = callee, C = argument count (vm_calls.c3
            // try_fast_compiled_call). The call reads the callee, the receiver
            // slot after it and the C arguments after that.
            return reg >= (uint)ins.b && reg <= (uint)ins.b + 1 + (uint)ins.c;
        case Opcode.CALL_UNDEF_THIS:
        case Opcode.TAILCALL_UNDEF_THIS:
            // As CALL, but the receiver is undefined: the slot after the
            // callee is written, never read.
            return reg == (uint)ins.b || (reg >= (uint)ins.b + 2 && reg <= (uint)ins.b + 1 + (uint)ins.c);
        case Opcode.ADDI..Opcode.USHRI:
        case Opcode.JMP_NLTI..Opcode.JMP_SNEQI:
            // B = source register, C = immediate.
            return (uint)ins.b == reg;
        case Opcode.INITELEM:
            // A = array register, B = immediate element index, C = value register.
            return (uint)ins.a == reg || (uint)ins.c == reg;
        case Opcode.PUTPROPC:
            // A = object register, B = value register, C = key-constant index.
            return (uint)ins.a == reg || (uint)ins.b == reg;
        case Opcode.RET:
            // A = result register; B and C are unused.
            return (uint)ins.a == reg;
        case Opcode.RETUNDEF:
        case Opcode.LDTHIS:
        case Opcode.LDUNDEF:
        case Opcode.LDNULL:
        case Opcode.LDTRUE:
        case Opcode.LDFALSE:
            // No operands but the destination, so B and C are encoded 0 rather
            // than naming register 0.
            return false;
        case Opcode.GETTHISC:
            // A = dst, B unused, C = key-constant index.
            return false;
        case Opcode.PUTTHISC:
            // A = value register, B unused, C = key-constant index.
            return (uint)ins.a == reg;
        default:
            // Adding an opcode above is a correctness-critical claim about its
            // operand encoding, verified against the VM. CALL_S must never be
            // added, since it genuinely reads C as a register
            // (`ds.regs_base + insn.c`).
            //
            // A is a read unless the opcode is a confirmed write-only destination
            // (moveelim_a_is_write) or a compare-branch, whose A is an offset. PUTPROP
            // reads its object from A.
            return (uint)ins.b == reg || (uint)ins.c == reg
                || ((uint)ins.a == reg && !moveelim_a_is_write(ins.op) && !bytecode::is_cmp_branch(ins.op));
    }
}

// Scan forward from `start` (inclusive) and report whether `reg` is read
// before it is next overwritten, the shared "is this scratch register
// dead after the consumer" check every hand-written pass re-implements.
//
// IF_TRUE/IF_FALSE read field `a` (the condition register), so they are checked
// before the write rule. Only ABC-format opcodes have register operands in b/c.
// A_BC, A_SBX and WIDE operands are indices or offsets and are never read as
// registers.
//
// This is a linear scan, not a CFG walk. Reads found past a branch only
// over-report liveness, which is safe. Writes are different: a write inside
// the window a conditional branch can skip may not execute, so it cannot end
// the scan. `join_pc` is the furthest pending branch target; while the scan is
// before it, `A == reg` is not a kill. Treating such a write as a kill dropped
// the `r=1` store in `(o=1)-(r=1)<0 && (r=o)`.
fn bool fusion_reg_live_from(Instruction* code, uint code_count, uint start, uint reg) {
    int join_pc = -1;
    for (uint j = start; j < code_count; j++) {
        Instruction jns = code[j];
        Opcode jop = jns.op;
        // A NOP is encoded with A = 0, which must not count as a write of r0.
        if (jop == Opcode.NOP) { continue; }
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
        // WIDE forms and the compare-branch family hold a branch offset in A, so
        // their A is not a destination. Reading it as one ends the scan early on
        // a live register, which permits an unsafe fusion.
        OpFormat jfmt_w = bytecode::get_op_format(jop);
        if ((int)j >= join_pc && jfmt_w != OpFormat.WIDE_SABC && jfmt_w != OpFormat.WIDE_ABC && !bytecode::is_cmp_branch(jop)) {
            if ((uint)jns.a == reg) { return false; }   // overwritten -> dead from here
        }
    }
    return false;
}

// If `code[j]` is a conditional branch, return the slot it can skip TO;
// otherwise return -1. Used by the forward dead-register scans to bound how
// far a branch's "this write might not execute" effect reaches.
//
// A conditional branch at j makes the slots in (j, target) skippable: control
// may jump straight over them. A write in that window therefore kills the
// scanned register only on the fall-through path and must not end the scan.
// Once the scan reaches `target` the two paths have rejoined, so writes are
// unconditional again and kills are valid once more. Callers track the maximum
// target seen so far, which handles nested/overlapping branches: the window
// stays open until the scan passes every pending join point.
//
// A BACKWARD branch (target <= j, i.e. a loop back-edge) opens no window: it
// skips nothing ahead of the scan. It is reported as its own slot so the
// caller's running maximum is unaffected.
//
// Unconditional transfers (JUMP/BREAK/CONTINUE/RET/THROW) are deliberately not
// here: they never fall through, so a scan continuing past one is already
// looking at unrelated code, which the jump-target and A-field guards handle.
fn int fusion_conditional_branch_target(Instruction* code, uint j) {
    Instruction ins = code[j];
    int off;
    switch (ins.op) {
        case Opcode.IF_TRUE:
        case Opcode.IF_FALSE:
            off = ins.get_sbc();
        case Opcode.JMP_NLT..Opcode.JMP_SNEQI:
            off = (int)(ichar)ins.a;
        default:
            return -1;
    }
    return (int)j + 1 + off;
}

// The slot any pc-relative branch at `code[j]` can transfer to, conditional or
// not, or -1. Forward scans use it to spot loop back-edges.
fn int fusion_branch_target(Instruction* code, uint j) {
    switch (code[j].op) {
        case Opcode.JUMP:
        case Opcode.BREAK:
        case Opcode.CONTINUE:
            return (int)j + 1 + code[j].get_sabc();
        default:
            return fusion_conditional_branch_target(code, j);
    }
}

// Whether some path through slots [from, to), entered at `from` the way a loop
// back-edge re-runs them, reads `reg` before writing it. The walk follows both
// successors of every branch, so a write on one arm kills only that arm. A path
// that reaches `to` or beyond has passed the copy that sets `reg`; one that
// branches back before `from`, or meets a TRY, is reported as a read, the safe
// answer.
fn bool fusion_reg_read_before_write(Instruction* code, uint from, uint to, uint reg) {
    if (from >= to) { return false; }
    bool found = false;
    @pool() {
        uint span = to - from;
        bool[] seen = mem::temp_array(bool, span);
        uint[] stack = mem::temp_array(uint, span);
        uint sp = 0;
        stack[sp++] = from;
        seen[0] = true;
        while (sp > 0 && !found) {
            uint j = stack[--sp];
            Instruction jns = code[j];
            Opcode jop = jns.op;
            OpFormat jfmt = bytecode::get_op_format(jop);
            bool reads;
            bool writes = false;
            if (jop == Opcode.NOP) {
                reads = false;
            } else if (jop == Opcode.TRY) {
                reads = true;
            } else if (jop == Opcode.IF_TRUE || jop == Opcode.IF_FALSE) {
                reads = (uint)jns.a == reg;
            } else if (jfmt == OpFormat.ABC) {
                reads = fusion_abc_reads_reg(jns, reg);
                writes = !reads && (uint)jns.a == reg && moveelim_a_is_write(jop);
            } else if (jfmt == OpFormat.WIDE_SABC || jfmt == OpFormat.WIDE_ABC) {
                reads = false;
            } else {
                reads = (uint)jns.a == reg && !moveelim_a_is_write(jop);
                writes = (uint)jns.a == reg && !reads;
            }
            if (reads) { found = true; break; }
            if (writes) { continue; }

            int[2] next = { -1, -1 };
            switch (jop) {
                case Opcode.RET:
                case Opcode.RETUNDEF:
                case Opcode.RET_GEN:
                case Opcode.RETUNDEF_GEN:
                case Opcode.THROW:
                    break;
                case Opcode.JUMP:
                case Opcode.BREAK:
                case Opcode.CONTINUE:
                    next[0] = fusion_branch_target(code, j);
                default:
                    next[0] = (int)j + 1;
                    next[1] = fusion_conditional_branch_target(code, j);
            }
            foreach (s : next) {
                if (s < 0) { continue; }
                if (s < (int)from) { found = true; break; }
                if (s >= (int)to || seen[(uint)s - from]) { continue; }
                seen[(uint)s - from] = true;
                stack[sp++] = (uint)s;
            }
        }
    };
    return found;
}

// Mark every instruction slot that a branch, loop exit or exception handler can
// transfer control to. `jump_targets` is a caller-provided buffer of at least
// `code_count` bools and is fully overwritten.
//
// Every fusion pass needs this predicate, so it lives here once. A pass that
// skips it miscompiles a trigger on one arm of a branch whose consumer is the
// join point. Every pc-relative form belongs in the switch below: JUMP/BREAK/
// CONTINUE (WIDE_SABC), IF_TRUE/IF_FALSE (A_SBX), the JMP_* family (8-bit
// offset in A), and TRY's catch and finally offsets. A finally's ENDFINALLY is
// found by a runtime scan and is never a fusion target, so it needs no arm.
fn void build_jump_targets(Instruction* code, uint code_count, bool* jump_targets) {
    for (uint i = 0; i < code_count; i++) { jump_targets[i] = false; }
    for (uint i = 0; i < code_count; i++) {
        Instruction ins = code[i];
        switch (ins.op) {
            case Opcode.INLINE_GUARD:
            case Opcode.INLINE_READ_GUARD:
            case Opcode.INLINE_NUM_GUARD:
            case Opcode.INLINE_GETFREE:
            case Opcode.INLINE_GETCAP:
                if (i + 2 < code_count) jump_targets[i + 2] = true;
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
            case Opcode.JMP_NLT..Opcode.JMP_SNEQI: {
                // ABC form: signed 8-bit offset in field A.
                int off = (int)(ichar)ins.a;
                int tgt = (int)i + 1 + off;
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

// Run one fusion rule over the whole instruction stream. Finds the consumer by
// skipping NOPs, checks the scratch register is dead after it, enforces the
// jump-target guard, and emits the NOP + rewrite.
//
// Jump-target safety:
//   - NOP-ing the trigger slot is always safe: a jump landing there falls
//     through into the rewritten consumer, which no longer reads the register.
//   - The consumer slot must NOT be a jump target. The rewrite bakes in the
//     trigger's value, which is only correct on the fallthrough path.
//     `5 + (c ? 10 : 20)` compiles to
//     `LDINT r4,10 / JUMP join / LDINT r4,20 / join: ADD r2=r2,r4`; without
//     this guard every condition yields 20.
//
// `jump_targets` is built by the caller. These rules preserve branch targets,
// so consecutive passes share it. Inlining specializes the constant rule's
// callbacks instead of making indirect calls for every instruction.
fn void run_fusion_rule(Instruction* code, uint code_count, bool* jump_targets, FusionRule rule, void* ctx = null) @inline {

    for (uint i = 0; i < code_count; i++) {
        FusionMatch tm = rule.trigger(code[i], ctx);
        if (!tm.matched) { continue; }

        // Any slot from just after the trigger through the consumer being a
        // jump target means control can reach the consumer without having
        // executed the trigger (a NOP in between is fallthrough into the
        // consumer, so it is exactly as unsafe as the consumer itself).
        uint k = i;
        uint skipped = 0;
        FusionMatch cm;
        while (true) {
            k++;
            while (k < code_count && code[k].op == Opcode.NOP) {
                if (jump_targets[k]) { k = code_count; }
                else { k++; }
            }
            if (k >= code_count || jump_targets[k]) { cm.matched = false; break; }
            cm = rule.consumer(code[i], code[k], tm.dest_reg, ctx);
            if (cm.matched || !rule.gap || skipped++ >= FUSION_GAP_MAX
                || !fusion_transparent(code[k], tm.dest_reg)) { break; }
        }
        if (!cm.matched) { continue; }

        if (fusion_reg_live_from(code, code_count, k + 1, tm.dest_reg)) { continue; }

        code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
        code[k] = bytecode::make_abc(cm.rewrite_op, cm.dest_reg, cm.src_reg, cm.imm);
    }
}

// ============================================================================
// Rule: LDINT rK, imm  +  rD = rX <op> rY  ->  NOP + <op>I rD = rS, imm
// ============================================================================
//
// `<op>` is any operator with an immediate form (bytecode::IMM_FORMS). The
// immediate must fit the form's 8-bit field (bytecode::imm_fits).
//
// The immediate is normally the right operand, giving `rS <op> imm`. `+` is not
// commutative: ECMA-262 AdditiveOperator makes it concatenation when either
// operand is a string, and an immediate form cannot record which side the
// immediate came from. Folding `imm + rS` would turn `1 + a` with a = "A" into
// "A1". `imm + rS` stays LDINT+ADD. MUL, BAND, BOR and BXOR are commutative, so
// they fold an immediate on the left too.

fn FusionMatch fusion_imm_binop_trigger(Instruction trigger, void* ctx) {
    FusionMatch m;
    if (trigger.op != Opcode.LDINT) { return m; }
    int imm = trigger.get_sbc();
    if (imm < -128 || imm > 255) { return m; }
    m.matched  = true;
    m.dest_reg = (uint)trigger.a;      // rK: the scratch register holding the literal
    return m;
}

fn FusionMatch fusion_imm_binop_consumer(Instruction trigger, Instruction consumer, uint rK, void* ctx) {
    FusionMatch m;
    Opcode imm_op = bytecode::imm_form(consumer.op);
    int imm = trigger.get_sbc();
    if (imm_op == Opcode.NOP || !bytecode::imm_fits(imm_op, imm)) { return m; }

    uint rX = (uint)consumer.b;
    uint rY = (uint)consumer.c;
    if (rX == rK && rY == rK) { return m; }
    if (rY == rK) { m.src_reg = rX; }
    else if (rX == rK && bytecode::imm_form_commutes(consumer.op)) { m.src_reg = rY; }
    else { return m; }

    m.matched    = true;
    m.rewrite_op = imm_op;
    m.dest_reg   = (uint)consumer.a;
    m.imm        = (uint)imm & 0xFF;
    return m;
}

const FusionRule FUSION_IMM_BINOP = {
    .trigger  = &fusion_imm_binop_trigger,
    .consumer = &fusion_imm_binop_consumer,
};

// Run the immediate-operand fusion over `code[0..code_count)`.
fn void fuse_imm_binop(Instruction* code, uint code_count, bool* jump_targets) {
    run_fusion_rule(code, code_count, jump_targets, FUSION_IMM_BINOP);
}

// ============================================================================
// Rule: LDCONST rK, idx  +  GETPROP ra = rb, rK  ->  NOP + GETPROPC ra = rb, idx
// ============================================================================
//
// `ctx` is the constant pool (`TVal*`). The trigger checks `idx <= 255`
// (GETPROPC.c is 8 bits) and that the constant is a string (GETPROPC assumes
// string keys).
//
// The dead-after scan (`fusion_reg_live_from`) covers the case where rK is kept
// alive for a following PUTPROP/DELPROP, since that is just a later read of rK.

fn FusionMatch fusion_getpropc_trigger(Instruction trigger, void* ctx) {
    FusionMatch m;
    if (trigger.op != Opcode.LDCONST) { return m; }
    uint idx = trigger.get_bc();
    if (idx > 255) { return m; }
    TVal* constants = (TVal*)ctx;
    if (!constants[idx].is_string()) { return m; }
    m.matched  = true;
    m.dest_reg = (uint)trigger.a;   // rK: the scratch register holding the key
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

// Run the GETPROPC fusion over `code[0..code_count)`. `constants` is the
// function's constant pool.
fn void fuse_getpropc(Instruction* code, uint code_count, bool* jump_targets, TVal* constants) {
    run_fusion_rule(code, code_count, jump_targets, FUSION_GETPROPC, (void*)constants);
}

// ============================================================================
// Rule: LDCONST rK, idx  +  PUTPROP ra = rK, rc  ->  NOP + PUTPROPC ra = rc, idx
// ============================================================================
//
// The store form of the GETPROPC rule: the key constant moves into C, and the
// value register into B. The object register stays in A, which PUTPROP also
// reads rather than writes. A key register that is also the object or the
// value is left alone.

fn FusionMatch fusion_putpropc_consumer(Instruction trigger, Instruction consumer, uint rK, void* ctx) {
    FusionMatch m;
    if (consumer.op != Opcode.PUTPROP) { return m; }
    if ((uint)consumer.b != rK || (uint)consumer.a == rK || (uint)consumer.c == rK) { return m; }

    m.matched    = true;
    m.rewrite_op = Opcode.PUTPROPC;
    m.dest_reg   = (uint)consumer.a;
    m.src_reg    = (uint)consumer.c;
    m.imm        = trigger.get_bc();
    return m;
}

// The key is loaded before the right-hand side, so PUTPROP usually trails the
// LDCONST by the value's instructions. The gap covers that.
const FusionRule FUSION_PUTPROPC = {
    .trigger  = &fusion_getpropc_trigger,
    .consumer = &fusion_putpropc_consumer,
    .gap      = true,
};

fn void fuse_putpropc(Instruction* code, uint code_count, bool* jump_targets, TVal* constants) {
    run_fusion_rule(code, code_count, jump_targets, FUSION_PUTPROPC, (void*)constants);
}

// ============================================================================
// Rule: LDTHIS rT  +  GETPROPC ra = rT, idx  ->  NOP + GETTHISC ra, idx
// ============================================================================
//
// `this.name` reads the frame's `this` without a register: the instruction pair
// collapses when rT is not read again. The pair is adjacent, so an
// uninitialized `this` throws at the same point it did before.

fn FusionMatch fusion_this_trigger(Instruction trigger, void* ctx) {
    FusionMatch m;
    if (trigger.op != Opcode.LDTHIS) { return m; }
    m.matched  = true;
    m.dest_reg = (uint)trigger.a;
    return m;
}

fn FusionMatch fusion_getthisc_consumer(Instruction trigger, Instruction consumer, uint rT, void* ctx) {
    FusionMatch m;
    if (consumer.op != Opcode.GETPROPC || (uint)consumer.b != rT) { return m; }
    m.matched    = true;
    m.rewrite_op = Opcode.GETTHISC;
    m.dest_reg   = (uint)consumer.a;
    m.imm        = (uint)consumer.c;
    return m;
}

const FusionRule FUSION_GETTHISC = {
    .trigger  = &fusion_this_trigger,
    .consumer = &fusion_getthisc_consumer,
};

fn void fuse_getthisc(Instruction* code, uint code_count, bool* jump_targets) {
    run_fusion_rule(code, code_count, jump_targets, FUSION_GETTHISC);
}

// ============================================================================
// Rule: LDTHIS rT  +  PUTPROPC rT = rV, idx  ->  NOP + PUTTHISC rV, idx
// ============================================================================
//
// The store form. The right-hand side runs between the two instructions, so a
// `this` that super() initializes there would be read after it instead of
// before; the caller runs this rule only for functions whose `this` is never
// uninitialized.

fn FusionMatch fusion_putthisc_consumer(Instruction trigger, Instruction consumer, uint rT, void* ctx) {
    FusionMatch m;
    if (consumer.op != Opcode.PUTPROPC || (uint)consumer.a != rT || (uint)consumer.b == rT) { return m; }
    m.matched    = true;
    m.rewrite_op = Opcode.PUTTHISC;
    m.dest_reg   = (uint)consumer.b;
    m.imm        = (uint)consumer.c;
    return m;
}

const FusionRule FUSION_PUTTHISC = {
    .trigger  = &fusion_this_trigger,
    .consumer = &fusion_putthisc_consumer,
    .gap      = true,
};

fn void fuse_putthisc(Instruction* code, uint code_count, bool* jump_targets) {
    run_fusion_rule(code, code_count, jump_targets, FUSION_PUTTHISC);
}

// ============================================================================
// 3-slot fusion driver: fixed physically-adjacent triple, middle slot rewrite
// ============================================================================
//
// The 2-slot rules drop a dying scratch register. GETVAR+INC/DEC+PUTVAR is a
// three-slot window over a live variable register that survives the fusion.
// Its slots are always adjacent, and correctness comes from matching all three,
// so it does not need the NOP-skip or liveness scan. It gets its own schema
// rather than a fit into FusionMatch.

// Result of matching a 3-slot fusion window.
struct Fusion3Match {
    bool   matched;
    Opcode rewrite_op;   // opcode to install at the middle slot
    uint   reg;          // the shared register (dest_reg field of the rewrite)
    uint   imm;          // immediate baked into the rewrite (e.g. a name index)
}

// Report whether three physically adjacent instructions fuse. There is no
// NOP-skipping. `ctx` is the same opaque pointer as in `FusionTriggerFn`.
alias Fusion3MatchFn = fn Fusion3Match(Instruction slot0, Instruction slot1, Instruction slot2, void* ctx);

struct Fusion3Rule {
    Fusion3MatchFn match;
}

// Run one 3-slot rule over the whole instruction stream. On match, slot0 and
// slot2 become NOPs and slot1 becomes the rewrite (A_BC: reg, imm). Slot1 is a
// valid landing point for jumps to slot0 and slot1, so no jump-target bitset is
// needed.
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
//
// `ctx` is the `const_count` bound (`uint*`). It rejects a name index the
// constant pool has not reached yet.

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

// Run the INC_VAR/DEC_VAR fusion over `code[0..code_count)`. `const_count`
// bounds the GETVAR/PUTVAR name index.
fn void fuse_inc_dec_var(Instruction* code, uint code_count, uint const_count) {
    run_fusion3_rule(code, code_count, FUSION_INC_DEC_VAR, (void*)&const_count);
}

// ============================================================================
// Jump-aware fusion driver: compare + IF_FALSE/IF_TRUE -> fused compare-branch
// ============================================================================
//
// The jump-fusing driver. It rewrites the compare slot into a fused
// compare-and-branch and NOPs the branch slot, so it reasons about control flow
// as well as the scratch register. It checks:
//   - the whole-function jump-target bitset: the branch slot must not be a target
//   - dual-path liveness: the compare result must be dead on both the
//     fall-through and the taken path
//   - the bridge correction (B23/B26/B28): a forward IF_FALSE/IF_TRUE on the same
//     register at the branch target (an `&&`/`||` continuation) is skipped by
//     the fused offset. A backward one is a loop back-edge and is not a bridge.
//   - the short-circuit skip guard (B27): a target preceded by an LDREG that
//     writes the result register materializes the operator's value and blocks
//     the fusion
//   - alias preservation: when the result register aliases a compare operand,
//     the taken path keeps the pre-compare value
//   - a signed 8-bit offset fit
//
// A rule is pure data: the compare opcode it triggers on, and the fused op to
// install for each branch direction. Relational (LT/LE/GT/GE) and strict
// equality (SEQ/SNEQ) rules share every line of the driver, adding a compare
// form is a table entry, not a new hand-written scan.
//
// Loose EQ/NEQ fuse to JMP_EQ/JMP_NEQ. Their switch handler runs abstract_eq,
// which can call user code and throw, with the same restart handling as the
// relational branches; the threaded handler takes only pairs that never coerce.

// One compare→branch fusion rule: `cmp_op` is the comparison opcode; the two
// fused ops are what to install when the following instruction is IF_FALSE
// (branch-when-compare-false) vs IF_TRUE (branch-when-compare-true).
struct CmpBranchRule {
    Opcode cmp_op;
    Opcode fused_if_false;
    Opcode fused_if_true;
}

// The full compare→branch fusion table. Relational forms map onto the
// existing JMP_N*/JMP_* opcodes; equality forms map onto JMP_SEQ/JMP_SNEQ and
// JMP_EQ/JMP_NEQ. Note the polarity: SEQ+IF_FALSE branches when NOT strictly
// equal (JMP_SNEQ) and SNEQ+IF_FALSE branches when strictly equal (JMP_SEQ).
const CmpBranchRule[8] CMP_BRANCH_RULES = {
    { Opcode.LT,   Opcode.JMP_NLT,  Opcode.JMP_LT   },
    { Opcode.LE,   Opcode.JMP_NLE,  Opcode.JMP_LE   },
    { Opcode.GT,   Opcode.JMP_NGT,  Opcode.JMP_GT   },
    { Opcode.GE,   Opcode.JMP_NGE,  Opcode.JMP_GE   },
    { Opcode.SEQ,  Opcode.JMP_SNEQ, Opcode.JMP_SEQ  },
    { Opcode.SNEQ, Opcode.JMP_SEQ,  Opcode.JMP_SNEQ },
    { Opcode.EQ,   Opcode.JMP_NEQ,  Opcode.JMP_EQ   },
    { Opcode.NEQ,  Opcode.JMP_EQ,   Opcode.JMP_NEQ  },
};

// Look up the fused opcode for a (compare, branch-direction) pair. Returns
// NOP (never a real fused op) when the compare op has no fusion rule or is a
// operation that does not fuse.
fn Opcode cmp_branch_fused_op(Opcode cmp_op, bool is_if_false) {
    foreach (&rule : CMP_BRANCH_RULES) {
        if (rule.cmp_op == cmp_op) {
            Opcode fused = is_if_false ? rule.fused_if_false : rule.fused_if_true;
            return fused;
        }
    }
    return Opcode.NOP;
}

// Scan [start, code_count) and report whether `reg` is read before it is
// overwritten. A jump target is probed for a read of `reg` and the scan
// continues. RET/THROW/JUMP end the block and count as dead. `skip_first_target`
// ignores the jump-target flag on the entry slot.
fn bool cmp_result_live_from(Instruction* code, uint code_count, bool* jump_targets,
                             uint start, uint reg, bool skip_first_target) {
    int join_pc = -1;
    for (uint j = start; j < code_count; j++) {
        if (jump_targets[j] && !(skip_first_target && j == start)) {
            // Probe this slot for a read of reg only, then keep scanning.
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
            return false;   // block ends without reading reg → dead
        }
        if (jop == Opcode.NOP) { continue; }   // A = 0 is padding, not a write of r0
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
        // A write inside a conditional branch's skip window is not a kill.
        if ((int)j >= join_pc && jfmt != OpFormat.WIDE_SABC && jfmt != OpFormat.WIDE_ABC) {
            if ((uint)jns.a == reg) { return false; }   // overwritten → dead
        }
    }
    return false;
}

// Drop a JUMP to the next instruction. A switch whose last clause falls out of
// its body leaves one.
fn void drop_jumps_to_next(Instruction* code, uint code_count) {
    for (uint i = 0; i < code_count; i++) {
        if (code[i].op == Opcode.JUMP && code[i].get_sabc() == 0) { code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0); }
    }
}

// Whether the code holds a compare followed by a branch that
// run_cmp_branch_fusion could fuse, which is what its liveness is for.
fn bool has_cmp_branch_pair(Instruction* code, uint code_count) {
    for (uint i = 0; i + 1 < code_count; i++) {
        Opcode next = code[i + 1].op;
        if (next != Opcode.IF_FALSE && next != Opcode.IF_TRUE) continue;
        if (code[i].op == Opcode.LNOT) return true;
        if (cmp_branch_fused_op(code[i].op, next == Opcode.IF_FALSE) != Opcode.NOP) return true;
    }
    return false;
}

// `LNOT rT = rX` + `IF_FALSE rT` branches when rX is truthy, so it becomes
// `IF_TRUE rX` (and `IF_TRUE rT` becomes `IF_FALSE rX`) once the branch is the
// only reader of rT. Offsets are untouched: the branch keeps its slot. The
// bridge a `&&`/`||` chain leaves re-tests rT at the target, which keeps rT
// live, so only a branch whose negation has no other reader fuses. A try
// region's exception edges are outside the liveness, so it keeps the pair.
// `!!x` leaves a second LNOT feeding the rewritten branch, which folds the
// same way; the NOPs between must not be jump targets, since a jump onto one
// skips the earlier LNOT.
fn void fuse_lnot_branch(Instruction* code, uint code_count, bool* jump_targets,
                         RegSet* live_out, bool* in_try, uint i) @private {
    uint q = i + 1;
    for (uint p = i; code[p].op == Opcode.LNOT; p--) {
        uint rT = (uint)code[q].a;
        if ((uint)code[p].a != rT || in_try[p] || live_out[q].test(rT)) { return; }
        for (uint k = p + 1; k <= q; k++) { if (jump_targets[k]) { return; } }
        int sbx = code[q].get_sbc();
        uint skip_tgt = (uint)((int)q + 1 + sbx);
        if (skip_tgt >= 1 && skip_tgt < code_count) {
            Instruction ti = code[skip_tgt - 1];
            if (ti.op == Opcode.LDREG && (uint)ti.a == rT) { return; }
        }
        Opcode inverted = code[q].op == Opcode.IF_FALSE ? Opcode.IF_TRUE : Opcode.IF_FALSE;
        code[q] = bytecode::make_a_sbx(inverted, (uint)code[p].b, sbx);
        code[p] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
        if (p == 0) { return; }
    }
}

// A loose-equality branch whose operand is the null or undefined the previous
// instruction just loaded becomes JMP_NULL/JMP_NNULL at slot `i`, and that load
// becomes a NOP. The load's register must be dead once the branch has run, which
// the whole-function liveness decides. Returns whether it rewrote the pair.
fn bool fuse_null_operand(Instruction* code, bool* jump_targets, RegSet* live_out,
                          uint i, Opcode fused_op, uint offset) @private {
    if (i == 0 || jump_targets[i]) { return false; }
    Opcode null_op;
    switch (fused_op) {
        case Opcode.JMP_EQ:  null_op = Opcode.JMP_NULL;
        case Opcode.JMP_NEQ: null_op = Opcode.JMP_NNULL;
        default: return false;
    }
    Instruction load = code[i - 1];
    if (load.op != Opcode.LDNULL && load.op != Opcode.LDUNDEF) { return false; }
    uint rK = (uint)load.a;
    uint rB = (uint)code[i].b;
    uint rC = (uint)code[i].c;
    if (rB == rC || (rK != rB && rK != rC)) { return false; }
    if (live_out[i + 1].test(rK)) { return false; }
    uint other = rK == rC ? rB : rC;
    code[i - 1] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
    code[i]     = bytecode::make_abc(null_op, offset, other, other);
    return true;
}

// Run all compare→branch fusions over `code[0..code_count)`. `jump_targets`
// is the caller's precomputed map of incoming branches. Replaces
// the hand-written comparison→JMP_N* pass in CompilerContext.finish().
//
// `live_out` is the whole-function liveness of this code, which decides
// whether the compare's result is dead once the branch has read it. Fusing
// only removes that dead result, so other registers' liveness, and the
// later decisions made from it, stay valid as the pass goes. Its CFG has no
// exception edges, so inside a try region the block-local scan
// (cmp_result_live_from) decides instead.
fn void run_cmp_branch_fusion(Instruction* code, uint code_count, bool* jump_targets,
                              RegSet* live_out, bool* in_try) {
    if (code_count < 2) { return; }

    // The caller already built jump targets alongside the liveness analysis.
    // --- Fuse each compare + IF_FALSE/IF_TRUE. ---
    for (uint i = 0; i + 1 < code_count; i++) {
        Opcode cmp_op = code[i].op;
        bool is_if_false = (code[i + 1].op == Opcode.IF_FALSE);
        bool is_if_true  = (code[i + 1].op == Opcode.IF_TRUE);
        if (!is_if_false && !is_if_true) { continue; }

        if (cmp_op == Opcode.LNOT) {
            fuse_lnot_branch(code, code_count, jump_targets, live_out, in_try, i);
            continue;
        }

        Opcode fused_op = cmp_branch_fused_op(cmp_op, is_if_false);
        if (fused_op == Opcode.NOP) { continue; }   // no rule / excluded compare

        // Compare writes rA; the branch reads rA via its `a` field.
        uint rA = (uint)code[i].a;
        if ((uint)code[i + 1].a != rA) { continue; }

        // The branch slot must not be a jump target (landing there post-fusion
        // would fall through the NOP without branching).
        if (jump_targets[i + 1]) { continue; }

        int sbx = code[i + 1].get_sbc();

        // Bridge correction: a forward IF_FALSE/IF_TRUE on rA at the branch target
        // is an `&&`/`||` continuation, and the fused offset must skip past it. It
        // must read rA. A bridge on another register is an unrelated branch, and
        // skipping it would delete an instruction from the taken path. A backward
        // one is a loop back-edge and is never a bridge.
        //
        // The target is computed as a signed int and cast to uint. A target before
        // the function start wraps to a huge value and fails the `< code_count`
        // bound, so no explicit `>= 0` test is needed. The same holds for
        // `skip_tgt`. Do not change either to a signed comparison.
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

        // Short-circuit skip guard (B27): if the branch target is immediately
        // preceded by an LDREG writing rA, the branch materializes the
        // operator's boolean result; fusing would drop it.
        uint skip_tgt = (uint)((int)i + 2 + sbx + bridge_sbx + (bridge_sbx != 0 ? 1 : 0));
        if (skip_tgt >= 1 && skip_tgt < code_count) {
            Instruction ti = code[skip_tgt - 1];
            if (ti.op == Opcode.LDREG && (uint)ti.a == rA) { continue; }
        }
        int fused_off = sbx + 1 + bridge_sbx + (bridge_sbx != 0 ? 1 : 0);
        if (fused_off < -128 || fused_off > 127) { continue; }
        uint rB = (uint)code[i].b;
        uint rC = (uint)code[i].c;

        if (!in_try[i]) {
            // The branch's live-out covers both of its successors.
            if (live_out[i + 1].test(rA)) { continue; }
            if (fuse_null_operand(code, jump_targets, live_out, i, fused_op, (uint)(char)fused_off)) {
                code[i + 1] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
                continue;
            }
            code[i]     = bytecode::make_abc(fused_op, (uint)(char)fused_off, rB, rC);
            code[i + 1] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
            continue;
        }

        // (a) fall-through path: rA must be dead from i+2.
        if (cmp_result_live_from(code, code_count, jump_targets, i + 2, rA, false)) { continue; }

        // (b) taken-branch path: rA must be dead from the branch target, UNLESS
        // rA aliases a compare operand (then the fused op preserves the operand's
        // pre-compare value, which is exactly what the target expects), EXCEPT
        // when the target itself is an IF_TRUE/IF_FALSE reading rA as a boolean
        // condition. That always wants the *comparison result*, never the
        // pre-compare operand value, so the alias exception does not apply
        // there regardless of what rA aliases: a fused compare op (JMP_LT/
        // JMP_SEQ/etc.) writes no register at all, so a downstream branch on
        // rA would silently test the stale operand instead of the (now
        // nonexistent) boolean result. This specifically covers `(a === b ||
        // c) ? ... : ...` and `a === b || c === d` chains landing on an
        // unrelated IF_FALSE/IF_TRUE that merely happens to read the same
        // register, not a genuine `&&`/`||` chain continuation.
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

        code[i]     = bytecode::make_abc(fused_op, (uint)(char)fused_off, rB, rC);
        code[i + 1] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
    }
}

// ============================================================================
// Rule: LDNULL/LDUNDEF rK  +  JMP_EQ/JMP_NEQ rX, rK  ->  NOP + JMP_NULL/JMP_NNULL rX
// ============================================================================
//
// `null` and `undefined` loosely equal each other, the [[IsHTMLDDA]] object and
// nothing else, and comparing against them never coerces, so the other operand
// can sit on either side. The offset in field A is unchanged, and C repeats B.

fn FusionMatch fusion_null_branch_trigger(Instruction trigger, void* ctx) {
    FusionMatch m;
    if (trigger.op != Opcode.LDNULL && trigger.op != Opcode.LDUNDEF) { return m; }
    m.matched  = true;
    m.dest_reg = (uint)trigger.a;
    return m;
}

fn FusionMatch fusion_null_branch_consumer(Instruction trigger, Instruction consumer, uint rK, void* ctx) {
    FusionMatch m;
    if (consumer.op != Opcode.JMP_EQ && consumer.op != Opcode.JMP_NEQ) { return m; }
    uint rB = (uint)consumer.b;
    uint rC = (uint)consumer.c;
    if (rB == rC) { return m; }
    if (rC == rK) { m.src_reg = rB; }
    else if (rB == rK) { m.src_reg = rC; }
    else { return m; }
    m.matched    = true;
    m.rewrite_op = consumer.op == Opcode.JMP_EQ ? Opcode.JMP_NULL : Opcode.JMP_NNULL;
    m.dest_reg   = (uint)consumer.a;
    m.imm        = m.src_reg;
    return m;
}

const FusionRule FUSION_NULL_BRANCH = {
    .trigger  = &fusion_null_branch_trigger,
    .consumer = &fusion_null_branch_consumer,
};

fn void fuse_null_branch(Instruction* code, uint code_count, bool* jump_targets) {
    run_fusion_rule(code, code_count, jump_targets, FUSION_NULL_BRANCH);
}

// The second instruction stays ordinary so a slow first operation can return
// to the switch and a partially completed pair resumes without replaying it.
fn void fuse_threaded_pairs(Instruction* code, uint count, bool* targets) {
    build_jump_targets(code, count, targets);
    for (uint i = 0; i + 1 < count; i++) {
        Instruction first = code[i];
        Instruction second = code[i + 1];
        if (first.op == Opcode.ADD && second.op == Opcode.ADD
            && !targets[i + 1] && (second.b == first.a || second.c == first.a)) {
            code[i].op = Opcode.ADD_FUSED;
            i++;
        } else if (first.op == Opcode.INC && second.op == Opcode.JMP_LT
            && second.b == first.a && second.c != first.a) {
            // Rotated loops enter at the intact comparison before any increment.
            // The numeric handler caches a distinct bound before publication.
            code[i].op = Opcode.INC_LT;
            i++;
        }
    }
}

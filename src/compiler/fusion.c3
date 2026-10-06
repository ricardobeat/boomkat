// Declarative superinstruction-fusion framework.
//
// A "fusion" collapses a short instruction sequence that shares a scratch
// register into a single superinstruction that bakes the scratch value in
// as an immediate/index, freeing the register and saving a dispatch. The
// first pair (ADDI/SUBI, now fuse_imm_binop below) was written by hand
// directly in CompilerContext.finish(); this file factors the error-prone
// shared machinery into one driver (`run_fusion_rule`), so future fusions reuse
// it instead of re-deriving subtly different, and subtly buggy, copies. That
// machinery is the NOP-skipping that finds the real consumer, the jump-target
// guard that stops a branch landing on the rewritten consumer without having
// run the trigger, and the dead-after-liveness scan proving the scratch
// register can be discarded.
//
// Phase: fusion rules that key off a scratch register produced by LDINT/
// LDCONST/etc. must run AFTER copy-propagation. Copy-propagation NOPs out
// LDREG moves that the parser emits between a literal load and its use
// (e.g. `n - 1` as a call argument loads into a temp, then LDREG-copies it
// into the argument slot); until those moves are NOP'd, the immediate's
// consumer is not yet adjacent, so a fusion pass run first would silently
// find no match. `run_fusion_rule` skips NOPs to find the consumer for
// exactly this reason, see the FUSION_PHASE_NOTE below for where each
// existing hand-written pass would sit on this timeline.
module boomkat::compiler;

import boomkat::bytecode;
import boomkat::types;

// FUSION_PHASE_NOTE, ordering of every fusion-shaped pass in finish(),
// documented once here instead of re-derived per pass:
//
//   1. GETVAR+INC/DEC+PUTVAR -> INC_VAR/DEC_VAR   (no scratch-reg dependency;
//      order-independent, so it could run anywhere before NOP compaction,
//      declarative, this file: FUSION_INC_DEC_VAR / run_fusion3_rule)
//   2. LDCONST+GETPROP -> GETPROPC                (same, order-independent;
//      declarative, this file: FUSION_GETPROPC / run_fusion_rule; the store
//      form LDCONST+PUTPROP -> PUTPROPC is FUSION_PUTPROPC)
//   3. compare+IF_FALSE/IF_TRUE -> JMP_N*/JMP_*/JMP_SEQ/JMP_SNEQ
//      (order-independent and declarative, in this file: run_cmp_branch_fusion,
//      a distinct jump-aware driver that owns the whole-function jump-target
//      bitset (built by the shared build_jump_targets), dual-path liveness,
//      and bridge/short-circuit corrections, and
//      is table-driven over the compare form (CMP_BRANCH_RULES). Loose
//      EQ/NEQ are excluded, they coerce and can throw.)
//   4. copy-propagation (LDREG rT=rX substitution), MUST run before any
//      rule whose trigger's consumer may be separated from it by a
//      parser-emitted LDREG move (rule 5 depends on this). Hand-written,
//      deliberately: pure copy-prop/DCE, not a superinstruction fusion
//      (no new opcode is ever installed).
//   5. LDINT+binop / LDINT+JMP_* -> <op>I immediate forms (declarative, this file)
//
// The copy-propagation pass (rule 4) and the dead-LDREG-before-INC/DEC DCE
// pass (same reasoning) are the only fusion-shaped passes left hand-written
// in context.c3, and they are not superinstruction fusions at all (they
// install no new opcode). All four true fusions are declarative. See
// plans/058-fusion-rule-framework.md for the full "why" on each.

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
fn bool fusion_transparent(Instruction ins, uint reg) {
    switch (ins.op) {
        case Opcode.GETGLOBAL:
        case Opcode.GETVAR:
        case Opcode.LDINT:
        case Opcode.LDCONST:
        case Opcode.LDUNDEF:
        case Opcode.LDTHIS:
            return (uint)ins.a != reg;
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
// argument count and C as a name-constant index; GETPROPC encodes C as a
// constant index. Comparing those raw values against a register number is a
// false positive that silently pins the register live and blocks fusion,
// which is a correctness-safe direction, but costs real optimizations
// whenever a scratch register happens to equal an argc or constant index.
fn bool fusion_abc_reads_reg(Instruction ins, uint reg) {
    switch (ins.op) {
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
            // KNOWN CONSERVATIVE GAP (deliberately not widened here): plain
            // CALL and CALL_UNDEF_THIS also decode C as an argument COUNT, not
            // a register (vm_calls.c3: `nargs = insn.c`), so a scratch register
            // whose number happens to equal the argc is falsely reported live
            // and its fusion is skipped. That is the SAFE direction (a missed
            // optimization, never a miscompile), which is why it is left alone
            // rather than folded into the carve-out above: adding an opcode
            // here is a correctness-critical claim about that opcode's operand
            // encoding, and each one needs its own verification against
            // vm_calls.c3. CALL_S must never be added, since it genuinely reads C as
            // a register (`ds.regs_base + insn.c`).
            return (uint)ins.b == reg || (uint)ins.c == reg;
    }
}

// Scan forward from `start` (inclusive) and report whether `reg` is read
// before it is next overwritten, the shared "is this scratch register
// dead after the consumer" check every hand-written pass re-implements.
//
// IF_TRUE/IF_FALSE use field `a` as a READ (the condition register), not a
// write, so they're checked explicitly before the generic write-then-stop
// rule. Only ABC-format opcodes have plain register operands in b/c;
// A_BC/A_SBX/WIDE_* operands are indices or branch offsets, never register
// references, and must not be misread as one. See fusion_abc_reads_reg for the
// ABC forms whose b and c are likewise not registers. The same applies to field
// A on the WIDE forms, which the guard below enforces.
//
// This is a linear scan over slots, not a CFG walk, so it keeps scanning
// straight through a branch into code that is not necessarily the executed
// successor. Reads found that way only over-report liveness (a suppressed
// fusion, never a miscompile), but WRITES do not: inside the window a
// conditional branch can skip, the write may not execute at runtime, so it
// cannot end the scan. `join_pc` holds the furthest pending branch target;
// while the scan sits before it, every `A == reg` is ignored as a kill.
// Treating a conditionally-executed write as a kill is what made
// `(o=1)-(r=1)<0 && (r=o)` drop the `r=1` store: r's only later mention is the
// `r=o` on the not-taken arm, so r was declared dead and left undefined. The
// opposite error, reporting a live register dead, is the one that miscompiles,
// and the WIDE-format guard below is the other half of preventing it.
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
        // Only non-WIDE, non-branch forms use A as a destination register.
        // WIDE_SABC/WIDE_ABC (JUMP/BREAK/CONTINUE) pack a 24-bit branch offset
        // across A/B/C, and the compare-branch family keeps an 8-bit offset in
        // A, so their A field is the offset's low byte, and reading it as a
        // write to register `a` makes any `JUMP +N` look like an overwrite of
        // register N and ends the scan early, reporting a still-live register
        // as dead. That is the unsafe direction: it PERMITS a fusion whose
        // consumer's value is read again at the branch target. Measured on
        // test262, 212 scans stopped on exactly this alias (211 JUMP, 1 BREAK).
        // cmp_result_live_from and run_move_gg_fusion's scan already carried
        // this guard; this shared helper was the copy that omitted it.
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

// Mark every instruction slot that some branch, loop exit or exception
// handler can transfer control to. `jump_targets` is a caller-provided
// buffer of at least `code_count` bools; it is fully overwritten (callers
// need not pre-clear it).
//
// The single source of truth for "can control arrive here from somewhere
// other than the preceding instruction": every fusion pass needs exactly
// this predicate, and a private copy in one pass can drift. A pass that
// skips the bitset entirely silently miscompiles any pattern where the
// trigger sits on one arm of a branch and the consumer is the join point
// (a ternary's false arm feeding a binary operator is the canonical case).
//
// Every pc-relative branch form belongs in the switch below, including ones
// no in-compiler caller can currently observe. The set is JUMP/BREAK/CONTINUE
// (WIDE_SABC), IF_TRUE/IF_FALSE (A_SBX), the JMP_* compare-branch family
// (ABC, 8-bit offset in field A), and TRY's catch and finally offsets. Handler entries reached without an offset need no arm here: a
// finally's ENDFINALLY is found by a runtime scan, and its slot always holds
// a real ENDFINALLY, which no fusion pass can turn into a data word.
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

// Run one fusion rule over the whole instruction stream. Owns:
//   - NOP-skipping to locate the consumer (copy-prop leaves NOPs between
//     a trigger and its now-adjacent-in-spirit consumer)
//   - the dead-after-liveness scan on the scratch register
//   - the jump-target guard on the consumer slot
//   - the NOP+rewrite emission
//
// Jump-target safety, both halves:
//   - NOP-ing the TRIGGER slot is always safe: a jump landing there falls
//     through into the rewritten consumer, which no longer depends on the
//     trigger's register.
//   - The CONSUMER slot must NOT be a jump target. The rewrite bakes the
//     trigger's value in as an immediate, which is only the right value on
//     the fallthrough path that actually executed the trigger. Control
//     arriving from a branch expected the scratch register to hold *its*
//     value; the baked-in immediate silently supplies the trigger's
//     instead. `5 + (c ? 10 : 20)` compiles to
//     `LDINT r4,10 / JUMP join / LDINT r4,20 / join: ADD r2=r2,r4`, so
//     without this guard the false arm fuses into `ADDI r2=r2,20` and the
//     true arm jumps straight onto it, so every condition yields 20.
//
// `jump_targets` is a caller-provided scratch buffer of at least
// `code_count` bools (kept out of this module so fusion.c3 stays free of
// any heap dependency).
fn void run_fusion_rule(Instruction* code, uint code_count, bool* jump_targets, FusionRule rule, void* ctx = null) {
    build_jump_targets(code, code_count, jump_targets);

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
// Operand order: the immediate is normally the RIGHT source, so the folded
// form is `rS <op> imm`. `+` is NOT commutative in JavaScript — ES5 §11.6.1
// makes it string concatenation whenever either operand is a string after
// ToPrimitive — and an immediate form has no field left to record which side
// the immediate came from. Folding `imm + rS` would emit the same ADDI as
// `rS + imm`, so `function f(a){return 1+a} f("A")` would evaluate to "A1".
// `imm + rS` stays LDINT+ADD, which reads its operands in source order.
// MUL, BAND, BOR and BXOR give the same result either way, so they also fold
// an immediate on the left.

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
// Ported from the hand-written pass in CompilerContext.finish() (search
// "fuse LDCONST rK, idx" in context.c3 for the original). Verified
// byte-identical against it via the golden-bytecode suite.
//
// `ctx` carries the constant pool (`TVal*`) so the trigger can check
// `idx <= 255` (GETPROPC.c is 8 bits) and that the constant is a string
// (GETPROPC assumes string keys), the only rule so far that needs more
// than the raw instruction bits to validate its trigger.
//
// Liveness: the shared dead-after scan (`fusion_reg_live_from`) already
// implements the exact rK-liveness rule the hand-written pass re-derived
// (IF_TRUE/IF_FALSE read `a`; ABC-format ops read `b`/`c`; any write to
// `a` ends the scan), including the "rK kept alive for a following
// PUTPROP/DELPROP in LHS/assignment mode" case, which is just "rK is read
// again before it's overwritten", i.e. the ordinary dead-after-liveness
// predicate. No special-casing needed.

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

// Run the declarative GETPROPC fusion over `code[0..code_count)`.
// Drop-in replacement for the hand-written pass at the same site in
// CompilerContext.finish(). `constants` is the function's constant pool,
// needed to validate the trigger (string key, index fits GETPROPC.c).
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

// The key constant is loaded when the member expression is parsed, ahead of the
// right-hand side, so the PUTPROP usually trails the LDCONST by the value's
// own instructions; the rule's gap covers that.
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
// ADDI/SUBI and GETPROPC both shrink a trigger+consumer pair down to one
// instruction by discarding a dying scratch register. GETVAR+INC/DEC+PUTVAR
// is shaped differently: it's a *three*-instruction window over ONE register
// that survives the fusion (it's a live variable, not a scratch temp), so
// there is nothing to NOP-skip to and no dead-after-liveness scan to run,
// the three ops are always physically adjacent by construction (the parser
// never interposes anything between a variable read, its increment, and the
// write-back), and correctness comes entirely from an equality match across
// all three slots, not from proving a register's death. Forcing this through
// `FusionMatch`/`run_fusion_rule` (which NOPs the trigger and rewrites the
// consumer) would mean inventing dummy liveness/immediate fields that don't
// mean anything for this pattern, so it gets its own minimal parallel
// schema instead of a mangled fit into the 2-slot one.

// Result of matching a 3-slot fusion window.
struct Fusion3Match {
    bool   matched;
    Opcode rewrite_op;   // opcode to install at the middle slot
    uint   reg;          // the shared register (dest_reg field of the rewrite)
    uint   imm;          // immediate baked into the rewrite (e.g. a name index)
}

// Given the three physically-adjacent instructions of a candidate window,
// report whether they fuse. `slot0`/`slot1`/`slot2` are `code[i]`,
// `code[i+1]`, `code[i+2]`, no NOP-skipping; this pattern requires exact
// adjacency. `ctx` mirrors the opaque per-rule pointer of the 2-slot
// driver (see `FusionTriggerFn`).
alias Fusion3MatchFn = fn Fusion3Match(Instruction slot0, Instruction slot1, Instruction slot2, void* ctx);

struct Fusion3Rule {
    Fusion3MatchFn match;
}

// Run one 3-slot fusion rule over the whole instruction stream. On match,
// NOPs slot0 and slot2 and installs the rewrite (A-BC format: reg, imm) at
// slot1, the middle slot is always a valid landing point for control flow
// (both a jump to slot0, which falls through, and a jump to slot1 itself,
// which now finds the fused op) so no jump-target bitset is needed, exactly
// as with the 2-slot driver's trigger-NOP.
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
// Ported from the hand-written pass in CompilerContext.finish() (search
// "fuse GETVAR + INC/DEC + PUTVAR" in context.c3 for the original). `ctx`
// carries the const_count bound (mirroring GETPROPC's use of `ctx` for the
// constant pool), so the match fn can reject a name index the constant pool
// hasn't grown to yet, see fuse_inc_dec_var below for how it's threaded.

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

// Run the declarative INC_VAR/DEC_VAR fusion over `code[0..code_count)`.
// Drop-in replacement for the hand-written pass at the same site in
// CompilerContext.finish(). `const_count` bounds the GETVAR/PUTVAR name
// index, mirroring the original pass's `name0 < self.const_count` guard.
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

// One compare→branch fusion rule: `cmp_op` is the comparison opcode; the two
// fused ops are what to install when the following instruction is IF_FALSE
// (branch-when-compare-false) vs IF_TRUE (branch-when-compare-true).
struct CmpBranchRule {
    Opcode cmp_op;
    Opcode fused_if_false;
    Opcode fused_if_true;
}

// The full compare→branch fusion table. Relational forms map onto the
// existing JMP_N*/JMP_* opcodes; strict-equality forms map onto JMP_SEQ/
// JMP_SNEQ. Note the polarity: SEQ+IF_FALSE branches when NOT strictly equal
// (JMP_SNEQ) and SNEQ+IF_FALSE branches when strictly equal (JMP_SEQ).
const CmpBranchRule[8] CMP_BRANCH_RULES = {
    { Opcode.LT,   Opcode.JMP_NLT,  Opcode.JMP_LT   },
    { Opcode.LE,   Opcode.JMP_NLE,  Opcode.JMP_LE   },
    { Opcode.GT,   Opcode.JMP_NGT,  Opcode.JMP_GT   },
    { Opcode.GE,   Opcode.JMP_NGE,  Opcode.JMP_GE   },
    { Opcode.SEQ,  Opcode.JMP_SNEQ, Opcode.JMP_SEQ  },
    { Opcode.SNEQ, Opcode.JMP_SEQ,  Opcode.JMP_SNEQ },
    { Opcode.EQ,   Opcode.NOP,      Opcode.NOP      },  // sentinel: not fused (see note above)
    { Opcode.NEQ,  Opcode.NOP,      Opcode.NOP      },  // sentinel: not fused
};

// Look up the fused opcode for a (compare, branch-direction) pair. Returns
// NOP (never a real fused op) when the compare op has no fusion rule or is a
// deliberately-excluded sentinel (EQ/NEQ).
fn Opcode cmp_branch_fused_op(Opcode cmp_op, bool is_if_false) {
    foreach (&rule : CMP_BRANCH_RULES) {
        if (rule.cmp_op == cmp_op) {
            Opcode fused = is_if_false ? rule.fused_if_false : rule.fused_if_true;
            return fused;
        }
    }
    return Opcode.NOP;
}

// Scan a basic-block-local range [start, code_count) and report whether `reg`
// is read before it is overwritten. Stops (treating `reg` as live) at the
// first jump target, a new basic block we can't prove dead across, and at
// terminal instructions (RET/THROW/JUMP) which end the block cleanly (dead).
// This is the compare-result liveness rule the hand-written pass ran on both
// the fall-through and taken-branch paths. `skip_first_target` lets the
// branch-path scan ignore the jump-target flag on its own entry slot.
fn bool cmp_result_live_from(Instruction* code, uint code_count, bool* jump_targets,
                             uint start, uint reg, bool skip_first_target) {
    int join_pc = -1;
    for (uint j = start; j < code_count; j++) {
        if (jump_targets[j] && !(skip_first_target && j == start)) {
            // A path from outside reaches j; probe this one slot for a read of
            // reg. If reg isn't read here, keep scanning (matches the original
            // one-instruction probe at cross-edge targets).
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
        // Inside a conditional branch's skip window the write may not execute,
        // so it is not a kill. See fusion_reg_live_from for the failure this
        // prevents.
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

// Run all compare→branch fusions over `code[0..code_count)`. `jump_targets`
// is a caller-provided scratch buffer of at least `code_count` bools (kept out
// of this module so fusion.c3 stays free of any heap dependency). Replaces
// the hand-written comparison→JMP_N* pass in CompilerContext.finish().
fn void run_cmp_branch_fusion(Instruction* code, uint code_count, bool* jump_targets) {
    if (code_count < 2) { return; }

    // --- Build the jump-target bitset. ---
    build_jump_targets(code, code_count, jump_targets);

    // --- Fuse each compare + IF_FALSE/IF_TRUE. ---
    for (uint i = 0; i + 1 < code_count; i++) {
        Opcode cmp_op = code[i].op;
        bool is_if_false = (code[i + 1].op == Opcode.IF_FALSE);
        bool is_if_true  = (code[i + 1].op == Opcode.IF_TRUE);
        if (!is_if_false && !is_if_true) { continue; }

        Opcode fused_op = cmp_branch_fused_op(cmp_op, is_if_false);
        if (fused_op == Opcode.NOP) { continue; }   // no rule / excluded compare

        // Compare writes rA; the branch reads rA via its `a` field.
        uint rA = (uint)code[i].a;
        if ((uint)code[i + 1].a != rA) { continue; }

        // The branch slot must not be a jump target (landing there post-fusion
        // would fall through the NOP without branching).
        if (jump_targets[i + 1]) { continue; }

        int sbx = code[i + 1].get_sbc();

        // Bridge correction (B23/B26/B28): a FORWARD IF_FALSE/IF_TRUE at the
        // branch's target is an `&&`/`||` continuation; extend the fused offset
        // past it. A backward continuation is a loop back-edge, not a bridge.
        //
        // The continuation must read rA, the very register this fusion stops
        // materializing. That is the whole reason the correction exists, since
        // the bridge would otherwise re-test a stale compare result. A forward
        // IF_FALSE or IF_TRUE on any other register is an unrelated branch that
        // merely happens to sit at the target, and skipping past it deletes a
        // real instruction from the taken path. A backward branch landing on the
        // first statement of a loop body is exactly that shape: `for (...) { if
        // (j) ... }` puts an `IF_FALSE rJ` at the back-edge target, and treating
        // it as a bridge moves the back-edge into the else arm, so every
        // iteration after the first runs only that arm.
        //
        // The negative-target handling is load-bearing and not obvious from the
        // expression: the target is computed in signed `int` and then cast to
        // `uint`. A backward branch far enough to run off the front of the
        // function yields a negative value, which wraps to a huge unsigned
        // number and fails the `< code_count` bound below, so no explicit `>= 0`
        // test is needed and adding one would be dead code. The same holds for
        // `skip_tgt` further down. Do not change either to a signed comparison
        // without re-deriving both bounds.
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

        // Adjusted offset must fit signed 8 bits (stored in field A).
        if (fused_off < -128 || fused_off > 127) { continue; }

        code[i]     = bytecode::make_abc(fused_op, (uint)(char)fused_off, rB, rC);
        code[i + 1] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
    }
}

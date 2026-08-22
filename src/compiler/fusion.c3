// Declarative superinstruction-fusion framework.
//
// A "fusion" collapses a short instruction sequence that shares a scratch
// register into a single superinstruction that bakes the scratch value in
// as an immediate/index, freeing the register and saving a dispatch. The
// first pair (ADDI/SUBI, see fuse_addi_subi below) was written by hand
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
//      declarative, this file: FUSION_GETPROPC / run_fusion_rule)
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
//   5. LDINT+ADD/SUB -> ADDI/SUBI                 (declarative, this file)
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
}

// Does ABC-format instruction `ins` READ `reg` in one of its operand fields?
//
// Not every ABC field is a register. CALL_VAR/CALL_GLOBAL encode B as an
// argument count and C as a name-constant index; GETPROPC encodes C as a
// constant index. Comparing those raw values against a register number is a
// false positive that silently pins the register live and blocks fusion,
// which is a correctness-safe direction, but costs real optimizations
// whenever a scratch register happens to equal an argc or constant index.
fn bool fusion_abc_reads_reg(Instruction ins, uint reg) {
    switch (ins.op) {
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
        // Only non-WIDE forms use A as a destination register. WIDE_SABC/
        // WIDE_ABC (JUMP/BREAK/CONTINUE) pack a 24-bit branch offset across
        // A/B/C, so their A field is the offset's low byte, and reading it as a
        // write to register `a` makes any `JUMP +N` look like an overwrite of
        // register N and ends the scan early, reporting a still-live register
        // as dead. That is the unsafe direction: it PERMITS a fusion whose
        // consumer's value is read again at the branch target. Measured on
        // test262, 212 scans stopped on exactly this alias (211 JUMP, 1 BREAK).
        // cmp_result_live_from and run_move_gg_fusion's scan already carried
        // this guard; this shared helper was the copy that omitted it.
        OpFormat jfmt_w = bytecode::get_op_format(jop);
        if ((int)j >= join_pc && jfmt_w != OpFormat.WIDE_SABC && jfmt_w != OpFormat.WIDE_ABC) {
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
            // Two-word form: the offset applies once both words are consumed.
            return (int)j + 2 + (int)(ichar)ins.a;
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
// this predicate, and a private copy in one pass can drift. A pass that skips the bitset entirely silently miscompiles any
// pattern where the trigger sits on one arm of a branch and the consumer
// is the join point (a ternary's false arm feeding a binary operator is
// the canonical case).
//
// Every pc-relative branch form belongs in the switch below, including ones
// no in-compiler caller can currently observe. The set is JUMP/BREAK/CONTINUE
// (WIDE_SABC), IF_TRUE/IF_FALSE (A_SBX), the JMP_* compare-branch family and
// JMP_LT_G (ABC, 8-bit offset in field A), and TRY's catch and finally
// offsets. Handler entries reached without an offset need no arm here: a
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
                // ABC form: signed 8-bit offset in field A.
                int off = (int)(ichar)ins.a;
                int tgt = (int)i + 1 + off;
                if (tgt >= 0 && (uint)tgt < code_count) { jump_targets[tgt] = true; }
            }
            case Opcode.JMP_LT_G: {
                // Two-word ABC form: the offset is applied once both words are
                // consumed, so the base is i+2 rather than i+1.
                //
                // JMP_LT_G is installed after every pass in finish() that reads
                // this bitset, so within the compiler the arm below never fires.
                // It is here for peephole_scan, which runs on final code where
                // JMP_LT_G does exist and whose GETPROPC2 fusion turns a slot
                // into a data word that a branch must never land on.
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
//
// Ported from the hand-written pass in CompilerContext.finish() (search
// "fuse LDINT rK, imm" in context.c3 for the original). Verified
// byte-identical against it via the golden-bytecode suite
// (test/golden_bytecode/, `just test-golden-bytecode`).
//
// Operand order: ADD and SUB both fold only when rK is the RIGHT source, so
// the folded form is always `rS <op> imm`. `+` is NOT commutative in
// JavaScript — ES5 §11.6.1 makes it string concatenation whenever either
// operand is a string after ToPrimitive — and ADDI has no field left to
// record which side the immediate came from. Folding `imm + rS` would emit
// the same ADDI as `rS + imm`, so `function f(a){return 1+a} f("A")` would
// evaluate to "A1". `imm + rS` is left as LDINT+ADD, which reads its
// operands in source order and concatenates correctly.

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

// Run the declarative ADDI/SUBI fusion over `code[0..code_count)`.
// Drop-in replacement for the hand-written pass at the same site in
// CompilerContext.finish().
fn void fuse_addi_subi(Instruction* code, uint code_count, bool* jump_targets) {
    run_fusion_rule(code, code_count, jump_targets, FUSION_ADDI_SUBI);
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
// adjacency. `ctx` mirrors the 2-slot driver's opaque per-rule pointer
// (see `FusionTriggerFn`).
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

// Run all compare→branch fusions over `code[0..code_count)`. `jump_targets`
// is a caller-provided scratch buffer of at least `code_count` bools (kept out
// of this module so fusion.c3 stays free of any heap dependency). Drop-in
// replacement for the hand-written comparison→JMP_N* pass in
// CompilerContext.finish().
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

// Fuse the `GETGLOBAL_PRIM rX, S` + `PUTGLOBAL_PRIM rX, D` pair emitted for a
// plain `a = b` assignment between two proven primitive-only globals into a
// single two-word `MOVE_GG` superinstruction (word 1: A-BC, BC = dst name D;
// word 2: a kept NOP whose BC = src name S). This halves the op count for
// global-to-global copies: no scratch round-trip, one dispatch.
//
// `jump_targets` is a caller-provided scratch buffer of at least `code_count`
// bools (kept out of this module so fusion.c3 stays heap-free).
//
// Two-word layout invariant: MOVE_GG's VM handler reads the IMMEDIATELY-next
// word as the source name, so the pair must be strictly adjacent (j == i+1).
// Jump-target safety: the MOVE_GG word (i) may itself be a jump target, a
// loop back-edge landing on it re-executes the full copy, which is correct.
// But the trailing word (i+1) must NOT be a jump target: a jump landing there
// would skip the read half. We also require the source register to be a dead
// scratch temp after the pair (PUTGLOBAL_PRIM consumes it), so nothing
// downstream reads the value the fused op no longer materializes in a register.
fn void run_move_gg_fusion(Instruction* code, uint code_count, bool* jump_targets) {
    if (code_count < 2) { return; }

    // --- Build the jump-target bitset (all branch/handler forms). ---
    build_jump_targets(code, code_count, jump_targets);

    // --- Fuse each strictly-adjacent GETGLOBAL_PRIM + PUTGLOBAL_PRIM pair. ---
    for (uint i = 0; i + 1 < code_count; i++) {
        if (code[i].op != Opcode.GETGLOBAL_PRIM) { continue; }
        if (code[i + 1].op != Opcode.PUTGLOBAL_PRIM) { continue; }

        // Same scratch register: GETGLOBAL_PRIM writes rX (field A),
        // PUTGLOBAL_PRIM reads rX (field A).
        uint rX = (uint)code[i].a;
        if ((uint)code[i + 1].a != rX) { continue; }

        // The trailing word (i+1) must not be a jump target, landing there
        // would skip the MOVE_GG read half.
        if (jump_targets[i + 1]) { continue; }

        // rX must be dead after the pair: PUTGLOBAL_PRIM sets it undefined and
        // the fused op writes no register, so any later read would see garbage.
        // Uses the shared scan (which owns the WIDE-format A-is-not-a-register
        // rule) rather than a private copy, since a hand-copied liveness scan here
        // is exactly how the shared helper came to be missing that guard.
        if (fusion_reg_live_from(code, code_count, i + 2, rX)) { continue; }

        uint dst_name = code[i + 1].get_bc();   // D, destination global
        uint src_name = code[i].get_bc();        // S, source global

        // Word 1: MOVE_GG, BC = dst name. Word 2: kept NOP, BC = src name.
        code[i]     = bytecode::make_a_bc(Opcode.MOVE_GG, 0, dst_name);
        code[i + 1] = bytecode::make_a_bc(Opcode.NOP, 0, src_name);
    }
}

// Fuse `GETGLOBAL_PRIM rX, S` + `JMP_LT off, rB, rX` into a single two-word
// `JMP_LT_G` (word 1: ABC, A = the jump offset, B = the surviving register
// operand; word 2: a kept NOP whose BC = the global's name index S). The
// loop-bound global is read straight into the comparison instead of being
// materialized in a scratch register, saving a dispatch per iteration on the
// hottest loop shape in the suite.
//
// `jump_targets` is a caller-provided scratch buffer of at least `code_count`
// bools (kept out of this module so fusion.c3 stays heap-free).
//
// Safety, mirroring run_move_gg_fusion:
//   - strictly adjacent (the VM reads the immediately-next word as the name)
//   - the trailing word must NOT be a jump target: landing there would skip
//     the load half and misread the name word as an instruction. The
//     JMP_LT_G word itself MAY be a target, re-executing the pair is correct.
//   - `rX` must be dead after the pair on BOTH the fall-through and the
//     taken-branch paths, since the fused op materializes no register. The
//     backward-branch (loop back-edge) case is covered because the scan from
//     the target runs over the whole loop body.
//   - the offset carries over unchanged: the original JMP_LT sits one slot
//     later and branches relative to (i+1)+1, while JMP_LT_G branches
//     relative to i+2 after consuming both words, the same base.
fn void run_jmp_lt_g_fusion(Instruction* code, uint code_count, bool* jump_targets) {
    if (code_count < 2) { return; }

    build_jump_targets(code, code_count, jump_targets);

    for (uint i = 0; i + 1 < code_count; i++) {
        if (code[i].op != Opcode.GETGLOBAL_PRIM) { continue; }
        if (code[i + 1].op != Opcode.JMP_LT) { continue; }

        // The branch's C operand must be exactly the register the load wrote.
        uint rX = (uint)code[i].a;
        if ((uint)code[i + 1].c != rX) { continue; }
        // A self-comparison (`rB` is the same scratch) has no register operand
        // left once the load is folded away; leave it to the plain path.
        if ((uint)code[i + 1].b == rX) { continue; }

        if (jump_targets[i + 1]) { continue; }

        // The offset needs no re-basing: the original JMP_LT sits at slot i+1
        // and branches relative to (i+1)+1, while the fused JMP_LT_G sits at
        // slot i and branches relative to i+2 after consuming both words,
        // the same base, so the stored offset carries over unchanged.
        int off = (int)(ichar)code[i + 1].a;

        // rX must be dead on the fall-through path...
        if (fusion_reg_live_from(code, code_count, i + 2, rX)) { continue; }
        // ...and on the taken-branch path.
        int tgt = (int)i + 2 + off;
        if (tgt < 0 || (uint)tgt >= code_count) { continue; }
        if (fusion_reg_live_from(code, code_count, (uint)tgt, rX)) { continue; }

        uint name_idx = code[i].get_bc();

        // Word 1: JMP_LT_G, A = re-based offset, B = surviving register operand.
        // Word 2: kept NOP, BC = the global's name index.
        code[i]     = bytecode::make_abc(Opcode.JMP_LT_G, (uint)(char)(ichar)off,
                                         (uint)code[i + 1].b, 0);
        code[i + 1] = bytecode::make_a_bc(Opcode.NOP, 0, name_idx);
    }
}

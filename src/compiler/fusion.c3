/// Declarative superinstruction-fusion framework.
///
/// A "fusion" collapses a short instruction sequence that shares a scratch
/// register into a single superinstruction that bakes the scratch value in
/// as an immediate/index, freeing the register and saving a dispatch. The
/// first pair (ADDI/SUBI, see fuse_addi_subi below) was written by hand
/// directly in CompilerContext.finish(); this file factors the error-prone
/// shared machinery — NOP-skipping to find the real consumer, and the
/// dead-after-liveness scan that proves the scratch register can be
/// discarded — into ONE driver (`run_fusion_rule`) so future fusions reuse
/// it instead of re-deriving subtly different (and subtly buggy) copies.
///
/// Phase: fusion rules that key off a scratch register produced by LDINT/
/// LDCONST/etc. must run AFTER copy-propagation. Copy-propagation NOPs out
/// LDREG moves that the parser emits between a literal load and its use
/// (e.g. `n - 1` as a call argument loads into a temp, then LDREG-copies it
/// into the argument slot); until those moves are NOP'd, the immediate's
/// consumer is not yet adjacent, so a fusion pass run first would silently
/// find no match. `run_fusion_rule` skips NOPs to find the consumer for
/// exactly this reason — see the FUSION_PHASE_NOTE below for where each
/// existing hand-written pass would sit on this timeline.
module duktape::compiler;

import duktape::bytecode;
import duktape::types;

/// FUSION_PHASE_NOTE — ordering of every fusion-shaped pass in finish(),
/// documented once here instead of re-derived per pass:
///
///   1. GETVAR+INC/DEC+PUTVAR -> INC_VAR/DEC_VAR   (no scratch-reg dependency;
///      order-independent, could run anywhere before NOP compaction —
///      declarative, this file: FUSION_INC_DEC_VAR / run_fusion3_rule)
///   2. LDCONST+GETPROP -> GETPROPC                (same — order-independent;
///      declarative, this file: FUSION_GETPROPC / run_fusion_rule)
///   3. compare+IF_FALSE/IF_TRUE -> JMP_N*/JMP_*/JMP_SEQ/JMP_SNEQ
///      (order-independent; declarative, this file: run_cmp_branch_fusion —
///      a distinct jump-aware driver that owns the whole-function jump-target
///      bitset, dual-path liveness, and bridge/short-circuit corrections, and
///      is table-driven over the compare form (CMP_BRANCH_RULES). Loose
///      EQ/NEQ are excluded — they coerce and can throw.)
///   4. copy-propagation (LDREG rT=rX substitution) — MUST run before any
///      rule whose trigger's consumer may be separated from it by a
///      parser-emitted LDREG move (rule 5 depends on this). Hand-written,
///      deliberately: pure copy-prop/DCE, not a superinstruction fusion
///      (no new opcode is ever installed).
///   5. LDINT+ADD/SUB -> ADDI/SUBI                 (declarative, this file)
///
/// The copy-propagation pass (rule 4) and the dead-LDREG-before-INC/DEC DCE
/// pass (same reasoning) are the only fusion-shaped passes left hand-written
/// in context.c3 — and they are not superinstruction fusions at all (they
/// install no new opcode). All four true fusions are declarative. See
/// plans/058-fusion-rule-framework.md for the full "why" on each.

/// Result of matching a fusion's trigger+consumer pair, produced by a
/// rule's `match_consumer` callback.
struct FusionMatch {
    bool   matched;
    Opcode rewrite_op;   // opcode to install at the consumer's slot
    uint   dest_reg;     // destination register of the rewritten instruction
    uint   src_reg;      // surviving source register (register operand)
    uint   imm;          // immediate baked into the rewritten instruction (raw bc bits)
}

/// A trigger predicate: does this instruction introduce a fusable scratch
/// value (e.g. an in-range LDINT), and what register/immediate does it
/// carry? Returning `matched = false` skips this instruction as a trigger.
/// `ctx` is an opaque per-rule pointer threaded through unchanged from
/// `run_fusion_rule`'s caller (e.g. the constant pool, for rules whose
/// guard depends on more than the raw instruction bits); rules that don't
/// need it simply ignore the parameter.
alias FusionTriggerFn = fn FusionMatch(Instruction trigger, void* ctx);

/// A consumer predicate: given the already-validated trigger and a
/// candidate consumer instruction (the next non-NOP instruction after the
/// trigger), does it consume the trigger's scratch register in a fusable
/// way? On match, fills in rewrite_op/dest_reg/src_reg/imm.
alias FusionConsumerFn = fn FusionMatch(Instruction trigger, Instruction consumer, uint scratch_reg, void* ctx);

/// One declarative fusion rule: {trigger predicate, consumer predicate}.
/// The shared driver (`run_fusion_rule`) owns NOP-skipping and the
/// dead-after-liveness scan; the rule only supplies the opcode-specific
/// matching/rewrite logic.
struct FusionRule {
    FusionTriggerFn  trigger;
    FusionConsumerFn consumer;
}

/// Scan forward from `start` (inclusive) and report whether `reg` is read
/// before it is next overwritten — the shared "is this scratch register
/// dead after the consumer" check every hand-written pass re-implements.
///
/// IF_TRUE/IF_FALSE use field `a` as a READ (the condition register), not a
/// write, so they're checked explicitly before the generic write-then-stop
/// rule. Only ABC-format opcodes have plain register operands in b/c;
/// A_BC/A_SBX/WIDE_* operands are indices or branch offsets, never register
/// references, and must not be misread as one.
fn bool fusion_reg_live_from(Instruction* code, uint code_count, uint start, uint reg) {
    for (uint j = start; j < code_count; j++) {
        Instruction jns = code[j];
        Opcode jop = jns.op;
        if (jop == Opcode.IF_TRUE || jop == Opcode.IF_FALSE) {
            if ((uint)jns.a == reg) { return true; }
            continue;
        }
        if (bytecode::get_op_format(jop) == OpFormat.ABC) {
            if ((uint)jns.b == reg || (uint)jns.c == reg) { return true; }
        }
        if ((uint)jns.a == reg) { return false; }   // overwritten -> dead from here
    }
    return false;
}

/// Run one fusion rule over the whole instruction stream. Owns:
///   - NOP-skipping to locate the consumer (copy-prop leaves NOPs between
///     a trigger and its now-adjacent-in-spirit consumer)
///   - the dead-after-liveness scan on the scratch register
///   - the NOP+rewrite emission
/// Jump-target safety is NOT re-derived here: NOP-ing the trigger slot is
/// always safe (a jump landing there falls through into the rewritten
/// consumer, which no longer depends on the trigger's register), which is
/// why every trigger-then-consumer fusion (not e.g. a fused *branch*) can
/// share this driver unconditionally.
fn void run_fusion_rule(Instruction* code, uint code_count, FusionRule rule, void* ctx = null) {
    for (uint i = 0; i < code_count; i++) {
        FusionMatch tm = rule.trigger(code[i], ctx);
        if (!tm.matched) { continue; }

        uint k = i + 1;
        while (k < code_count && code[k].op == Opcode.NOP) { k++; }
        if (k >= code_count) { continue; }

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
// Commutativity: ADD folds with rK as either source (rS+imm == imm+rS).
// SUB folds only `rS - imm` (rK must be the right/second source); `imm -
// rS` is not a subtract-immediate and is left alone.

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

    uint rS;
    if (is_sub) {
        if (rY != rK || rX == rK) { return m; }   // need `rX - rK`
        rS = rX;
    } else {
        if (rX == rK && rY != rK)      { rS = rY; }
        else if (rY == rK && rX != rK) { rS = rX; }
        else { return m; }
    }

    m.matched    = true;
    m.rewrite_op = is_sub ? Opcode.SUBI : Opcode.ADDI;
    m.dest_reg   = rD;
    m.src_reg    = rS;
    // Re-decode the immediate directly rather than threading it through
    // FusionMatch.dest_reg's caller — trigger.get_sbc() was already
    // range-checked to [-128,127] by fusion_addi_subi_trigger.
    m.imm        = (uint)(ichar)trigger.get_sbc();
    return m;
}

const FusionRule FUSION_ADDI_SUBI = {
    .trigger  = &fusion_addi_subi_trigger,
    .consumer = &fusion_addi_subi_consumer,
};

/// Run the declarative ADDI/SUBI fusion over `code[0..code_count)`.
/// Drop-in replacement for the hand-written pass at the same site in
/// CompilerContext.finish().
fn void fuse_addi_subi(Instruction* code, uint code_count) {
    run_fusion_rule(code, code_count, FUSION_ADDI_SUBI);
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
// (GETPROPC assumes string keys) — the only rule so far that needs more
// than the raw instruction bits to validate its trigger.
//
// Liveness: the shared dead-after scan (`fusion_reg_live_from`) already
// implements the exact rK-liveness rule the hand-written pass re-derived
// (IF_TRUE/IF_FALSE read `a`; ABC-format ops read `b`/`c`; any write to
// `a` ends the scan) — including the "rK kept alive for a following
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

/// Run the declarative GETPROPC fusion over `code[0..code_count)`.
/// Drop-in replacement for the hand-written pass at the same site in
/// CompilerContext.finish(). `constants` is the function's constant pool,
/// needed to validate the trigger (string key, index fits GETPROPC.c).
fn void fuse_getpropc(Instruction* code, uint code_count, TVal* constants) {
    run_fusion_rule(code, code_count, FUSION_GETPROPC, (void*)constants);
}

// ============================================================================
// 3-slot fusion driver: fixed physically-adjacent triple, middle slot rewrite
// ============================================================================
//
// ADDI/SUBI and GETPROPC both shrink a trigger+consumer pair down to one
// instruction by discarding a dying scratch register. GETVAR+INC/DEC+PUTVAR
// is shaped differently: it's a *three*-instruction window over ONE register
// that survives the fusion (it's a live variable, not a scratch temp), so
// there is nothing to NOP-skip to and no dead-after-liveness scan to run —
// the three ops are always physically adjacent by construction (the parser
// never interposes anything between a variable read, its increment, and the
// write-back), and correctness comes entirely from an equality match across
// all three slots, not from proving a register's death. Forcing this through
// `FusionMatch`/`run_fusion_rule` (which NOPs the trigger and rewrites the
// consumer) would mean inventing dummy liveness/immediate fields that don't
// mean anything for this pattern, so it gets its own minimal parallel
// schema instead of a mangled fit into the 2-slot one.

/// Result of matching a 3-slot fusion window.
struct Fusion3Match {
    bool   matched;
    Opcode rewrite_op;   // opcode to install at the middle slot
    uint   reg;          // the shared register (dest_reg field of the rewrite)
    uint   imm;          // immediate baked into the rewrite (e.g. a name index)
}

/// Given the three physically-adjacent instructions of a candidate window,
/// report whether they fuse. `slot0`/`slot1`/`slot2` are `code[i]`,
/// `code[i+1]`, `code[i+2]` — no NOP-skipping; this pattern requires exact
/// adjacency. `ctx` mirrors the 2-slot driver's opaque per-rule pointer
/// (see `FusionTriggerFn`).
alias Fusion3MatchFn = fn Fusion3Match(Instruction slot0, Instruction slot1, Instruction slot2, void* ctx);

struct Fusion3Rule {
    Fusion3MatchFn match;
}

/// Run one 3-slot fusion rule over the whole instruction stream. On match,
/// NOPs slot0 and slot2 and installs the rewrite (A-BC format: reg, imm) at
/// slot1 — the middle slot is always a valid landing point for control flow
/// (both a jump to slot0, which falls through, and a jump to slot1 itself,
/// which now finds the fused op) so no jump-target bitset is needed, exactly
/// as with the 2-slot driver's trigger-NOP.
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
// hasn't grown to yet — see fuse_inc_dec_var below for how it's threaded.

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

/// Run the declarative INC_VAR/DEC_VAR fusion over `code[0..code_count)`.
/// Drop-in replacement for the hand-written pass at the same site in
/// CompilerContext.finish(). `const_count` bounds the GETVAR/PUTVAR name
/// index, mirroring the original pass's `name0 < self.const_count` guard.
fn void fuse_inc_dec_var(Instruction* code, uint code_count, uint const_count) {
    run_fusion3_rule(code, code_count, FUSION_INC_DEC_VAR, (void*)&const_count);
}

// ============================================================================
// Jump-aware fusion driver: compare + IF_FALSE/IF_TRUE -> fused compare-branch
// ============================================================================
//
// This is the jump-fusing driver — structurally distinct from the two
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
// equality (SEQ/SNEQ) rules share every line of the driver — adding a compare
// form is a table entry, not a new hand-written scan.
//
// NOT included: loose EQ/NEQ. Those coerce operands via abstract_eq, which can
// call user code and throw; a fused branch would have to replicate the
// needs_restart/throw dance and is deliberately out of scope here.

/// One compare→branch fusion rule: `cmp_op` is the comparison opcode; the two
/// fused ops are what to install when the following instruction is IF_FALSE
/// (branch-when-compare-false) vs IF_TRUE (branch-when-compare-true).
struct CmpBranchRule {
    Opcode cmp_op;
    Opcode fused_if_false;
    Opcode fused_if_true;
}

/// The full compare→branch fusion table. Relational forms map onto the
/// existing JMP_N*/JMP_* opcodes; strict-equality forms map onto JMP_SEQ/
/// JMP_SNEQ. Note the polarity: SEQ+IF_FALSE branches when NOT strictly equal
/// (JMP_SNEQ) and SNEQ+IF_FALSE branches when strictly equal (JMP_SEQ).
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

/// Look up the fused opcode for a (compare, branch-direction) pair. Returns
/// NOP (never a real fused op) when the compare op has no fusion rule or is a
/// deliberately-excluded sentinel (EQ/NEQ).
fn Opcode cmp_branch_fused_op(Opcode cmp_op, bool is_if_false) {
    foreach (&rule : CMP_BRANCH_RULES) {
        if (rule.cmp_op == cmp_op) {
            Opcode fused = is_if_false ? rule.fused_if_false : rule.fused_if_true;
            return fused;
        }
    }
    return Opcode.NOP;
}

/// Scan a basic-block-local range [start, code_count) and report whether `reg`
/// is read before it is overwritten. Stops (treating `reg` as live) at the
/// first jump target — a new basic block we can't prove dead across — and at
/// terminal instructions (RET/THROW/JUMP) which end the block cleanly (dead).
/// This is the compare-result liveness rule the hand-written pass ran on both
/// the fall-through and taken-branch paths. `skip_first_target` lets the
/// branch-path scan ignore the jump-target flag on its own entry slot.
fn bool cmp_result_live_from(Instruction* code, uint code_count, bool* jump_targets,
                             uint start, uint reg, bool skip_first_target) {
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
                if (top == Opcode.GETPROPC) {
                    if ((uint)tj.b == reg) { return true; }
                } else if ((uint)tj.b == reg || (uint)tj.c == reg) {
                    return true;
                }
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
            continue;
        }
        OpFormat jfmt = bytecode::get_op_format(jop);
        if (jfmt == OpFormat.ABC) {
            if (jop == Opcode.GETPROPC) {
                if ((uint)jns.b == reg) { return true; }
            } else if ((uint)jns.b == reg || (uint)jns.c == reg) {
                return true;
            }
        }
        if (jfmt != OpFormat.WIDE_SABC && jfmt != OpFormat.WIDE_ABC) {
            if ((uint)jns.a == reg) { return false; }   // overwritten → dead
        }
    }
    return false;
}

/// Run all compare→branch fusions over `code[0..code_count)`. `jump_targets`
/// is a caller-provided scratch buffer of at least `code_count` bools (kept out
/// of this module so fusion.c3 stays free of any heap dependency). Drop-in
/// replacement for the hand-written comparison→JMP_N* pass in
/// CompilerContext.finish().
fn void run_cmp_branch_fusion(Instruction* code, uint code_count, bool* jump_targets) {
    if (code_count < 2) { return; }

    // --- Build the jump-target bitset. ---
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
        // past it. A backward continuation is a loop back-edge — not a bridge.
        int bridge_sbx = 0;
        uint bridge_slot = (uint)((int)i + 2 + sbx);
        if (bridge_slot < code_count) {
            Opcode bop = code[bridge_slot].op;
            if (bop == Opcode.IF_FALSE || bop == Opcode.IF_TRUE) {
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
        // pre-compare value, which is exactly what the target expects).
        uint rB = (uint)code[i].b;
        uint rC = (uint)code[i].c;
        bool ra_aliases_src = (rA == rB || rA == rC);
        if (!ra_aliases_src) {
            int tgt_raw = (int)i + 2 + sbx;
            if (tgt_raw >= 0 && (uint)tgt_raw < code_count) {
                if (cmp_result_live_from(code, code_count, jump_targets, (uint)tgt_raw, rA, true)) { continue; }
            }
        }

        // Adjusted offset must fit signed 8 bits (stored in field A).
        if (fused_off < -128 || fused_off > 127) { continue; }

        code[i]     = bytecode::make_abc(fused_op, (uint)(char)fused_off, rB, rC);
        code[i + 1] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
    }
}

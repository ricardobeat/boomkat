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
///      order-independent, could run anywhere before NOP compaction)
///   2. LDCONST+GETPROP -> GETPROPC                (same — order-independent)
///   3. comparison+IF_FALSE -> JMP_N*              (same — order-independent)
///   4. copy-propagation (LDREG rT=rX substitution) — MUST run before any
///      rule whose trigger's consumer may be separated from it by a
///      parser-emitted LDREG move (rule 5 depends on this).
///   5. LDINT+ADD/SUB -> ADDI/SUBI                 (declarative, this file)
///
/// Rules 1-3 don't interact with LDREG copy-prop and are left as hand-written
/// passes (see the design doc out/fusion-framework.md for how they'd map
/// onto this same framework). Rule 5 is the one ported below.

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

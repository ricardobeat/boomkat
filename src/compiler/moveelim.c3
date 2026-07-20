/// Liveness-based move (copy) elimination.
///
/// Targets the `producer rT=... ; LDREG rDst=rT` pattern the parser emits
/// whenever an expression result lands in a scratch register before being
/// copied into its final destination (e.g. a call argument: `n - 1` computes
/// into a temp, then an LDREG copies the temp into the argument slot). When
/// the producer can be safely retargeted to write rDst directly, the LDREG
/// becomes dead and is NOP'd, saving one dispatch.
///
/// This is NOT a local peephole: retargeting a producer to write rDst
/// instead of rT is only safe when rDst is not live-in at the producer's
/// site (no other value already in rDst is needed there) and rT is not
/// live-out of the LDREG (its only remaining use was this copy). Both facts
/// require whole-function liveness, not a local forward/backward scan from
/// the pair itself — the register allocator's scratch/live-range reuse means
/// two unrelated live ranges can sit in registers that are adjacent in the
/// instruction stream without being adjacent in their liveness. A prior
/// local-scan-only peephole attempt measured the same win but corrupted
/// state in 3 tests by retargeting into a still-live rDst; see
/// plans/ (move-elim liveness pass) for the postmortem.
///
/// Phase: runs after copy-propagation and all fusion passes (so LDREG moves
/// separated from their producer by copy-prop's own NOPs are already
/// resolved into adjacency where possible, and fused superinstructions are
/// in their final form), and before NOP compaction (so the NOPs this pass
/// introduces are physically removed).
module duktape::compiler;

import duktape::bytecode;

/// Number of uint words needed to hold a MAX_REGISTERS-sized bitset.
/// MAX_REGISTERS is defined in context.c3; this pass is only ever invoked
/// with `code_count` bounded reg indices that fit in a register file no
/// larger than that, so 512 bits (16 words) is always sufficient headroom.
const uint MOVEELIM_BITSET_WORDS = (512 + 31) / 32;

struct RegSet {
    uint[MOVEELIM_BITSET_WORDS] words;
}

fn void RegSet.clear(&self) {
    for (uint i = 0; i < MOVEELIM_BITSET_WORDS; i++) { self.words[i] = 0; }
}

fn void RegSet.set(&self, uint reg) {
    self.words[reg / 32] |= (1u << (reg % 32));
}

fn bool RegSet.test(&self, uint reg) {
    return (self.words[reg / 32] & (1u << (reg % 32))) != 0;
}

fn void RegSet.copy_from(&self, RegSet* other) {
    for (uint i = 0; i < MOVEELIM_BITSET_WORDS; i++) { self.words[i] = other.words[i]; }
}

fn void RegSet.union_with(&self, RegSet* other) {
    for (uint i = 0; i < MOVEELIM_BITSET_WORDS; i++) { self.words[i] |= other.words[i]; }
}

fn bool RegSet.equals(&self, RegSet* other) {
    for (uint i = 0; i < MOVEELIM_BITSET_WORDS; i++) {
        if (self.words[i] != other.words[i]) { return false; }
    }
    return true;
}

/// Whether `op`'s A field is a plain destination register that is
/// write-only — i.e. never simultaneously read as a value, a branch
/// condition, or an assignment source. This is the exhaustive
/// write-only-A allow-list (identical to `moveelim_producer_allowed`'s
/// opcode set, since those are exactly the opcodes this pass ever proves
/// safe to retarget); every opcode outside it is conservatively treated as
/// reading A (see `moveelim_a_is_read` below) even for opcodes where A is
/// actually unused (e.g. INITTZ, YIELD's B/C=0-only forms) — marking an
/// unused field as "read" only adds a harmless spurious liveness entry for
/// register 0, since unused fields are always encoded as 0.
fn bool moveelim_a_is_write_only(Opcode op) {
    return moveelim_producer_allowed(op);
}

/// Whether `op` reads its A field as a genuine register operand (a value
/// used as an input, an assignment source, or a branch condition) that
/// liveness must track as a use. Conservative default: true for every
/// opcode NOT proven write-only-A above — this is deliberately the inverse
/// of a deny-list, because the opcode surface here is too large (~130
/// opcodes) to safely enumerate every "A is a read" case by hand (PUTVAR/
/// PUTVAR_ASSIGN/DECLVAR/PUTLEX/PUTLEX_C/SETCONST/TOPROPKEY/TOSTR/INC/DEC/
/// IF_TRUE/IF_FALSE were all found this way, and that list is very likely
/// still incomplete). Over-marking A as "read" only makes liveness see a
/// register as live longer than strictly necessary — the same direction of
/// error as `moveelim_a_is_write`'s under-recognition above, and safe for
/// the identical reason: it can only suppress a retarget, never permit an
/// unsafe one.
fn bool moveelim_a_is_read(Opcode op) {
    return !moveelim_a_is_write_only(op);
}

/// Whether `op` writes its A field as a plain destination register, for the
/// purposes of the liveness def-kill (`live_in = uses U (live_out - defs)`).
///
/// This is a POSITIVE allow-list, not a deny-list: only opcodes explicitly
/// confirmed (against their doc comments in bytecode.c3) to treat A as a
/// pure "the result lands here" destination are included. Every other
/// opcode — including every fused/exotic form not individually reasoned
/// about here (JMP_NLT/JMP_SEQ/etc use A as a branch offset, not a
/// register, GETPROPC2 splits state across two slots, CALL/CALL_PROP/
/// NEW_OBJ/generator ops all have non-trivial A semantics) — returns
/// false. Under-recognizing a def only makes liveness treat a register as
/// live further back than strictly necessary (a missed optimization, never
/// an incorrect one): the register merely looks live-in one instruction
/// earlier than its true last use, which can only SUPPRESS a retarget
/// (rDst wrongly appears live-in at a producer site), never PERMIT an
/// unsafe one.
fn bool moveelim_a_is_write(Opcode op) {
    switch (op) {
        case Opcode.LDREG:
        case Opcode.LDCONST:
        case Opcode.LDINT:
        case Opcode.LDINTX:
        case Opcode.LDUNDEF:
        case Opcode.LDNULL:
        case Opcode.LDTRUE:
        case Opcode.LDFALSE:
        case Opcode.LDTHIS:
        case Opcode.ADD:
        case Opcode.SUB:
        case Opcode.MUL:
        case Opcode.DIV:
        case Opcode.MOD:
        case Opcode.EXP:
        case Opcode.ADDI:
        case Opcode.SUBI:
        case Opcode.UNP:
        case Opcode.UNM:
        case Opcode.BNOT:
        case Opcode.LNOT:
        case Opcode.TYPEOF:
        case Opcode.VOID:
        case Opcode.BAND:
        case Opcode.BOR:
        case Opcode.BXOR:
        case Opcode.SHL:
        case Opcode.SHR:
        case Opcode.USHR:
        case Opcode.EQ:
        case Opcode.NEQ:
        case Opcode.SEQ:
        case Opcode.SNEQ:
        case Opcode.LT:
        case Opcode.LE:
        case Opcode.GT:
        case Opcode.GE:
        case Opcode.INSTANCEOF:
        case Opcode.IN:
        case Opcode.GETPROP:
        case Opcode.GETPROTO:
        case Opcode.GETVAR:
        case Opcode.GETBOUND:
        case Opcode.TYPEOFIDENT:
            return true;

        default:
            return false;
    }
}

/// Whether `op`'s producer semantics are safe to retarget: writing directly
/// to rDst instead of rT must be equivalent to writing rT then copying —
/// i.e. the instruction must not itself special-case the identity of A
/// beyond "the result lands here" (no self-referential reads of A, no
/// multi-register writes tied to A's position, no control-flow dependence
/// on A's value at a *different* point than the copy would have observed).
/// This is a conservative allow-list, not a deny-list: only opcodes proven
/// to be a simple `A = f(B, C)` with A write-only are included.
fn bool moveelim_producer_allowed(Opcode op) {
    switch (op) {
        case Opcode.LDREG:
        case Opcode.LDCONST:
        case Opcode.LDINT:
        case Opcode.LDUNDEF:
        case Opcode.LDNULL:
        case Opcode.LDTRUE:
        case Opcode.LDFALSE:
        case Opcode.LDTHIS:
        case Opcode.ADD:
        case Opcode.SUB:
        case Opcode.MUL:
        case Opcode.DIV:
        case Opcode.MOD:
        case Opcode.EXP:
        case Opcode.ADDI:
        case Opcode.SUBI:
        case Opcode.UNP:
        case Opcode.UNM:
        case Opcode.BNOT:
        case Opcode.LNOT:
        case Opcode.TYPEOF:
        case Opcode.VOID:
        case Opcode.BAND:
        case Opcode.BOR:
        case Opcode.BXOR:
        case Opcode.SHL:
        case Opcode.SHR:
        case Opcode.USHR:
        case Opcode.EQ:
        case Opcode.NEQ:
        case Opcode.SEQ:
        case Opcode.SNEQ:
        case Opcode.LT:
        case Opcode.LE:
        case Opcode.GT:
        case Opcode.GE:
        case Opcode.INSTANCEOF:
        case Opcode.IN:
        case Opcode.GETPROP:
        case Opcode.GETPROTO:
        case Opcode.GETVAR:
        case Opcode.GETBOUND:
        case Opcode.TYPEOFIDENT:
            return true;
        default:
            return false;
    }
}

/// Re-encode `ins` (whose opcode is `op`) with A replaced by `new_a`,
/// preserving B/C or the combined BC/immediate payload according to `op`'s
/// operand format. Only ever called on opcodes accepted by
/// `moveelim_producer_allowed`, all of which use ABC, A_BC, or A_SBX.
fn Instruction moveelim_retarget_a(Instruction ins, Opcode op, uint new_a) {
    OpFormat fmt = bytecode::get_op_format(op);
    switch (fmt) {
        case OpFormat.A_BC:
            return bytecode::make_a_bc(op, new_a, ins.get_bc());
        case OpFormat.A_SBX:
            return bytecode::make_a_sbx(op, new_a, ins.get_sbc());
        default:
            return bytecode::make_abc(op, new_a, ins.b, ins.c);
    }
}

/// Add every register `ins` reads (per its opcode's operand format, plus the
/// A-is-read special cases) into `live`. Does NOT add the register(s) it
/// writes — callers apply the write-kill separately so the standard
/// backward liveness recurrence (`live_in = uses U (live_out - defs)`) holds.
fn void moveelim_add_uses(Instruction ins, RegSet* live) {
    Opcode op = ins.op;
    if (moveelim_a_is_read(op)) {
        live.set((uint)ins.a);
    }
    if (bytecode::get_op_format(op) == OpFormat.ABC) {
        // CALL/CALL_PROP/CALL_S/SUPER_CALL/SUPER_CALL_S/NEW_OBJ/NEW_OBJ_S/
        // TAILCALL's C field is an argument COUNT (or a count-register for
        // the _S forms — itself a genuine register read), never a plain
        // value register; including it as a "use" is always safe (it either
        // correctly marks a count-register live, or harmlessly marks an
        // unrelated low register live for opcodes with a literal count,
        // which can only make the analysis more conservative, never wrong).
        //
        // GETPROPC/GETPROPC2's C is a constant-pool index, not a register —
        // must NOT be read as a use (would wrongly keep an unrelated
        // register alive and could suppress a valid elimination, but never
        // corrupt correctness either way since over-conservative liveness
        // is always safe). Excluded explicitly for precision.
        if (op == Opcode.GETPROPC || op == Opcode.GETPROPC2 || op == Opcode.GETPROPC_CACHED) {
            live.set((uint)ins.b);
        } else {
            live.set((uint)ins.b);
            live.set((uint)ins.c);
        }
    }
    // A_BC/A_SBX/WIDE_ABC/WIDE_SABC/NONE formats carry no register operands
    // in b/c (they're indices, immediates, or branch offsets) — nothing to
    // add for those formats beyond the a-is-read case already handled.
}

/// Compute the register this instruction WRITES as a plain destination, if
/// any (per `moveelim_a_is_write`). Returns true and fills `out_reg` when
/// there is one.
fn bool moveelim_get_def(Instruction ins, uint* out_reg) {
    Opcode op = ins.op;
    if (!moveelim_a_is_write(op)) { return false; }
    *out_reg = (uint)ins.a;
    return true;
}

/// Build the jump-target bitset AND record, for TRY/ENDTRY pairs, the
/// [start,end] index ranges to exclude from elimination entirely (an
/// exception can transfer control from any instruction inside a protected
/// region straight to its catch/finally handler — an edge this pass's CFG
/// walk does not otherwise model). `in_try` is sized `code_count` and set
/// true for every instruction inside such a range (inclusive of TRY and its
/// matching ENDTRY).
fn void moveelim_mark_jump_targets_and_try_regions(Instruction* code, uint code_count,
                                                    bool* jump_targets, bool* in_try) {
    for (uint i = 0; i < code_count; i++) { jump_targets[i] = false; in_try[i] = false; }

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
                // Find the matching ENDTRY by scanning forward for the next
                // ENDTRY at nesting depth 0 relative to this TRY (TRY/ENDTRY
                // nest the same way parens do — statements.c3 emits exactly
                // one ENDTRY per TRY at the end of the protected block).
                uint depth = 1;
                uint j = i + 1;
                uint end_idx = i;
                while (j < code_count) {
                    if (code[j].op == Opcode.TRY) { depth++; }
                    else if (code[j].op == Opcode.ENDTRY) {
                        depth--;
                        if (depth == 0) { end_idx = j; break; }
                    }
                    j++;
                }
                if (end_idx == i) { end_idx = code_count > 0 ? code_count - 1 : 0; }
                for (uint k = i; k <= end_idx && k < code_count; k++) { in_try[k] = true; }
            }
            default: {}
        }
    }
}

/// Run liveness-based move elimination over `code[0..code_count)`.
///
/// For every `LDREG rDst = rT` at index `k` whose immediately preceding
/// non-NOP instruction at index `i` is an allow-listed producer writing rT
/// as its plain destination register, retarget the producer to write rDst
/// directly and NOP the LDREG, PROVIDED:
///   - rT is not live-out of the LDREG (its bitcode-visible-uses beyond this
///     copy are none — computed from whole-function backward liveness, not
///     a local scan);
///   - rDst is not live-in at the producer's site (no value already resident
///     in rDst needs to survive past the producer);
///   - rDst is not itself read by the producer as one of its own source
///     operands (retargeting would make the producer read its own
///     just-clobbered destination);
///   - neither the producer slot nor the LDREG slot is inside a try-
///     protected region (exception edges aren't modeled by this pass's CFG
///     walk);
///   - the LDREG slot's *destination* being rewritten in place is fine
///     regardless of whether it's a jump target (a jump landing there would
///     have expected rDst to already hold the producer's result — NOPing
///     it changes nothing observable since the producer immediately above
///     it, now the last write to rDst, already ran); the producer slot
///     itself must NOT be a jump target on the same reasoning as the
///     dead-after-liveness passes in fusion.c3 (a jump landing exactly on
///     the producer slot still executes the retargeted producer, which is
///     what we want) — so no additional guard is needed for either slot's
///     jump-target status.
fn void run_move_elimination(Instruction* code, uint code_count, bool* jump_targets, bool* in_try,
                              RegSet* live_out, RegSet* live_in) {
    if (code_count < 2) { return; }

    moveelim_mark_jump_targets_and_try_regions(code, code_count, jump_targets, in_try);

    // --- Backward liveness fixed-point over live-out sets. ---
    // live_out[i] = union of live_in[s] for every successor s of i.
    // live_in[i]  = uses(i) U (live_out[i] - defs(i)).
    for (uint i = 0; i < code_count; i++) { live_out[i].clear(); live_in[i].clear(); }

    bool changed = true;
    while (changed) {
        changed = false;
        // Iterate backward: on a typical (mostly-forward) CFG this converges
        // in very few passes since a single backward sweep already propagates
        // most fallthrough-chain liveness in one go; the fixed-point loop
        // only needs extra iterations for back-edges (loops).
        uint ii = code_count;
        while (ii > 0) {
            ii--;
            Instruction ins = code[ii];
            Opcode op = ins.op;

            RegSet new_out;
            new_out.clear();

            // Fallthrough successor: any instruction except an unconditional
            // jump/return/throw. (IF_TRUE/IF_FALSE/TRY DO fall through.)
            bool falls_through = !(op == Opcode.JUMP || op == Opcode.BREAK
                || op == Opcode.CONTINUE || op == Opcode.RET || op == Opcode.RET_GEN
                || op == Opcode.RETUNDEF || op == Opcode.RETUNDEF_GEN
                || op == Opcode.THROW || op == Opcode.THROW_REF || op == Opcode.THROW_SYNTAX);
            if (falls_through && ii + 1 < code_count) {
                new_out.union_with(&live_in[ii + 1]);
            }

            // Explicit branch/jump successor.
            switch (op) {
                case Opcode.JUMP:
                case Opcode.BREAK:
                case Opcode.CONTINUE: {
                    int off = ins.get_sabc();
                    int tgt = (int)ii + 1 + off;
                    if (tgt >= 0 && (uint)tgt < code_count) { new_out.union_with(&live_in[(uint)tgt]); }
                }
                case Opcode.IF_TRUE:
                case Opcode.IF_FALSE: {
                    int off = ins.get_sbc();
                    int tgt = (int)ii + 1 + off;
                    if (tgt >= 0 && (uint)tgt < code_count) { new_out.union_with(&live_in[(uint)tgt]); }
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
                    int tgt = (int)ii + 1 + off;
                    if (tgt >= 0 && (uint)tgt < code_count) { new_out.union_with(&live_in[(uint)tgt]); }
                }
                case Opcode.TRY: {
                    uint catch_off = ins.get_bc();
                    uint catch_tgt = ii + catch_off;
                    if (catch_tgt < code_count) { new_out.union_with(&live_in[catch_tgt]); }
                    if (ii + 1 < code_count) {
                        uint finally_off = code[ii + 1].get_bc();
                        if (finally_off != 0) {
                            uint finally_tgt = ii + finally_off;
                            if (finally_tgt < code_count) { new_out.union_with(&live_in[finally_tgt]); }
                        }
                    }
                }
                default: {}
            }

            if (!new_out.equals(&live_out[ii])) {
                live_out[ii].copy_from(&new_out);
                changed = true;
            }

            // live_in[ii] = uses(ii) U (live_out[ii] - defs(ii))
            RegSet new_in;
            new_in.copy_from(&live_out[ii]);
            uint def_reg;
            if (moveelim_get_def(ins, &def_reg)) {
                new_in.words[def_reg / 32] &= ~(1u << (def_reg % 32));
            }
            RegSet uses;
            uses.clear();
            moveelim_add_uses(ins, &uses);
            new_in.union_with(&uses);

            if (!new_in.equals(&live_in[ii])) {
                live_in[ii].copy_from(&new_in);
                changed = true;
            }
        }
    }

    // --- Elimination pass: for every LDREG rDst=rT, find its immediately
    // preceding non-NOP instruction (the producer candidate) and retarget
    // when every safety condition holds. ---
    for (uint k = 1; k < code_count; k++) {
        if (code[k].op != Opcode.LDREG) { continue; }
        if (in_try[k]) { continue; }

        // The LDREG slot must not itself be a jump target: unlike a fusion
        // trigger (safe to NOP because control falls through to the still-
        // intact consumer immediately after), here the LDREG IS the
        // instruction being removed. A branch that lands directly on it —
        // e.g. the fall-through arm of an if/else or ternary converging
        // into a single post-join copy, where only ONE arm reaches this
        // slot by textual fallthrough and every other arm reaches it via a
        // jump — still expects the copy to run for its own producer (a
        // different, earlier register than the textually-preceding one
        // this pass would retarget). Removing it would silently skip the
        // copy for every predecessor that isn't the textual one.
        if (jump_targets[k]) { continue; }

        uint rDst = (uint)code[k].a;
        uint rT   = (uint)code[k].b;
        if (rDst == rT) { continue; }   // a no-op move; unrelated to this pass

        // rT must be dead-out of the LDREG: live_out[k] excludes rT (its
        // only remaining use besides this copy is none).
        if (live_out[k].test(rT)) { continue; }

        int pi = -1;
        uint scan = k;
        while (scan > 0) {
            scan--;
            if (code[scan].op != Opcode.NOP) { pi = (int)scan; break; }
        }
        if (pi < 0) { continue; }
        uint i = (uint)pi;
        if (in_try[i]) { continue; }

        // The producer slot must not be a jump target either: a jump
        // landing directly on the producer bypasses whatever came before
        // it, so the producer may be shared by more than one logical path
        // (e.g. this LDREG's textual predecessor AND a separate jump-in
        // entry point that reaches the producer for an unrelated purpose).
        // Retargeting it to rDst would silently change every such path,
        // not just the one this LDREG belongs to. Excluding jump-target
        // producers is always conservative — it only forfeits eliminations
        // where the producer happens to double as a branch landing site.
        if (jump_targets[i]) { continue; }

        Instruction producer = code[i];
        Opcode pop = producer.op;
        if (!moveelim_producer_allowed(pop)) { continue; }

        uint def_reg;
        if (!moveelim_get_def(producer, &def_reg)) { continue; }
        if (def_reg != rT) { continue; }   // not this LDREG's producer

        // rDst must not be read by the producer itself as a source operand
        // (retargeting would make it read its own about-to-be-clobbered
        // destination instead of the original value).
        RegSet producer_uses;
        producer_uses.clear();
        moveelim_add_uses(producer, &producer_uses);
        if (producer_uses.test(rDst)) { continue; }

        // rDst must not be live-in at the producer's site: live_in[i] is
        // computed as uses(i) U (live_out[i] - defs(i)); since defs(i) is
        // rT (not rDst), rDst is live-in here iff either the producer uses
        // it (already excluded above) or it's live-out of the producer.
        // live_out[i] with the producer's own def removed is exactly
        // live_in[i] minus uses(i) — but the simplest direct and always-
        // correct check is: is rDst live going INTO instruction i, i.e.
        // is it in live_in[i]? A register in live_in[i] but not among the
        // producer's own uses is live purely because it survives i to some
        // later point — precisely the "already resident value that must
        // not be clobbered" case this guard exists for.
        if (live_in[i].test(rDst)) { continue; }

        // The LDREG slot itself must not be a jump target that also serves
        // as a target for skip-shortcircuit style materialization tricks —
        // no such interaction exists for this pattern (unlike the fused
        // compare-branch pass), so no extra guard beyond try-region
        // exclusion and the liveness checks above is required.

        code[i] = moveelim_retarget_a(producer, pop, rDst);
        code[k] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
    }
}

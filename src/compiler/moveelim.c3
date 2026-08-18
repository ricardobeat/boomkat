/// Liveness-based move (copy) elimination.
///
/// Two transforms share a whole-function liveness pass in two flavors (with
/// and without the call-family argument windows, see run_move_elimination):
///
/// 1. Producer retargeting. Targets the `producer rT=... ; LDREG rDst=rT`
///    pattern the parser emits whenever an expression result lands in a
///    scratch register before being copied into its final destination (e.g.
///    a call argument: `n - 1` computes into a temp, then an LDREG copies
///    the temp into the argument slot). When the producer can be safely
///    retargeted to write rDst directly, the LDREG becomes dead and is
///    NOP'd, saving one dispatch.
/// 2. Dead-destination removal. An `LDREG rDst=rT` whose rDst is not
///    live-out of the copy is NOP'd as-is: nothing downstream reads the
///    destination, so the copy has no observable effect. No producer is
///    involved and nothing is rewritten. This catches copies that hold a
///    discarded statement value (the `sum += v` expression-statement
///    shape), which retargeting cannot touch because rT stays live.
///
/// This is NOT a local peephole: retargeting a producer to write rDst
/// instead of rT is only safe when rDst is not live-in at the producer's
/// site (no other value already in rDst is needed there) and rT is not
/// live-out of the LDREG (its only remaining use was this copy). Both facts
/// require whole-function liveness, not a local forward/backward scan from
/// the pair itself, since the register allocator's scratch and live-range reuse mean
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
module boomkat::compiler;

import boomkat::bytecode;

/// Register bitset for the liveness pass, sized to the registers the
/// function under compilation actually uses instead of the full 16-bit
/// register file. A fixed MAX_REGISTERS-wide set is 8 KB per instruction
/// slot, which turns the four per-PC liveness arrays into megabytes even
/// for a function whose register high-water mark is a few dozen.
/// `words` points into the per-function liveness arena allocated in
/// CompilerContext.finish; `word_count` is how many words are valid, so a
/// set covering registers 0..max_reg-1 needs (max_reg + 31) / 32 words.
struct RegSet {
    uint* words;
    uint  word_count;
}

fn void RegSet.clear(&self) {
    for (uint i = 0; i < self.word_count; i++) { self.words[i] = 0; }
}

/// Both accessors clamp to the allocated word count. `moveelim_a_is_read` is
/// the inverse of a small allow-list, so A is read as a register for opcodes
/// where it is really a packed branch offset (JUMP, JMP_LT, JMP_SNEQ) whose
/// value routinely exceeds the function's register high-water mark. That was
/// harmless while every set covered the whole 16-bit register file, but the
/// sets are now sized to max_reg, so an unclamped index writes past the arena.
/// Dropping an out-of-range register loses nothing: the function has no such
/// register, so nothing can be live in it.
fn void RegSet.set(&self, uint reg) {
    uint w = reg / 32;
    if (w >= self.word_count) return;
    self.words[w] |= (1u << (reg % 32));
}

fn void RegSet.unset(&self, uint reg) {
    uint w = reg / 32;
    if (w >= self.word_count) return;
    self.words[w] &= ~(1u << (reg % 32));
}

fn bool RegSet.test(&self, uint reg) {
    uint w = reg / 32;
    if (w >= self.word_count) return false;
    return (self.words[w] & (1u << (reg % 32))) != 0;
}

fn void RegSet.copy_from(&self, RegSet* other) {
    for (uint i = 0; i < self.word_count; i++) { self.words[i] = other.words[i]; }
}

fn void RegSet.union_with(&self, RegSet* other) {
    for (uint i = 0; i < self.word_count; i++) { self.words[i] |= other.words[i]; }
}

fn bool RegSet.equals(&self, RegSet* other) {
    for (uint i = 0; i < self.word_count; i++) {
        if (self.words[i] != other.words[i]) { return false; }
    }
    return true;
}

/// Whether `op`'s A field is a plain destination register that is
/// write-only, meaning never simultaneously read as a value, a branch
/// condition, or an assignment source. This is the exhaustive
/// write-only-A allow-list (identical to `moveelim_producer_allowed`'s
/// opcode set, since those are exactly the opcodes this pass ever proves
/// safe to retarget); every opcode outside it is conservatively treated as
/// reading A (see `moveelim_a_is_read` below) even for opcodes where A is
/// actually unused (e.g. INITTZ, YIELD's B/C=0-only forms), marking an
/// unused field as "read" only adds a harmless spurious liveness entry for
/// register 0, since unused fields are always encoded as 0.
fn bool moveelim_a_is_write_only(Opcode op) {
    return moveelim_producer_allowed(op);
}

/// Whether `op` reads its A field as a genuine register operand (a value
/// used as an input, an assignment source, or a branch condition) that
/// liveness must track as a use. Conservative default: true for every
/// opcode NOT proven write-only-A above, this is deliberately the inverse
/// of a deny-list, because the opcode surface here is too large (~130
/// opcodes) to safely enumerate every "A is a read" case by hand (PUTVAR/
/// PUTVAR_ASSIGN/DECLVAR/PUTLEX/PUTLEX_C/SETCONST/TOPROPKEY/TOSTR/INC/DEC/
/// IF_TRUE/IF_FALSE were all found this way, and that list is very likely
/// still incomplete). Over-marking A as "read" only makes liveness see a
/// register as live longer than strictly necessary, which is the same direction of
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
/// opcode, including every fused/exotic form not individually reasoned
/// about here (JMP_NLT/JMP_SEQ/etc use A as a branch offset, not a
/// register, GETPROPC2 splits state across two slots, CALL/CALL_PROP/
/// NEW_OBJ/generator ops all have non-trivial A semantics), returns
/// false. Under-recognizing a def only makes liveness treat a register as
/// live further back than strictly necessary (a missed optimization, never
/// an incorrect one): the register merely looks live-in one instruction
/// earlier than its true last use, which can only SUPPRESS a retarget
/// (rDst wrongly appears live-in at a producer site), never PERMIT an
/// unsafe one.
fn bool moveelim_a_is_write(Opcode op) {
    // Identical to the producer allow-list, plus LDINTX: it writes A as a
    // plain destination, but is excluded from producer retargeting because
    // it spans two instruction words.
    return op == Opcode.LDINTX || moveelim_producer_allowed(op);
}

/// Whether `op`'s producer semantics are safe to retarget: writing directly
/// to rDst instead of rT must be equivalent to writing rT then copying, so
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
        case Opcode.GETGLOBAL:
        case Opcode.GETGLOBAL_PRIM:
        case Opcode.TYPEOFIDENT:
            return true;
        default:
            return false;
    }
}

/// Whether `op` is safe to retarget into rDst EVEN WHEN the producer reads
/// rDst as one of its own source operands, as in `A = f(A, ...)` (or the
/// unary `A = f(A)`) is a correct in-place accumulate on this register
/// machine. This holds for exactly the arithmetic and bitwise value ops,
/// each of which reads ALL of its source operands (rb, rc) into locals and
/// computes the full result BEFORE writing its A destination (verified
/// against vm_execute.c3 / vm_arith.c3 / vm_bigint.c3): the fastint fast
/// paths read rb/rc then `ra.set_*` last; the numeric slow paths compute
/// both `vm_to_number` results before the final `ra.set_*`; and the bigint
/// paths (`vm_bigint_binop`/`vm_bigint_unary`) copy `*rb`/`*rc` into locals
/// at entry and only write `*ra` at the very end. So aliasing ra==rb (or
/// ra==rc) never clobbers an operand before it is read.
///
/// This is a strict SUBSET of `moveelim_producer_allowed`. Ops deliberately
/// excluded (even though they too write A last): comparisons and the
/// property/var loads (GETPROP/GETVAR/etc), which are covered by the base
/// allow-list for the non-aliasing case but are kept conservative here since
/// the cross-axis accumulate win comes only from the arithmetic/bitwise
/// family. LDREG is excluded because a producer whose A==rDst would be a
/// self-copy already filtered upstream.
fn bool moveelim_accum_safe(Opcode op) {
    switch (op) {
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
        case Opcode.BAND:
        case Opcode.BOR:
        case Opcode.BXOR:
        case Opcode.SHL:
        case Opcode.SHR:
        case Opcode.USHR:
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

/// Mark every register in [first, last] (inclusive) as used, clamped to
/// the bitset.
fn void moveelim_mark_range(RegSet* live, uint first, uint last) {
    uint hi = last;
    if (hi >= live.word_count * 32) { hi = live.word_count * 32 - 1; }
    for (uint r = first; r <= hi; r++) { live.set(r); }
}

/// Add every register `ins` reads (per its opcode's operand format, plus the
/// A-is-read special cases) into `live`. Does NOT add the register(s) it
/// writes, callers apply the write-kill separately so the standard
/// backward liveness recurrence (`live_in = uses U (live_out - defs)`) holds.
/// `mark_call_windows` additionally marks the call-family argument windows.
fn void moveelim_add_uses(Instruction ins, RegSet* live, bool mark_call_windows) {
    Opcode op = ins.op;

    // Call-family argument windows. The VM builds the callee's frame at
    // callee_reg + 2 and reads every register from the callee slot up
    // through the last argument, but those slots are not operands of the
    // call instruction itself, so the generic marking below never sees
    // them as uses. Literal-count forms mark the exact window
    // (callee_reg .. callee_reg + 1 + nargs); the _S forms read the count
    // from a register at runtime, so the window top is unknown and
    // everything from the callee register up is marked.
    //
    // This over-approximation is loaded only into the dead-destination
    // liveness (see run_move_elimination). The producer-retarget liveness
    // runs with it OFF: a call reads the window slots as ARGUMENTS, whose
    // values arrive via SPREAD_ARG/PUTARG or the argument LDREGs, never via
    // a retargetable producer. Marking them live would wrongly suppress the
    // retarget that makes a trailing non-spread argument safe (`f(1,...a,99)`
    // needs `LDINT rT, 99; LDREG scratch, rT` collapsed so the literal is
    // written below first_arg, outside the spread's dest window).
    if (mark_call_windows) {
        switch (op) {
            case Opcode.CALL:
            case Opcode.CALL_UNDEF_THIS:
            case Opcode.NEW_OBJ:
            case Opcode.SUPER_CALL:
                moveelim_mark_range(live, (uint)ins.b, (uint)ins.b + 1 + (uint)ins.c);
            case Opcode.CALL_VAR:
            case Opcode.CALL_GLOBAL:
                // A is the callee/result slot, B the literal arg count.
                moveelim_mark_range(live, (uint)ins.a, (uint)ins.a + 1 + (uint)ins.b);
            case Opcode.CALL_S:
            case Opcode.NEW_OBJ_S:
            case Opcode.SUPER_CALL_S:
                moveelim_mark_range(live, (uint)ins.b, live.word_count * 32 - 1);
            default: {}
        }
    }

    if (moveelim_a_is_read(op)) {
        live.set((uint)ins.a);
    }
    if (bytecode::get_op_format(op) == OpFormat.ABC) {
        // CALL/CALL_PROP/CALL_S/SUPER_CALL/SUPER_CALL_S/NEW_OBJ/NEW_OBJ_S/
        // TAILCALL's C field is an argument COUNT (or a count-register for
        // the _S forms, itself a genuine register read), never a plain
        // value register; including it as a "use" is always safe (it either
        // correctly marks a count-register live, or harmlessly marks an
        // unrelated low register live for opcodes with a literal count,
        // which can only make the analysis more conservative, never wrong).
        //
        // GETPROPC and GETPROPC2 use C as a constant-pool index, not a register,
        // must NOT be read as a use (would wrongly keep an unrelated
        // register alive and could suppress a valid elimination, but never
        // corrupt correctness either way since over-conservative liveness
        // is always safe). Excluded explicitly for precision.
        //
        // LDREG (`A = B`) defaults to ABC but its C field is unused, since the VM
        // reads only rb (verified in vm_execute.c3). Marking C (encoded 0) as
        // a use spuriously keeps r0 live across every LDREG, which in
        // particular defeats the accumulate move-elimination whenever the
        // accumulator lives in r0 (`s = s + 1` with s in r0): the copy's own
        // C=0 makes r0 look live-out of the producer. Reading only B here is
        // both correct (C is genuinely never read) and necessary for that
        // optimization to fire.
        if (op == Opcode.GETPROPC || op == Opcode.GETPROPC2 || op == Opcode.GETPROPC_CACHED
            || op == Opcode.LDREG) {
            live.set((uint)ins.b);
        } else {
            live.set((uint)ins.b);
            live.set((uint)ins.c);
        }
    }
    // A_BC/A_SBX/WIDE_ABC/WIDE_SABC/NONE formats carry no register operands
    // in b/c (they're indices, immediates, or branch offsets), nothing to
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
/// region straight to its catch/finally handler, an edge this pass's CFG
/// walk does not otherwise model). `in_try` is sized `code_count` and set
/// true for every instruction inside such a range (inclusive of TRY and its
/// matching ENDTRY).
///
/// The jump-target half is `build_jump_targets`, not a copy of it. This pass
/// wants the same answer to "can control arrive here from elsewhere" that the
/// fusion passes want, so a second switch over the branch opcodes would be one
/// more place to remember when a branch form is added.
fn void moveelim_mark_jump_targets_and_try_regions(Instruction* code, uint code_count,
                                                    bool* jump_targets, bool* in_try) {
    build_jump_targets(code, code_count, jump_targets);

    for (uint i = 0; i < code_count; i++) { in_try[i] = false; }

    for (uint i = 0; i < code_count; i++) {
        if (code[i].op != Opcode.TRY) { continue; }
        // Find the matching ENDTRY by scanning forward for the next ENDTRY at
        // nesting depth 0 relative to this TRY (TRY/ENDTRY nest the same way
        // parens do, statements.c3 emits exactly one ENDTRY per TRY at the end
        // of the protected block).
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
}

/// Run liveness-based move elimination over `code[0..code_count)`.
///
/// For every `LDREG rDst = rT` at index `k` whose immediately preceding
/// non-NOP instruction at index `i` is an allow-listed producer writing rT
/// as its plain destination register, retarget the producer to write rDst
/// directly and NOP the LDREG, PROVIDED:
///   - rT is not live-out of the LDREG (its bitcode-visible-uses beyond this
///     copy are none, computed from whole-function backward liveness, not
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
///     have expected rDst to already hold the producer's result, NOPing
///     it changes nothing observable since the producer immediately above
///     it, now the last write to rDst, already ran); the producer slot
///     itself must NOT be a jump target on the same reasoning as the
///     dead-after-liveness passes in fusion.c3 (a jump landing exactly on
///     the producer slot still executes the retargeted producer, which is
///     what we want), so no additional guard is needed for either slot's
///     jump-target status.
/// Backward liveness fixed-point over live-out sets.
/// live_out[i] = union of live_in[s] for every successor s of i.
/// live_in[i]  = uses(i) U (live_out[i] - defs(i)).
/// `mark_call_windows` picks the use-set's view of the call-family argument
/// windows: ON for the dead-destination liveness, OFF for the producer-
/// retarget liveness (see run_move_elimination for why the two differ).
/// `scratch` supplies the three working sets (new_out, new_in, uses), whose
/// words are already wired into the function's liveness arena.
fn void moveelim_compute_liveness(Instruction* code, uint code_count, RegSet* live_out, RegSet* live_in,
                                  bool mark_call_windows, RegSet* scratch) {
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

            RegSet* new_out = &scratch[0];
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
                live_out[ii].copy_from(new_out);
                changed = true;
            }

            // live_in[ii] = uses(ii) U (live_out[ii] - defs(ii))
            RegSet* new_in = &scratch[1];
            new_in.copy_from(&live_out[ii]);
            uint def_reg;
            if (moveelim_get_def(ins, &def_reg)) {
                new_in.unset(def_reg);
            }
            RegSet* uses = &scratch[2];
            uses.clear();
            moveelim_add_uses(ins, uses, mark_call_windows);
            new_in.union_with(uses);

            if (!new_in.equals(&live_in[ii])) {
                live_in[ii].copy_from(new_in);
                changed = true;
            }
        }
    }
}

/// Run liveness-based move elimination over `code[0..code_count)`.
///
/// Two transforms share the pass:
///
/// 1. Producer retargeting (the pass's original job): for every
///    `LDREG rDst = rT` at index `k` whose immediately preceding non-NOP
///    instruction at index `i` is an allow-listed producer writing rT as its
///    plain destination register, retarget the producer to write rDst
///    directly and NOP the LDREG. Safe when rT is not live-out of the LDREG
///    (its bitcode-visible uses beyond this copy are none, from whole-
///    function backward liveness, not a local scan), rDst is not live-in at
///    the producer's site, rDst is not itself read by the producer (unless
///    the opcode is an accumulate-safe arithmetic op, whose read-before-write
///    A makes in-place retargeting correct), and neither slot is inside a
///    try-protected region (exception edges aren't modeled by this pass's
///    CFG walk). The LDREG slot may be a jump target (a jump landing there
///    expects rDst to hold the producer's result; NOPing the copy changes
///    nothing since the producer immediately above, now the last write to
///    rDst, already ran); the producer slot must not be, on the same
///    reasoning as the dead-after-liveness passes in fusion.c3.
///
/// 2. Dead-destination elimination: when rDst is not live-out of the LDREG,
///    nothing downstream reads it, so the copy is removable outright.
///
/// The two transforms need different liveness views of the call-family
/// argument windows (see moveelim_add_uses). `live_out`/`live_in` include
/// them, so the dead-destination check sees every register a call reads as
/// its callee, receiver, or argument and never removes a copy writing into a
/// live window. `ret_out`/`ret_in` exclude them, which keeps the producer-
/// retarget logic on its historical ground: the window over-approximation
/// would otherwise suppress the retarget that makes a trailing non-spread
/// argument after a spread safe (`f(1,...a,99)`).
fn void run_move_elimination(Instruction* code, uint code_count, bool* jump_targets, bool* in_try,
                              RegSet* live_out, RegSet* live_in, RegSet* ret_out, RegSet* ret_in,
                              RegSet* scratch) {
    if (code_count < 2) { return; }

    moveelim_mark_jump_targets_and_try_regions(code, code_count, jump_targets, in_try);

    moveelim_compute_liveness(code, code_count, live_out, live_in, true, scratch);
    moveelim_compute_liveness(code, code_count, ret_out, ret_in, false, scratch);

    // --- Elimination pass: for every LDREG rDst=rT, find its immediately
    // preceding non-NOP instruction (the producer candidate) and retarget
    // when every safety condition holds. ---
    for (uint k = 1; k < code_count; k++) {
        if (code[k].op != Opcode.LDREG) { continue; }
        if (in_try[k]) { continue; }

        // The LDREG slot must not itself be a jump target: unlike a fusion
        // trigger (safe to NOP because control falls through to the still-
        // intact consumer immediately after), here the LDREG IS the
        // instruction being removed. A branch that lands directly on it
        // e.g. the fall-through arm of an if/else or ternary converging
        // into a single post-join copy, where only ONE arm reaches this
        // slot by textual fallthrough and every other arm reaches it via a
        // jump, still expects the copy to run for its own producer (a
        // different, earlier register than the textually-preceding one
        // this pass would retarget). Removing it would silently skip the
        // copy for every predecessor that isn't the textual one.
        if (jump_targets[k]) { continue; }

        uint rDst = (uint)code[k].a;
        uint rT   = (uint)code[k].b;
        if (rDst == rT) { continue; }   // a no-op move; unrelated to this pass

        // Dead destination: if rDst is not live-out of the copy, nothing
        // downstream reads it, so the copy is removable outright. No
        // producer is retargeted and no instruction is rewritten; the
        // LDREG simply never runs. This check uses the window-inclusive
        // live_out, so an argument slot a later call reads is never seen as
        // dead. The jump-target and try-region guards above are what make
        // the removal sound: a branch landing on this slot, or an exception
        // edge out of a try region, could both reach code that expects the
        // copy to have executed, and neither edge is in this pass's CFG walk.
        if (!live_out[k].test(rDst)) {
            code[k] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
            continue;
        }

        // rT must be dead-out of the LDREG: ret_out[k] excludes rT (its
        // only remaining use besides this copy is none). ret_out is the
        // window-free liveness; a call window must not pin rT here, or the
        // trailing-arg-after-spread retarget (which moves the literal write
        // below first_arg) would never fire.
        if (ret_out[k].test(rT)) { continue; }

        int pi = -1;
        uint scan = k;
        while (scan > 0) {
            scan--;
            if (code[scan].op != Opcode.NOP) { pi = (int)scan; break; }
        }
        if (pi < 0) { continue; }
        uint i = (uint)pi;
        if (in_try[i]) { continue; }

        Instruction producer = code[i];
        Opcode pop = producer.op;
        if (!moveelim_producer_allowed(pop)) { continue; }

        uint def_reg;
        if (!moveelim_get_def(producer, &def_reg)) { continue; }
        if (def_reg != rT) { continue; }   // not this LDREG's producer

        bool accum = moveelim_accum_safe(pop);

        // The producer slot must not be a jump target: a jump landing
        // directly on the producer bypasses whatever came before it, so the
        // producer may be shared by more than one logical path (e.g. this
        // LDREG's textual predecessor AND a separate jump-in entry point
        // that reaches the producer for an unrelated purpose). Retargeting
        // it to rDst would silently change every such path.
        //
        // For the ACCUMULATE case (`A = A op B`) this guard is relaxed: the
        // hottest instance is exactly a jump-target producer, the loop-body
        // entry `s = s + 1` that the back-edge conditional jumps onto. The
        // retarget is safe for EVERY entry path because (a) every path
        // reaching the producer falls straight through to this LDREG (only
        // NOPs between; the LDREG being a separate jump target is excluded
        // above), so retarget+NOP is consistent on all paths; and (b) the
        // whole-function backward liveness below already models the jump/
        // back-edges into the producer, so `ret_out[i].test(rDst)` catches
        // any path on which rDst would still be needed after the producer.
        // rT dead-out of the LDREG is checked above and covers the loss of
        // rT's copy. So no extra jump-target-producer guard is needed here.
        if (!accum && jump_targets[i]) { continue; }

        // Does the producer read rDst as one of its own source operands?
        // Normally this bails: retargeting would make the producer read its
        // own just-clobbered destination. But for the arithmetic/bitwise
        // accumulate ops (`A = A op B`, `A = op(A)`, the `s = s + 1` /
        // `acc = acc * x` / `n = n - 1` family) it is CORRECT: every op in
        // `moveelim_accum_safe` reads all its source operands before writing
        // A, so aliasing ra==rb/rc reads the old value first. See that
        // helper for the per-op read-before-write verification.
        RegSet* producer_uses = &scratch[3];
        producer_uses.clear();
        moveelim_add_uses(producer, producer_uses, false);
        bool producer_reads_rdst = producer_uses.test(rDst);
        if (producer_reads_rdst && !accum) { continue; }

        // rDst must not be live-in at the producer's site: ret_in[i] is
        // computed as uses(i) U (ret_out[i] - defs(i)); since defs(i) is
        // rT (not rDst), rDst is live-in here iff either the producer uses
        // it or it's live-out of the producer.
        //
        // For the ordinary (non-accumulate) case the producer does NOT read
        // rDst, so ret_in[i].test(rDst) == ret_out[i].test(rDst): a set
        // bit means an already-resident value survives past i and must not
        // be clobbered, bail.
        //
        // For the accumulate case the producer DOES read rDst, so rDst is in
        // ret_in[i] purely because of that read, which is exactly the value
        // we want to consume, not a survival hazard. The real hazard is rDst
        // being needed AFTER the producer, i.e. rDst in ret_out[i]. But rDst
        // can never be live-out of the producer here: the only successor
        // reachable before rDst's next def is the LDREG at k (only NOPs sit
        // between i and k), and the LDREG defines rDst, killing it on
        // the path from i, leaving ret_out[i] free of rDst except when a NOP
        // between i and k spuriously marks r0. Checking ret_out[i] (not
        // ret_in[i]) for the accumulate case is therefore the correct guard:
        // it ignores the producer's own consuming read while still catching
        // any genuine post-producer survival of rDst.
        if (accum && producer_reads_rdst) {
            if (ret_out[i].test(rDst)) { continue; }
        } else {
            if (ret_in[i].test(rDst)) { continue; }
        }

        // The LDREG slot itself must not be a jump target that also serves
        // as a target for skip-shortcircuit style materialization tricks,
        // no such interaction exists for this pattern (unlike the fused
        // compare-branch pass), so no extra guard beyond try-region
        // exclusion and the liveness checks above is required.

        code[i] = moveelim_retarget_a(producer, pop, rDst);
        code[k] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
    }
}

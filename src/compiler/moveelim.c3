// Liveness-based move (copy) elimination.
//
// Two transforms share a whole-function liveness pass:
//
// 1. Producer retargeting. Matches `producer rT=... ; LDREG rDst=rT`. When
//    the producer can write rDst directly, the LDREG is replaced with NOP.
// 2. Dead-destination removal. An `LDREG rDst=rT` whose rDst is not
//    live-out of the copy is replaced with NOP.
//
// Retargeting a producer to write rDst instead of rT requires whole-function
// liveness: rDst must not be live-in at the producer, and rT must not be
// live-out of the LDREG.
//
// Runs after copy-propagation and fusion passes, and before NOP compaction.
module boomkat::compiler;

import boomkat::bytecode;

// Register bitset for the liveness pass, sized to the highest register the
// function uses. Words point into the per-function liveness arena.
struct RegSet {
    uint* words;
    uint  word_count;
}

fn void RegSet.clear(&self) {
    for (uint i = 0; i < self.word_count; i++) { self.words[i] = 0; }
}

// Accessors clamp to the allocated word count so out-of-range register
// indices do not write past the arena.
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

// True if op's A field is write-only. Every opcode outside this allow-list
// is conservatively treated as reading A.
fn bool moveelim_a_is_write_only(Opcode op) {
    return moveelim_producer_allowed(op);
}

// True if op reads its A field as a register operand. Conservatively
// defaults to true for any opcode not proven write-only.
fn bool moveelim_a_is_read(Opcode op) {
    return !moveelim_a_is_write_only(op);
}

// True if op writes its A field as a destination register for liveness
// def-kill calculation (`live_in = uses U (live_out - defs)`).
fn bool moveelim_a_is_write(Opcode op) {
    // Identical to the producer allow-list, plus LDINTX which spans two words.
    return op == Opcode.LDINTX || moveelim_producer_allowed(op);
}

// True if writing directly to rDst instead of rT is semantics-preserving.
// Limited to simple operations where A is purely the destination.
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

// True if op is safe to retarget into rDst even when the producer reads rDst
// as a source operand (`A = f(A, ...)`). Holds for arithmetic and bitwise
// operations, which read all source operands before writing the result into A.
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

// Re-encode `ins` (whose opcode is `op`) with A replaced by `new_a`,
// preserving B/C or the combined BC/immediate payload according to `op`'s
// operand format. Only ever called on opcodes accepted by
// `moveelim_producer_allowed`, all of which use ABC, A_BC, or A_SBX.
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

// Mark every register in [first, last] (inclusive) as used, clamped to
// the bitset.
fn void moveelim_mark_range(RegSet* live, uint first, uint last) {
    uint hi = last;
    if (hi >= live.word_count * 32) { hi = live.word_count * 32 - 1; }
    for (uint r = first; r <= hi; r++) { live.set(r); }
}

// Add every register `ins` reads into `live`.
// Does not add written registers; callers apply write-kill separately.
// `mark_call_windows` additionally marks the call-family argument windows.
fn void moveelim_add_uses(Instruction ins, RegSet* live, bool mark_call_windows) {
    Opcode op = ins.op;

    // Call-family argument windows: when mark_call_windows is true (for dead-destination
    // liveness), mark the full argument window as live. Producer retargeting runs with
    // this disabled so trailing arguments after spread are not blocked from retargeting.
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
        // GETPROPC / GETPROPC2 use C as a constant index, not a register.
        // LDREG uses only B; C is unused and must not be marked as a use.
        if (op == Opcode.GETPROPC || op == Opcode.GETPROPC2 || op == Opcode.GETPROPC_CACHED
            || op == Opcode.LDREG) {
            live.set((uint)ins.b);
        } else {
            live.set((uint)ins.b);
            live.set((uint)ins.c);
        }
    }
}

// Compute the register this instruction writes as a plain destination, if any.
// Returns true and fills `out_reg` when one is found.
fn bool moveelim_get_def(Instruction ins, uint* out_reg) {
    Opcode op = ins.op;
    if (!moveelim_a_is_write(op)) { return false; }
    *out_reg = (uint)ins.a;
    return true;
}

// Build the jump-target bitset and mark try-protected regions.
// Exception edges are not modeled in the CFG walk, so instructions inside
// try blocks are excluded from elimination.
fn void moveelim_mark_jump_targets_and_try_regions(Instruction* code, uint code_count,
                                                    bool* jump_targets, bool* in_try) {
    build_jump_targets(code, code_count, jump_targets);

    for (uint i = 0; i < code_count; i++) { in_try[i] = false; }

    for (uint i = 0; i < code_count; i++) {
        if (code[i].op != Opcode.TRY) { continue; }
        // Find the matching ENDTRY by scanning forward for depth 0.
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

// Backward liveness fixed-point over live-out sets:
// live_out[i] = union of live_in[s] for every successor s of i.
// live_in[i]  = uses(i) U (live_out[i] - defs(i)).
// `mark_call_windows` controls whether call argument windows are included in uses.
fn void moveelim_compute_liveness(Instruction* code, uint code_count, RegSet* live_out, RegSet* live_in,
                                  bool mark_call_windows, RegSet* scratch) {
    for (uint i = 0; i < code_count; i++) { live_out[i].clear(); live_in[i].clear(); }

    bool changed = true;
    while (changed) {
        changed = false;
        // Iterate backward to propagate fallthrough liveness in fewer passes.
        uint ii = code_count;
        while (ii > 0) {
            ii--;
            Instruction ins = code[ii];
            Opcode op = ins.op;

            RegSet* new_out = &scratch[0];
            new_out.clear();

            // Fallthrough successor: any instruction except unconditional jump/return/throw.
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

// Run liveness-based move elimination over `code[0..code_count)`.
//
// Performs two transforms:
// 1. Producer retargeting: replaces `producer rT; LDREG rDst=rT` with
//    `producer rDst; NOP` when rT is dead after the copy and rDst is not
//    live before it.
// 2. Dead-destination elimination: removes `LDREG rDst=rT` when rDst is not
//    live-out of the copy.
fn void run_move_elimination(Instruction* code, uint code_count, bool* jump_targets, bool* in_try,
                              RegSet* live_out, RegSet* live_in, RegSet* ret_out, RegSet* ret_in,
                              RegSet* scratch) {
    if (code_count < 2) { return; }

    moveelim_mark_jump_targets_and_try_regions(code, code_count, jump_targets, in_try);

    moveelim_compute_liveness(code, code_count, live_out, live_in, true, scratch);
    moveelim_compute_liveness(code, code_count, ret_out, ret_in, false, scratch);

    // For every LDREG rDst=rT, find its preceding producer and retarget if safe.
    for (uint k = 1; k < code_count; k++) {
        if (code[k].op != Opcode.LDREG) { continue; }
        if (in_try[k]) { continue; }

        // The LDREG slot must not be a jump target: a branch landing here
        // expects the copy to run for its own incoming path.
        if (jump_targets[k]) { continue; }

        uint rDst = (uint)code[k].a;
        uint rT   = (uint)code[k].b;
        if (rDst == rT) { continue; }   // no-op move; unrelated to this pass

        // Dead destination: if rDst is not live-out of the copy, nothing
        // downstream reads it, so the copy is removable outright. No
        // producer is retargeted. This check uses window-inclusive live_out,
        // so call argument slots are never seen as dead. The jump-target
        // and try-region guards ensure soundness across branch/exception edges.
        if (!live_out[k].test(rDst)) {
            code[k] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
            continue;
        }

        // rT must be dead-out of the LDREG (ret_out[k] excludes rT).
        // ret_out is window-free liveness, so call windows do not pin rT here.
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
        if (def_reg != rT) { continue; }

        bool accum = moveelim_accum_safe(pop);

        // The producer slot must not be a jump target, because a jump landing
        // on the producer bypasses preceding instructions and may be shared by
        // multiple logical paths.
        // For accumulate ops (`A = A op B`), this is relaxed for loop-body entry
        // headers because: (a) every path reaching the producer falls straight
        // through to this LDREG, and (b) whole-function backward liveness already
        // models jump/back-edges into the producer.
        if (!accum && jump_targets[i]) { continue; }

        // Does the producer read rDst as a source operand?
        // Normally this bails to prevent clobbering an input. For arithmetic/bitwise
        // accumulate ops (`A = A op B`, `A = op(A)`), aliasing ra == rb/rc is safe
        // because each op in moveelim_accum_safe reads all source operands before writing A.
        RegSet* producer_uses = &scratch[3];
        producer_uses.clear();
        moveelim_add_uses(producer, producer_uses, false);
        bool producer_reads_rdst = producer_uses.test(rDst);
        if (producer_reads_rdst && !accum) { continue; }

        // rDst must not be live-in at the producer's site:
        // For non-accumulate ops, ret_in[i].test(rDst) checks if an already-resident
        // value survives past i.
        // For accumulate ops reading rDst, rDst is in ret_in[i] due to the read itself
        // (which is the consumed value), so we check ret_out[i] to ensure rDst is not
        // needed past the producer.
        if (accum && producer_reads_rdst) {
            if (ret_out[i].test(rDst)) { continue; }
        } else {
            if (ret_in[i].test(rDst)) { continue; }
        }

        code[i] = moveelim_retarget_a(producer, pop, rDst);
        code[k] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
    }
}

// Liveness-based move (copy) elimination.
//
// Two transforms share a whole-function liveness pass, in two flavors (with
// and without the call-family argument windows, see run_move_elimination):
//
// 1. Producer retargeting. Targets the `producer rT=... ; LDREG rDst=rT`
//    pattern emitted when an expression result lands in a scratch register
//    before being copied to its destination (e.g. a call argument). If the
//    producer can write rDst directly, the LDREG is NOP'd.
// 2. Dead-destination removal. An LDREG or LDUNDEF whose destination is not
//    live-out is NOP'd. This catches discarded statement values (`sum += v`)
//    that retargeting cannot touch, and hoisted undefined initializations
//    overwritten before their first read.
//
// Retargeting is only safe when rDst is not live-in at the producer and rT is
// not live-out of the LDREG. Both need whole-function liveness: two unrelated
// live ranges can be adjacent in the instruction stream without being adjacent
// in liveness. A local-scan peephole was rejected because it retargeted into a
// still-live rDst.
//
// Runs after copy propagation and the fusion passes, so the LDREG/producer
// pairs are already adjacent where possible, and before NOP compaction, which
// removes the NOPs this pass introduces.
module boomkat::compiler;

import boomkat::bytecode;
import boomkat::frontendstats;
import boomkat::heap;
import std::io;

// The JIT loop window uses registers 0..63.
const uint LOOP_REGS_MIN = 64;

// Register bitset for the liveness pass, sized to the function's register
// high-water mark rather than the full 16-bit register file (8 KB per slot).
// `words` points into the liveness arena allocated in CompilerContext.finish;
// registers 0..max_reg-1 need (max_reg + 31) / 32 words.
struct RegSet {
    uint* words;
    uint  word_count;
}

fn void RegSet.clear(&self) {
    for (uint i = 0; i < self.word_count; i++) { self.words[i] = 0; }
}

// Both accessors clamp to the allocated word count. `moveelim_a_is_read` treats
// A as a register for some opcodes where it is really a branch offset (JUMP,
// JMP_LT, JMP_SNEQ) that can exceed max_reg, so an out-of-range register must
// be dropped rather than written past the arena. Such a register cannot be
// live, since the function never uses it.
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

// Whether `op`'s A field is a plain destination register that is
// write-only, meaning never simultaneously read as a value, a branch
// condition, or an assignment source. This is the exhaustive
// write-only-A allow-list (`moveelim_producer_allowed`'s opcode set, the
// opcodes this pass proves safe to retarget, including fused property loads);
// every opcode outside it is conservatively treated as
// reading A (see `moveelim_a_is_read` below) even for opcodes where A is
// actually unused (e.g. INITTZ, YIELD's B/C=0-only forms), marking an
// unused field as "read" only adds a harmless spurious liveness entry for
// register 0, since unused fields are always encoded as 0.
fn bool moveelim_a_is_write_only(Opcode op) {
    return moveelim_producer_allowed(op);
}

// Whether `op` reads its A field as a register (an input, an assignment
// source, or a branch condition). Defaults to true for every opcode not in the
// write-only set. The opcode surface is too large to enumerate reads by hand,
// so this is an allow-list of writes rather than a list of reads. Over-marking
// A as read keeps a register live longer than needed, which can only suppress
// a retarget.
fn bool moveelim_a_is_read(Opcode op) {
    return !moveelim_a_is_write_only(op);
}

// Whether `op` writes its A field as a plain destination register, for the
// liveness def-kill (`live_in = uses U (live_out - defs)`).
//
// A positive allow-list: any other opcode, including JMP_NLT/JMP_SEQ (A is a
// branch offset) and CALL/CALL_PROP/NEW_OBJ/generator ops, returns false.
// Missing a def keeps a register live too far back, which can only suppress a
// retarget, never permit an unsafe one.
fn bool moveelim_a_is_write(Opcode op) {
    // The producer allow-list, plus LDINTX (it spans two instruction words).
    return op == Opcode.LDINTX || moveelim_a_is_write_only(op);
}

// Whether `op` is safe to retarget: writing rDst directly must match writing rT
// and then copying. So the instruction must not special-case the identity of A
// beyond "the result lands here": no reads of A, no multi-register writes tied
// to A's position, and no control-flow dependence on A's value. A conservative
// allow-list of simple `A = f(B, C)` opcodes with A write-only.
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
        case Opcode.ADDI..Opcode.USHRI:
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
        case Opcode.GETPROPC:
        case Opcode.GETPROPC_CACHED:
        case Opcode.GETTHISC:
        case Opcode.GETPROTO:
        case Opcode.GETVAR:
        case Opcode.GETBOUND:
        case Opcode.GETGLOBAL:
        case Opcode.GETCAP:
        case Opcode.TONUMERIC:
        case Opcode.TYPEOFIDENT:
            return true;
        default:
            return false;
    }
}

// Whether `op` may be retargeted into rDst even when it reads rDst as a source,
// as in `A = f(A, ...)`. This holds for the arithmetic and bitwise ops, which
// read all of rb and rc before writing ra (checked in vm_execute.c3,
// vm_arith.c3 and vm_bigint.c3), so ra==rb or ra==rc is safe. A strict subset
// of `moveelim_producer_allowed`: comparisons and property/var loads are left
// out, since the accumulate win comes from the arithmetic family only.
fn bool moveelim_accum_safe(Opcode op) {
    switch (op) {
        case Opcode.ADD:
        case Opcode.SUB:
        case Opcode.MUL:
        case Opcode.DIV:
        case Opcode.MOD:
        case Opcode.EXP:
        case Opcode.ADDI..Opcode.USHRI:
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

// Add every register `ins` reads (per its opcode's operand format, plus the
// A-is-read special cases) into `live`. Does NOT add the register(s) it
// writes, callers apply the write-kill separately so the standard
// backward liveness recurrence (`live_in = uses U (live_out - defs)`) holds.
// `mark_call_windows` additionally marks the call-family argument windows.
// An opcode's register operands, as moveelim_add_uses and moveelim_get_def
// read them. Liveness visits every instruction on each sweep, so the
// predicates are folded into one table, built from them on first use.
bitstruct MoveelimRoles : char {
    bool a_read : 0;
    bool b_read : 1;
    bool c_read : 2;
    bool a_write : 3;
    // The operands are ranges or windows: moveelim_add_uses_general reads them.
    bool general : 4;
}

MoveelimRoles[256] moveelim_roles;
bool moveelim_roles_ready;

fn void moveelim_init_roles() {
    foreach (op : Opcode::values) {
        MoveelimRoles r;
        // Read-modify-write opcodes still define A; keeping them out of the
        // def-kill would overstate liveness at every loop header.
        r.a_write = moveelim_a_is_write(op) || op == Opcode.INC
            || op == Opcode.INC_LT || op == Opcode.DEC || op == Opcode.ADD_FUSED;
        switch (tailcall_base(op)) {
            case Opcode.CLASS_SCALAR_GUARD:
            case Opcode.CALL:
            case Opcode.CALL_UNDEF_THIS:
            case Opcode.NEW_OBJ:
            case Opcode.SUPER_CALL:
            case Opcode.CALL_VAR:
            case Opcode.CALL_GLOBAL:
            case Opcode.CALL_S:
            case Opcode.NEW_OBJ_S:
            case Opcode.SUPER_CALL_S:
            case Opcode.SPREAD_PROJECTION:
            case Opcode.INIT_SLOT:
            case Opcode.STRJOIN:
            case Opcode.STRJOIN_LENGTH:
            case Opcode.NEWARR_FILL:
                r.general = true;
            default:
                // Record the general reader's answer for an instruction whose
                // operands are each set to its own register.
                RegSet probe;
                uint[2] words;
                probe.words = &words;
                probe.word_count = 2;
                probe.clear();
                moveelim_add_uses_general(bytecode::make_abc(op, 1, 2, 3), &probe, false);
                r.a_read = probe.test(1);
                r.b_read = probe.test(2);
                r.c_read = probe.test(3);
        }
        // The fused add derives both results from B and C; it does not read
        // the intermediate it writes into A.
        if (op == Opcode.ADD_FUSED) r.a_read = false;
        moveelim_roles[op.ordinal] = r;
    }
    moveelim_roles_ready = true;
}

// The alias window covers these registers. A function with more is left to the
// interpreter rather than given an unbounded table.
const uint BYTECODE_REGS_MAX = 1024;

// Operands of the instruction at `pos`, including the high bytes a WIDE prefix
// at pos - 1 contributes. `ok` is false when the operands are not a plain
// role-decoded form the alias window can rewrite; `next` is the position after
// the instruction, skipping a prefix pair.
struct BytecodeOperands {
    uint a;
    uint b;
    uint c;
    bool a_reg;
    bool b_reg;
    bool c_reg;
    bool ok;
    uint next;
}

fn BytecodeOperands bytecode_operands(Instruction* code, uint pos, uint end) {
    BytecodeOperands o;
    DecodedBytecode decoded = bytecode::decode_bytecode(code, end + 1, pos);
    o.next = decoded.next_pc;
    if (!decoded.valid) return o;
    Opcode op = decoded.insn.op;
    uint pa = decoded.insn.a >> 8;
    uint pb = decoded.insn.b >> 8;
    uint pc = decoded.insn.c >> 8;
    // The shared decoder rejects nested WIDE prefixes. LDINTX and general
    // instructions need paired or window semantics the alias pass cannot rewrite.
    if (op == Opcode.LDINTX) return o;
    MoveelimRoles r = moveelim_roles[op.ordinal];
    if (r.general) return o;
    o.a = decoded.insn.a;
    o.b = decoded.insn.b;
    o.c = decoded.insn.c;
    o.a_reg = r.a_read || r.a_write;
    o.b_reg = r.b_read;
    o.c_reg = r.c_read && bytecode::get_op_format(op) == OpFormat.ABC;
    // A field that is not a register cannot carry a widened value: its prefix
    // byte belongs to an index or immediate this pass does not rewrite.
    if ((!o.a_reg && pa != 0) || (!o.b_reg && pb != 0) || (!o.c_reg && pc != 0)) return o;
    o.ok = true;
    return o;
}

// Collect every register touched by [begin, end] in a single pass. Unknown
// WIDE payloads conservatively reserve the entire set, including when the
// prefix is truncated at the end of the window.
fn void bytecode_register_set(Instruction* code, uint begin, uint end, RegSet* used) @public {
    if (!moveelim_roles_ready) moveelim_init_roles();
    used.clear();
    for (uint i = begin; i <= end; i++) {
        BytecodeOperands o = bytecode_operands(code, i, end);
        if (!o.ok) {
            if (code[i].op == Opcode.WIDE) {
                for (uint word = 0; word < used.word_count; word++) used.words[word] = uint::max;
                return;
            }
            moveelim_add_uses(code[i], used, true);
            uint def;
            if (moveelim_get_def(code[i], &def)) used.set(def);
            continue;
        }
        if (o.a_reg) used.set(o.a);
        if (o.b_reg) used.set(o.b);
        if (o.c_reg) used.set(o.c);
        i = o.next - 1;
    }
}

fn ulong bytecode_low_register_mask(Instruction* code, uint begin, uint end) @public {
    uint[32] words;
    RegSet used = { .words = &words[0], .word_count = 32 };
    bytecode_register_set(code, begin, end, &used);
    return (ulong)words[0] | ((ulong)words[1] << 32);
}

fn bool bytecode_register_used(Instruction* code, uint begin, uint end, uint reg) @public {
    if (reg >= BYTECODE_REGS_MAX) return true;
    uint[32] words;
    RegSet used = { .words = &words[0], .word_count = 32 };
    bytecode_register_set(code, begin, end, &used);
    return used.test(reg);
}

// Rewrite register operands through `map`, which maps each high register to a
// free low slot. Only plain ABC forms and the A field of A-BC/A-SBX forms are
// rewritten; a high register inside a call/argument window or another combined
// operand makes the range unsupported.
fn bool bytecode_remap_registers(Instruction* code, uint begin, uint end, uint[BYTECODE_REGS_MAX] map) @public {
    if (!moveelim_roles_ready) moveelim_init_roles();
    for (uint i = begin; i <= end; i++) {
        Instruction ins = code[i];
        if (ins.op == Opcode.LDINTX) return false;
        MoveelimRoles r = moveelim_roles[ins.op.ordinal];
        if (r.general) {
            if (ins.op == Opcode.WIDE) return false;
            uint[32] words;
            RegSet live = { .words = &words[0], .word_count = 32 };
            moveelim_add_uses(ins, &live, true);
            uint def;
            if (moveelim_get_def(ins, &def)) live.set(def);
            for (uint reg = LOOP_REGS_MIN; reg < BYTECODE_REGS_MAX; reg++) if (live.test(reg)) {
                return false;
            }
            continue;
        }
        BytecodeOperands o = bytecode_operands(code, i, end);
        if (!o.ok) return false;
        // Every rewritten operand lands in a low slot, so the pair collapses to
        // an ordinary instruction and a NOP. Below that, the analysis and the
        // emitters only ever see the unchanged 8-bit form.
        uint[3] field;
        field[0] = o.a;
        field[1] = o.b;
        field[2] = o.c;
        bool[3] is_reg;
        is_reg[0] = o.a_reg;
        is_reg[1] = o.b_reg;
        is_reg[2] = o.c_reg;
        for (uint f = 0; f < 3; f++) {
            if (!is_reg[f] || field[f] < LOOP_REGS_MIN) continue;
            if (field[f] >= BYTECODE_REGS_MAX || map[field[f]] == field[f]) {
                return false;
            }
            field[f] = map[field[f]];
        }
        Instruction payload = code[o.next - 1];
        payload.a = (char)field[0];
        payload.b = (char)field[1];
        payload.c = (char)field[2];
        code[o.next - 1] = payload;
        if (ins.op == Opcode.WIDE) code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
        i = o.next - 1;
    }
    return true;
}

// Both packed and decoded instructions use the same per-field roles.
macro void moveelim_add_role_uses(MoveelimRoles roles, uint a, uint b, uint c, RegSet* live) {
    if (roles.a_read) live.set(a);
    if (roles.b_read) live.set(b);
    if (roles.c_read) live.set(c);
}

// The role table and general window logic are shared with decoded WIDE
// bytecode, whose effective register fields can exceed one byte. The caller
// initializes moveelim_roles before the first use, as for packed bytecode.
fn void moveelim_add_decoded_uses(DecodedInsn ins, RegSet* live, bool mark_call_windows) {
    MoveelimRoles r = moveelim_roles[ins.op.ordinal];
    if (r.general) {
        moveelim_add_decoded_uses_general(ins, live, mark_call_windows);
        return;
    }
    moveelim_add_role_uses(r, ins.a, ins.b, ins.c, live);
}

// Keep the ordinary bytecode's common role checks on packed fields; only the
// less common window instructions need a widened temporary.
fn void moveelim_add_uses(Instruction ins, RegSet* live, bool mark_call_windows) {
    MoveelimRoles r = moveelim_roles[ins.op.ordinal];
    if (r.general) {
        moveelim_add_uses_general(ins, live, mark_call_windows);
        return;
    }
    moveelim_add_role_uses(r, (uint)ins.a, (uint)ins.b, (uint)ins.c, live);
}

fn void moveelim_add_uses_general(Instruction ins, RegSet* live, bool mark_call_windows) {
    DecodedInsn decoded = { ins.op, ins.a, ins.b, ins.c };
    moveelim_add_decoded_uses_general(decoded, live, mark_call_windows);
}

fn void moveelim_add_decoded_uses_general(DecodedInsn ins, RegSet* live, bool mark_call_windows) {
    // A tail call reads what the call it shadows reads.
    Opcode op = tailcall_base(ins.op);
    ins.op = op;

    // Call-family argument windows. The VM reads every register from the callee
    // slot through the last argument, but those slots are not operands of the
    // call, so the generic marking below misses them. Literal-count forms mark
    // callee_reg .. callee_reg + 1 + nargs. The _S forms take the count from a
    // register, so everything from the callee register up is marked.
    //
    // Only the dead-destination liveness uses this over-approximation. The
    // producer-retarget liveness runs without it: arguments arrive via
    // SPREAD_ARG/PUTARG or argument LDREGs, never via a retargetable producer,
    // and marking them live would block the retarget in `f(1,...a,99)`.
    if (op == Opcode.CLASS_SCALAR_GUARD) {
        moveelim_mark_range(live, (uint)ins.a, (uint)ins.a + 1 + (uint)ins.b);
    }
    if (mark_call_windows) {
        switch (op) {
            case Opcode.CALL:
            case Opcode.NEW_OBJ:
            case Opcode.SUPER_CALL:
                moveelim_mark_range(live, (uint)ins.b, (uint)ins.b + 1 + (uint)ins.c);
            case Opcode.CALL_UNDEF_THIS:
                // The call stores undefined into the receiver slot; it reads
                // only the callee and the arguments.
                live.set((uint)ins.b);
                moveelim_mark_range(live, (uint)ins.b + 2, (uint)ins.b + 1 + (uint)ins.c);
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

    if (op == Opcode.SPREAD_PROJECTION) {
        live.set((uint)ins.b);
        return;
    }

    if (op == Opcode.INIT_SLOT) {
        live.set((uint)ins.a);
        live.set((uint)ins.c);
        return;
    }
    // STRJOIN and NEWARR_FILL read consecutive registers B .. B+C-1; C is a
    // count, not a register. Marking only B and C would make the other slots
    // look dead and let move elimination drop their fills. This applies to both
    // liveness analyses, so it is outside the call-window gate.
    if (op == Opcode.STRJOIN || op == Opcode.STRJOIN_LENGTH || op == Opcode.NEWARR_FILL) {
        if (ins.c > 0) {
            moveelim_mark_range(live, (uint)ins.b, (uint)ins.b + (uint)ins.c - 1);
        }
        return;
    }

    // A compare-branch keeps a jump offset in A, and an immediate form keeps
    // its immediate in C; neither is a register read.
    if (bytecode::is_cmp_branch(op)) {
        live.set((uint)ins.b);
        if (bytecode::reg_form(op) == Opcode.NOP) { live.set((uint)ins.c); }
        return;
    }
    if (bytecode::is_imm_form(op)) {
        if (moveelim_a_is_read(op)) { live.set((uint)ins.a); }
        live.set((uint)ins.b);
        return;
    }

    // JUMP, BREAK and CONTINUE keep a jump offset across all three fields.
    OpFormat format = bytecode::get_op_format(op);
    if (format == OpFormat.WIDE_SABC || format == OpFormat.WIDE_ABC) return;
    if (moveelim_a_is_read(op)) {
        live.set((uint)ins.a);
    }
    if (format == OpFormat.ABC) {
        // Call-family C fields are argument counts (or count registers for the
        // _S forms). Marking C as a use is safe, at worst conservative.
        //
        // GETPROPC's C is a constant-pool index, so it is not marked. LDREG's C
        // is unused (the VM reads only rb). Marking it would keep r0 live across
        // every LDREG and defeat accumulate elimination for `s = s + 1` in r0.
        if (op == Opcode.GETTHISC) {
            // No register operand but the destination.
        } else if (op == Opcode.PUTTHISC) {
            // A is the value register, already counted above; B and C are unused.
        } else if (op == Opcode.GETPROPC || op == Opcode.GETPROPC_CACHED
            || op == Opcode.LDREG) {
            live.set((uint)ins.b);
        } else if (op == Opcode.INITELEM) {
            // B is an immediate element index.
            live.set((uint)ins.c);
        } else {
            live.set((uint)ins.b);
            live.set((uint)ins.c);
        }
    }
    // A_BC/A_SBX/WIDE_ABC/WIDE_SABC/NONE formats carry no register operands
    // in b/c (they're indices, immediates, or branch offsets), nothing to
    // add for those formats beyond the a-is-read case already handled.
}

// Compute the register this instruction WRITES as a plain destination, if
// any (per `moveelim_a_is_write`). Returns true and fills `out_reg` when
// there is one.
macro bool moveelim_get_role_def(MoveelimRoles roles, uint a, uint* out_reg) {
    if (!roles.a_write) return false;
    *out_reg = a;
    return true;
}

fn bool moveelim_get_decoded_def(DecodedInsn ins, uint* out_reg) {
    return moveelim_get_role_def(moveelim_roles[ins.op.ordinal], ins.a, out_reg);
}

fn bool moveelim_get_def(Instruction ins, uint* out_reg) {
    return moveelim_get_role_def(moveelim_roles[ins.op.ordinal], (uint)ins.a, out_reg);
}

// Build the jump-target bitset AND record, for TRY/ENDTRY pairs, the
// [start,end] index ranges to exclude from elimination entirely (an
// exception can transfer control from any instruction inside a protected
// region straight to its catch/finally handler, an edge this pass's CFG
// walk does not otherwise model). `in_try` is sized `code_count` and set
// true for every instruction inside such a range (inclusive of TRY and its
// matching ENDTRY).
//
// The jump-target half is `build_jump_targets`, not a copy of it. This pass
// wants the same answer to "can control arrive here from elsewhere" that the
// fusion passes want, so a second switch over the branch opcodes would be one
// more place to remember when a branch form is added.
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

        // A finally is also entered by abrupt completions (break, continue and
        // return inside the try route through finally_pc, and ENDFINALLY replays
        // the pending completion). The CFG walk does not model that edge, so a
        // store in the finally could look dead. Exclude FINALLY..ENDFINALLY. The
        // finally_offset lives in the NOP slot at i+1.
        if (i + 1 < code_count) {
            uint finally_off = bytecode::try_finally_offset(code[i + 1]);
            if (finally_off != 0) {
                uint fin_start = i + finally_off;
                // Walk from the FINALLY marker to its matching ENDFINALLY,
                // honoring nesting (an inner try/finally in this finally body
                // has its own FINALLY/ENDFINALLY pair).
                uint fdepth = 0;
                uint fk = fin_start;
                while (fk < code_count) {
                    Opcode fop = code[fk].op;
                    if (fop == Opcode.FINALLY) { fdepth++; }
                    else if (fop == Opcode.ENDFINALLY) {
                        fdepth--;
                        if (fdepth == 0) { break; }
                    }
                    in_try[fk] = true;
                    fk++;
                }
                if (fk < code_count) { in_try[fk] = true; } // include ENDFINALLY
            }
        }
    }
}

// Run liveness-based move elimination over `code[0..code_count)`.
//
// For every `LDREG rDst = rT` at index `k` whose immediately preceding
// non-NOP instruction at index `i` is an allow-listed producer writing rT
// as its plain destination register, retarget the producer to write rDst
// directly and NOP the LDREG, PROVIDED:
//   - rT is not live-out of the LDREG (its bitcode-visible-uses beyond this
//     copy are none, computed from whole-function backward liveness, not
//     a local scan);
//   - rDst is not live-in at the producer's site (no value already resident
//     in rDst needs to survive past the producer);
//   - rDst is not itself read by the producer as one of its own source
//     operands (retargeting would make the producer read its own
//     just-clobbered destination);
//   - neither the producer slot nor the LDREG slot is inside a try-
//     protected region (exception edges aren't modeled by this pass's CFG
//     walk);
//   - neither the LDREG slot nor the producer slot is a jump target, except
//     that the producer may be one for accumulate ops (see run_move_elimination).
//
// Backward liveness fixed-point over live-out sets.
// live_out[i] = union of live_in[s] for every successor s of i.
// live_in[i]  = uses(i) U (live_out[i] - defs(i)).
// `mark_call_windows` picks the use-set's view of the call-family argument
// windows: ON for the dead-destination liveness, OFF for the producer-
// retarget liveness (see run_move_elimination for why the two differ).
// `scratch` supplies one working set for successor liveness. Each live-in
// set is derived in place once its live-out changes.
// `pinned` (may be null) holds registers read outside the bytecode, which are
// live at every point. The only source is the parameter registers of a sloppy
// function with a mapped `arguments` object. ECMA-262 Arguments Exotic Objects
// (https://tc39.es/ecma262/#sec-arguments-exotic-objects) aliases arguments[i]
// to parameter i, and the VM reads those slots from the activation
// (vm_calls::mapped_args_read), so a store to a parameter is observable.
fn void moveelim_compute_liveness(Instruction* code, uint code_count, RegSet* live_out, RegSet* live_in,
                                  bool mark_call_windows, RegSet* scratch, RegSet* pinned = null) {
    frontendstats::fs_liveness_call(code_count, scratch[0].word_count);
    if (!moveelim_roles_ready) moveelim_init_roles();
    for (uint i = 0; i < code_count; i++) { live_out[i].clear(); live_in[i].clear(); }

    // Every successor of an instruction lies after it unless a jump goes
    // back, so without one the first backward sweep is already the fixed
    // point and a second would only confirm it.
    bool has_back_edge = false;
    for (uint i = 0; i < code_count && !has_back_edge; i++) {
        Instruction ins = code[i];
        switch (ins.op) {
            case Opcode.JUMP:
            case Opcode.BREAK:
            case Opcode.CONTINUE: has_back_edge = ins.get_sabc() < 0;
            case Opcode.IF_TRUE:
            case Opcode.IF_FALSE: has_back_edge = ins.get_sbc() < 0;
            case Opcode.JMP_NLT..Opcode.JMP_SNEQI: has_back_edge = (ichar)ins.a < 0;
            default: {}
        }
    }
    if (has_back_edge) frontendstats::fs_liveness_backedge();

    bool changed = true;
    bool first = true;
    while (changed) {
        frontendstats::fs_liveness_sweep();
        if (!first && !has_back_edge) break;
        // The first sweep initializes use sets even when live-out is empty.
        // Later sweeps need to revisit only changes propagated through edges.
        changed = first;
        // Iterate backward: on a typical (mostly-forward) CFG this converges
        // in very few passes since a single backward sweep already propagates
        // most fallthrough-chain liveness in one go; the fixed-point loop
        // only needs extra iterations for back-edges (loops).
        uint ii = code_count;
        while (ii > 0) {
            ii--;
            frontendstats::fs_liveness_visit();
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
                case Opcode.JMP_NLT..Opcode.JMP_SNEQI: {
                    int off = (int)(ichar)ins.a;
                    int tgt = (int)ii + 1 + off;
                    if (tgt >= 0 && (uint)tgt < code_count) { new_out.union_with(&live_in[(uint)tgt]); }
                }
                case Opcode.TRY: {
                    uint catch_off = ins.get_bc();
                    uint catch_tgt = ii + catch_off;
                    if (catch_tgt < code_count) { new_out.union_with(&live_in[catch_tgt]); }
                    if (ii + 1 < code_count) {
                        uint finally_off = bytecode::try_finally_offset(code[ii + 1]);
                        if (finally_off != 0) {
                            uint finally_tgt = ii + finally_off;
                            if (finally_tgt < code_count) { new_out.union_with(&live_in[finally_tgt]); }
                        }
                    }
                }
                default: {}
            }

            // Pinned registers are live on every edge, including function
            // exit, so a store into one is never dead.
            if (pinned != null) { new_out.union_with(pinned); }

            // live_in is a function of live_out alone, so after the first
            // sweep an unchanged live_out leaves live_in as it was.
            if (!new_out.equals(&live_out[ii])) {
                live_out[ii].copy_from(new_out);
                changed = true;
            } else if (!first) {
                continue;
            }

            // live_in[ii] = uses(ii) U (live_out[ii] - defs(ii)). Its
            // transfer is deterministic, so a changed live-out already
            // schedules another sweep; no separate input comparison is needed.
            RegSet* input = &live_in[ii];
            input.copy_from(new_out);
            uint def_reg;
            if (moveelim_get_def(ins, &def_reg)) {
                input.unset(def_reg);
            }
            moveelim_add_uses(ins, input, mark_call_windows);
            if (pinned != null) { input.union_with(pinned); }
        }
        first = false;
    }
}

// Compatibility adapters retain word-PC-indexed outputs while consuming the
// shared canonical decoded CFG. No fixed-point sweep decodes bytecode again.
fn bool moveelim_decoded_branch(DecodedBytecode view, long* target) {
    return bytecode_cfg_branch(view, target);
}

fn bool moveelim_compute_decoded_liveness(Instruction* code, uint code_count,
    RegSet* live_out, RegSet* live_in, RegSet* scratch, bool* boundary,
    heap::Heap* h = null) {
    for (uint pc = 0; pc < code_count; pc++) boundary[pc] = false;
    DecodedCfg cfg;
    if (!bytecode_cfg_build(&cfg, code, code_count, h)) return false;
    defer bytecode_cfg_free(&cfg);
    for (uint i = 0; i < cfg.instruction_count; i++) boundary[cfg.nodes[i].view.pc] = true;
    bytecode_cfg_liveness(&cfg, live_out, live_in, scratch, true, true);
    return true;
}

// Both narrow and WIDE continuations use canonical instruction slots. The VM
// provides a positive opcode predicate; unsupported control flow or exhausted
// memory/graph budgets refuses to its conservative recovery path.
fn bool moveelim_decoded_continuation(Instruction* code, uint count, uint num_regs,
    uint continuation, heap::Heap* h, DecodedOpAllowed allowed, bool* live, uint live_count,
    bool require_wide = false) {
    if (count == 0 || count > 512 || num_regs >= BYTECODE_REGS_MAX || continuation >= count) return false;
    DecodedCfg cfg;
    if (!bytecode_cfg_build(&cfg, code, count, h)) return false;
    defer bytecode_cfg_free(&cfg);
    if ((require_wide && !cfg.has_wide) || cfg.pc_to_index[continuation] == CFG_NO_INSTRUCTION) return false;
    for (uint i = 0; i < cfg.instruction_count; i++) {
        Opcode op = cfg.nodes[i].view.insn.op;
        if (!allowed(op) && op != Opcode.DECLVAR && op != Opcode.DECLVAR_HOIST) return false;
    }
    uint slots = cfg.instruction_count;
    uint word_count = (num_regs + 32) / 32;
    if (word_count < 2) word_count = 2;
    usz set_bytes = (usz)slots * 2 * RegSet::size;
    usz word_bytes = ((usz)slots * 2 + 1) * word_count * uint::size;
    if (set_bytes + word_bytes > 8 * 1024 * 1024) return false;
    RegSet* sets = (RegSet*)h.alloc_func(h.heap_udata, set_bytes);
    if (sets == null) return false;
    defer h.free_func(h.heap_udata, sets);
    uint* words = (uint*)h.alloc_func(h.heap_udata, word_bytes);
    if (words == null) return false;
    defer h.free_func(h.heap_udata, words);
    for (uint i = 0; i < slots * 2; i++) {
        sets[i].words = words + (usz)i * word_count;
        sets[i].word_count = word_count;
    }
    RegSet scratch = { .words = words + (usz)slots * 2 * word_count, .word_count = word_count };
    bytecode_cfg_liveness(&cfg, sets, sets + slots, &scratch);
    RegSet* input = &sets[slots + cfg.pc_to_index[continuation]];
    for (uint reg = 0; reg < live_count; reg++) live[reg] = input.test(reg);
    return true;
}

fn bool moveelim_wide_continuation(Instruction* code, uint count, uint num_regs,
    uint continuation, heap::Heap* h, DecodedOpAllowed allowed, bool* live, uint live_count) {
    return moveelim_decoded_continuation(code, count, num_regs, continuation, h, allowed, live, live_count, true);
}

// Run liveness-based move elimination over `code[0..code_count)`.
//
// Two transforms share the pass:
//
// 1. Producer retargeting: for `LDREG rDst = rT` at index `k`, where the
//    preceding non-NOP instruction `i` is an allow-listed producer writing rT,
//    retarget the producer to write rDst and NOP the LDREG. Requires rT dead
//    after the copy, rDst not live-in at the producer, no try region, and no
//    jump target at the LDREG or, unless accumulating, the producer.
// 2. Dead-destination elimination: when rDst is dead after the LDREG, NOP it.
//
// The transforms use different views of the call-family argument windows.
// `live_out`/`live_in` include them, so a copy into a live argument slot is
// never removed. `ret_out`/`ret_in` exclude them, so a window cannot block the
// retarget in `f(1,...a,99)`.
fn void run_move_elimination(Instruction* code, uint code_count, bool* jump_targets, bool* in_try,
                              RegSet* live_out, RegSet* live_in, RegSet* ret_out, RegSet* ret_in,
                              RegSet* scratch, RegSet* pinned = null) {
    if (code_count < 2) { return; }

    // The caller supplies both maps; operand retargeting and dead moves
    // preserve control flow, including a second pass after parameter aliases.
    // Only an LDUNDEF or LDREG can be removed, and only LDREG uses the
    // retarget view, so a function without them skips the liveness.
    bool has_ldreg = false;
    bool has_ldundef = false;
    for (uint k = 0; k < code_count; k++) {
        if (code[k].op == Opcode.LDREG) has_ldreg = true;
        if (code[k].op == Opcode.LDUNDEF) has_ldundef = true;
    }
    if (!has_ldreg && !has_ldundef) return;
    moveelim_compute_liveness(code, code_count, live_out, live_in, true, scratch, pinned);
    if (has_ldreg) moveelim_compute_liveness(code, code_count, ret_out, ret_in, false, scratch, pinned);

    // Hoisted locals can be assigned before their initial undefined value is
    // read. Reuse the call-window and capture-aware liveness proof; exception
    // regions keep their stores because their edges are not modeled here.
    for (uint k = 0; k < code_count; k++) {
        if (code[k].op == Opcode.LDUNDEF && !in_try[k]
            && !jump_targets[k] && !live_out[k].test((uint)code[k].a)) {
            code[k] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
        }
    }

    // --- Elimination pass: for every LDREG rDst=rT, find its immediately
    // preceding non-NOP instruction (the producer candidate) and retarget
    // when every safety condition holds. ---
    for (uint k = 1; k < code_count; k++) {
        if (code[k].op != Opcode.LDREG) { continue; }
        if (in_try[k]) { continue; }

        // The LDREG is removed here, so it must not be a jump target. A branch
        // landing on it, such as a ternary arm joining a shared copy, still
        // expects the copy to run for its own producer.
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

        // Every path into the LDREG must pass through the producer, so no
        // jump may land between them. A jump onto the producer itself is
        // fine: it still falls through to the LDREG, as when an arm of a
        // conditional expression starts with it.
        bool entered_between = false;
        for (uint s = i + 1; s <= k; s++) entered_between = entered_between || jump_targets[s];
        if (entered_between) { continue; }

        // Retargeting a producer that reads rDst is only safe for accumulate ops
        // (`A = A op B`), which read their operands before writing A.
        RegSet* producer_uses = &scratch[1];
        producer_uses.clear();
        moveelim_add_uses(producer, producer_uses, false);
        bool producer_reads_rdst = producer_uses.test(rDst);
        if (producer_reads_rdst && !accum) { continue; }

        // rDst must not hold a value that survives the producer. For a
        // non-accumulate producer, ret_in[i] and ret_out[i] agree on rDst.
        // For an accumulate producer, rDst in ret_in[i] comes only from the
        // read being consumed, so ret_out[i] is checked instead.
        if (accum && producer_reads_rdst) {
            if (ret_out[i].test(rDst)) { continue; }
        } else {
            if (ret_in[i].test(rDst)) { continue; }
        }

        code[i] = moveelim_retarget_a(producer, pop, rDst);
        code[k] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
    }
}

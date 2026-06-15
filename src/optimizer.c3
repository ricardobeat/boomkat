/// Post-compilation bytecode optimizer.
///
/// Runs after the compiler has produced a `CompiledFunction` and applies
/// function-local transforms that are awkward or impossible to do cleanly
/// during single-pass emission.  The optimizer is intentionally simple: it
/// works within basic blocks, avoids heavy data-flow analysis, and reports
/// exactly what it changed so performance effects are easy to measure.
module duktape::optimizer;

import duktape::bytecode;
import duktape::types;
import std::io;
import libc;

// ============================================================================
// Tuning / debug flags
// ============================================================================

/// Set to true to print every function's bytecode before and after optimizing.
/// Controlled via the DUK_OPT_DUMP environment variable at startup.
bool g_dump_bytecode = false;

/// Master switch for the optimizer.  Controlled via the DUK_OPT_DISABLE
/// environment variable.
bool g_enabled = true;

// ============================================================================
// Statistics
// ============================================================================

struct OptStats {
    uint functions_optimized;
    uint blocks_scanned;
    uint ldreg_removed;
    uint const_folded;
    uint dead_ops_removed;
    uint arith_dest_coalesced;
}

OptStats g_stats;

fn void reset_stats() {
    g_stats = {};
}

fn void print_stats() {
    io::printfn("=== optimizer stats ===");
    io::printfn("  functions optimized: %d", g_stats.functions_optimized);
    io::printfn("  basic blocks scanned: %d", g_stats.blocks_scanned);
    io::printfn("  LDREG removed: %d", g_stats.ldreg_removed);
    io::printfn("  constants folded: %d", g_stats.const_folded);
    io::printfn("  dead ops removed: %d", g_stats.dead_ops_removed);
    io::printfn("  arith dest coalesced: %d", g_stats.arith_dest_coalesced);
}

// ============================================================================
// Initialization
// ============================================================================

/// Call once at program startup to read environment controls.
fn void init_from_env() {
    char* dump = libc::getenv("DUK_OPT_DUMP");
    if (dump != null && *dump != 0) {
        g_dump_bytecode = true;
    }
    char* disable = libc::getenv("DUK_OPT_DISABLE");
    if (disable != null && *disable != 0) {
        g_enabled = false;
    }
}

// ============================================================================
// Helpers
// ============================================================================

fn bool is_arithmetic_or_bitwise(Opcode op) {
    switch (op) {
        case Opcode.ADD:
        case Opcode.SUB:
        case Opcode.MUL:
        case Opcode.DIV:
        case Opcode.MOD:
        case Opcode.EXP:
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

fn bool is_comparison(Opcode op) {
    switch (op) {
        case Opcode.LT:
        case Opcode.LE:
        case Opcode.GT:
        case Opcode.GE:
        case Opcode.SEQ:
        case Opcode.SNEQ:
        case Opcode.EQ:
        case Opcode.NEQ:
            return true;
        default:
            return false;
    }
}

fn bool is_terminator(Opcode op) {
    switch (op) {
        case Opcode.RET:
        case Opcode.RETUNDEF:
        case Opcode.RET_GEN:
        case Opcode.RETUNDEF_GEN:
        case Opcode.THROW:
        case Opcode.JUMP:
        case Opcode.IF_TRUE:
        case Opcode.IF_FALSE:
        case Opcode.JMP_LT:
        case Opcode.JMP_LE:
        case Opcode.JMP_GT:
        case Opcode.JMP_GE:
        case Opcode.JMP_NLT:
        case Opcode.JMP_NLE:
        case Opcode.JMP_NGT:
        case Opcode.JMP_NGE:
            return true;
        default:
            return false;
    }
}

/// Returns true if the instruction has no side effects and its only effect is
/// to define a register from other registers/constants.
fn bool is_pure_compute(Opcode op) {
    if (is_arithmetic_or_bitwise(op)) return true;
    if (is_comparison(op)) return true;
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
        case Opcode.UNP:
        case Opcode.UNM:
        case Opcode.BNOT:
        case Opcode.LNOT:
        case Opcode.TYPEOF:
        case Opcode.TYPEOFIDENT:
            return true;
        default:
            return false;
    }
}

const uint NO_REG = 0xFFFF;

/// Returns true if `reg` is read as an operand by `insn`.
fn bool reads_register(Instruction insn, uint reg) {
    Opcode op = insn.op;
    OpFormat fmt = bytecode::get_op_format(op);

    // Check whether insn is a call-like op whose argument window
    // [B+1, B+C] is implicitly read (this + explicit args).
    bool call_like = false;
    switch (op) {
        case Opcode.CALL:
        case Opcode.CALL_PROP:
        case Opcode.NEW_OBJ:
        case Opcode.TAILCALL:
        case Opcode.SUPER_CALL:
        case Opcode.CALL_S:
            call_like = true;
            break;
        default:
            break;
    }

    switch (fmt) {
        case ABC:
            // Call-like ops: check both explicit operands AND the implicit
            // argument window [B+1, B+(insn.c)].
            if (call_like) {
                // The callee register B is always read.
                if ((uint)insn.b == reg) return true;
                // For CALL_S, insn.c is a register holding the count at runtime,
                // so the exact window is unknown.  Conservatively mark every
                // register after B as potentially read.
                if (op == Opcode.CALL_S && reg > (uint)insn.b) return true;
                // Fixed-arg call-like: C counts explicit args only.
                // The implicit window (incl. `this`) is [B+1, B+1+C].
                if (reg > (uint)insn.b && reg <= (uint)insn.b + 1 + (uint)insn.c) return true;
                return false;
            }
            switch (op) {
                // JMP_* and other control flow: A is an offset, not a reg.
                case Opcode.JMP_NLT: case Opcode.JMP_NLE:
                case Opcode.JMP_NGT: case Opcode.JMP_NGE:
                case Opcode.JMP_LT:  case Opcode.JMP_LE:
                case Opcode.JMP_GT:  case Opcode.JMP_GE:
                    return (uint)insn.b == reg || (uint)insn.c == reg;
                // THROW, RET, RET_GEN read A (the value being thrown/returned).
                case Opcode.THROW:
                case Opcode.RET:
                case Opcode.RET_GEN:
                    return (uint)insn.a == reg
                        || (uint)insn.b == reg || (uint)insn.c == reg;
                // IN: A is both source (B) and destination (A).  We model
                // it as reading both B and C (the key and the object).
                // The standard ABC dest is A.
                case Opcode.IN:
                    return (uint)insn.a == reg
                        || (uint)insn.b == reg || (uint)insn.c == reg;
                // CATCH: A is the destination (the caught value goes there).
                default:
                    return (uint)insn.b == reg || (uint)insn.c == reg;
            }
        case A_BC:
        case A_SBX:
            switch (op) {
                // A is a source register (the value being used).
                case Opcode.IF_TRUE:
                case Opcode.IF_FALSE:
                case Opcode.PUTVAR:
                case Opcode.DECLVAR:
                case Opcode.SETALEN:
                case Opcode.WITH_START:
                case Opcode.PUTLEX:
                case Opcode.PUTLEX_C:
                    return (uint)insn.a == reg;
                // A is the destination (we write a result to it).
                case Opcode.LDCONST:
                case Opcode.LDINTX:
                case Opcode.GETVAR:
                case Opcode.TYPEOFIDENT:
                case Opcode.DELVAR:
                case Opcode.CLOSURE:
                case Opcode.GETBOUND:
                case Opcode.INC_VAR:
                case Opcode.DEC_VAR:
                case Opcode.LDINT:
                default:
                    return false;
            }
        case NONE:
            // INC/DEC read and write register A.
            if (op == Opcode.INC || op == Opcode.DEC) {
                return (uint)insn.a == reg;
            }
            return false;
        case WIDE_ABC:
        case WIDE_SABC:
            return false;
    }
    return false;
}

/// Returns the register defined by an instruction, or NO_REG if the
/// instruction does not define a register (e.g. control flow, JMP, TRY,
/// or ops whose A field encodes flags/offsets rather than a register).
fn uint get_dest_reg(Instruction insn) {
    Opcode op = insn.op;
    OpFormat fmt = bytecode::get_op_format(op);
    switch (fmt) {
        case ABC:
            // Standard ABC: A is the destination.  Exceptions: control-flow
            // ops (JUMP, IF_TRUE, IF_FALSE are A_SBX; JMP_NLT etc. have A as
            // an offset, not a dest reg).  CALL also has A as dest reg.
            switch (op) {
                case Opcode.JMP_NLT: case Opcode.JMP_NLE:
                case Opcode.JMP_NGT: case Opcode.JMP_NGE:
                case Opcode.JMP_LT:  case Opcode.JMP_LE:
                case Opcode.JMP_GT:  case Opcode.JMP_GE:
                    // A is a signed 8-bit offset, B/C are source regs.
                    return NO_REG;
                default:
                    return (uint)insn.a;
            }
        case A_BC:
        case A_SBX:
            // A is a destination register only for the ops that actually
            // store a result there.  For PUTVAR/DECLVAR/PUTLEX/... A is a
            // source register.  For TRY/BREAK/CONTINUE/INITTZ A is flags or
            // metadata, not a register.
            switch (op) {
                case Opcode.LDCONST:
                case Opcode.LDINTX:
                case Opcode.GETVAR:
                case Opcode.TYPEOFIDENT:
                case Opcode.DELVAR:
                case Opcode.CLOSURE:
                case Opcode.GETBOUND:
                case Opcode.INC_VAR:
                case Opcode.DEC_VAR:
                case Opcode.LDINT:
                    return (uint)insn.a;
                default:
                    return NO_REG;
            }
        case NONE:
        case WIDE_ABC:
        case WIDE_SABC:
            return NO_REG;
    }
}

/// Reads the B and C source registers for an ABC-format instruction.
fn void get_abc_sources(Instruction insn, uint* b, uint* c) {
    *b = (uint)insn.b;
    *c = (uint)insn.c;
}

/// If `insn` is a definition of a constant fastint value, write the value
/// to `*out` and return true.  Handles LDINT, LDCONST (when the constant
/// pool entry is a fastint), and LDINTX.  Other defining ops (LDREG, etc.)
/// return false.
fn bool try_const_value(Instruction insn, CompiledFunction* func, long* out) {
    switch (insn.op) {
        case Opcode.LDINT:
            *out = (long)insn.get_sbc();
            return true;
        case Opcode.LDCONST: {
            uint const_idx = insn.get_bc();
            if (const_idx >= func.const_count) return false;
            TVal cv = func.get_const(const_idx);
            if (!cv.is_fastint()) return false;
            *out = cv.get_fastint();
            return true;
        }
        case Opcode.LDINTX: {
            // LDINTX: rA = (rA << 16) | BC.  We need rA's value at the time
            // of the LDINTX, which requires a prior def of rA in the same
            // block.  This is rare; bail.
            // (Could be added by walking back one more step.)
            return false;
        }
        default:
            return false;
    }
}

/// True when the most recent definition of `reg` in the same basic block
/// (looking back from `hint_pos`) is a constant fastint.  Used to decide
/// whether LNOT on a register can be folded to a boolean constant without
/// risking a wrong tag (e.g. `LNOT 0.0` is `LDFALSE`, but `LNOT 0` is also
/// `LDFALSE` per ES5 ToBoolean; we only fold when the source is unambiguously
/// a fastint to avoid mishandling -0 / NaN / "" / null).
fn bool def_is_fastint_const(CompiledFunction* func, int hint_pos, uint reg) {
    for (int j = hint_pos; j >= 0; j--) {
        Instruction def = func.code[j];
        if (def.op == Opcode.NOP) continue;
        uint ddest = get_dest_reg(def);
        if (ddest == NO_REG) {
            if (!is_pure_compute(def.op)) return false;
            continue;
        }
        if (ddest != reg) continue;
        return def.op == Opcode.LDINT
            || (def.op == Opcode.LDCONST
                && (int)def.get_bc() < (int)func.const_count
                && func.get_const(def.get_bc()).is_fastint());
    }
    return false;
}

// ============================================================================
// Disassembly helper
// ============================================================================

fn void dump_function(CompiledFunction* func, int depth) {
    for (int d = 0; d < depth; d++) io::printf("  ");
    io::printfn("=== FUNC depth=%d (%d insns, %d regs, %d consts, %d inner) ===",
                depth, func.code_count, func.num_regs, func.const_count, func.inner_count);
    for (uint i = 0; i < func.code_count; i++) {
        char[128] buf;
        buf[0] = 0;
        usz len = func.code[i].disassemble(&buf);
        for (int d = 0; d < depth; d++) io::printf("  ");
        for (usz j = 0; j < len; j++) io::putchar(buf[j]);
        io::putchar('\n');
    }
    for (uint i = 0; i < func.inner_count; i++) {
        dump_function(func.inner_funcs[i], depth + 1);
    }
}

// ============================================================================
// Basic-block local passes
// ============================================================================

/// Coalesce `LDINT rX, imm; OP rY=rA,rX; LDREG rZ=rY; CALL rB=rB,nargs` into
/// `LDINT rX, imm; OP rZ=rA,rX; CALL rB=rB,nargs`, when:
///   * the OP is a pure arithmetic/bitwise op,
///   * the LDREG destination `rZ` is the first argument slot of the CALL.
///     With the sliding-window register layout, this is `callee + 2` (the
///     slot just past the `this` slot that the VM clears to undefined),
///   * the overwritten source register is the LDINT's destination
///     (not clobbered between the LDINT and the OP),
///   * no other instructions appear between the LDREG and the CALL
///     (the LDREG must be immediately followed by the CALL).
///
/// This is the main win for recursive fibonacci-style code, where the
/// compiler loads a small constant, computes `n - 1` into a temporary, then
/// copies the temporary into the argument slot.  The LDUNDEF/LDTHIS that
/// the compiler emits between the LDINT and the SUB (e.g. to materialize
/// `undefined` for the `this` slot) is allowed as long as it doesn't write
/// to the LDINT destination register.
fn uint pass_coalesce_arith_dest(CompiledFunction* func, uint start, uint end) {
    uint changed = 0;
    for (uint i = start + 1; i + 1 < end; i++) {
        Instruction op_insn = func.code[i];
        if (!is_arithmetic_or_bitwise(op_insn.op)) continue;

        uint op_dest = (uint)op_insn.a;
        Instruction mov_insn = func.code[i + 1];
        if (mov_insn.op != Opcode.LDREG) continue;
        if ((uint)mov_insn.b != op_dest) continue;
        uint mov_dest = (uint)mov_insn.a;
        if (mov_dest == op_dest) continue;  // already in place

        uint src_b = (uint)op_insn.b;
        uint src_c = (uint)op_insn.c;

        // The LDREG destination must equal one of the arithmetic sources.
        uint overwritten_src = NO_REG;
        if (mov_dest == src_b) {
            overwritten_src = src_b;
        } else if (mov_dest == src_c) {
            overwritten_src = src_c;
        } else {
            continue;
        }

        // Walk backward from the OP looking for the instruction that defines
        // `overwritten_src`.  The instruction must write `overwritten_src`
        // (as a destination) and not have been clobbered in between.
        if (i == 0) continue;
        uint def_pos = NO_REG;
        for (uint k = i; k > start; k--) {
            Instruction prev = func.code[k - 1];
            uint d = get_dest_reg(prev);
            if (d == overwritten_src) {
                def_pos = k - 1;
                break;
            }
            // Bail on any non-pure instruction that might clobber
            // overwritten_src.
            if (!is_pure_compute(prev.op) && prev.op != Opcode.LDUNDEF
                && prev.op != Opcode.LDNULL && prev.op != Opcode.LDTRUE
                && prev.op != Opcode.LDFALSE && prev.op != Opcode.LDTHIS
                && prev.op != Opcode.NOP && prev.op != Opcode.LDREG
                && prev.op != Opcode.GETVAR) {
                break;
            }
        }
        if (def_pos == NO_REG) continue;

        // The CALL must be at i+2 (LDREG adjacent to CALL).
        bool clobbered = false;
        uint call_pos = 0;
        for (uint j = i + 2; j < end; j++) {
            Instruction jns = func.code[j];
            if (jns.op == Opcode.CALL) {
                uint callee = (uint)jns.b;
                uint argc = (uint)jns.c;
                // Compiler convention (sliding-window):
                //   callee    -> callee slot
                //   callee+1  -> this slot (cleared to undefined by VM)
                //   callee+2..callee+1+argc -> arg slots
                // So the first arg is at callee+2.
                if (argc >= 1 && mov_dest == callee + 2) {
                    call_pos = j;
                }
                break;
            }
            // Bail on any non-pure instruction that might write to a register.
            break;
        }
        if (call_pos == 0 || clobbered) continue;

        // Replace the arithmetic op's destination with the LDREG destination
        // and NOP out the LDREG.
        func.code[i] = bytecode::make_abc(op_insn.op, mov_dest, src_b, src_c);
        func.code[i + 1] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
        changed++;
        g_stats.arith_dest_coalesced++;
    }
    return changed;
}

/// Remove `LDREG rD = rS` where rD is not used before being overwritten within
/// the same basic block.  This catches copies that are not consumed.
fn uint pass_elide_unused_ldreg(CompiledFunction* func, uint start, uint end) {
    uint changed = 0;
    for (uint i = start; i < end; i++) {
        Instruction insn = func.code[i];
        if (insn.op != Opcode.LDREG) continue;
        uint dest = (uint)insn.a;
        uint src = (uint)insn.b;
        if (dest == src) {
            // Self-copy is a no-op.
            func.code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
            changed++;
            g_stats.ldreg_removed++;
            continue;
        }
        // Walk forward to determine the status of `dest` (the LDREG target):
        //   USED:    a subsequent instruction reads dest.
        //   OVERWRITTEN: a subsequent instruction writes to dest without
        //                reading it first.  Then the LDREG is dead.
        //   UNKNOWN: the block ends before we find either.  The value may
        //            flow to a successor.  Be conservative: keep the LDREG.
        bool used = false;
        bool overwritten = false;
        for (uint j = i + 1; j < end; j++) {
            Instruction jns = func.code[j];
            if (jns.op == Opcode.NOP) continue;
            if (reads_register(jns, dest)) { used = true; break; }
            uint jdest = get_dest_reg(jns);
            if (jdest != NO_REG && jdest == dest) {
                overwritten = true;
                break;
            }
        }
        if (used || !overwritten) continue;
        func.code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
        changed++;
        g_stats.ldreg_removed++;
    }
    return changed;
}

/// Fold arithmetic on two constant operands into a single LDINT.
fn uint pass_constant_fold(CompiledFunction* func, uint start, uint end) {
    uint changed = 0;
    for (uint i = start; i < end; i++) {
        Instruction insn = func.code[i];
        if (!is_arithmetic_or_bitwise(insn.op)) continue;
        // For DIV/MOD with c=0, we cannot fold; let the VM raise the error.
        if ((insn.op == Opcode.DIV || insn.op == Opcode.MOD)
            && (uint)insn.c == 0) continue;

        long vb = 0;
        long vc = 0;
        bool have_b = false;
        bool have_c = false;
        bool vb_clobbered = false;
        bool vc_clobbered = false;
        // Walk back to the most recent definitions of rB and rC in this block.
        for (int j = (int)i - 1; j >= (int)start; j--) {
            Instruction def = func.code[j];
            if (def.op == Opcode.NOP) continue;
            uint ddest = get_dest_reg(def);
            if (ddest == NO_REG) {
                // Non-defining instruction: bails for both (could have side effects).
                if (!is_pure_compute(def.op)) break;
                continue;
            }
            if (!have_b && !vb_clobbered && ddest == (uint)insn.b) {
                if (try_const_value(def, func, &vb)) {
                    have_b = true;
                } else {
                    vb_clobbered = true;  // defined by something we can't fold
                }
            }
            if (!have_c && !vc_clobbered && ddest == (uint)insn.c) {
                if (try_const_value(def, func, &vc)) {
                    have_c = true;
                } else {
                    vc_clobbered = true;
                }
            }
            if ((have_b || vb_clobbered) && (have_c || vc_clobbered)) break;
        }
        if (!have_b || !have_c) continue;

        long result = 0;
        bool ok = true;
        switch (insn.op) {
            case Opcode.ADD: result = vb + vc; break;
            case Opcode.SUB: result = vb - vc; break;
            case Opcode.MUL: result = vb * vc; break;
            case Opcode.DIV:
                // Keep only integer-division results so we stay in fastint land.
                if (vb % vc != 0) { ok = false; break; }
                result = vb / vc;
                break;
            case Opcode.MOD:
                // JS modulo follows the sign of the dividend; C % does too.
                result = vb % vc;
                break;
            case Opcode.BAND: result = vb & vc; break;
            case Opcode.BOR:  result = vb | vc; break;
            case Opcode.BXOR: result = vb ^ vc; break;
            case Opcode.SHL: result = vb << (vc & 0x1F); break;
            case Opcode.SHR: result = vb >> (vc & 0x1F); break;
            case Opcode.USHR: {
                // Convert to uint64 for the logical shift, then back to long.
                ulong uv = (ulong)vb;
                result = (long)(uv >> (vc & 0x1F));
                break;
            }
            default: ok = false; break;
        }
        if (!ok) continue;
        if (result < types::FASTINT_MIN || result > types::FASTINT_MAX) continue;
        if (result < bytecode::MIN_SBC || result > bytecode::MAX_SBC) continue;

        // Replace the arithmetic op with an LDINT of the result.
        func.code[i] = bytecode::make_a_sbx(Opcode.LDINT, (uint)insn.a, (int)result);
        changed++;
        g_stats.const_folded++;
    }
    return changed;
}

/// Fold unary ops on a constant operand.  The result is placed in `rA`.
/// Handles UNM (negation, preserves -0 special case), BNOT (bitwise not, always
/// fastint), and LNOT (logical not — produces a BOOLEAN, not a fastint).
fn uint pass_constant_fold_unary(CompiledFunction* func, uint start, uint end) {
    uint changed = 0;
    for (uint i = start; i < end; i++) {
        Instruction insn = func.code[i];
        Opcode op = insn.op;
        bool is_unm = op == Opcode.UNM;
        bool is_bnot = op == Opcode.BNOT;
        bool is_lnot = op == Opcode.LNOT;
        if (!is_unm && !is_bnot && !is_lnot) continue;

        // All three read rB and write rA.
        uint src = (uint)insn.b;
        long v = 0;
        bool have_src = false;
        bool clobbered = false;
        for (int j = (int)i - 1; j >= (int)start; j--) {
            Instruction def = func.code[j];
            if (def.op == Opcode.NOP) continue;
            uint ddest = get_dest_reg(def);
            if (ddest == NO_REG) {
                if (!is_pure_compute(def.op)) break;
                continue;
            }
            if (ddest == src) {
                if (try_const_value(def, func, &v)) {
                    have_src = true;
                } else {
                    clobbered = true;
                }
                break;
            }
        }
        if (!have_src || clobbered) continue;

        if (is_unm) {
            // -0 must be NUMBER, not FASTINT (integers have no -0).
            if (v == 0) continue;
            long r = -v;
            if (r < bytecode::MIN_SBC || r > bytecode::MAX_SBC) continue;
            func.code[i] = bytecode::make_a_sbx(Opcode.LDINT, (uint)insn.a, (int)r);
            changed++;
            g_stats.const_folded++;
        } else if (is_bnot) {
            // BNOT always produces a 32-bit result, always fits in LDINT.
            int bnot_v = (int)(v & 0xFFFFFFFFL);
            int r = ~bnot_v;
            func.code[i] = bytecode::make_a_sbx(Opcode.LDINT, (uint)insn.a, r);
            changed++;
            g_stats.const_folded++;
        } else {
            // LNOT: result must be a BOOLEAN tag, not a fastint.  Determine
            // truthiness of `v` per the same rules the VM uses (see
            // is_truthy in vm.c3):
            //   fastint:    true iff nonzero
            //   everything else: conservatively assume truthy (we don't have
            //     enough info to fold an object/string to a constant here).
            //   For LDCONST of non-fastint, we bail (could be 0.0, "", null,
            //     undefined — easy to mishandle).
            bool truthy = false;
            if (def_is_fastint_const(func, (int)i - 1, src)) {
                truthy = v != 0;
            } else {
                continue;
            }
            func.code[i] = bytecode::make_abc(
                truthy ? Opcode.LDFALSE : Opcode.LDTRUE,
                (uint)insn.a, 0, 0);
            changed++;
            g_stats.const_folded++;
        }
    }
    return changed;
}

/// Peephole: `LDINT rX, imm; LDREG rY = rX` → `LDINT rY, imm`; NOP the LDREG.
/// Also handles `LDCONST rX, idx_of_fastint; LDREG rY = rX` → `LDINT rY, val`.
/// Eliminates a register-to-register move in the common `i = 0` loop init
/// pattern that the compiler emits as `LDINT tmp; LDREG slot; PUTVAR slot`.
fn uint pass_ldint_through_ldreg(CompiledFunction* func, uint start, uint end) {
    uint changed = 0;
    for (uint i = start; i + 1 < end; i++) {
        Instruction insn = func.code[i];
        Instruction next = func.code[i + 1];
        if (next.op != Opcode.LDREG) continue;
        if ((uint)next.b != (uint)insn.a) continue;
        uint ldreg_dest = (uint)next.a;
        if (ldreg_dest == (uint)insn.a) {
            // LDREG of a register into itself — NOP it.
            func.code[i + 1] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
            changed++;
            g_stats.dead_ops_removed++;
            continue;
        }
        if (insn.op == Opcode.LDINT) {
            int v = insn.get_sbc();
            if (v < bytecode::MIN_SBC || v > bytecode::MAX_SBC) continue;
            func.code[i] = bytecode::make_a_sbx(Opcode.LDINT, ldreg_dest, v);
            func.code[i + 1] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
            changed++;
            g_stats.dead_ops_removed++;
        } else if (insn.op == Opcode.LDCONST) {
            uint const_idx = insn.get_bc();
            if (const_idx >= func.const_count) continue;
            TVal cv = func.get_const(const_idx);
            if (!cv.is_fastint()) continue;
            long v = cv.get_fastint();
            if (v < bytecode::MIN_SBC || v > bytecode::MAX_SBC) continue;
            func.code[i] = bytecode::make_a_sbx(Opcode.LDINT, ldreg_dest, (int)v);
            func.code[i + 1] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
            changed++;
            g_stats.dead_ops_removed++;
        }
    }
    return changed;
}

/// Copy-propagation: when `LDREG rA = rB` is the only use of rB before rB is
/// overwritten, rewrite subsequent reads of rA as reads of rB and NOP the LDREG.
/// Conservatively only acts when rA is not used by a subsequent LDREG (chain
/// patterns) and not the source of a call argument.
/// Limited to a single-use window for safety.
fn uint pass_copy_propagate(CompiledFunction* func, uint start, uint end) {
    uint changed = 0;
    for (uint i = start; i < end; i++) {
        Instruction insn = func.code[i];
        if (insn.op != Opcode.LDREG) continue;
        uint dest = (uint)insn.a;
        uint src = (uint)insn.b;
        if (dest == src) continue;

        // Find the next use of dest.  If dest is overwritten (without being
        // read) before any use, bail.  We must see exactly one use of dest
        // in this basic block.
        uint use_pos = NO_REG;
        for (uint j = i + 1; j < end; j++) {
            Instruction jns = func.code[j];
            if (jns.op == Opcode.NOP) continue;
            if (reads_register(jns, dest)) {
                use_pos = j;
                break;
            }
            uint jdest = get_dest_reg(jns);
            if (jdest != NO_REG && jdest == dest) break;  // overwritten
        }
        if (use_pos == NO_REG) continue;

        // Bail on the use if the use has side effects we'd perturb.
        // - CALL: rA would be the callee or arg slot; rewriting the arg slot
        //   source register would change which argument the callee sees.
        // - PUTVAR: the source register A is part of the calling convention
        //   (some paths look at A). Keep rA intact.
        // - GETPROP/GETPROPC/SETPROP/etc: the dest is rA, not a source.
        // We allow: ABC ops that read rA as b or c (the typical arith/consume
        // pattern), and that's it.  Conservative.
        Instruction use = func.code[use_pos];
        OpFormat ufmt = bytecode::get_op_format(use.op);
        if (ufmt != ABC) continue;
        // Don't rewrite when the use is a CALL, CALL_S, NEW, or other
        // call-like op that has register-window semantics.  The b field of
        // CALL is the callee register, c is the arg count, and the
        // sliding-window argument slots are callee+1..callee+1+argc.  Those
        // are physical positions, not the operand value itself.
        switch (use.op) {
            case Opcode.CALL:
            case Opcode.CALL_S:
            case Opcode.SPREAD_ARG:
            case Opcode.ARRSPRD:
            case Opcode.SUPER_CALL:
                continue;
            default: break;
        }
        // The use's A field is its destination — we don't want to perturb
        // that.  It can be any of B or C that we're rewriting, but it's only
        // safe to rewrite one.  Pick whichever matches dest.
        Instruction new_use = use;
        if ((uint)use.b == dest) {
            new_use = bytecode::make_abc(use.op, (uint)use.a, src, (uint)use.c);
        } else if ((uint)use.c == dest) {
            new_use = bytecode::make_abc(use.op, (uint)use.a, (uint)use.b, src);
        } else {
            continue;
        }
        func.code[use_pos] = new_use;
        func.code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
        changed++;
        g_stats.ldreg_removed++;
    }
    return changed;
}

/// Remove dead pure computations whose result is overwritten before being read.
fn uint pass_dead_store(CompiledFunction* func, uint start, uint end) {
    uint changed = 0;
    for (uint i = start; i < end; i++) {
        Instruction insn = func.code[i];
        if (insn.op == Opcode.NOP) continue;
        uint dest = get_dest_reg(insn);
        if (dest == NO_REG) continue;
        if (!is_pure_compute(insn.op)) continue;

        bool used = false;
        bool overwritten = false;
        for (uint j = i + 1; j < end; j++) {
            Instruction jns = func.code[j];
            if (jns.op == Opcode.NOP) continue;
            if (reads_register(jns, dest)) { used = true; break; }
            uint jdest = get_dest_reg(jns);
            if (jdest != NO_REG && jdest == dest) {
                overwritten = true;
                break;
            }
        }
        if (g_dump_bytecode && (int)insn.op == 1 && dest == 14) {
            io::printfn("  DS for LDCONST r14 at i=%d, end=%d: used=%d, overwritten=%d", i, end, used, overwritten);
        }
        if (used || !overwritten) continue;
        func.code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
        changed++;
        g_stats.dead_ops_removed++;
    }
    return changed;
}

// ============================================================================
// Basic block scanning and compaction
// ============================================================================

/// Mark jump targets so we can split basic blocks.
fn void mark_jump_targets(CompiledFunction* func, bool* targets) {
    for (uint i = 0; i < func.code_count; i++) {
        targets[i] = false;
    }
    for (uint i = 0; i < func.code_count; i++) {
        Instruction insn = func.code[i];
        Opcode op = insn.op;
        if (op == Opcode.JUMP) {
            int off = insn.get_sabc();
            int tgt = (int)i + 1 + off;
            if (tgt >= 0 && tgt < (int)func.code_count) targets[tgt] = true;
        } else if (op == Opcode.IF_TRUE || op == Opcode.IF_FALSE) {
            int off = insn.get_sbc();
            int tgt = (int)i + 1 + off;
            if (tgt >= 0 && tgt < (int)func.code_count) targets[tgt] = true;
        } else if (op == Opcode.TRY) {
            // TRY is followed by a NOP holding the finally offset; the catch
            // target is encoded in the TRY instruction's BC field as a delta
            // from the instruction after the NOP.
            uint catch_off = insn.get_bc();
            int tgt = (int)i + 2 + (int)catch_off;
            if (tgt >= 0 && tgt < (int)func.code_count) targets[tgt] = true;
        }
    }
}

/// Find the old pc that maps to a given new pc via an old_to_new table.
/// A new pc may correspond to multiple old pcs (e.g. when NOPs are removed,
/// the old pcs of the NOPs themselves also "map" to the surrounding new pc).
/// We need the first old pc that ACTUALLY maps to a new instruction (not a
/// NOP), so we walk forward from each candidate.
fn uint find_old_pc(uint* old_to_new, uint old_count, uint new_pc,
                    CompiledFunction* func) {
    for (uint k = 0; k < old_count; k++) {
        if (old_to_new[k] != new_pc) continue;
        if (func.code[k].op == Opcode.NOP) continue;
        return k;
    }
    return 0;
}

/// Compact NOPs out of the instruction stream and remap pc-relative jumps.
/// Mirrors the compiler's NOP compaction pass so the optimizer can delete
/// instructions safely.  NOPs that immediately follow TRY are preserved because
/// they hold the finally_offset consumed by the VM.
fn void compact_nops(CompiledFunction* func) {
    if (func.code_count == 0) return;

    // Mark protected NOPs: the slot immediately after TRY carries finally info.
    bool* protected = (bool*)libc::malloc((usz)func.code_count);
    if (protected == null) return;
    libc::memset(protected, 0, (usz)func.code_count);
    for (uint i = 0; i + 1 < func.code_count; i++) {
        if (func.code[i].op == Opcode.TRY) {
            protected[i + 1] = true;
        }
    }

    // old_to_new[old_pc] = new_pc.  Heap-allocated because large functions
    // can exceed a stack buffer.
    uint* old_to_new = (uint*)libc::malloc((usz)func.code_count * 4);
    if (old_to_new == null) { libc::free(protected); return; }
    uint new_count = 0;
    for (uint i = 0; i < func.code_count; i++) {
        old_to_new[i] = new_count;
        if (func.code[i].op != Opcode.NOP || protected[i]) {
            new_count++;
        }
    }

    if (new_count == func.code_count) {
        libc::free(protected);
        libc::free(old_to_new);
        return;
    }

    // Build compacted code in a temporary buffer.
    Instruction* new_code = (Instruction*)libc::malloc((usz)new_count * 4);
    if (new_code == null) { libc::free(protected); return; }
    // Zero the buffer so any unused slots are deterministic.  This is
    // belt-and-suspenders defense: every slot from 0..new_count-1 is
    // explicitly written below, but malloc leaves contents undefined.
    libc::memset(new_code, 0, (usz)new_count * 4);
    uint idx = 0;
    for (uint i = 0; i < func.code_count; i++) {
        if (func.code[i].op == Opcode.NOP && !protected[i]) continue;
        new_code[idx] = func.code[i];
        idx++;
    }

    // protected is no longer needed; free it before the remap loop.
    libc::free(protected);

    // Remap jumps.
    for (uint i = 0; i < new_count; i++) {
        Instruction insn = new_code[i];
        Opcode op = insn.op;
        if (op == Opcode.JUMP) {
            uint old_pc = find_old_pc(old_to_new, func.code_count, i, func);
            int old_abs = (int)old_pc + 1 + insn.get_sabc();
            uint new_tgt = old_to_new[(uint)old_abs];
            int new_off = (int)new_tgt - (int)i - 1;
            new_code[i] = bytecode::make_sabc(Opcode.JUMP, new_off);
        } else if (op == Opcode.IF_TRUE || op == Opcode.IF_FALSE) {
            uint old_pc = find_old_pc(old_to_new, func.code_count, i, func);
            int old_abs = (int)old_pc + 1 + insn.get_sbc();
            uint new_tgt = old_to_new[(uint)old_abs];
            int new_off = (int)new_tgt - (int)i - 1;
            new_code[i] = bytecode::make_a_sbx(op, (uint)insn.a, new_off);
        } else if (op == Opcode.JMP_NLT || op == Opcode.JMP_NLE
                || op == Opcode.JMP_NGT || op == Opcode.JMP_NGE
                || op == Opcode.JMP_LT  || op == Opcode.JMP_LE
                || op == Opcode.JMP_GT  || op == Opcode.JMP_GE) {
            // Fused compare-branch: A is a signed 8-bit offset, B/C are regs.
            uint old_pc = find_old_pc(old_to_new, func.code_count, i, func);
            int old_abs = (int)old_pc + 1 + (int)(ichar)insn.a;
            uint new_tgt = old_to_new[(uint)old_abs];
            int new_off = (int)new_tgt - (int)i - 1;
            new_code[i] = bytecode::make_abc(op, (uint)(ichar)new_off, insn.b, insn.c);
        } else if (op == Opcode.TRY) {
            uint old_pc = find_old_pc(old_to_new, func.code_count, i, func);
            uint old_flags = (uint)insn.a;
            uint old_catch_off = insn.get_bc();
            uint old_catch = old_pc + 2 + old_catch_off;
            uint new_catch = old_to_new[old_catch];
            int new_catch_off = (int)new_catch - (int)i - 2;
            // Preserve the following NOP's BC field (finally offset) unchanged;
            // the VM reads it from the absolute next instruction.
            // Use old_pc+1 directly (the protected NOP slot) rather than
            // find_old_pc, because find_old_pc skips NOPs and would return 0.
            uint next_new = i + 1;
            uint next_old = old_pc + 1;
            new_code[next_new] = func.code[next_old];
            new_code[i] = bytecode::make_a_bc(Opcode.TRY, old_flags, (uint)new_catch_off);
        }
    }

    libc::free(func.code);
    func.code = new_code;
    func.code_count = new_count;
    libc::free(old_to_new);
}

// ============================================================================
// Driver
// ============================================================================

/// Optimize a single function in place.  Also recurses into inner functions.
fn void optimize_function(CompiledFunction* func) {
    if (!g_enabled) return;
    if (func == null) return;

    g_stats.functions_optimized++;

    if (g_dump_bytecode) {
        io::printfn("=== BEFORE OPT ===");
        dump_function(func, 0);
    }

    bool* targets = (bool*)libc::malloc((usz)func.code_count);
    if (targets == null) return;
    libc::memset(targets, 0, (usz)func.code_count);
    mark_jump_targets(func, targets);

    uint block_start = 0;
    while (block_start < func.code_count) {
        // Find block end: next jump target or terminator.
        uint block_end = block_start + 1;
        while (block_end < func.code_count && !targets[block_end]) {
            if (is_terminator(func.code[block_end - 1].op)) break;
            block_end++;
        }
        if (block_end > func.code_count) block_end = func.code_count;
        if (g_dump_bytecode && block_start <= 35 && 35 < block_end) {
            io::printfn("  BLOCK for i=35: [%d, %d)", block_start, block_end);
        }

        g_stats.blocks_scanned++;

        // Run passes repeatedly until stable.
        // Order matters: arithmetic folding and LDINT-through-LDREG run first
        // to surface dead LDINTs and the through-move pattern, then
        // copy-propagation and dead-store cleanup mop up the leftovers.
        for (uint iter = 0; iter < 4; iter++) {
            uint changed = 0;
            changed += pass_coalesce_arith_dest(func, block_start, block_end);
            changed += pass_constant_fold(func, block_start, block_end);
            changed += pass_constant_fold_unary(func, block_start, block_end);
            changed += pass_ldint_through_ldreg(func, block_start, block_end);
            // changed += pass_copy_propagate(func, block_start, block_end);
            changed += pass_elide_unused_ldreg(func, block_start, block_end);
            changed += pass_dead_store(func, block_start, block_end);
            if (changed == 0) break;
        }

        block_start = block_end;
    }

    libc::free(targets);

    compact_nops(func);

    if (g_dump_bytecode) {
        io::printfn("=== AFTER OPT ===");
        dump_function(func, 0);
    }

    // Recurse into inner functions.
    for (uint i = 0; i < func.inner_count; i++) {
        optimize_function(func.inner_funcs[i]);
    }
}

/// Public entry point: optimize a compiled program.
fn void optimize(CompiledFunction* func) {
    init_from_env();
    reset_stats();
    optimize_function(func);
    if (g_dump_bytecode || g_stats.arith_dest_coalesced > 0
        || g_stats.ldreg_removed > 0 || g_stats.const_folded > 0
        || g_stats.dead_ops_removed > 0) {
        print_stats();
    }
}

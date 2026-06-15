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
    switch (fmt) {
        case ABC:
            // For most ABC ops A is the destination and B/C are sources.
            // For CALL, B is the callee register and C is the arg count; arguments
            // are implicit, so we conservatively treat the callee as read.
            return (uint)insn.b == reg || (uint)insn.c == reg;
        case A_BC:
        case A_SBX:
            // For IF_TRUE/IF_FALSE, A is the condition register (source).
            // For LDINT/LDCONST etc., A is the destination.
            if (op == Opcode.IF_TRUE || op == Opcode.IF_FALSE) {
                return (uint)insn.a == reg;
            }
            return false;
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

/// Returns the register defined by an instruction, or NO_REG if none.
fn uint get_dest_reg(Instruction insn) {
    Opcode op = insn.op;
    OpFormat fmt = bytecode::get_op_format(op);
    switch (fmt) {
        case ABC:
        case A_BC:
        case A_SBX:
            return (uint)insn.a;
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
        bool used = false;
        for (uint j = i + 1; j < end; j++) {
            Instruction jns = func.code[j];
            // Check reads of dest.
            OpFormat jfmt = bytecode::get_op_format(jns.op);
            if (jfmt == ABC) {
                if ((uint)jns.b == dest || (uint)jns.c == dest) {
                    used = true;
                    break;
                }
            } else if (jfmt == A_BC || jfmt == A_SBX) {
                if (jns.op == Opcode.GETVAR || jns.op == Opcode.PUTVAR
                    || jns.op == Opcode.INC_VAR || jns.op == Opcode.DEC_VAR
                    || jns.op == Opcode.DECLVAR || jns.op == Opcode.DELVAR
                    || jns.op == Opcode.LDCONST || jns.op == Opcode.LDINTX
                    || jns.op == Opcode.TYPEOFIDENT) {
                    if ((uint)jns.get_bc() == dest) {
                        used = true;
                        break;
                    }
                }
            }
            uint jdest = get_dest_reg(jns);
            if (jdest == dest) break;
        }
        if (!used) {
            func.code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
            changed++;
            g_stats.ldreg_removed++;
        }
    }
    return changed;
}

/// Fold arithmetic on two constant operands into a single LDCONST/LDINT.
fn uint pass_constant_fold(CompiledFunction* func, uint start, uint end) {
    uint changed = 0;
    for (uint i = start; i < end; i++) {
        Instruction insn = func.code[i];
        if (!is_arithmetic_or_bitwise(insn.op)) continue;
        // Only fastint constants for now.
        uint b = (uint)insn.b;
        uint c = (uint)insn.c;
        // We need to know the values in rB and rC.  Track backwards from the
        // start of the block for the most recent definitions.
        long vb = 0;
        long vc = 0;
        bool have_b = false;
        bool have_c = false;
        for (int j = (int)i - 1; j >= (int)start; j--) {
            Instruction def = func.code[j];
            uint ddest = get_dest_reg(def);
            if (!have_b && ddest == b) {
                if (def.op == Opcode.LDINT) {
                    vb = (long)def.get_sbc();
                    have_b = true;
                } else if (def.op == Opcode.LDCONST) {
                    TVal cv = func.get_const(def.get_bc());
                    if (cv.is_fastint()) {
                        vb = cv.get_fastint();
                        have_b = true;
                    }
                }
            }
            if (!have_c && ddest == c) {
                if (def.op == Opcode.LDINT) {
                    vc = (long)def.get_sbc();
                    have_c = true;
                } else if (def.op == Opcode.LDCONST) {
                    TVal cv = func.get_const(def.get_bc());
                    if (cv.is_fastint()) {
                        vc = cv.get_fastint();
                        have_c = true;
                    }
                }
            }
            if (have_b && have_c) break;
        }
        if (!have_b || !have_c) continue;

        long result = 0;
        bool ok = true;
        switch (insn.op) {
            case Opcode.ADD: result = vb + vc; break;
            case Opcode.SUB: result = vb - vc; break;
            case Opcode.MUL: result = vb * vc; break;
            case Opcode.DIV: {
                if (vc == 0) { ok = false; break; }
                // Division can produce non-integer results; bail for now.
                if (vb % vc != 0) { ok = false; break; }
                result = vb / vc;
                break;
            }
            case Opcode.MOD: {
                if (vc == 0) { ok = false; break; }
                result = vb % vc;
                break;
            }
            case Opcode.BAND: result = vb & vc; break;
            case Opcode.BOR:  result = vb | vc; break;
            case Opcode.BXOR: result = vb ^ vc; break;
            case Opcode.SHL: result = vb << vc; break;
            case Opcode.SHR: result = vb >> vc; break;
            case Opcode.USHR: {
                // Logical right shift on signed long is tricky; bail.
                ok = false;
                break;
            }
            default: ok = false; break;
        }
        if (!ok) continue;
        if (result < types::FASTINT_MIN || result > types::FASTINT_MAX) continue;

        // Replace the arithmetic op with an LDINT of the result.
        func.code[i] = bytecode::make_a_sbx(Opcode.LDINT, (uint)insn.a, (int)result);
        changed++;
        g_stats.const_folded++;
    }
    return changed;
}

/// Remove dead pure computations whose result is overwritten before being read.
fn uint pass_dead_store(CompiledFunction* func, uint start, uint end) {
    uint changed = 0;
    for (uint i = start; i < end; i++) {
        Instruction insn = func.code[i];
        uint dest = get_dest_reg(insn);
        if (dest == NO_REG) continue;
        if (!is_pure_compute(insn.op)) continue;

        bool used = false;
        for (uint j = i + 1; j < end; j++) {
            Instruction jns = func.code[j];
            OpFormat jfmt = bytecode::get_op_format(jns.op);
            if (jfmt == ABC) {
                if ((uint)jns.b == dest || (uint)jns.c == dest) {
                    used = true;
                    break;
                }
            } else if (jfmt == A_BC || jfmt == A_SBX) {
                if (jns.op == Opcode.GETVAR || jns.op == Opcode.PUTVAR
                    || jns.op == Opcode.INC_VAR || jns.op == Opcode.DEC_VAR
                    || jns.op == Opcode.DECLVAR || jns.op == Opcode.DELVAR
                    || jns.op == Opcode.LDCONST || jns.op == Opcode.LDINTX
                    || jns.op == Opcode.TYPEOFIDENT) {
                    if ((uint)jns.get_bc() == dest) {
                        used = true;
                        break;
                    }
                }
            }
            uint jdest = get_dest_reg(jns);
            if (jdest == dest) break;
        }
        if (!used) {
            func.code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
            changed++;
            g_stats.dead_ops_removed++;
        }
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
            // target is encoded in the TRY instruction's A field as a delta
            // from the instruction after the NOP.
            uint catch_off = (uint)insn.a;
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
            uint old_catch = old_pc + 2 + (uint)insn.a;
            uint new_catch = old_to_new[old_catch];
            int new_catch_off = (int)new_catch - (int)i - 2;
            // Preserve the following NOP's BC field (finally offset) unchanged;
            // the VM reads it from the absolute next instruction.
            uint next_new = i + 1;
            uint next_old = find_old_pc(old_to_new, func.code_count, next_new, func);
            new_code[next_new] = func.code[next_old];
            new_code[i] = bytecode::make_a_bc(Opcode.TRY, (uint)new_catch_off, insn.get_bc());
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

        g_stats.blocks_scanned++;

        // Run passes repeatedly until stable.
        for (uint iter = 0; iter < 4; iter++) {
            uint changed = 0;
            // Only enable thoroughly validated passes.
            changed += pass_coalesce_arith_dest(func, block_start, block_end);
            // changed += pass_constant_fold(func, block_start, block_end);
            // changed += pass_elide_unused_ldreg(func, block_start, block_end);
            // changed += pass_dead_store(func, block_start, block_end);
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

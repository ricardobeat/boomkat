/// Disassembler for the bytecode representation defined in `bytecode.c3`.
///
/// This translation unit is part of the `duktape::bytecode` module and
/// contains the human-readable disassembly helpers: the 119-entry
/// `OPCODE_NAMES` table, the `get_opcode_name` lookup, the per-format
/// formatter inside `Instruction.disassemble`, and the small
/// `write_str` / `write_uint` / `write_int` buffer-writer helpers.
///
/// All real implementations are gated on the `TRACE_VM` build feature.
/// The release build provides no-op stubs so that callers (`vm_trace.c3`,
/// the `-c` / `--format json` dumpers in `benchmarks/duktape_c3.c3`,
/// and the `dump_vm_state` crash helper) remain linkable. LLVM's dead
/// code elimination drops the `OPCODE_NAMES` array from the final binary
/// when nothing in the `TRACE_VM` branch references it.
module duktape::bytecode;

// ============================================================================
// Instruction.disassemble — one-line textual rendering
// ============================================================================

/// Writes a one-line textual disassembly of the instruction into `buf`.
/// Returns the number of characters that were written.
///
/// Format examples:
///   `ADD       r3 = r1, r2`
///   `LDCONST   r0 = K[42]`
///   `JUMP      +17`
fn usz Instruction.disassemble(&self, char[] buf) {
$if $feature(TRACE_VM):
    if (buf.len == 0) { return 0; }

    Opcode op = self.op;
    OpFormat fmt = get_op_format(op);
    usz pos = 0;

    // Write opcode name (we use the ordinal as a compact representation;
    // a full name table could be added later).
    pos = write_opcode_name(op, buf, pos);

    // Pad to column 14 for alignment.
    while (pos < 14 && pos < buf.len) {
        buf[pos] = ' ';
        pos++;
    }

    switch (fmt) {
        case ABC:
            // Fused compare-branch ops encode A as a signed 8-bit offset, not a register.
            if (op == Opcode.JMP_NLT || op == Opcode.JMP_NLE
                || op == Opcode.JMP_NGT || op == Opcode.JMP_NGE
                || op == Opcode.JMP_LT  || op == Opcode.JMP_LE
                || op == Opcode.JMP_GT  || op == Opcode.JMP_GE) {
                pos = write_int(buf, pos, (int)(ichar)self.a);
                pos = write_str(buf, pos, ", r");
                pos = write_uint(buf, pos, self.b);
                pos = write_str(buf, pos, ", r");
                pos = write_uint(buf, pos, self.c);
            } else {
                pos = write_str(buf, pos, "r");
                pos = write_uint(buf, pos, self.a);
                pos = write_str(buf, pos, " = r");
                pos = write_uint(buf, pos, self.b);
                pos = write_str(buf, pos, ", r");
                pos = write_uint(buf, pos, self.c);
            }

        case A_BC:
            pos = write_str(buf, pos, "r");
            pos = write_uint(buf, pos, self.a);
            pos = write_str(buf, pos, ", ");
            pos = write_uint(buf, pos, self.get_bc());

        case A_SBX:
            pos = write_str(buf, pos, "r");
            pos = write_uint(buf, pos, self.a);
            pos = write_str(buf, pos, ", ");
            pos = write_int(buf, pos, self.get_sbc());

        case WIDE_SABC:
            pos = write_int(buf, pos, self.get_sabc());

        case WIDE_ABC:
            pos = write_uint(buf, pos, self.get_abc());

        case NONE:
            // For INC/DEC show the target register even though they
            // use no formal operands.
            if (op == Opcode.INC || op == Opcode.DEC) {
                pos = write_str(buf, pos, "r");
                pos = write_uint(buf, pos, self.a);
            }
            break;
    }

    return pos;
$else
    // TRACE_VM disabled — keep callers (CLI -c/--format json) linkable.
    // The CLI in the release build detects missing TRACE_VM and tells the
    // user to use `just build-trace`. Code should never reach this stub.
    (void)buf;
    return 0;
$endif
}

// ============================================================================
// Opcode name table (for disassembly / debugging)
// ============================================================================

/// String names for each opcode, indexed by ordinal.
///
/// LLVM drops this constant from the final binary in non-TRACE_VM builds
/// because no reachable code references it. In `TRACE_VM` builds every
/// disassembler path reads it.
const char*[Opcode.LAST_OP.ordinal + 1] OPCODE_NAMES = {
    [Opcode.LDREG.ordinal]       = "LDREG",
    [Opcode.LDCONST.ordinal]     = "LDCONST",
    [Opcode.SETCONST.ordinal]    = "SETCONST",
    [Opcode.FREEZEOBJ.ordinal]   = "FREEZEOBJ",
    [Opcode.PUTPROP_NE.ordinal]  = "PUTPROP_NE",
    [Opcode.LDINT.ordinal]       = "LDINT",
    [Opcode.LDINTX.ordinal]      = "LDINTX",
    [Opcode.LDUNDEF.ordinal]     = "LDUNDEF",
    [Opcode.LDNULL.ordinal]      = "LDNULL",
    [Opcode.LDTRUE.ordinal]      = "LDTRUE",
    [Opcode.LDFALSE.ordinal]     = "LDFALSE",
    [Opcode.LDTHIS.ordinal]      = "LDTHIS",
    [Opcode.ADD.ordinal]         = "ADD",
    [Opcode.SUB.ordinal]         = "SUB",
    [Opcode.MUL.ordinal]         = "MUL",
    [Opcode.DIV.ordinal]         = "DIV",
    [Opcode.MOD.ordinal]         = "MOD",
    [Opcode.EXP.ordinal]         = "EXP",
    [Opcode.UNP.ordinal]         = "UNP",
    [Opcode.UNM.ordinal]         = "UNM",
    [Opcode.BNOT.ordinal]        = "BNOT",
    [Opcode.LNOT.ordinal]        = "LNOT",
    [Opcode.TYPEOF.ordinal]      = "TYPEOF",
    [Opcode.VOID.ordinal]        = "VOID",
    [Opcode.BAND.ordinal]        = "BAND",
    [Opcode.BOR.ordinal]         = "BOR",
    [Opcode.BXOR.ordinal]        = "BXOR",
    [Opcode.SHL.ordinal]         = "SHL",
    [Opcode.SHR.ordinal]         = "SHR",
    [Opcode.USHR.ordinal]        = "USHR",
    [Opcode.EQ.ordinal]          = "EQ",
    [Opcode.NEQ.ordinal]         = "NEQ",
    [Opcode.SEQ.ordinal]         = "SEQ",
    [Opcode.SNEQ.ordinal]        = "SNEQ",
    [Opcode.LT.ordinal]          = "LT",
    [Opcode.LE.ordinal]          = "LE",
    [Opcode.GT.ordinal]          = "GT",
    [Opcode.GE.ordinal]          = "GE",
    [Opcode.INSTANCEOF.ordinal]  = "INSTANCEOF",
    [Opcode.IN.ordinal]          = "IN",
    [Opcode.JUMP.ordinal]        = "JUMP",
    [Opcode.IF_TRUE.ordinal]     = "IF_TRUE",
    [Opcode.IF_FALSE.ordinal]    = "IF_FALSE",
    [Opcode.GETPROP.ordinal]     = "GETPROP",
    [Opcode.GETPROP_CACHE.ordinal] = "GETPROP_CACHE",
    [Opcode.GETPROPC.ordinal]    = "GETPROPC",
    [Opcode.PUTPROP.ordinal]     = "PUTPROP",
    [Opcode.DELPROP.ordinal]     = "DELPROP",
    [Opcode.NEWOBJ.ordinal]      = "NEWOBJ",
    [Opcode.NEWARR.ordinal]      = "NEWARR",
    [Opcode.SETALEN.ordinal]     = "SETALEN",
    [Opcode.CALL.ordinal]        = "CALL",
    [Opcode.CALL_PROP.ordinal]   = "CALL_PROP",
    [Opcode.NEW_OBJ.ordinal]     = "NEW_OBJ",
    [Opcode.TAILCALL.ordinal]    = "TAILCALL",
    [Opcode.RET.ordinal]         = "RET",
    [Opcode.RETUNDEF.ordinal]    = "RETUNDEF",
    [Opcode.GETVAR.ordinal]      = "GETVAR",
    [Opcode.TYPEOFIDENT.ordinal]  = "TYPEOFIDENT",
    [Opcode.PUTVAR.ordinal]      = "PUTVAR",
    [Opcode.DECLVAR.ordinal]     = "DECLVAR",
    [Opcode.DELVAR.ordinal]      = "DELVAR",
    [Opcode.CLOSURE.ordinal]     = "CLOSURE",
    [Opcode.GETBOUND.ordinal]    = "GETBOUND",
    [Opcode.INITFOR.ordinal]     = "INITFOR",
    [Opcode.NEXTFOR.ordinal]     = "NEXTFOR",
    [Opcode.TRY.ordinal]         = "TRY",
    [Opcode.ENDTRY.ordinal]      = "ENDTRY",
    [Opcode.THROW.ordinal]       = "THROW",
    [Opcode.THROW_REF.ordinal]   = "THROW_REF",
    [Opcode.THROW_SYNTAX.ordinal] = "THROW_SYNTAX",
    [Opcode.CATCH.ordinal]       = "CATCH",
    [Opcode.FINALLY.ordinal]     = "FINALLY",
    [Opcode.ENDFINALLY.ordinal]  = "ENDFINALLY",
    [Opcode.TOPROPKEY.ordinal]   = "TOPROPKEY",
    [Opcode.TOSTR.ordinal]       = "TOSTR",
    [Opcode.NOP.ordinal]         = "NOP",
    [Opcode.DEBUGGER.ordinal]    = "DEBUGGER",
    [Opcode.BREAK.ordinal]       = "BREAK",
    [Opcode.CONTINUE.ordinal]    = "CONTINUE",
    [Opcode.INITSET.ordinal]     = "INITSET",
    [Opcode.INITGET.ordinal]     = "INITGET",
    [Opcode.INITSETI.ordinal]    = "INITSETI",
    [Opcode.INITPROPN.ordinal]   = "INITPROPN",
    [Opcode.CLASS_INITGET.ordinal] = "CLASS_INITGET",
    [Opcode.CLASS_INITSET.ordinal] = "CLASS_INITSET",
    [Opcode.CLASS_INITPROP.ordinal] = "CLASS_INITPROP",
    [Opcode.CSVARI.ordinal]      = "CSVARI",
    [Opcode.PUSH_LEX.ordinal]    = "PUSH_LEX",
    [Opcode.POP_LEX.ordinal]     = "POP_LEX",
    [Opcode.PUTLEX.ordinal]      = "PUTLEX",
    [Opcode.PUTLEX_C.ordinal]    = "PUTLEX_C",
    [Opcode.INITTZ.ordinal]      = "INITTZ",
    [Opcode.CHKGLOBALLEX.ordinal]  = "CHKGLOBALLEX",
    [Opcode.CHKGLOBALVAR.ordinal]  = "CHKGLOBALVAR",
    [Opcode.CHKGLOBALFUNC.ordinal] = "CHKGLOBALFUNC",
    [Opcode.NEWREGEXP.ordinal]   = "NEWREGEXP",
    [Opcode.ARRSPRD.ordinal]     = "ARRSPRD",
    [Opcode.SPREAD_ARG.ordinal]  = "SPREAD_ARG",
    [Opcode.FWD_ARGS.ordinal]    = "FWD_ARGS",
    [Opcode.CALL_S.ordinal]      = "CALL_S",
    [Opcode.OBJSPRD.ordinal]     = "OBJSPRD",
    [Opcode.SETPROTO.ordinal]    = "SETPROTO",
    [Opcode.GETPROTO.ordinal]    = "GETPROTO",
    [Opcode.PUTPROP_SUPER.ordinal] = "PUTPROP_SUPER",
    [Opcode.GETPROP_SUPER.ordinal] = "GETPROP_SUPER",
    [Opcode.SUPER_CALL.ordinal]  = "SUPER_CALL",
    [Opcode.SUPER_CALL_S.ordinal] = "SUPER_CALL_S",
    [Opcode.NEWTARGET.ordinal]   = "NEWTARGET",
    [Opcode.LOAD_RESUME.ordinal] = "LOAD_RESUME",
    [Opcode.YIELD.ordinal]       = "YIELD",
    [Opcode.YIELD_STAR.ordinal]  = "YIELD_STAR",
    [Opcode.RET_GEN.ordinal]     = "RET_GEN",
    [Opcode.RETUNDEF_GEN.ordinal] = "RETUNDEF_GEN",
    [Opcode.GEN_START.ordinal]    = "GEN_START",
    [Opcode.AWAIT.ordinal]        = "AWAIT",
    [Opcode.DYN_IMPORT.ordinal]   = "DYN_IMPORT",
    [Opcode.INC.ordinal]          = "INC",
    [Opcode.DEC.ordinal]          = "DEC",
    [Opcode.PUTARG.ordinal]       = "PUTARG",
    [Opcode.NEW_OBJ_S.ordinal]    = "NEW_OBJ_S",
    [Opcode.INC_VAR.ordinal]      = "INC_VAR",
    [Opcode.DEC_VAR.ordinal]      = "DEC_VAR",
    [Opcode.JMP_NLT.ordinal]      = "JMP_NLT",
    [Opcode.JMP_NLE.ordinal]      = "JMP_NLE",
    [Opcode.JMP_NGT.ordinal]      = "JMP_NGT",
    [Opcode.JMP_NGE.ordinal]      = "JMP_NGE",
    [Opcode.JMP_LT.ordinal]       = "JMP_LT",
    [Opcode.JMP_LE.ordinal]       = "JMP_LE",
    [Opcode.JMP_GT.ordinal]       = "JMP_GT",
    [Opcode.JMP_GE.ordinal]       = "JMP_GE",
    [Opcode.GETPROPC2.ordinal]    = "GETPROPC2",
    [Opcode.GETPROPC_CACHED.ordinal] = "GETPROPC_CACHED",
    [Opcode.REQUIRE_OBJ.ordinal] = "REQUIRE_OBJ",
    [Opcode.CHKOBJ.ordinal]      = "CHKOBJ",
    [Opcode.ITER_CLOSE.ordinal]  = "ITER_CLOSE",
    [Opcode.CHKCTOR.ordinal]     = "CHKCTOR",
    [Opcode.CHK_PROT.ordinal]    = "CHK_PROT",
    [Opcode.NEW_PRIV_SYM.ordinal] = "NEW_PRIV_SYM",
    [Opcode.ADD_BRAND.ordinal]   = "ADD_BRAND",
    [Opcode.CHK_BRAND.ordinal]   = "CHK_BRAND",
    [Opcode.INITPROP_PRIV.ordinal] = "INITPROP_PRIV",
    [Opcode.TONUMERIC.ordinal]   = "TONUMERIC",
    [Opcode.LAST_OP.ordinal]     = "LAST_OP",
};

/// Return the human-readable name for an opcode, or "???" for unknown
/// values. Always present (called by `write_opcode_name` whose caller
/// chain is gated on TRACE_VM), so OPCODE_NAMES must be reachable too.
fn char* get_opcode_name(Opcode op) {
    uint idx = (uint)op.ordinal;
    if (idx <= Opcode.LAST_OP.ordinal) {
        char* name = OPCODE_NAMES[idx];
        if (name != null) {
            return name;
        }
    }
    return "???";
}

// ============================================================================
// Internal helpers for disassembly buffer writing
// ============================================================================

/// Write an opcode name into `buf` starting at `pos`.  Returns new pos.
fn usz write_opcode_name(Opcode op, char[] buf, usz pos) {
$if $feature(TRACE_VM):
    char* name = get_opcode_name(op);
    usz i = 0;
    while (name[i] != 0 && pos < buf.len) {
        buf[pos] = name[i];
        pos++;
        i++;
    }
    return pos;
$else
    // Stub for non-TRACE_VM builds. Body only reachable via
    // Instruction.disassemble (also stubbed above).
    (void)op; (void)buf;
    return pos;
$endif
}

/// Write a C string into `buf` starting at `pos`.  Returns new pos.
fn usz write_str(char[] buf, usz pos, char* s) {
$if $feature(TRACE_VM):
    usz i = 0;
    while (s[i] != 0 && pos < buf.len) {
        buf[pos] = s[i];
        pos++;
        i++;
    }
    return pos;
$else
    (void)buf; (void)s;
    return pos;
$endif
}

/// Write an unsigned integer (decimal) into `buf` starting at `pos`.
fn usz write_uint(char[] buf, usz pos, uint val) {
$if $feature(TRACE_VM):
    // Small stack buffer for decimal digits (max 10 digits for uint).
    char[12] tmp;
    usz len = 0;

    if (val == 0) {
        if (pos < buf.len) {
            buf[pos] = '0';
            pos++;
        }
        return pos;
    }

    uint v = val;
    while (v > 0) {
        tmp[len] = (char)('0' + (v % 10));
        len++;
        v /= 10;
    }

    // Write in reverse order.
    for (usz i = len; i > 0 && pos < buf.len; ) {
        i--;
        buf[pos] = tmp[i];
        pos++;
    }
    return pos;
$else
    (void)buf; (void)val;
    return pos;
$endif
}

/// Write a signed integer (decimal) into `buf` starting at `pos`.
fn usz write_int(char[] buf, usz pos, int val) {
$if $feature(TRACE_VM):
    if (val < 0) {
        if (pos < buf.len) {
            buf[pos] = '-';
            pos++;
        }
        // Handle INT_MIN carefully.
        if (val == -2147483647 - 1) {
            return write_uint(buf, pos, (uint)2147483648);
        }
        return write_uint(buf, pos, (uint)(-val));
    }
    if (val > 0) {
        if (pos < buf.len) {
            buf[pos] = '+';
            pos++;
        }
    }
    return write_uint(buf, pos, (uint)val);
$else
    (void)buf; (void)val;
    return pos;
$endif
}
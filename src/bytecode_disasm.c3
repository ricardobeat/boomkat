/// Disassembler for the bytecode representation defined in `bytecode.c3`.
///
/// Part of the `boomkat::bytecode` module, holding the disassembly helpers: the
/// `OPCODE_NAMES` table, the `get_opcode_name` lookup, the per-format formatter
/// in `Instruction.disassemble`, and the `write_str`, `write_uint`, and
/// `write_int` buffer writers.
///
/// The `TRACE_VM` feature gates every real implementation. Release builds get
/// no-op stubs instead, which keeps callers linkable: `vm_trace.c3`, the `-c`
/// and `--format json` dumpers, and the `dump_vm_state` crash helper. Dead code
/// elimination then drops `OPCODE_NAMES` from the binary.
module boomkat::bytecode;

// ============================================================================
// Instruction.disassemble: one-line textual rendering
// ============================================================================

/// Write a one-line disassembly of the instruction into `buf`, returning how
/// many characters it wrote. For example:
///   `ADD       r3 = r1, r2`
///   `LDCONST   r0 = K[42]`
///   `JUMP      +17`
fn usz Instruction.disassemble(&self, char[] buf) {
$if $feature(TRACE_VM):
    if (buf.len == 0) { return 0; }

    Opcode op = self.op;
    OpFormat fmt = get_op_format(op);
    usz pos = 0;

    pos = write_opcode_name(op, buf, pos);

    // Pad to column 16 for alignment (widest mnemonic is CALL_UNDEF_THIS,
    // 15 chars, so leave at least one space before the operands).
    while (pos < 16 && pos < buf.len) {
        buf[pos] = ' ';
        pos++;
    }

    switch (fmt) {
        case ABC:
            // Fused compare-branch ops encode A as a signed 8-bit offset, not a register.
            if (op == Opcode.JMP_LT_G) {
                // Two-word: A = signed offset, B = register operand; the
                // global's name index lives in the trailing word's BC.
                pos = write_int(buf, pos, (int)(ichar)self.a);
                pos = write_str(buf, pos, ", r");
                pos = write_uint(buf, pos, self.b);
                pos = write_str(buf, pos, ", g[..]");
            } else if (op == Opcode.JMP_NLT || op == Opcode.JMP_NLE
                || op == Opcode.JMP_NGT || op == Opcode.JMP_NGE
                || op == Opcode.JMP_LT  || op == Opcode.JMP_LE
                || op == Opcode.JMP_GT  || op == Opcode.JMP_GE) {
                pos = write_int(buf, pos, (int)(ichar)self.a);
                pos = write_str(buf, pos, ", r");
                pos = write_uint(buf, pos, self.b);
                pos = write_str(buf, pos, ", r");
                pos = write_uint(buf, pos, self.c);
            } else if (op == Opcode.CALL_VAR || op == Opcode.CALL_GLOBAL) {
                // A=result/callee reg, B=argc (not a register), C=name const idx.
                pos = write_str(buf, pos, "r");
                pos = write_uint(buf, pos, self.a);
                pos = write_str(buf, pos, ", argc=");
                pos = write_uint(buf, pos, self.b);
                pos = write_str(buf, pos, ", K[");
                pos = write_uint(buf, pos, self.c);
                pos = write_str(buf, pos, "]");
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
    // Without TRACE_VM this stub keeps the CLI dumpers linkable.
    // The CLI in the release build detects missing TRACE_VM and tells the
    // user to use `just build-trace`. Code should never reach this stub.
    (void)buf;
    return 0;
$endif
}

// ============================================================================
// DecodedInsn.disassemble: same rendering, widened operands
// ============================================================================

/// Write a one-line disassembly of a decoded (possibly WIDE-expanded)
/// instruction into `buf`. Mirrors Instruction.disassemble but reads the
/// effective 16-bit operand values, so a WIDE-prefixed instruction renders
/// the registers the VM will actually use.
fn usz DecodedInsn.disassemble(&self, char[] buf) {
$if $feature(TRACE_VM):
    if (buf.len == 0) { return 0; }

    Opcode op = self.op;
    OpFormat fmt = get_op_format(op);
    usz pos = 0;

    pos = write_opcode_name(op, buf, pos);

    while (pos < 16 && pos < buf.len) {
        buf[pos] = ' ';
        pos++;
    }

    switch (fmt) {
        case ABC:
            if (op == Opcode.JMP_LT_G) {
                pos = write_int(buf, pos, (int)(ichar)self.a);
                pos = write_str(buf, pos, ", r");
                pos = write_uint(buf, pos, self.b);
                pos = write_str(buf, pos, ", g[..]");
            } else if (op == Opcode.JMP_NLT || op == Opcode.JMP_NLE
                || op == Opcode.JMP_NGT || op == Opcode.JMP_NGE
                || op == Opcode.JMP_LT  || op == Opcode.JMP_LE
                || op == Opcode.JMP_GT  || op == Opcode.JMP_GE) {
                pos = write_int(buf, pos, (int)(ichar)self.a);
                pos = write_str(buf, pos, ", r");
                pos = write_uint(buf, pos, self.b);
                pos = write_str(buf, pos, ", r");
                pos = write_uint(buf, pos, self.c);
            } else if (op == Opcode.CALL_VAR || op == Opcode.CALL_GLOBAL) {
                pos = write_str(buf, pos, "r");
                pos = write_uint(buf, pos, self.a);
                pos = write_str(buf, pos, ", argc=");
                pos = write_uint(buf, pos, self.b);
                pos = write_str(buf, pos, ", K[");
                pos = write_uint(buf, pos, self.c);
                pos = write_str(buf, pos, "]");
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
            if (op == Opcode.INC || op == Opcode.DEC) {
                pos = write_str(buf, pos, "r");
                pos = write_uint(buf, pos, self.a);
            }
            break;
    }

    return pos;
$else
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
    [Opcode.WIDE.ordinal]        = "WIDE",
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
    [Opcode.ADDI.ordinal]        = "ADDI",
    [Opcode.SUBI.ordinal]        = "SUBI",
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
    [Opcode.RESOLVEVAR.ordinal]  = "RESOLVEVAR",
    [Opcode.THROW_UNRESOLVED.ordinal] = "THROW_UNRESOLVED",
    [Opcode.TYPEOFIDENT.ordinal]  = "TYPEOFIDENT",
    [Opcode.PUTVAR.ordinal]      = "PUTVAR",
    [Opcode.PUTVAR_ASSIGN.ordinal] = "PUTVAR_ASSIGN",
    [Opcode.DECLVAR.ordinal]     = "DECLVAR",
    [Opcode.DECLGLOBALFUNC.ordinal] = "DECLGLOBALFUNC",
    [Opcode.DECLVAR_HOIST.ordinal] = "DECLVAR_HOIST",
    [Opcode.GETGLOBAL.ordinal]   = "GETGLOBAL",
    [Opcode.PUTGLOBAL.ordinal]   = "PUTGLOBAL",
    [Opcode.GETGLOBAL_PRIM.ordinal] = "GETGLOBAL_PRIM",
    [Opcode.PUTGLOBAL_PRIM.ordinal] = "PUTGLOBAL_PRIM",
    [Opcode.MOVE_GG.ordinal]     = "MOVE_GG",
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
    [Opcode.INITPROP.ordinal]    = "INITPROP",
    [Opcode.INITPROPN.ordinal]   = "INITPROPN",
    [Opcode.CLASS_INITGET.ordinal] = "CLASS_INITGET",
    [Opcode.CLASS_INITSET.ordinal] = "CLASS_INITSET",
    [Opcode.CLASS_INITPROP.ordinal] = "CLASS_INITPROP",
    [Opcode.CSVARI.ordinal]      = "CSVARI",
    [Opcode.PUSH_LEX.ordinal]    = "PUSH_LEX",
    [Opcode.POP_LEX.ordinal]     = "POP_LEX",
    [Opcode.PUSH_VAR.ordinal]    = "PUSH_VAR",
    [Opcode.POP_VAR.ordinal]     = "POP_VAR",
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
    [Opcode.CALL_UNDEF_THIS.ordinal] = "CALL_UNDEF_THIS",
    [Opcode.CALL_VAR.ordinal]    = "CALL_VAR",
    [Opcode.CALL_GLOBAL.ordinal] = "CALL_GLOBAL",
    [Opcode.OBJSPRD.ordinal]     = "OBJSPRD",
    [Opcode.OBJREST.ordinal]     = "OBJREST",
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
    [Opcode.YIELD_STAR_ASYNC.ordinal] = "YIELD_STAR_ASYNC",
    [Opcode.RET_GEN.ordinal]     = "RET_GEN",
    [Opcode.RETUNDEF_GEN.ordinal] = "RETUNDEF_GEN",
    [Opcode.GEN_START.ordinal]    = "GEN_START",
    [Opcode.AWAIT.ordinal]        = "AWAIT",
    [Opcode.DYN_IMPORT.ordinal]   = "DYN_IMPORT",
    [Opcode.IMPORT_META.ordinal]  = "IMPORT_META",
    [Opcode.INC.ordinal]          = "INC",
    [Opcode.DEC.ordinal]          = "DEC",
    [Opcode.PUTARG.ordinal]       = "PUTARG",
    [Opcode.NEW_OBJ_S.ordinal]    = "NEW_OBJ_S",
    [Opcode.INC_VAR.ordinal]      = "INC_VAR",
    [Opcode.DEC_VAR.ordinal]      = "DEC_VAR",
    [Opcode.INC_GLOBAL.ordinal]   = "INC_GLOBAL",
    [Opcode.DEC_GLOBAL.ordinal]   = "DEC_GLOBAL",
    [Opcode.JMP_NLT.ordinal]      = "JMP_NLT",
    [Opcode.JMP_NLE.ordinal]      = "JMP_NLE",
    [Opcode.JMP_NGT.ordinal]      = "JMP_NGT",
    [Opcode.JMP_NGE.ordinal]      = "JMP_NGE",
    [Opcode.JMP_LT.ordinal]       = "JMP_LT",
    [Opcode.JMP_LT_G.ordinal]     = "JMP_LT_G",
    [Opcode.JMP_LE.ordinal]       = "JMP_LE",
    [Opcode.JMP_GT.ordinal]       = "JMP_GT",
    [Opcode.JMP_GE.ordinal]       = "JMP_GE",
    [Opcode.JMP_SEQ.ordinal]      = "JMP_SEQ",
    [Opcode.JMP_SNEQ.ordinal]     = "JMP_SNEQ",
    [Opcode.GETPROPC2.ordinal]    = "GETPROPC2",
    [Opcode.GETPROPC_CACHED.ordinal] = "GETPROPC_CACHED",
    [Opcode.REQUIRE_OBJ.ordinal] = "REQUIRE_OBJ",
    [Opcode.CHKOBJ.ordinal]      = "CHKOBJ",
    [Opcode.CHKITER.ordinal]     = "CHKITER",
    [Opcode.ITER_CLOSE.ordinal]  = "ITER_CLOSE",
    [Opcode.GET_ITER_ASYNC.ordinal]   = "GET_ITER_ASYNC",
    [Opcode.ITER_CLOSE_ASYNC.ordinal] = "ITER_CLOSE_ASYNC",
    [Opcode.CHKCTOR.ordinal]     = "CHKCTOR",
    [Opcode.CHK_PROT.ordinal]    = "CHK_PROT",
    [Opcode.NEW_PRIV_SYM.ordinal] = "NEW_PRIV_SYM",
    [Opcode.ADD_BRAND.ordinal]   = "ADD_BRAND",
    [Opcode.CHK_BRAND.ordinal]   = "CHK_BRAND",
    [Opcode.HAS_BRAND.ordinal]   = "HAS_BRAND",
    [Opcode.INITPROP_PRIV.ordinal] = "INITPROP_PRIV",
    [Opcode.GETPROP_PRIVATE.ordinal] = "GETPROP_PRIVATE",
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
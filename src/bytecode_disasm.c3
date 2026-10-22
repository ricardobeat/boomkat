// Disassembler for the bytecode representation defined in `bytecode.c3`.
//
// Part of the `boomkat::bytecode` module, holding the disassembly helpers: the
// `get_opcode_name` lookup, the per-format formatter in
// `Instruction.disassemble`, and the `write_str`, `write_uint`, and
// `write_int` buffer writers.
//
// The `TRACE_VM` feature gates every real implementation. Release builds get
// no-op stubs instead, which keeps callers linkable: `vm_trace.c3`, the `-c`
// and `--format json` dumpers, and the `dump_vm_state` crash helper. Dead code
// elimination then drops the disassembly code from the binary.
module boomkat::bytecode;

// ============================================================================
// Instruction.disassemble: one-line textual rendering
// ============================================================================

// Write a one-line disassembly of the instruction into `buf`, returning how
// many characters it wrote. For example:
//   `ADD       r3 = r1, r2`
//   `LDCONST   r0 = K[42]`
//   `JUMP      +17`
fn usz Instruction.disassemble(&self, char[] buf) {
$if $feat(TRACE_VM):
    if (buf.len == 0) { return 0; }

    Opcode op = self.op;
    OpFormat fmt = get_op_format(op);
    usz pos = 0;

    pos = write_opcode_name(op, buf, pos);
    pos = pad_mnemonic(buf, pos);

    switch (fmt) {
        case ABC:
            // Fused compare-branch ops encode A as a signed 8-bit offset.
            if (is_cmp_branch(op)) {
                pos = write_int(buf, pos, (int)(ichar)self.a);
                pos = write_str(buf, pos, ", r");
                pos = write_uint(buf, pos, self.b);
                if (reg_form(op) != Opcode.NOP) {
                    pos = write_str(buf, pos, ", ");
                    pos = write_int(buf, pos, (int)imm_value(op, self.c));
                } else {
                    pos = write_str(buf, pos, ", r");
                    pos = write_uint(buf, pos, self.c);
                }
            } else if (op == Opcode.CALL_VAR || op == Opcode.CALL_GLOBAL) {
                // A=result/callee reg, B=argc (not a register), C=name const idx.
                pos = write_str(buf, pos, "r");
                pos = write_uint(buf, pos, self.a);
                pos = write_str(buf, pos, ", argc=");
                pos = write_uint(buf, pos, self.b);
                pos = write_str(buf, pos, ", K[");
                pos = write_uint(buf, pos, self.c);
                pos = write_str(buf, pos, "]");
            } else if (op == Opcode.DESTRUCT_ARRAY_FAST) {
                pos = write_str(buf, pos, "src=r");
                pos = write_uint(buf, pos, self.a);
                pos = write_str(buf, pos, ", dst=r");
                pos = write_uint(buf, pos, self.b);
                pos = write_str(buf, pos, ", count=");
                pos = write_uint(buf, pos, self.c);
            } else if (op == Opcode.DESTRUCT_ARRAY_REST_FAST) {
                pos = write_str(buf, pos, "src=r");
                pos = write_uint(buf, pos, self.a);
                pos = write_str(buf, pos, ", dst=r");
                pos = write_uint(buf, pos, self.b);
                pos = write_str(buf, pos, ", prefix=");
                pos = write_uint(buf, pos, self.c);
            } else {
                pos = write_str(buf, pos, "r");
                pos = write_uint(buf, pos, self.a);
                pos = write_str(buf, pos, " = r");
                pos = write_uint(buf, pos, self.b);
                if (is_imm_form(op)) {
                    pos = write_str(buf, pos, ", ");
                    pos = write_int(buf, pos, (int)imm_value(op, self.c));
                } else {
                    pos = write_str(buf, pos, ", r");
                    pos = write_uint(buf, pos, self.c);
                }
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
            // INC/DEC have no formal operands but still show the target register.
            if (op == Opcode.INC || op == Opcode.DEC) {
                pos = write_str(buf, pos, "r");
                pos = write_uint(buf, pos, self.a);
            }
            break;
    }

    return pos;
$else
    // Keeps the CLI dumpers linkable. The CLI asks for `just build-trace` instead.
    (void)buf;
    return 0;
$endif
}

// ============================================================================
// DecodedInsn.disassemble: same rendering, widened operands
// ============================================================================

// Like Instruction.disassemble, but for a decoded instruction: operands are the
// effective values after WIDE expansion, as the VM will use them.
fn usz DecodedInsn.disassemble(&self, char[] buf) {
$if $feat(TRACE_VM):
    if (buf.len == 0) { return 0; }

    Opcode op = self.op;
    OpFormat fmt = get_op_format(op);
    usz pos = 0;

    pos = write_opcode_name(op, buf, pos);
    pos = pad_mnemonic(buf, pos);

    switch (fmt) {
        case ABC:
            if (is_cmp_branch(op)) {
                pos = write_int(buf, pos, (int)(ichar)self.a);
                pos = write_str(buf, pos, ", r");
                pos = write_uint(buf, pos, self.b);
                if (reg_form(op) != Opcode.NOP) {
                    pos = write_str(buf, pos, ", ");
                    pos = write_int(buf, pos, (int)imm_value(op, self.c));
                } else {
                    pos = write_str(buf, pos, ", r");
                    pos = write_uint(buf, pos, self.c);
                }
            } else if (op == Opcode.CALL_VAR || op == Opcode.CALL_GLOBAL) {
                pos = write_str(buf, pos, "r");
                pos = write_uint(buf, pos, self.a);
                pos = write_str(buf, pos, ", argc=");
                pos = write_uint(buf, pos, self.b);
                pos = write_str(buf, pos, ", K[");
                pos = write_uint(buf, pos, self.c);
                pos = write_str(buf, pos, "]");
            } else if (op == Opcode.DESTRUCT_ARRAY_FAST) {
                pos = write_str(buf, pos, "src=r");
                pos = write_uint(buf, pos, self.a);
                pos = write_str(buf, pos, ", dst=r");
                pos = write_uint(buf, pos, self.b);
                pos = write_str(buf, pos, ", count=");
                pos = write_uint(buf, pos, self.c);
            } else if (op == Opcode.DESTRUCT_ARRAY_REST_FAST) {
                pos = write_str(buf, pos, "src=r");
                pos = write_uint(buf, pos, self.a);
                pos = write_str(buf, pos, ", dst=r");
                pos = write_uint(buf, pos, self.b);
                pos = write_str(buf, pos, ", prefix=");
                pos = write_uint(buf, pos, self.c);
            } else {
                pos = write_str(buf, pos, "r");
                pos = write_uint(buf, pos, self.a);
                pos = write_str(buf, pos, " = r");
                pos = write_uint(buf, pos, self.b);
                if (is_imm_form(op)) {
                    pos = write_str(buf, pos, ", ");
                    pos = write_int(buf, pos, (int)imm_value(op, self.c));
                } else {
                    pos = write_str(buf, pos, ", r");
                    pos = write_uint(buf, pos, self.c);
                }
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
// Opcode names (for disassembly / debugging)
// ============================================================================

// Name of an opcode, or "???" for an out-of-range value. Read from the enum
// reflection so a new opcode cannot leave the disassembler behind.
fn char* get_opcode_name(Opcode op) {
    uint idx = (uint)op.ordinal;
    if (idx <= Opcode.LAST_OP.ordinal) {
        return Opcode::names[idx].ptr;
    }
    return "???";
}

// ============================================================================
// Internal helpers for disassembly buffer writing
// ============================================================================

// Write an opcode name into `buf` starting at `pos`.  Returns new pos.
fn usz write_opcode_name(Opcode op, char[] buf, usz pos) {
$if $feat(TRACE_VM):
    char* name = get_opcode_name(op);
    usz i = 0;
    while (name[i] != 0 && pos < buf.len) {
        buf[pos] = name[i];
        pos++;
        i++;
    }
    return pos;
$else
    // Non-TRACE_VM stub; only reached via Instruction.disassemble.
    (void)op; (void)buf;
    return pos;
$endif
}

// Pad the mnemonic to column 20, always leaving at least one space so a name
// longer than 20 characters does not run into its operands. Returns new pos.
fn usz pad_mnemonic(char[] buf, usz pos) @inline {
    usz target = pos < 20 ? 20 : pos + 1;
    while (pos < target && pos < buf.len) {
        buf[pos] = ' ';
        pos++;
    }
    return pos;
}

// Write a C string into `buf` starting at `pos`.  Returns new pos.
fn usz write_str(char[] buf, usz pos, char* s) {
$if $feat(TRACE_VM):
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

// Write an unsigned integer (decimal) into `buf` starting at `pos`.
fn usz write_uint(char[] buf, usz pos, uint val) {
$if $feat(TRACE_VM):
    // Decimal digits, least significant first. A uint has at most 10.
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

// Write a signed integer (decimal) into `buf` starting at `pos`.
fn usz write_int(char[] buf, usz pos, int val) {
$if $feat(TRACE_VM):
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

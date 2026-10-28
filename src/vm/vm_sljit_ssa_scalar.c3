module boomkat::vm;

import boomkat::bytecode;

fn bool ssa_scalar_binary(Opcode op) @feat(SLJIT) {
    switch (op) {
        case LT: case LE: case GT: case GE:
        case EQ: case NEQ: case SEQ: case SNEQ:
        case ADD: case ADD_FUSED: case SUB: case MUL: case DIV:
        case BAND: case BOR: case BXOR: case SHL: case SHR: case USHR: return true;
        default: return false;
    }
}

fn Opcode ssa_comparison_branch(Opcode op) @feat(SLJIT) {
    switch (op) {
        case LT: return Opcode.JMP_LT;
        case LE: return Opcode.JMP_LE;
        case GT: return Opcode.JMP_GT;
        case GE: return Opcode.JMP_GE;
        case EQ: case SEQ: return Opcode.JMP_SEQ;
        case NEQ: case SNEQ: return Opcode.JMP_SNEQ;
        default: unreachable("SSA comparison opcode");
    }
}

// Scalar semantics are identical in a caller and an expanded leaf. Preserve
// JavaScript's numeric guards and int32 overflow exits in one lowering path.
fn int ssa_scalar(SsaGraph* g, Opcode opcode, int left_input, int right_input = -1, long immediate = 0) @feat(SLJIT) {
    switch (opcode) {
        case ADD:
        case ADD_FUSED:
        case SUB:
        case MUL:
        case DIV:

            {
                int left  = left_input;
                int right = right_input;
                if (left < 0 || right < 0) {
                    g.failed = true;
                    return -1;
                }
                SsaOp op     = opcode == Opcode.ADD || opcode == Opcode.ADD_FUSED ? ADD
                    : opcode == Opcode.SUB ? SUB
                    : opcode == Opcode.MUL ? MUL
                    : DIV;
                // Integer arithmetic stays in GPRs with overflow exits
                // instead of round-tripping through doubles.
                bool integer = op != DIV && g.values[left].rep == INT32 && g.values[right].rep == INT32;
                SsaRep rep   = integer ? INT32 : F64;
                left = ssa_convert(g, left, rep, integer);
                right = ssa_convert(g, right, rep, integer);
                ssa_use(g, left);
                ssa_use(g, right);

                return ssa_value(g, op, rep, left, right, 0);
            }
        case ADDI:
        case SUBI:
        case MULI:

            {
                int left = left_input;
                if (left < 0) {
                    g.failed = true;
                    return -1;
                }
                SsaOp op     = opcode == Opcode.SUBI ? SUB : opcode == Opcode.MULI ? MUL : ADD;
                bool integer = g.values[left].rep == INT32;
                SsaRep rep   = integer ? INT32 : F64;
                left = ssa_convert(g, left, rep, integer);
                ssa_use(g, left);

                return ssa_value(g, op, rep, left, -1, immediate);
            }
        case BAND:
        case BOR:
        case BXOR:
        case SHL:
        case SHR:
        case USHR:

            {
                int left  = left_input;
                int right = right_input;
                if (left < 0 || right < 0) {
                    g.failed = true;
                    return -1;
                }
                left = ssa_convert(g, left, INT32, false);
                bool immediate_right = g.values[right].op == CONST_I;
                long literal = immediate_right ? g.values[right].imm : 0;
                if (!immediate_right) right = ssa_convert(g, right, INT32, false);
                ssa_use(g, left);
                if (!immediate_right) ssa_use(g, right);
                SsaOp op = opcode == Opcode.BAND ? BAND
                    : opcode == Opcode.BOR ? BOR
                    : opcode == Opcode.BXOR ? BXOR
                    : opcode == Opcode.SHL ? SHL
                    : opcode == Opcode.SHR ? SHR
                    : USHR;

                return ssa_value(g, op, INT32, left, immediate_right ? -1 : right, literal);
            }
        case BANDI:
        case BORI:
        case BXORI:
        case SHLI:
        case SHRI:
        case USHRI:

            {
                int left = left_input;
                if (left < 0) {
                    g.failed = true;
                    return -1;
                }
                left = ssa_convert(g, left, INT32, false);
                ssa_use(g, left);
                SsaOp op = opcode == Opcode.BANDI ? BAND
                    : opcode == Opcode.BORI ? BOR
                    : opcode == Opcode.BXORI ? BXOR
                    : opcode == Opcode.SHLI ? SHL
                    : opcode == Opcode.SHRI ? SHR
                    : USHR;

                return ssa_value(g, op, INT32, left, -1, immediate);
            }
        case BNOT:

            {
                int value = left_input;
                if (value < 0) {
                    g.failed = true;
                    return -1;
                }
                value = ssa_convert(g, value, INT32, false);
                ssa_use(g, value);

                return ssa_value(g, BNOT, INT32, value, -1, 0);
            }
        case LT: case LE: case GT: case GE:
        case EQ: case NEQ: case SEQ: case SNEQ:
            if (left_input < 0 || right_input < 0) return -1;
            bool integer = g.values[left_input].rep == INT32 && g.values[right_input].rep == INT32;
            SsaRep rep = integer ? INT32 : F64;
            int left = ssa_convert(g, left_input, rep, false);
            bool literal = integer && g.values[right_input].op == CONST_I;
            long immediate_right = literal ? g.values[right_input].imm : 0;
            int right = literal ? -1 : ssa_convert(g, right_input, rep, false);
            ssa_use(g, left);
            if (right >= 0) ssa_use(g, right);
            int value = ssa_value(g, COMPARE, BOXED, left, right, immediate_right);
            g.values[value].branch_op = ssa_comparison_branch(opcode);
            return value;
        case UNM:
            if (left_input < 0) return -1;
            int operand = ssa_convert(g, left_input, F64, false);
            ssa_use(g, operand);
            return ssa_value(g, NEG, F64, operand, -1, 0);
        default: return -1;
    }
}

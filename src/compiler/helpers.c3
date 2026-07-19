module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import std::io;

// ============================================================================
// Helpers
// ============================================================================

/// Compare two char slices for equality.
fn bool str_eq(char[] a, char[] b) {
    if (a.len != b.len) {
        return false;
    }
    if (a.len == 0) {
        return true;
    }
    for (usz i = 0; i < a.len; i++) {
        if (a[i] != b[i]) {
            return false;
        }
    }
    return true;
}

fn int get_binary_precedence(TokenType tt) {
    switch (tt) {
        case TokenType.LOG_OR:      return PREC_LOGICAL_OR;
        case TokenType.LOG_AND:     return PREC_LOGICAL_AND;
        case TokenType.BIT_OR:      return PREC_BITWISE_OR;
        case TokenType.BIT_XOR:     return PREC_BITWISE_XOR;
        case TokenType.BIT_AND:     return PREC_BITWISE_AND;
        case TokenType.EQ:          return PREC_EQUALITY;
        case TokenType.NE:          return PREC_EQUALITY;
        case TokenType.SEQ:         return PREC_EQUALITY;
        case TokenType.SNE:         return PREC_EQUALITY;
        case TokenType.LT:          return PREC_RELATIONAL;
        case TokenType.GT:          return PREC_RELATIONAL;
        case TokenType.LE:          return PREC_RELATIONAL;
        case TokenType.GE:          return PREC_RELATIONAL;
        case TokenType.INSTANCEOF:  return PREC_RELATIONAL;
        case TokenType.IN:          return PREC_RELATIONAL;
        case TokenType.SHL:         return PREC_SHIFT;
        case TokenType.SHR:         return PREC_SHIFT;
        case TokenType.USHR:        return PREC_SHIFT;
        case TokenType.PLUS:        return PREC_ADDITIVE;
        case TokenType.MINUS:       return PREC_ADDITIVE;
        case TokenType.STAR:        return PREC_MULTIPLICATIVE;
        case TokenType.SLASH:       return PREC_MULTIPLICATIVE;
        case TokenType.PERCENT:     return PREC_MULTIPLICATIVE;
        case TokenType.STARSTAR:    return PREC_EXPONENTIATION;
        case TokenType.NULLISH:     return PREC_NULLISH;
        default:                    return PREC_NONE;
    }
}

/// Map a binary operator token type to the corresponding bytecode opcode.
fn Opcode token_to_binary_opcode(TokenType tt) {
    switch (tt) {
        case TokenType.PLUS:        return Opcode.ADD;
        case TokenType.MINUS:       return Opcode.SUB;
        case TokenType.STAR:        return Opcode.MUL;
        case TokenType.SLASH:       return Opcode.DIV;
        case TokenType.PERCENT:     return Opcode.MOD;
        case TokenType.STARSTAR:    return Opcode.EXP;
        case TokenType.BIT_AND:     return Opcode.BAND;
        case TokenType.BIT_OR:      return Opcode.BOR;
        case TokenType.BIT_XOR:     return Opcode.BXOR;
        case TokenType.SHL:         return Opcode.SHL;
        case TokenType.SHR:         return Opcode.SHR;
        case TokenType.USHR:        return Opcode.USHR;
        case TokenType.EQ:          return Opcode.EQ;
        case TokenType.NE:          return Opcode.NEQ;
        case TokenType.SEQ:         return Opcode.SEQ;
        case TokenType.SNE:         return Opcode.SNEQ;
        case TokenType.LT:          return Opcode.LT;
        case TokenType.LE:          return Opcode.LE;
        case TokenType.GT:          return Opcode.GT;
        case TokenType.GE:          return Opcode.GE;
        case TokenType.INSTANCEOF:  return Opcode.INSTANCEOF;
        case TokenType.IN:          return Opcode.IN;
        default:                    return Opcode.NOP;
    }
}

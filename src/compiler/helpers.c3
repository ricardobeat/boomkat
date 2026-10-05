module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import std::io;

// Compare two char slices for equality.
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

// Map a binary operator token type to the corresponding bytecode opcode.
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

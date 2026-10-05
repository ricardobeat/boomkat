module boomkat::compiler;

import boomkat::ast;
import boomkat::lexer;
import boomkat::types;
import boomkat::bytecode;

// Bound both recursion and repeated probes of overlapping subtrees. Failure
// leaves ordinary generation in charge, including all coercions and effects.
fn bool fold_number(ast::Ast* tree, uint n, uint* budget, TVal* result) {
    if (*budget == 0) return false;
    (*budget)--;
    NodeTag tag = tree.tags.data[n];
    if (tag == NodeTag.NUMBER) {
        result.set_number(bitcast(((ulong)tree.rhs.data[n] << 32) | (ulong)tree.lhs.data[n], double));
        return true;
    }
    if (tag != NodeTag.BINARY && tag != NodeTag.UNARY) return false;
    TokenType op = (TokenType)(tree.flags.data[n] & 0x7F);
    TVal left;
    if (!fold_number(tree, tree.lhs.data[n], budget, &left) || !left.is_number()) return false;
    double a = left.get_number();
    if (tag == NodeTag.UNARY) {
        switch (op) {
            case PLUS: result.set_number(a);
            case MINUS: result.set_number(-a);
            case LOG_NOT: result.set_boolean(a == 0.0 || a != a);
            default: return false;
        }
        return true;
    }
    TVal right;
    if (!fold_number(tree, tree.rhs.data[n], budget, &right) || !right.is_number()) return false;
    double b = right.get_number();
    // Keep the source tree's association and use the VM's double operations.
    switch (op) {
        case PLUS: result.set_number(a + b);
        case MINUS: result.set_number(a - b);
        case STAR: result.set_number(a * b);
        case SLASH: result.set_number(a / b);
        case PERCENT: result.set_number(a % b);
        case LT: result.set_boolean(a < b);
        case LE: result.set_boolean(a <= b);
        case GT: result.set_boolean(a > b);
        case GE: result.set_boolean(a >= b);
        case EQ:
        case SEQ: result.set_boolean(a == b);
        case NE:
        case SNE: result.set_boolean(a != b);
        default: return false;
    }
    return true;
}

fn Val CompilerContext.gen_number(&self, double value) {
    ushort reg = self.alloc_reg();
    // Bounds precede conversion; negative zero must remain a double constant.
    if (value >= bytecode::MIN_SBC && value <= bytecode::MAX_SBC
        && (double)(int)value == value && (value != 0.0 || 1.0 / value > 0.0)) {
        self.emit_a_sbx(Opcode.LDINT, (uint)reg, (int)value);
    } else {
        self.emit_a_bc(Opcode.LDCONST, (uint)reg, self.add_number_constant(value));
    }
    return { reg, false, 0 };
}

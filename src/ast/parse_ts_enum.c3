// TypeScript enums. An enum is a runtime object, so it is desugared into the
// shape TypeScript emits: a variable holding an object whose members are the
// enum's names. A numeric member is mapped back to its name as well, so that
// `E[E.A]` gives "A"; a string-valued member has no such mapping.
module boomkat::ast @feat(!NO_TYPESCRIPT);

import boomkat::lexer;
import boomkat::ast::vec;
import std::math;

// What an enum member's initialiser evaluates to when it is a constant
// expression. TypeScript folds those into the value it emits.
enum EnumConst : char {
    NONE,       // not a constant expression
    NUMBER,
    STRING,
}

// A parsed enum member: its name and the constant it stands for.
struct EnumMember {
    uint name;
    EnumConst kind;
    double num;
}

// `enum E { A, B = 1 << 2 }` and `const enum E { ... }`, desugared into the
// runtime object TypeScript emits. The current token is `enum` or `const`.
fn uint? Parser.ts_enum(&self, uint pos, uint* name) {
    if (self.tok.type == TokenType.CONST) self.next()!;
    self.next()!;
    if (self.tok.type != TokenType.IDENTIFIER) return self.fail("an enum name must be an identifier")~;
    *name = self.atom(self.tok.str_value);
    self.next()!;
    self.expect(TokenType.LBRACE)!;

    Vec{EnumMember} members;
    members.init(8);
    defer members.free();

    uint mark = self.scratch_mark();
    while (self.tok.type != TokenType.RBRACE) {
        if (self.tok.type == TokenType.EOF_TOKEN) return self.unexpected()~;
        uint member = self.ts_enum_member_name()!;
        uint init = 0;
        EnumConst kind = EnumConst.NONE;
        double num = 0;
        if (self.tok.type == TokenType.ASSIGN) {
            self.next()!;
            // An `as` assertion makes the initialiser a computed value, so it
            // is no longer folded into a constant.
            self.ts_asserted = false;
            init = self.assign_expr()!;
            if (!self.ts_asserted) kind = self.ts_enum_const(init, &members, &num);
        } else if (members.len == 0) {
            kind = EnumConst.NUMBER;
        } else if (members.data[members.len - 1].kind == EnumConst.NUMBER) {
            // A member without an initialiser counts up from the previous one.
            kind = EnumConst.NUMBER;
            num = members.data[members.len - 1].num + 1;
        }
        members.push({ .name = member, .kind = kind, .num = num });
        self.scratch_push(self.ts_enum_member_value(*name, member, init, kind, num, pos));
        if (self.tok.type != TokenType.COMMA) break;
        self.next()!;
    }
    self.expect(TokenType.RBRACE)!;
    // `return E;` hands the object back, so that the variable can hold it.
    self.scratch_push(self.node(NodeTag.RETURN, pos, self.node(NodeTag.IDENT, pos, *name)));
    uint body = self.node(NodeTag.BLOCK, pos, self.scratch_list(mark));
    return self.ts_object_var(*name, *name, body, pos);
}

// The name of an enum member: an identifier or a string literal. A reserved
// word is a name here too, as it is in TypeScript.
fn uint? Parser.ts_enum_member_name(&self) {
    if (is_name_token(self.tok.type)) {
        uint name = self.atom(self.tok.str_value);
        self.next(true)!;
        return name;
    }
    if (self.tok.type == TokenType.STRING && !self.tok.is_template) {
        uint name = self.atom(self.tok.str_value);
        self.next()!;
        return name;
    }
    return self.unexpected()~;
}

// The statement that gives an enum member its value: `E["A"] = 1` for a
// string-valued member, and `E[E["A"] = 1] = "A"` for a numeric one, which
// also maps the value back to the member's name.
fn uint Parser.ts_enum_member_value(&self, uint enum_name, uint member, uint init, EnumConst kind, double num, uint pos) {
    uint value;
    bool reverse = true;
    if (kind == EnumConst.NUMBER) {
        value = self.ts_number_node(num, pos);
    } else if (kind == EnumConst.STRING) {
        // A string value has no reverse mapping, and the initialiser already
        // holds the string.
        value = init;
        reverse = false;
    } else if (init != 0) {
        value = init;
    } else {
        value = self.ts_void_zero(pos);
    }
    uint inner = self.node(NodeTag.ASSIGN, pos,
        self.node(NodeTag.INDEX, pos, self.node(NodeTag.IDENT, pos, enum_name),
            self.node(NodeTag.STRING, pos, member)),
        value, op_flag(TokenType.ASSIGN));
    if (!reverse) return self.node(NodeTag.EXPR_STMT, pos, inner);
    uint outer = self.node(NodeTag.ASSIGN, pos,
        self.node(NodeTag.INDEX, pos, self.node(NodeTag.IDENT, pos, enum_name), inner),
        self.node(NodeTag.STRING, pos, member), op_flag(TokenType.ASSIGN));
    return self.node(NodeTag.EXPR_STMT, pos, outer);
}

// The constant an enum member's initialiser evaluates to, when it is a
// constant expression.
fn EnumConst Parser.ts_enum_const(&self, uint n, Vec{EnumMember}* members, double* num) {
    if (n == 0) return EnumConst.NONE;
    switch (self.ast.tags.data[n]) {
        case NodeTag.NUMBER:
            *num = bitcast(((ulong)self.ast.rhs.data[n] << 32) | (ulong)self.ast.lhs.data[n], double);
            return EnumConst.NUMBER;
        case NodeTag.STRING:
            return EnumConst.STRING;
        case NodeTag.TEMPLATE: {
            // A template whose substitutions are all constant is a string.
            uint list = self.ast.lhs.data[n];
            uint parts = self.ast.template_exprs(list);
            for (uint i = 0; i < parts; i++) {
                uint e = self.ast.template_expr(list, i);
                if (e == 0) continue;
                double sub;
                if (self.ts_enum_const(e, members, &sub) == EnumConst.NONE) return EnumConst.NONE;
            }
            return EnumConst.STRING;
        }
        case NodeTag.IDENT: {
            uint atom = self.ast.lhs.data[n];
            for (sz i = 0; i < members.len; i++) {
                if (members.data[i].name != atom) continue;
                if (members.data[i].kind != EnumConst.NUMBER) return EnumConst.NONE;
                *num = members.data[i].num;
                return EnumConst.NUMBER;
            }
            return EnumConst.NONE;
        }
        case NodeTag.UNARY: {
            TokenType op = (TokenType)(self.ast.flags.data[n] & 0x7F);
            double a;
            if (self.ts_enum_const(self.ast.lhs.data[n], members, &a) != EnumConst.NUMBER) return EnumConst.NONE;
            switch (op) {
                case TokenType.MINUS: *num = -a; return EnumConst.NUMBER;
                case TokenType.PLUS: *num = a; return EnumConst.NUMBER;
                case TokenType.BIT_NOT: *num = (double)(~(int)a); return EnumConst.NUMBER;
                default: return EnumConst.NONE;
            }
        }
        case NodeTag.BINARY: {
            TokenType op = (TokenType)(self.ast.flags.data[n] & 0x7F);
            double a;
            double b;
            EnumConst left = self.ts_enum_const(self.ast.lhs.data[n], members, &a);
            EnumConst right = self.ts_enum_const(self.ast.rhs.data[n], members, &b);
            // A `+` with a string operand is a string, whatever the other side.
            if (op == TokenType.PLUS && (left == EnumConst.STRING || right == EnumConst.STRING)) {
                return EnumConst.STRING;
            }
            if (left != EnumConst.NUMBER || right != EnumConst.NUMBER) return EnumConst.NONE;
            switch (op) {
                case TokenType.PLUS: *num = a + b; return EnumConst.NUMBER;
                case TokenType.MINUS: *num = a - b; return EnumConst.NUMBER;
                case TokenType.STAR: *num = a * b; return EnumConst.NUMBER;
                case TokenType.SLASH: *num = a / b; return EnumConst.NUMBER;
                case TokenType.PERCENT: *num = a % b; return EnumConst.NUMBER;
                case TokenType.STARSTAR: *num = math::pow(a, b); return EnumConst.NUMBER;
                case TokenType.SHL: *num = (double)((int)a << ((int)b & 31)); return EnumConst.NUMBER;
                case TokenType.SHR: *num = (double)((int)a >> ((int)b & 31)); return EnumConst.NUMBER;
                case TokenType.USHR: *num = (double)((uint)(int)a >> ((int)b & 31)); return EnumConst.NUMBER;
                case TokenType.BIT_AND: *num = (double)((int)a & (int)b); return EnumConst.NUMBER;
                case TokenType.BIT_OR: *num = (double)((int)a | (int)b); return EnumConst.NUMBER;
                case TokenType.BIT_XOR: *num = (double)((int)a ^ (int)b); return EnumConst.NUMBER;
                default: return EnumConst.NONE;
            }
        }
        default:
            return EnumConst.NONE;
    }
}

// A numeric literal node.
fn uint Parser.ts_number_node(&self, double d, uint pos) {
    ulong bits = bitcast(d, ulong);
    return self.node(NodeTag.NUMBER, pos, (uint)(bits & 0xFFFFFFFF), (uint)(bits >> 32));
}

// The `void 0` a member without a value stands for.
fn uint Parser.ts_void_zero(&self, uint pos) {
    return self.node(NodeTag.UNARY, pos, self.ts_number_node(0, pos), 0, op_flag(TokenType.VOID));
}

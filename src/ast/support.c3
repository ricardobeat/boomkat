// Which functions the AST code generator (plan 101, stage 7) compiles. A function is generated
// from the tree only when every node of its body is a construct the generator knows; anything
// else leaves the function to the fused compiler. The whitelist grows with the generator.
module boomkat::ast;

import std::io;
import boomkat::lexer;

// Whether `scope`, a function scope, is one the generator can compile as a whole.
fn bool AstIndex.gen_supported(&self, uint scope) {
    Scope* sc = &self.res.scopes.data[scope];
    self.reject_why = "";
    if (sc.kind != ScopeKind.FUNCTION) return self.reject("not a function");
    NodeTag t = self.tree.tags.data[sc.node];
    if (t != NodeTag.FUNC_DECL && t != NodeTag.FUNC_EXPR) return self.reject("not a function");
    uint rec = self.tree.rhs.data[sc.node];
    uint fnf = self.tree.field(rec, FN_FLAGS);
    const uint REJECT = FNF_ASYNC | FNF_GENERATOR | FNF_EXPR_BODY | FNF_METHOD | FNF_CTOR
        | FNF_STATIC_BLOCK | FNF_FIELD_INIT;
    if ((fnf & REJECT) != 0 || (fnf & FNF_SIMPLE_PARAMS) == 0) return self.reject("function shape");
    const ushort SCOPE_REJECT = SCOPE_ARROW | SCOPE_HAS_EVAL | SCOPE_CAPTURE_ALL | SCOPE_USES_ARGUMENTS
        | SCOPE_HAS_WITH | SCOPE_EVAL_PARAMS;
    if ((sc.flags & SCOPE_REJECT) != 0) return self.reject("scope flags");
    uint body = self.tree.field(rec, FN_BODY);
    return self.stmt_supported(body);
}

fn bool AstIndex.reject(&self, String why) {
    if (self.reject_why.len == 0) self.reject_why = why;
    return false;
}

fn bool AstIndex.reject_tag(&self, uint n) {
    if (self.reject_why.len == 0) self.reject_why = NodeTag::names[self.tree.tags.data[n].ordinal];
    return false;
}

fn bool AstIndex.list_supported(&self, uint list, bool stmts) {
    uint n = self.tree.list_len(list);
    for (uint i = 0; i < n; i++) {
        uint item = self.tree.list_item(list, i);
        if (!(stmts ? self.stmt_supported(item) : self.expr_supported(item))) return false;
    }
    return true;
}

fn bool AstIndex.stmt_supported(&self, uint n) {
    if (n == 0) return true;
    Ast* a = &self.tree;
    switch (a.tags.data[n]) {
        case BLOCK:
            return self.list_supported(a.lhs.data[n], true);
        case EMPTY_STMT:
        case DIRECTIVE:
            return true;
        case IF:
            uint rec = a.rhs.data[n];
            return self.expr_supported(a.lhs.data[n]) && self.stmt_supported(a.field(rec, 0))
                && self.stmt_supported(a.field(rec, 1));
        case WHILE:
            return self.expr_supported(a.lhs.data[n]) && self.stmt_supported(a.rhs.data[n]);
        case DO_WHILE:
            return self.stmt_supported(a.lhs.data[n]) && self.expr_supported(a.rhs.data[n]);
        case FOR:
            uint rec = a.lhs.data[n];
            uint init = a.field(rec, 0);
            bool init_ok = a.tags.data[init] == NodeTag.VAR_DECL ? self.stmt_supported(init) : self.expr_supported(init);
            return init_ok && self.expr_supported(a.field(rec, 1)) && self.expr_supported(a.field(rec, 2))
                && self.stmt_supported(a.field(rec, 3));
        case BREAK:
        case CONTINUE:
            return a.lhs.data[n] == 0 || self.reject_tag(n);
        case EXPR_STMT:
            return self.expr_supported(a.lhs.data[n]);
        case RETURN:
        case THROW:
            return self.expr_supported(a.lhs.data[n]);
        case VAR_DECL:
            if ((a.flags.data[n] & VAR_KIND_MASK) != VAR_KIND_VAR) return false;
            uint ds = a.lhs.data[n];
            for (uint i = 0; i < a.list_len(ds); i++) {
                uint d = a.list_item(ds, i);
                if (a.tags.data[a.lhs.data[d]] != NodeTag.IDENT) return false;
                if (!self.expr_supported(a.rhs.data[d])) return false;
            }
            return true;
        default:
            return self.reject_tag(n);
    }
}

fn bool AstIndex.expr_supported(&self, uint n) {
    if (n == 0) return true;
    Ast* a = &self.tree;
    switch (a.tags.data[n]) {
        case NUMBER:
        case STRING:
        case IDENT:
        case THIS:
        case NULL_LIT:
        case TRUE_LIT:
        case FALSE_LIT:
            return true;
        case BINARY:
        case LOGICAL:
            return self.expr_supported(a.lhs.data[n]) && self.expr_supported(a.rhs.data[n]);
        case COND:
            uint rec = a.rhs.data[n];
            return self.expr_supported(a.lhs.data[n]) && self.expr_supported(a.field(rec, 0))
                && self.expr_supported(a.field(rec, 1));
        case ASSIGN:
            TokenType op = (TokenType)(a.flags.data[n] & 0x7F);
            if (op == TokenType.LOG_AND_ASSIGN || op == TokenType.LOG_OR_ASSIGN || op == TokenType.NULLISH_ASSIGN) {
                return self.reject_tag(n);
            }
            return self.ident_target(a.lhs.data[n]) && self.expr_supported(a.rhs.data[n]);
        case UPDATE_PRE:
        case UPDATE_POST:
            return self.ident_target(a.lhs.data[n]);
        case UNARY:
            TokenType op = (TokenType)(a.flags.data[n] & 0x7F);
            if (op == TokenType.DELETE) return self.reject("delete");
            uint operand = a.lhs.data[n];
            if (op == TokenType.TYPEOF) {
                // A member operand takes the legacy path that reuses its object register.
                NodeTag ot = a.tags.data[operand];
                if (ot == NodeTag.MEMBER || ot == NodeTag.INDEX) return self.reject("typeof member");
            }
            return self.expr_supported(operand);
        case MEMBER:
        case INDEX:
        case CALL:
            return self.chain_supported(n);
        default:
            return self.reject_tag(n);
    }
}

fn bool AstIndex.ident_target(&self, uint n) {
    if (self.tree.tags.data[n] == NodeTag.IDENT) return true;
    return self.reject_tag(n);
}

// A chain of `.name`, `[key]` and `(args)` steps over a supported primary. Parenthesised links
// and optional steps are left to the fused compiler.
fn bool AstIndex.chain_supported(&self, uint n) {
    Ast* a = &self.tree;
    NodeTag t = a.tags.data[n];
    if ((a.flags.data[n] & (FLAG_PAREN | FLAG_OPTIONAL)) != 0) return self.reject_tag(n);
    switch (t) {
        case MEMBER:
        case INDEX:
        case CALL:
            uint obj = a.lhs.data[n];
            if (t == NodeTag.CALL) {
                if (a.tags.data[obj] == NodeTag.IDENT && self.tree.atoms.get(a.lhs.data[obj]) == "eval") {
                    return self.reject("direct eval");
                }
                if (!self.list_supported(a.rhs.data[n], false)) return false;
            } else if (t == NodeTag.INDEX && !self.expr_supported(a.rhs.data[n])) {
                return false;
            }
            NodeTag ot = a.tags.data[obj];
            if (ot == NodeTag.MEMBER || ot == NodeTag.INDEX || ot == NodeTag.CALL) return self.chain_supported(obj);
            if ((a.flags.data[obj] & FLAG_PAREN) != 0 || (t == NodeTag.CALL && ot != NodeTag.IDENT)) return self.reject_tag(obj);
            return self.expr_supported(obj);
        default:
            return self.reject_tag(n);
    }
}

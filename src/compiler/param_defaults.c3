module boomkat::compiler;

import boomkat::ast;
import boomkat::lexer;

// What a parameter default may reference when it is compiled into the
// prologue instead of a thunk.
struct ParamExprScope {
    ast::Resolver* res;
    uint func_scope;  // the function's own scope: its parameters and body declarations
    uint params;
    uint before;      // parameters declared ahead of the default
    bool allow_this;
}

// Whether the default `n` reads the same bindings inline as from a thunk. An
// earlier plain parameter is in a register. Any other name must resolve
// outside the function: the function's own scope holds its later parameters
// (still in their TDZ) and its body declarations, which a default cannot see.
// `eval` and `arguments` keep the thunk, as do function and class
// expressions, which would capture the prologue's scope.
fn bool inline_param_expr(ParamExprScope* ps, ast::Ast* tree, uint n, uint* budget) {
    if (*budget == 0) return false;
    (*budget)--;
    switch (tree.tags.data[n]) {
        case NUMBER:
        case STRING:
        case TRUE_LIT:
        case FALSE_LIT:
        case NULL_LIT:
            return true;
        case THIS:
            return ps.allow_this;
        case IDENT:
            uint atom = tree.lhs.data[n];
            for (uint i = 0; i < ps.before; i++) {
                uint p = tree.list_item(ps.params, i);
                if (tree.tags.data[p] == NodeTag.ASSIGN_PAT) p = tree.lhs.data[p];
                if (tree.lhs.data[p] == atom) return true;
            }
            if (atom == ps.res.atom_eval || atom == ps.res.atom_arguments) return false;
            return ps.res.lookup(ps.func_scope, atom) == 0;
        case UNARY:
            TokenType op = (TokenType)(tree.flags.data[n] & 0x7F);
            if (op != TokenType.PLUS && op != TokenType.MINUS
                && op != TokenType.LOG_NOT && op != TokenType.BIT_NOT) return false;
            return inline_param_expr(ps, tree, tree.lhs.data[n], budget);
        case BINARY:
        case LOGICAL:
        case INDEX:
            return inline_param_expr(ps, tree, tree.lhs.data[n], budget)
                && inline_param_expr(ps, tree, tree.rhs.data[n], budget);
        case MEMBER:
        case OPT_CHAIN:
            return inline_param_expr(ps, tree, tree.lhs.data[n], budget);
        case CALL:
        case NEW:
            if (!inline_param_expr(ps, tree, tree.lhs.data[n], budget)) return false;
            uint args = tree.rhs.data[n];
            uint argc = tree.list_len(args);
            for (uint i = 0; i < argc; i++) {
                if (!inline_param_expr(ps, tree, tree.list_item(args, i), budget)) return false;
            }
            return true;
        default: break;
    }
    return false;
}

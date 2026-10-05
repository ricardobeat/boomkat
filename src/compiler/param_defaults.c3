module boomkat::compiler;

import boomkat::ast;
import boomkat::lexer;

// Only earlier plain parameters are visible through registers. Other names
// need the parameter environment's TDZ and outer-scope lookup rules.
fn bool inline_param_expr(ast::Ast* tree, uint n, uint params, uint before, uint* budget) {
    if (*budget == 0) return false;
    (*budget)--;
    switch (tree.tags.data[n]) {
        case NUMBER:
        case STRING:
        case TRUE_LIT:
        case FALSE_LIT:
        case NULL_LIT:
            return true;
        case IDENT:
            for (uint i = 0; i < before; i++) {
                if (*budget == 0) return false;
                (*budget)--;
                uint p = tree.list_item(params, i);
                if (tree.tags.data[p] == NodeTag.ASSIGN_PAT) p = tree.lhs.data[p];
                if (tree.lhs.data[p] == tree.lhs.data[n]) return true;
            }
        case UNARY:
            TokenType op = (TokenType)(tree.flags.data[n] & 0x7F);
            if (op != TokenType.PLUS && op != TokenType.MINUS
                && op != TokenType.LOG_NOT && op != TokenType.BIT_NOT) return false;
            return inline_param_expr(tree, tree.lhs.data[n], params, before, budget);
        case BINARY:
            return inline_param_expr(tree, tree.lhs.data[n], params, before, budget)
                && inline_param_expr(tree, tree.rhs.data[n], params, before, budget);
        default: break;
    }
    return false;
}

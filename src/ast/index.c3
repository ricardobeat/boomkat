module boomkat::ast;

import boomkat::lexer;

struct AstIndex {
    Ast tree;
    Parser parser;
    Lexer lexer;
    Resolver res;
    AstIndex* prev;
    bool built;
    bool use;
}

tlocal AstIndex* index_state;

fn AstIndex* index_begin(char[] source, void* heap, ParseOptions opts) {
    AstIndex* c = mem::new(AstIndex);
    c.prev = index_state;
    index_state = c;
    c.lexer = lexer::lexer_init(source, heap);
    c.tree.init(source);
    uint? root = parse_program(&c.parser, &c.tree, &c.lexer, opts);
    if (catch root) return c;
    c.res.init(&c.tree);
    c.res.run(root);
    c.built = true;
    if (c.res.failed) {
        c.parser.fail_at(c.res.err_pos, "code nested too deeply");
        return c;
    }
    c.use = true;
    Early early;
    early.init(&c.tree);
    defer early.free();
    if (!early.run(root, opts) || !early.conflicts(&c.res)) {
        c.parser.fail_at(early.err_pos, early.error_message());
        c.use = false;
    }
    c.parser.destroy();
    c.res.refs.free();
    c.res.annexb.free();
    c.tree.atoms.slots.free();
    return c;
}

fn void index_end(AstIndex* c) {
    index_state = c.prev;
    if (c.built) {
        c.res.free();
    }
    c.parser.destroy();
    c.tree.free();
    c.lexer.free_arena();
    mem::free(c);
}

fn bool AstIndex.is_register_capture(&self, Binding* b) {
    if (!b.captured) return false;
    ScopeKind dk = self.res.scopes.data[b.scope].kind;
    if (dk == ScopeKind.GLOBAL || dk == ScopeKind.MODULE) return false;
    return b.kind != DeclKind.CLASS_INNER && b.kind != DeclKind.FN_NAME;
}

fn uint AstIndex.function_scope(&self, uint n) {
    uint rec = self.tree.rhs.data[n];
    uint body = self.tree.field(rec, FN_BODY);
    uint inner = (self.tree.field(rec, FN_FLAGS) & FNF_EXPR_BODY) != 0
        ? self.tree.field(rec, FN_BODY_START) : self.tree.main_tok.data[body] + 1;
    uint scope = self.res.scope_at(inner);
    return scope != 0 && self.res.scopes.data[scope].node == n ? scope : 0;
}

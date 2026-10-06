module boomkat::ast;

import boomkat::lexer;
import boomkat::ast::vec;
import boomkat::bytecode;

struct ScalarClass {
    uint class_node;
    uint getter_member;
    uint getter_expr;
    uint field_count;
    uint[4] field_names;
    uint[4] field_args;
    void* constructor;
    void* getter;
    Vec{void*} guards;
}

struct AstIndex {
    Ast tree;
    Parser parser;
    Lexer lexer;
    Resolver res;
    AstIndex* prev;
    bool built;
    bool use;
    bool scalar_classes_known;
    Vec{ScalarClass} scalar_classes;
    // The unit's shared source text, copied on the first function that retains a slice.
    bytecode::SourceBuf* src_buf;
}

tlocal AstIndex* index_state;

fn AstIndex* index_begin(char[] source, void* heap, ParseOptions opts, void* source_buf = null) {
    AstIndex* c = mem::new(AstIndex);
    if (source_buf != null) {
        c.src_buf = (bytecode::SourceBuf*)source_buf;
        c.src_buf.refs++;
    }
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
    bytecode::source_buf_release(c.src_buf);
    if (c.built) {
        c.res.free();
    }
    c.parser.destroy();
    c.tree.free();
    c.lexer.free_arena();
    foreach (&candidate : c.scalar_classes.data[:c.scalar_classes.len]) candidate.guards.free();
    c.scalar_classes.free();
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

// The unit's shared source text with one reference added for the caller, or null if it cannot be allocated.
fn bytecode::SourceBuf* AstIndex.share_source(&self, char[] text) {
    if (self.src_buf == null) self.src_buf = bytecode::source_buf_new(text);
    if (self.src_buf != null) self.src_buf.refs++;
    return self.src_buf;
}

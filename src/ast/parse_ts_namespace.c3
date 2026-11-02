// TypeScript namespaces. A namespace is a runtime object, so it is desugared
// into the shape TypeScript emits: a variable holding an object whose members
// are the namespace's exports.
module boomkat::ast @feat(!NO_TYPESCRIPT);

import boomkat::lexer;

// Whether a `namespace` or `module` here starts a namespace with a name,
// rather than an ambient module declaration.
fn bool Parser.ts_namespace_ahead(&self) {
    if (!self.lex.ts_mode) return false;
    if (!self.at_word("namespace") && !self.at_word("module")) return false;
    if (self.at_word("namespace")) return true;
    // `module "name" { }` is an ambient module declaration.
    Token first = self.tok;
    bool named = false;
    if (catch err_a = self.next()) return false;
    named = self.tok.type == TokenType.IDENTIFIER;
    self.lex.seek_to_token(first);
    self.has_peek = false;
    self.peek_failed = false;
    self.tok = first;
    self.prev = first;
    if (catch err_c = self.next()) return false;
    return named;
}

// `namespace N { ... }` and `export namespace N { ... }`, desugared into the
// runtime object TypeScript emits. The current token is `namespace`.
fn uint? Parser.ts_namespace(&self, uint pos, uint* name) {
    self.next()!;
    // A dotted name is a namespace inside a namespace.
    uint[16] parts;
    uint count = 0;
    while (true) {
        if (self.tok.type != TokenType.IDENTIFIER) return self.fail("a namespace name must be an identifier")~;
        if (count >= 16) return self.fail("a namespace name may not have this many parts")~;
        parts[count] = self.atom(self.tok.str_value);
        count++;
        self.next()!;
        if (!(self.eat(TokenType.DOT)!)) break;
    }
    self.expect(TokenType.LBRACE)!;
    uint body = self.node(NodeTag.BLOCK, pos, self.ts_namespace_body(parts[count - 1], pos)!);
    self.expect(TokenType.RBRACE)!;

    // The inner namespaces come first: each one is declared in the namespace
    // that holds it and put on that namespace's object.
    uint decl = self.ts_object_var(parts[count - 1], body, pos);
    for (uint i = count - 1; i > 0; i--) {
        uint inner = self.ts_namespace_assign(pos, parts[i]);
        uint mark = self.scratch_mark();
        self.scratch_push(decl);
        self.scratch_push(inner);
        uint outer_body = self.node(NodeTag.BLOCK, pos, self.scratch_list(mark));
        decl = self.ts_object_var(parts[i - 1], outer_body, pos);
    }
    *name = parts[0];
    return decl;
}

// The body of a namespace: its statements, with every exported member also
// put on the namespace object.
fn uint? Parser.ts_namespace_body(&self, uint name, uint pos) {
    uint saved = self.ns_name;
    self.ns_name = name;
    defer self.ns_name = saved;
    uint mark = self.scratch_mark();
    while (self.tok.type != TokenType.RBRACE) {
        if (self.tok.type == TokenType.EOF_TOKEN) return self.unexpected()~;
        self.ts_namespace_statement()!;
    }
    // `return N;` hands the object back, so that the variable can hold it.
    self.scratch_push(self.node(NodeTag.RETURN, pos, self.node(NodeTag.IDENT, pos, name)));
    return self.scratch_list(mark);
}

// A statement of a namespace body. An exported member is followed by the
// assignment that puts it on the namespace object.
fn void? Parser.ts_namespace_statement(&self) {
    uint pos = self.tok.pos;
    bool exported = false;
    if (self.tok.type == TokenType.EXPORT) {
        Token? pk = self.peek();
        if (catch err = pk) return err~;
        if (pk.type == TokenType.LBRACE) return self.fail("export declarations are not permitted in a namespace")~;
        self.next()!;
        exported = true;
    }
    if (self.tok.type == TokenType.ENUM) {
        uint name;
        uint decl = self.ts_enum(pos, &name)!;
        self.scratch_push(decl);
        if (exported) self.scratch_push(self.ts_namespace_assign(pos, name));
        return;
    }
    if (self.at_word("namespace") || self.at_word("module")) {
        uint name;
        uint decl = self.ts_namespace(pos, &name)!;
        self.scratch_push(decl);
        if (exported) self.scratch_push(self.ts_namespace_assign(pos, name));
        return;
    }
    if (self.ts_import_equals_ahead()) {
        uint decl = self.ts_import_equals(pos)!;
        self.scratch_push(decl);
        if (exported) self.ts_namespace_exports(decl);
        return;
    }
    uint decl = self.statement_list_item_in_block()!;
    self.scratch_push(decl);
    if (exported) self.ts_namespace_exports(decl);
}

// The assignments that put a namespace member on the namespace object.
fn void Parser.ts_namespace_exports(&self, uint decl) {
    switch (self.ast.tags.data[decl]) {
        case NodeTag.VAR_DECL: {
            uint list = self.ast.lhs.data[decl];
            for (uint i = 0; i < self.ast.list_len(list); i++) {
                uint target = self.ast.lhs.data[self.ast.list_item(list, i)];
                if (self.ast.tags.data[target] != NodeTag.IDENT) continue;
                self.scratch_push(self.ts_namespace_assign(self.ast.main_tok.data[decl], self.ast.lhs.data[target]));
            }
        }
        case NodeTag.FUNC_DECL:
        case NodeTag.CLASS_DECL: {
            uint ident = self.ast.lhs.data[decl];
            if (ident != 0) {
                self.scratch_push(self.ts_namespace_assign(self.ast.main_tok.data[decl], self.ast.lhs.data[ident]));
            }
        }
        default:
    }
}

// The assignment that puts a namespace member on the namespace object:
// `N.x = x;`.
fn uint Parser.ts_namespace_assign(&self, uint pos, uint name) {
    uint member = self.node(NodeTag.MEMBER, pos, self.node(NodeTag.IDENT, pos, self.ns_name), name);
    uint value = self.node(NodeTag.IDENT, pos, name);
    uint assign = self.node(NodeTag.ASSIGN, pos, member, value, op_flag(TokenType.ASSIGN));
    return self.node(NodeTag.EXPR_STMT, pos, assign);
}

// Whether an `import` here is an import alias, `import X = A.B;`, rather than
// an ECMAScript import.
fn bool Parser.ts_import_equals_ahead(&self) {
    if (!self.lex.ts_mode) return false;
    if (self.tok.type != TokenType.IMPORT) return false;
    Token first = self.tok;
    bool found = false;
    if (catch err_a = self.next()) return false;
    if (catch err_b = self.next()) return false;
    found = self.tok.type == TokenType.ASSIGN;
    self.lex.seek_to_token(first);
    self.has_peek = false;
    self.peek_failed = false;
    self.tok = first;
    self.prev = first;
    if (catch err_c = self.next()) return false;
    return found;
}

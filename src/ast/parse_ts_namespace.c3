// TypeScript namespaces. A namespace is a runtime object, so it is desugared
// into the shape TypeScript emits: a variable holding an object whose members
// are the namespace's exports.
module boomkat::ast @feat(!NO_TYPESCRIPT);

import boomkat::lexer;

// Whether a `namespace` or `module` here starts a namespace with a name,
// rather than an identifier or an ambient module declaration.
fn bool Parser.ts_namespace_ahead(&self) {
    if (!self.lex.ts_mode) return false;
    if (!self.at_word("namespace") && !self.at_word("module")) return false;
    // The name of a namespace stands on the same line as the keyword: a
    // `namespace` on a line of its own is an identifier, and the line break
    // ends the statement.
    Token first = self.tok;
    bool named = false;
    if (catch err_a = self.next()) return false;
    named = self.tok.type == TokenType.IDENTIFIER && !self.tok.nl_before;
    self.lex.seek_to_token(first);
    self.has_peek = false;
    self.peek_failed = false;
    self.tok = first;
    self.prev = first;
    if (catch err_c = self.next()) return false;
    return named;
}

// Whether an ambient module declaration, `module "name" { ... }`, starts here.
fn bool Parser.ts_ambient_module_ahead(&self) {
    if (!self.lex.ts_mode) return false;
    if (!self.at_word("module")) return false;
    Token first = self.tok;
    bool ambient = false;
    if (catch err_a = self.next()) return false;
    ambient = self.tok.type == TokenType.STRING && !self.tok.nl_before;
    self.lex.seek_to_token(first);
    self.has_peek = false;
    self.peek_failed = false;
    self.tok = first;
    self.prev = first;
    if (catch err_c = self.next()) return false;
    return ambient;
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
    // A namespace that shares its name with a class or a function merges with
    // it: it fills that binding instead of declaring a variable of its own.
    bool merged = self.ts_merged_name(parts[0]);
    self.expect(TokenType.LBRACE)!;
    uint param;
    uint body = self.node(NodeTag.BLOCK, pos, self.ts_namespace_body(parts[count - 1], pos, &param)!);
    self.expect(TokenType.RBRACE)!;

    // The inner namespaces come first: each one is declared in the namespace
    // that holds it and put on that namespace's object.
    uint decl = self.ts_object_var(parts[count - 1], param, body, pos);
    for (uint i = count - 1; i > 0; i--) {
        uint saved = self.ns_name;
        self.ns_name = parts[i - 1];
        uint inner = self.ts_namespace_assign(pos, parts[i]);
        self.ns_name = saved;
        uint outer_param = parts[i - 1];
        uint outer_body = self.node(NodeTag.BLOCK, pos, self.ast.add_list(
            { decl, inner, self.node(NodeTag.RETURN, pos, self.node(NodeTag.IDENT, pos, outer_param)) }));
        if (i == 1 && merged) {
            // The outermost namespace fills the binding the class or the
            // function of that name made.
            *name = parts[0];
            return self.ts_object_merge(parts[0], outer_param, outer_body, pos);
        }
        decl = self.ts_object_var(parts[i - 1], outer_param, outer_body, pos);
    }
    *name = parts[0];
    if (merged) return self.ts_object_merge(parts[0], param, body, pos);
    return decl;
}

// The body of a namespace: its statements, with every exported member also
// put on the namespace object. The namespace's parameter takes a name of its
// own, so that a declaration in the body does not redeclare it.
fn uint? Parser.ts_namespace_body(&self, uint name, uint pos, uint* param) {
    uint saved = self.ns_name;
    *param = self.ts_ns_param(name);
    self.ns_name = *param;
    defer self.ns_name = saved;
    uint mark = self.scratch_mark();
    uint scope = self.ts_scope_push();
    while (self.tok.type != TokenType.RBRACE) {
        if (self.tok.type == TokenType.EOF_TOKEN) return self.unexpected()~;
        self.ts_namespace_statement()!;
    }
    // `return N;` hands the object back, so that the variable can hold it.
    self.scratch_push(self.node(NodeTag.RETURN, pos, self.node(NodeTag.IDENT, pos, *param)));
    self.ts_scope_pop(scope);
    return self.scratch_list(mark);
}

// The name the parameter of a namespace takes. The IIFE's parameter would be
// redeclared by a class or a function of the same name in the body, so it
// takes a name no source text spells. The name lives in the lexer's string
// arena: atom entries point into it for the rest of the compilation.
fn uint Parser.ts_ns_param(&self, uint name) {
    char[128] buf;
    String text = (String)self.ast.atoms.get(name);
    usz len = 0;
    if (len + 1 < buf.len) buf[len++] = ' ';
    for (usz i = 0; i < text.len && len + 1 < buf.len; i++) buf[len++] = text[i];
    char[] stable = self.lex.arena_dup(&buf[0], len);
    return self.atom(stable);
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
    if (self.ts_namespace_ahead()) {
        uint name;
        uint decl = self.ts_namespace(pos, &name)!;
        self.scratch_push(decl);
        if (exported) self.scratch_push(self.ts_namespace_assign(pos, name));
        return;
    }
    if (self.ts_import_equals_ahead()) {
        self.next()!;
        uint decl = self.ts_import_equals(pos)!;
        self.scratch_push(decl);
        if (exported) self.ts_namespace_exports(decl);
        return;
    }
    uint decl = self.statement_list_item_in_block()!;
    self.scratch_push(decl);
    self.ts_record_decl(decl);
    if (exported) self.ts_namespace_exports(decl);
}

// The assignments that put a namespace member on the namespace object.
fn void Parser.ts_namespace_exports(&self, uint decl) {
    switch (self.ast.tags.data[decl]) {
        case NodeTag.VAR_DECL: {
            uint list = self.ast.lhs.data[decl];
            bool mutable = (self.ast.flags.data[decl] & VAR_KIND_MASK) != VAR_KIND_CONST;
            for (uint i = 0; i < self.ast.list_len(list); i++) {
                uint target = self.ast.lhs.data[self.ast.list_item(list, i)];
                if (self.ast.tags.data[target] != NodeTag.IDENT) continue;
                uint pos = self.ast.main_tok.data[decl];
                uint name = self.ast.lhs.data[target];
                // A variable that can change stays the member: TypeScript
                // reads and writes the member wherever the namespace names it.
                if (mutable) {
                    self.scratch_push(self.ts_namespace_live(pos, name));
                } else {
                    self.scratch_push(self.ts_namespace_assign(pos, name));
                }
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

// The accessor that keeps an exported variable and its namespace member the
// same: `Object.defineProperty(N, "x", { get: function () { return x; },
// set: function (v) { x = v; }, enumerable: true, configurable: true })`.
// TypeScript instead turns each reference to the variable into the member;
// the accessor gives the same values without rewriting the references.
fn uint Parser.ts_namespace_live(&self, uint pos, uint name) {
    uint get_body = self.node(NodeTag.BLOCK, pos, self.ast.add_list({
        self.node(NodeTag.RETURN, pos, self.node(NodeTag.IDENT, pos, name)) }));
    uint getter = self.ts_function(self.ast.add_list({}), get_body, pos);
    // The value's parameter takes a name no source text spells, so that it
    // does not shadow the variable.
    uint value = self.ts_ns_param(name);
    uint set_body = self.node(NodeTag.BLOCK, pos, self.ast.add_list({
        self.node(NodeTag.EXPR_STMT, pos, self.node(NodeTag.ASSIGN, pos,
            self.node(NodeTag.IDENT, pos, name), self.node(NodeTag.IDENT, pos, value),
            op_flag(TokenType.ASSIGN))) }));
    uint setter = self.ts_function(self.ast.add_list({ self.node(NodeTag.IDENT, pos, value) }), set_body, pos);
    uint descriptor = self.node(NodeTag.OBJECT, pos, self.ast.add_list({
        self.ts_prop(pos, "get", getter),
        self.ts_prop(pos, "set", setter),
        self.ts_prop(pos, "enumerable", self.node(NodeTag.TRUE_LIT, pos)),
        self.ts_prop(pos, "configurable", self.node(NodeTag.TRUE_LIT, pos)) }));
    uint define = self.node(NodeTag.MEMBER, pos,
        self.node(NodeTag.IDENT, pos, self.atom("Object")), self.atom("defineProperty"));
    uint call = self.node(NodeTag.CALL, pos, define, self.ast.add_list({
        self.node(NodeTag.IDENT, pos, self.ns_name), self.node(NodeTag.STRING, pos, name), descriptor }));
    return self.node(NodeTag.EXPR_STMT, pos, call);
}

// An object literal's `key: value` property.
fn uint Parser.ts_prop(&self, uint pos, String key, uint value) {
    return self.node(NodeTag.PROP_INIT, pos, self.node(NodeTag.STRING, pos, self.atom(key)), value);
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

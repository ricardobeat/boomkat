// import and export declarations.
module boomkat::ast;

import boomkat::lexer;

// The module request after `from`: a string literal and an optional `with { key: "value" }` clause.
// Returns the request record.
fn uint? Parser.module_request(&self) {
    if (self.tok.type != TokenType.STRING || self.tok.is_template) return self.unexpected()~;
    uint src = self.atom(self.tok.str_value);
    self.next()!;
    uint attrs = 0;
    if (self.tok.type == TokenType.WITH) {
        self.next()!;
        self.expect(TokenType.LBRACE)!;
        uint mark = self.scratch_mark();
        while (self.tok.type != TokenType.RBRACE) {
            uint key;
            if (self.tok.type == TokenType.STRING && !self.tok.is_template) {
                key = self.atom(self.tok.str_value);
                self.next()!;
            } else if (is_name_token(self.tok.type)) {
                key = self.atom(self.tok.str_value);
                self.next(true)!;
            } else {
                return self.unexpected()~;
            }
            for (uint i = mark; i < (uint)self.scratch.len; i += 2) {
                if (self.scratch.data[i] == key) return self.fail("duplicate import attribute key")~;
            }
            self.expect(TokenType.COLON)!;
            if (self.tok.type != TokenType.STRING || self.tok.is_template) {
                return self.fail("import attribute value must be a string literal")~;
            }
            self.scratch_push(key);
            self.scratch_push(self.atom(self.tok.str_value));
            self.next()!;
            if (self.tok.type != TokenType.COMMA) break;
            self.next()!;
        }
        self.expect(TokenType.RBRACE)!;
        attrs = self.scratch_list(mark);
    }
    uint rec = self.ast.add_record(REQ_SIZE);
    self.ast.set_field(rec, REQ_SOURCE, src);
    self.ast.set_field(rec, REQ_ATTRS, attrs);
    return rec;
}

fn void? Parser.expect_word(&self, String word) {
    if (!self.at_word(word)) return self.unexpected()~;
    self.next()!;
}

// A ModuleExportName: an IdentifierName or a string literal.
fn uint? Parser.module_export_name(&self) {
    if (self.tok.type == TokenType.STRING && !self.tok.is_template) {
        uint a = self.atom(self.tok.str_value);
        self.next()!;
        return a;
    }
    if (!is_name_token(self.tok.type)) return self.unexpected()~;
    uint a = self.atom(self.tok.str_value);
    self.next(true)!;
    return a;
}

fn uint? Parser.binding_ident(&self) {
    if (!self.is_ident_token(self.tok)) return self.unexpected()~;
    Token t = self.tok;
    self.next()!;
    return self.ident_node(t);
}

fn uint? Parser.import_decl(&self) {
    uint pos = self.tok.pos;
    self.next()!;
    uint mark = self.scratch_mark();
    bool erased_specs = false;
    if (self.tok.type == TokenType.STRING && !self.tok.is_template) {
        uint req = self.module_request()!;
        self.semicolon()!;
        return self.node(NodeTag.IMPORT_DECL, pos, req, self.ast.add_list({}));
    }
    char phase = 0;
    if (self.at_word("defer") && self.peek_type() == TokenType.STAR) {
        phase = IMPORT_PHASE_DEFER;
        self.next()!;
    } else if (self.at_word("source")) {
        Token first = self.tok;
        Token? pk = self.peek();
        if (catch err = pk) return err~;
        if (self.is_ident_token(pk)) {
            self.next()!;
            if (self.at_word("from") && self.peek_type() == TokenType.STRING) {
                // `import source from "m"` imports the default export as `source`.
                uint local = self.ident_node(first);
                self.scratch_push(self.node(NodeTag.IMPORT_SPEC, first.pos, self.atom("default"), local));
                self.next()!;
                uint stmt = self.import_finish(pos, mark, 0)!;
    return erased_specs && self.ast.list_len(self.ast.rhs.data[stmt]) == 0
        ? self.node(NodeTag.EMPTY_STMT, pos) : stmt;
            }
            phase = IMPORT_PHASE_SOURCE;
        }
    }
    if (phase == IMPORT_PHASE_SOURCE) {
        uint spos = self.tok.pos;
        uint local = self.binding_ident()!;
        self.scratch_push(self.node(NodeTag.IMPORT_SPEC, spos, self.atom("default"), local));
        self.expect_word("from")!;
        return self.import_finish(pos, mark, phase);
    }
    if (phase == IMPORT_PHASE_DEFER) {
        uint spos = self.tok.pos;
        self.expect(TokenType.STAR)!;
        self.expect_word("as")!;
        uint local = self.binding_ident()!;
        self.scratch_push(self.node(NodeTag.IMPORT_SPEC, spos, self.atom("*"), local, IMPORT_NAMESPACE));
        self.expect_word("from")!;
        return self.import_finish(pos, mark, phase);
    }
    if (self.is_ident_token(self.tok)) {
        if (self.lex.ts_mode && self.peek_type() == TokenType.ASSIGN) return self.ts_import_equals(pos);
        uint spos = self.tok.pos;
        uint local = self.binding_ident()!;
        self.scratch_push(self.node(NodeTag.IMPORT_SPEC, spos, self.atom("default"), local));
        if (self.tok.type == TokenType.COMMA) {
            self.next()!;
            if (self.tok.type != TokenType.STAR && self.tok.type != TokenType.LBRACE) return self.unexpected()~;
        } else {
            self.expect_word("from")!;
            uint stmt = self.import_finish(pos, mark, 0)!;
    return erased_specs && self.ast.list_len(self.ast.rhs.data[stmt]) == 0
        ? self.node(NodeTag.EMPTY_STMT, pos) : stmt;
        }
    }
    if (self.tok.type == TokenType.STAR) {
        uint spos = self.tok.pos;
        self.next()!;
        self.expect_word("as")!;
        uint local = self.binding_ident()!;
        self.scratch_push(self.node(NodeTag.IMPORT_SPEC, spos, self.atom("*"), local, IMPORT_NAMESPACE));
    } else if (self.tok.type == TokenType.LBRACE) {
        self.next()!;
        while (self.tok.type != TokenType.RBRACE) {
            uint spos = self.tok.pos;
            bool erased = self.ts_type_specifier();
            erased_specs |= erased;
            if (erased) self.next()!;
            Token name_tok = self.tok;
            uint imported = self.module_export_name()!;
            uint local;
            if (self.at_word("as")) {
                self.next()!;
                local = self.binding_ident()!;
            } else {
                // `import {a}` binds `a`, so the name must be a valid binding identifier.
                if (name_tok.type == TokenType.STRING || !self.is_ident_token(name_tok)) {
                    return self.fail_at(name_tok.pos, "invalid import binding")~;
                }
                local = self.ident_node(name_tok);
            }
            if (!erased) self.scratch_push(self.node(NodeTag.IMPORT_SPEC, spos, imported, local));
            if (self.tok.type != TokenType.COMMA) break;
            self.next()!;
        }
        self.expect(TokenType.RBRACE)!;
    } else {
        return self.unexpected()~;
    }
    self.expect_word("from")!;
    uint stmt = self.import_finish(pos, mark, 0)!;
    return erased_specs && self.ast.list_len(self.ast.rhs.data[stmt]) == 0
        ? self.node(NodeTag.EMPTY_STMT, pos) : stmt;
}

// TS `import X = A.B` compiles to the `const X = A.B` that tsc emits.
fn uint? Parser.ts_import_equals(&self, uint pos) {
    uint mark = self.scratch_mark();
    uint target = self.binding_ident()!;
    self.expect(TokenType.ASSIGN)!;
    uint init = self.assign_expr()!;
    self.scratch_push(self.node(NodeTag.DECLARATOR, self.ast.main_tok.data[target], target, init));
    self.semicolon()!;
    return self.node(NodeTag.VAR_DECL, pos, self.scratch_list(mark), 0, VAR_KIND_CONST);
}

fn uint? Parser.import_finish(&self, uint pos, uint mark, char phase) {
    uint req = self.module_request()!;
    self.semicolon()!;
    return self.node(NodeTag.IMPORT_DECL, pos, req, self.scratch_list(mark), phase);
}

fn uint? Parser.export_decl(&self) {
    uint pos = self.tok.pos;
    self.next()!;
    if (self.lex.ts_mode && self.at_word("abstract") && self.peek_type() == TokenType.CLASS) self.next()!;
    switch (self.tok.type) {
        case TokenType.STAR:
            self.next()!;
            uint name = 0;
            if (self.at_word("as")) {
                self.next()!;
                name = self.module_export_name()!;
            }
            self.expect_word("from")!;
            uint req = self.module_request()!;
            self.semicolon()!;
            return self.node(NodeTag.EXPORT_ALL, pos, req, name);
        case TokenType.LBRACE:
            return self.export_named(pos);
        case TokenType.DEFAULT:
            return self.export_default(pos);
        case TokenType.VAR:
            return self.export_wrap(pos, self.var_statement(VAR_KIND_VAR)!);
        case TokenType.CONST:
            return self.export_wrap(pos, self.var_statement(VAR_KIND_CONST)!);
        case TokenType.LET:
            return self.export_wrap(pos, self.var_statement(VAR_KIND_LET)!);
        case TokenType.FUNCTION:
            return self.export_wrap(pos, self.function_decl(self.tok.pos, false)!);
        case TokenType.CLASS:
            return self.export_wrap(pos, self.class_decl()!);
        case TokenType.IDENTIFIER:
            if (self.at_word("async") && self.peek_type() == TokenType.FUNCTION) {
                uint start = self.tok.pos;
                self.next()!;
                return self.export_wrap(pos, self.function_decl(start, true)!);
            }
        default:
    }
    return self.unexpected()~;
}

fn uint Parser.export_wrap(&self, uint pos, uint decl) {
    return self.node(NodeTag.EXPORT_DECL, pos, decl);
}

// `export { a, b as c }` with an optional `from "m"`. Without `from`, each local name must be an
// identifier reference; the resolver checks that it is bound.
fn uint? Parser.export_named(&self, uint pos) {
    self.next()!;
    uint mark = self.scratch_mark();
    bool local_ok = true;
    while (self.tok.type != TokenType.RBRACE) {
        uint spos = self.tok.pos;
        bool erased = self.ts_type_specifier();
        if (erased) self.next()!;
        Token name_tok = self.tok;
        if (name_tok.type == TokenType.STRING) local_ok = false;
        uint local = self.module_export_name()!;
        uint exported = local;
        if (self.at_word("as")) {
            self.next()!;
            exported = self.module_export_name()!;
        }
        if (name_tok.type != TokenType.STRING && !self.is_ident_token(name_tok)) local_ok = false;
        if (!erased) self.scratch_push(self.node(NodeTag.EXPORT_SPEC, spos, local, exported));
        if (self.tok.type != TokenType.COMMA) break;
        self.next()!;
    }
    self.expect(TokenType.RBRACE)!;
    uint list = self.scratch_list(mark);
    uint src = 0;
    if (self.at_word("from")) {
        self.next()!;
        src = self.module_request()!;
    } else if (!local_ok) {
        return self.fail_at(pos, "invalid export specifier")~;
    }
    self.semicolon()!;
    return self.node(NodeTag.EXPORT_NAMED, pos, list, src);
}

fn uint? Parser.export_default(&self, uint pos) {
    self.next()!;
    uint inner;
    char flags = 0;
    if (self.lex.ts_mode && self.at_word("abstract") && self.peek_type() == TokenType.CLASS) self.next()!;
    Token t = self.tok;
    if (t.type == TokenType.FUNCTION) {
        inner = self.function_named(t.pos, false, true, true)!;
    } else if (t.type == TokenType.CLASS) {
        inner = self.class_decl(true)!;
    } else if (self.is_word(t, "async") && self.peek_type() == TokenType.FUNCTION) {
        Token? pk = self.peek();
        if (catch err = pk) return PARSE_ERROR~;
        if (pk.nl_before) {
            inner = self.assign_expr()!;
            flags = EXPORT_DEFAULT_EXPR;
            self.semicolon()!;
        } else {
            self.next()!;
            inner = self.function_named(t.pos, true, true, true)!;
        }
    } else {
        inner = self.assign_expr()!;
        flags = EXPORT_DEFAULT_EXPR;
        self.semicolon()!;
    }
    if (self.ast.tags.data[inner] == NodeTag.EMPTY_STMT) return inner;
    return self.node(NodeTag.EXPORT_DEFAULT, pos, inner, 0, flags);
}

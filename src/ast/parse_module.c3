// import and export declarations.
module boomkat::ast;

import boomkat::lexer;

// The string literal that names a module: `from "x"`.
fn uint? Parser.module_source(&self) {
    if (self.tok.type != TokenType.STRING || self.tok.is_template) return self.unexpected()~;
    uint a = self.atom(self.tok.str_value);
    self.next()!;
    return a;
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
    self.next()!;
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
    if (self.tok.type == TokenType.STRING && !self.tok.is_template) {
        uint src = self.module_source()!;
        self.semicolon()!;
        return self.node(NodeTag.IMPORT_DECL, pos, src, self.ast.add_list({}));
    }
    if (self.is_ident_token(self.tok)) {
        uint spos = self.tok.pos;
        uint local = self.binding_ident()!;
        self.scratch_push(self.node(NodeTag.IMPORT_SPEC, spos, self.atom("default"), local));
        if (self.tok.type == TokenType.COMMA) {
            self.next()!;
            if (self.tok.type != TokenType.STAR && self.tok.type != TokenType.LBRACE) return self.unexpected()~;
        } else {
            self.expect_word("from")!;
            return self.import_finish(pos, mark);
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
            self.scratch_push(self.node(NodeTag.IMPORT_SPEC, spos, imported, local));
            if (self.tok.type != TokenType.COMMA) break;
            self.next()!;
        }
        self.expect(TokenType.RBRACE)!;
    } else {
        return self.unexpected()~;
    }
    self.expect_word("from")!;
    return self.import_finish(pos, mark);
}

fn uint? Parser.import_finish(&self, uint pos, uint mark) {
    uint src = self.module_source()!;
    self.semicolon()!;
    return self.node(NodeTag.IMPORT_DECL, pos, src, self.scratch_list(mark));
}

fn uint? Parser.export_decl(&self) {
    uint pos = self.tok.pos;
    self.next()!;
    switch (self.tok.type) {
        case TokenType.STAR:
            self.next()!;
            uint name = 0;
            if (self.at_word("as")) {
                self.next()!;
                name = self.module_export_name()!;
            }
            self.expect_word("from")!;
            uint src = self.module_source()!;
            self.semicolon()!;
            return self.node(NodeTag.EXPORT_ALL, pos, src, name);
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
        Token name_tok = self.tok;
        if (name_tok.type == TokenType.STRING) local_ok = false;
        uint local = self.module_export_name()!;
        uint exported = local;
        if (self.at_word("as")) {
            self.next()!;
            exported = self.module_export_name()!;
        }
        if (name_tok.type != TokenType.STRING && !self.is_ident_token(name_tok)) local_ok = false;
        self.scratch_push(self.node(NodeTag.EXPORT_SPEC, spos, local, exported));
        if (self.tok.type != TokenType.COMMA) break;
        self.next()!;
    }
    self.expect(TokenType.RBRACE)!;
    uint list = self.scratch_list(mark);
    uint src = 0;
    if (self.at_word("from")) {
        self.next()!;
        src = self.module_source()!;
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
    return self.node(NodeTag.EXPORT_DEFAULT, pos, inner, 0, flags);
}

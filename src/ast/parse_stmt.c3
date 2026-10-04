// Statement parsing.
module boomkat::ast;

import boomkat::lexer;

// The program: a directive prologue and statements (or module items).
fn uint? Parser.program(&self, ParseOptions opts) {
    uint mark = self.scratch_mark();
    char flags = opts.is_module ? PROGRAM_MODULE : 0;
    self.directive_prologue(mark, &flags)!;
    if (self.ctx.strict) flags |= PROGRAM_STRICT;
    while (self.tok.type != TokenType.EOF_TOKEN) {
        self.scratch_push(self.statement_list_item()!);
    }
    return self.node(NodeTag.PROGRAM, 0, self.scratch_list(mark), 0, flags);
}

fn bool is_use_strict(Token t) @inline {
    if (t.type != TokenType.STRING || t.raw_value.len != 0 || t.str_value.len != 10) return false;
    String want = "use strict";
    for (usz i = 0; i < 10; i++) {
        if (t.str_value[i] != want[i]) return false;
    }
    return true;
}

// Parse the leading string-literal expression statements of a body, pushing them to the scratch
// stack as DIRECTIVE nodes. "use strict" sets ctx.strict and the PROGRAM_STRICT / FNF_USE_STRICT bit.
fn void? Parser.directive_prologue(&self, uint mark, char* flags) {
    while (self.tok.type == TokenType.STRING && !self.tok.is_template) {
        Token first = self.tok;
        uint stmt = self.statement()!;
        if (self.ast.tags.data[stmt] != NodeTag.EXPR_STMT) {
            self.scratch_push(stmt);
            return;
        }
        uint e = self.ast.lhs.data[stmt];
        if (self.ast.tags.data[e] != NodeTag.STRING || self.is_paren(e) || self.ast.main_tok.data[e] != first.pos) {
            self.scratch_push(stmt);
            return;
        }
        char f = 0;
        if (is_use_strict(first)) {
            f = DIR_USE_STRICT;
            self.ctx.strict = true;
            *flags |= PROGRAM_STRICT;
        }
        self.ast.tags.data[stmt] = NodeTag.DIRECTIVE;
        self.ast.flags.data[stmt] = f;
        self.scratch_push(stmt);
    }
}

// A StatementListItem: a statement, declaration, or module import/export.
fn uint? Parser.statement_list_item(&self) {
    switch (self.tok.type) {
        case TokenType.LET:
            if (self.let_starts_declaration()) return self.var_statement(VAR_KIND_LET);
        case TokenType.IMPORT:
            TokenType pt = self.peek_type();
            if (pt != TokenType.LPAREN && pt != TokenType.DOT) {
                if (!self.is_module) return self.fail("cannot use import statement outside a module")~;
                return self.import_decl();
            }
        case TokenType.EXPORT:
            if (!self.is_module) return self.fail("unexpected token 'export'")~;
            return self.export_decl();
        default:
    }
    return self.statement();
}

fn uint? Parser.statement(&self) {
    self.check_stack()!;
    Token t = self.tok;
    switch (t.type) {
        case TokenType.LBRACE:
            return self.block();
        case TokenType.VAR:
            return self.var_statement(VAR_KIND_VAR);
        case TokenType.CONST:
            return self.var_statement(VAR_KIND_CONST);
        case TokenType.LET:
            // Only a StatementListItem can be a LexicalDeclaration; as a sub-statement `let` is an
            // identifier, and `let [` is excluded by the ExpressionStatement lookahead.
            if (self.peek_type() == TokenType.LBRACKET) return self.fail("lexical declaration not allowed in statement position")~;
        case TokenType.SEMICOLON:
            self.next()!;
            return self.node(NodeTag.EMPTY_STMT, t.pos);
        case TokenType.IF:
            return self.if_statement();
        case TokenType.FOR:
            return self.for_statement();
        case TokenType.WHILE:
            return self.while_statement();
        case TokenType.DO:
            return self.do_statement();
        case TokenType.RETURN:
            return self.return_statement();
        case TokenType.BREAK:
        case TokenType.CONTINUE:
            return self.jump_statement();
        case TokenType.THROW:
            return self.throw_statement();
        case TokenType.TRY:
            return self.try_statement();
        case TokenType.SWITCH:
            return self.switch_statement();
        case TokenType.WITH:
            return self.with_statement();
        case TokenType.DEBUGGER:
            self.next()!;
            self.semicolon()!;
            return self.node(NodeTag.DEBUGGER, t.pos);
        case TokenType.FUNCTION:
            return self.function_decl(t.pos, false);
        case TokenType.CLASS:
            return self.class_decl();
        case TokenType.IDENTIFIER:
            if (self.is_word(t, "async")) {
                Token? pk = self.peek();
                if (catch err = pk) return PARSE_ERROR~;
                if (pk.type == TokenType.FUNCTION && !pk.nl_before) {
                    self.next()!;
                    return self.function_decl(t.pos, true);
                }
            }
        default:
    }
    // Labelled statement: an identifier followed by `:`.
    if (self.is_ident_token(t) && self.peek_type() == TokenType.COLON) {
        uint label = self.atom(t.str_value);
        self.next()!;
        self.next()!;
        uint body = self.statement()!;
        return self.node(NodeTag.LABELED, t.pos, label, body);
    }
    return self.expression_statement();
}

fn uint? Parser.expression_statement(&self) {
    uint pos = self.tok.pos;
    uint e = self.expression()!;
    self.semicolon()!;
    return self.node(NodeTag.EXPR_STMT, pos, e);
}

// `let` begins a LexicalDeclaration when a binding follows it.
fn bool Parser.let_starts_declaration(&self) {
    if (self.tok.has_escape) return false;
    Token? pk = self.peek();
    if (catch err = pk) return false;
    switch (pk.type) {
        case TokenType.IDENTIFIER:
        case TokenType.LBRACKET:
        case TokenType.LBRACE:
        case TokenType.LET:
        case TokenType.STATIC:
        case TokenType.YIELD:
        case TokenType.AWAIT:
            return true;
        default:
            return false;
    }
}

fn uint? Parser.block(&self) {
    uint pos = self.tok.pos;
    self.expect(TokenType.LBRACE)!;
    uint mark = self.scratch_mark();
    while (self.tok.type != TokenType.RBRACE) {
        if (self.tok.type == TokenType.EOF_TOKEN) return self.unexpected()~;
        self.scratch_push(self.statement_list_item_in_block()!);
    }
    self.next()!;
    return self.node(NodeTag.BLOCK, pos, self.scratch_list(mark));
}

// Blocks hold statements and declarations but never import/export.
fn uint? Parser.statement_list_item_in_block(&self) {
    return self.statement();
}

// `var`, `let` or `const` statement.
fn uint? Parser.var_statement(&self, char kind) {
    uint d = self.var_declaration(kind, false)!;
    if (self.tok.type != TokenType.SEMICOLON) self.ast.flags.data[d] |= VAR_NO_SEMI;
    self.semicolon()!;
    return d;
}

// The declaration list `var a = 1, b`. In a for-statement head (`in_for`) an initialiser is
// parsed with `in` disabled and a missing one is not an error.
fn uint? Parser.var_declaration(&self, char kind, bool in_for) {
    uint pos = self.tok.pos;
    self.next()!;
    uint mark = self.scratch_mark();
    bool saved_no_in = self.no_in;
    if (in_for) self.no_in = true;
    while (true) {
        uint target = self.binding_target()!;
        uint init = 0;
        if (self.tok.type == TokenType.ASSIGN) {
            self.next()!;
            init = self.assign_expr()!;
        }
        self.scratch_push(self.node(NodeTag.DECLARATOR, self.ast.main_tok.data[target], target, init));
        if (self.tok.type != TokenType.COMMA) break;
        self.next()!;
    }
    self.no_in = saved_no_in;
    return self.node(NodeTag.VAR_DECL, pos, self.scratch_list(mark), 0, kind);
}

fn uint? Parser.paren_expression(&self) {
    self.expect(TokenType.LPAREN)!;
    bool saved = self.no_in;
    self.no_in = false;
    uint e = self.expression()!;
    self.no_in = saved;
    self.expect(TokenType.RPAREN)!;
    return e;
}

fn uint? Parser.if_statement(&self) {
    uint pos = self.tok.pos;
    self.next()!;
    uint test = self.paren_expression()!;
    uint cons = self.statement()!;
    uint alt = 0;
    if (self.tok.type == TokenType.ELSE) {
        self.next()!;
        alt = self.statement()!;
    }
    return self.node(NodeTag.IF, pos, test, self.pair(cons, alt));
}

fn uint? Parser.while_statement(&self) {
    uint pos = self.tok.pos;
    self.next()!;
    uint test = self.paren_expression()!;
    uint body = self.statement()!;
    return self.node(NodeTag.WHILE, pos, test, body);
}

fn uint? Parser.do_statement(&self) {
    uint pos = self.tok.pos;
    self.next()!;
    uint body = self.statement()!;
    self.expect(TokenType.WHILE)!;
    uint test = self.paren_expression()!;
    // A semicolon after `do ... while ( )` is optional even without a line break (§12.10.1).
    if (self.tok.type == TokenType.SEMICOLON) self.next()!;
    return self.node(NodeTag.DO_WHILE, pos, body, test);
}

fn uint? Parser.return_statement(&self) {
    uint pos = self.tok.pos;
    if (!self.ctx.in_function) return self.fail("illegal return statement")~;
    self.next()!;
    uint arg = 0;
    if (self.tok.type != TokenType.SEMICOLON && self.tok.type != TokenType.RBRACE
        && self.tok.type != TokenType.EOF_TOKEN && !self.tok.nl_before) {
        arg = self.expression()!;
    }
    self.semicolon()!;
    return self.node(NodeTag.RETURN, pos, arg);
}

fn uint? Parser.jump_statement(&self) {
    uint pos = self.tok.pos;
    NodeTag tag = self.tok.type == TokenType.BREAK ? NodeTag.BREAK : NodeTag.CONTINUE;
    self.next()!;
    uint label = 0;
    if (!self.tok.nl_before && self.is_ident_token(self.tok)) {
        label = self.atom(self.tok.str_value);
        self.next()!;
    }
    self.semicolon()!;
    return self.node(tag, pos, label);
}

fn uint? Parser.throw_statement(&self) {
    uint pos = self.tok.pos;
    self.next()!;
    if (self.tok.nl_before) return self.fail("illegal newline after throw")~;
    uint arg = self.expression()!;
    self.semicolon()!;
    return self.node(NodeTag.THROW, pos, arg);
}

fn uint? Parser.try_statement(&self) {
    uint pos = self.tok.pos;
    self.next()!;
    uint block = self.block()!;
    uint param = 0;
    uint handler = 0;
    uint finalizer = 0;
    if (self.tok.type == TokenType.CATCH) {
        self.next()!;
        if (self.tok.type == TokenType.LPAREN) {
            self.next()!;
            param = self.binding_target()!;
            self.expect(TokenType.RPAREN)!;
        }
        handler = self.block()!;
    }
    if (self.tok.type == TokenType.FINALLY) {
        self.next()!;
        finalizer = self.block()!;
    }
    if (handler == 0 && finalizer == 0) return self.fail("missing catch or finally after try")~;
    return self.node(NodeTag.TRY, pos, block, self.triple(param, handler, finalizer));
}

fn uint? Parser.switch_statement(&self) {
    uint pos = self.tok.pos;
    self.next()!;
    uint disc = self.paren_expression()!;
    uint brace = self.tok.pos;
    self.expect(TokenType.LBRACE)!;
    uint cases = self.scratch_mark();
    while (self.tok.type != TokenType.RBRACE) {
        uint cpos = self.tok.pos;
        uint test = 0;
        if (self.tok.type == TokenType.CASE) {
            self.next()!;
            test = self.expression()!;
        } else if (self.tok.type == TokenType.DEFAULT) {
            self.next()!;
        } else {
            return self.unexpected()~;
        }
        self.expect(TokenType.COLON)!;
        uint body = self.scratch_mark();
        while (self.tok.type != TokenType.CASE && self.tok.type != TokenType.DEFAULT
            && self.tok.type != TokenType.RBRACE) {
            if (self.tok.type == TokenType.EOF_TOKEN) return self.unexpected()~;
            self.scratch_push(self.statement_list_item_in_block()!);
        }
        uint list = self.scratch_list(body);
        self.scratch_push(self.node(NodeTag.CASE, cpos, test, list));
    }
    self.next()!;
    uint case_list = self.scratch_list(cases);
    return self.node(NodeTag.SWITCH, pos, disc, self.pair(case_list, brace));
}

fn uint? Parser.with_statement(&self) {
    uint pos = self.tok.pos;
    self.next()!;
    uint obj = self.paren_expression()!;
    uint body = self.statement()!;
    return self.node(NodeTag.WITH, pos, obj, body);
}

// ---- for statements ----

fn uint? Parser.for_statement(&self) {
    uint pos = self.tok.pos;
    self.next()!;
    char fflags = 0;
    if (self.tok.type == TokenType.AWAIT && self.await_is_operator()) {
        fflags = FOR_AWAIT;
        self.next()!;
    }
    self.expect(TokenType.LPAREN)!;
    uint init = 0;
    switch (self.tok.type) {
        case TokenType.SEMICOLON:
            return self.for_rest(pos, 0);
        case TokenType.VAR:
            init = self.var_declaration(VAR_KIND_VAR, true)!;
        case TokenType.CONST:
            init = self.var_declaration(VAR_KIND_CONST, true)!;
        case TokenType.LET:
            if (self.let_starts_declaration()) {
                init = self.var_declaration(VAR_KIND_LET, true)!;
            } else {
                init = self.for_init_expression()!;
            }
        default:
            init = self.for_init_expression()!;
    }
    bool is_of = self.at_word("of");
    if (self.tok.type == TokenType.IN || is_of) {
        NodeTag tag = is_of ? NodeTag.FOR_OF : NodeTag.FOR_IN;
        if (self.ast.tags.data[init] != NodeTag.VAR_DECL) {
            NodeTag it = self.ast.tags.data[init];
            if ((it == NodeTag.ARRAY || it == NodeTag.OBJECT) && !self.is_paren(init)) {
                self.to_pattern(init, false)!;
                self.claim_cover(self.ast.main_tok.data[init]);
            } else if (!self.is_simple_target(init, false)) {
                return self.fail_at(self.ast.main_tok.data[init], "invalid left-hand side in for-loop")~;
            }
        } else if (self.ast.list_len(self.ast.lhs.data[init]) != 1) {
            return self.fail("invalid left-hand side in for-loop: must have a single binding")~;
        }
        self.next()!;
        uint right = is_of ? self.assign_expr()! : self.expression()!;
        self.expect(TokenType.RPAREN)!;
        uint body = self.statement()!;
        return self.node(tag, pos, init, self.pair(right, body), fflags);
    }
    if (fflags != 0) return self.unexpected()~;
    if (self.cover_init != 0) self.check_cover_init()!;
    return self.for_rest(pos, init);
}

// An expression in a for-head: `in` is not an operator, and a pattern may still claim a cover
// initialiser, so errors for it wait until the head is complete.
fn uint? Parser.for_init_expression(&self) {
    bool saved = self.no_in;
    self.no_in = true;
    self.cover_depth++;
    uint e = self.expression()!;
    self.cover_depth--;
    self.no_in = saved;
    return e;
}

// `;` test `;` update `)` body of a three-clause for.
fn uint? Parser.for_rest(&self, uint pos, uint init) {
    self.expect(TokenType.SEMICOLON)!;
    uint test = 0;
    uint update = 0;
    if (self.tok.type != TokenType.SEMICOLON) test = self.expression()!;
    self.expect(TokenType.SEMICOLON)!;
    if (self.tok.type != TokenType.RPAREN) update = self.expression()!;
    self.expect(TokenType.RPAREN)!;
    uint body = self.statement()!;
    return self.node(NodeTag.FOR, pos, self.quad(init, test, update, body));
}

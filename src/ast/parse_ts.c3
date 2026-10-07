module boomkat::ast;

import boomkat::lexer;

fn void? Parser.ts_skip_type(&self, bool expression = false) {
    int paren   = 0;
    int bracket = 0;
    int brace   = 0;
    int angle   = 0;
    bool consumed_any = false;
    bool paren_has_arrow  = false;
    bool last_group_had_arrow = false;
    bool group_seen_first = false;
    bool top_group_first_is_group = false;
    TokenType prev_tt = TokenType.EOF_TOKEN;
    char[] prev_str = (char[])"";
    bool just_closed_obj = false;

    for (;;) {
        TokenType tt = self.tok.type;
        if (tt == TokenType.TEMPLATE_HEAD) {
            self.ts_skip_template()!;
            continue;
        }
        int depth = paren + bracket + brace + angle;

        if (just_closed_obj && depth == 0) {
            if (tt != TokenType.BIT_OR && tt != TokenType.BIT_AND
                && tt != TokenType.EXTENDS && tt != TokenType.QUESTION
                && tt != TokenType.COLON && tt != TokenType.LBRACKET) {
                return;
            }
            just_closed_obj = false;
        }

        if (depth == 0) {
            if (expression && consumed_any && ts_token_completes_type(prev_tt)) {
                switch (tt) {
                    case PLUS: case MINUS: case STAR: case SLASH: case PERCENT: case STARSTAR:
                    case SHL: case SHR: case USHR: case EQ: case NE: case SEQ: case SNE:
                    case LOG_AND: case LOG_OR: case NULLISH: case LPAREN:
                        return;
                    default: break;
                }
            }
            switch (tt) {
                case TokenType.EOF_TOKEN:
                case TokenType.SEMICOLON:
                case TokenType.COMMA:
                case TokenType.RPAREN:
                case TokenType.RBRACKET:
                case TokenType.RBRACE:
                case TokenType.ASSIGN:
                    return;
                case TokenType.ARROW:
                    if (prev_tt == TokenType.RPAREN && last_group_had_arrow) return;
                    if (prev_tt == TokenType.RPAREN) break;
                    return;
                default:
                    break;
            }
            if (tt == TokenType.LBRACE && consumed_any && ts_token_completes_type(prev_tt)
                && !(prev_tt == TokenType.IDENTIFIER && ts_ident_is_type_operator(prev_str))) {
                return;
            }
            if (self.tok.nl_before && consumed_any && ts_token_completes_type(prev_tt)
                && !(prev_tt == TokenType.IDENTIFIER && ts_ident_is_type_operator(prev_str))) {
                if (tt != TokenType.BIT_OR && tt != TokenType.BIT_AND
                    && tt != TokenType.EXTENDS && tt != TokenType.QUESTION
                    && tt != TokenType.COLON && tt != TokenType.ARROW
                    && tt != TokenType.LBRACKET && tt != TokenType.LT
                    && tt != TokenType.DOT) {
                    return;
                }
            }
        }
        if (self.lex.ts_mode && tt == TokenType.IMPORT) {
            Token _imp = self.ts_advance()!;
            continue;
        }
        if (depth == 0 && ts_token_stops_type(tt)) {
            return;
        }

        Token skip_tok = self.ts_advance()!;
        consumed_any = true;
        if (paren == 1 && !group_seen_first && tt != TokenType.RPAREN) {
            group_seen_first = true;
            if (tt == TokenType.LPAREN || tt == TokenType.LT) {
                top_group_first_is_group = true;
            }
        }

        switch (tt) {
            case TokenType.LPAREN:
                if (paren == 0) paren_has_arrow = false;
                paren++;
                break;
            case TokenType.RPAREN:
                if (paren > 0) paren--;
                if (paren == 0) last_group_had_arrow = paren_has_arrow;
                break;
            case TokenType.LBRACKET: bracket++;
            case TokenType.RBRACKET: if (bracket > 0) bracket--;
            case TokenType.LBRACE:   brace++;
            case TokenType.RBRACE:   if (brace > 0) brace--;
            case TokenType.LT:       angle++;
            case TokenType.GT:       if (angle > 0) angle--;
            case TokenType.GE:       if (angle > 0) angle--;  // `>=` at end of generic like `T=>`
            case TokenType.SHR:      if (angle >= 2) { angle -= 2; } else if (angle == 1) angle--;
            case TokenType.USHR:     if (angle >= 3) { angle -= 3; } else if (angle > 0) angle = 0;
            case TokenType.ARROW:
                if (paren == 1 && top_group_first_is_group) paren_has_arrow = true;
                break;
            case TokenType.EOF_TOKEN:
                return;  // safety net; loop guard above should have exited
            default:
                break;
        }
        prev_tt = tt;
        prev_str = skip_tok.str_value;
        if (tt == TokenType.RBRACE && brace == 0 && paren == 0 && bracket == 0 && angle == 0) {
            just_closed_obj = true;
        }
    }
}

fn void? Parser.ts_skip_generic_params(&self) {
    Token _skip_open = self.expect(TokenType.LT)!;
    int angle = 1;
    int paren = 0;
    int bracket = 0;
    int brace = 0;

    while (angle > 0) {
        TokenType tt = self.tok.type;
        if (tt == TokenType.EOF_TOKEN) {
            return self.fail("unterminated type parameter list")~;
        }
        if (tt == TokenType.TEMPLATE_HEAD) {
            self.ts_skip_template()!;
            continue;
        }
        Token _skip = self.ts_advance()!;
        switch (tt) {
            case TokenType.LT:       angle++;
            case TokenType.GT:       angle--;
            case TokenType.GE:       angle--;
            case TokenType.SHR:      angle -= 2;
            case TokenType.USHR:     angle -= 3;
            case TokenType.LPAREN:   paren++;
            case TokenType.RPAREN:   if (paren > 0) paren--;
            case TokenType.LBRACKET: bracket++;
            case TokenType.RBRACKET: if (bracket > 0) bracket--;
            case TokenType.LBRACE:   brace++;
            case TokenType.RBRACE:   if (brace > 0) brace--;
            default: break;
        }
        if (angle < 0) angle = 0;
    }
}

fn Token? Parser.ts_advance(&self) {
    Token token = self.tok;
    self.next()!;
    return token;
}

fn void? Parser.ts_skip_template(&self) {
    for (;;) {
        self.next()!;
        self.ts_skip_type()!;
        if (self.tok.type != TokenType.RBRACE) return self.unexpected()~;
        self.rescan_template()!;
        if (self.tok.type == TokenType.TEMPLATE_TAIL) {
            self.next()!;
            return;
        }
        if (self.tok.type != TokenType.TEMPLATE_MIDDLE) return self.unexpected()~;
    }
}

fn void? Parser.ts_annotation(&self, bool optional = false, bool definite = false) {
    if (!self.lex.ts_mode) return;
    if ((optional && self.tok.type == TokenType.QUESTION)
        || (definite && self.tok.type == TokenType.LOG_NOT)) self.next()!;
    if (self.tok.type == TokenType.COLON) {
        self.next()!;
        self.ts_skip_type()!;
    }
}

fn void? Parser.ts_skip_body(&self) {
    self.expect(TokenType.LBRACE)!;
    uint depth = 1;
    while (depth != 0) {
        if (self.tok.type == TokenType.EOF_TOKEN) return self.unexpected()~;
        if (self.tok.type == TokenType.TEMPLATE_HEAD) {
            self.ts_skip_template()!;
            continue;
        }
        if (self.tok.type == TokenType.LBRACE) depth++;
        if (self.tok.type == TokenType.RBRACE) depth--;
        self.next()!;
    }
}

// `<` is also a comparison. Speculation consumes only erased tokens and restores the cursor.
fn bool Parser.ts_type_arguments(&self) {
    Parser saved = *self;
    Lexer lexer_saved = *self.lex;
    if (try self.ts_skip_generic_params()) {
        if (self.tok.type == TokenType.LPAREN || self.tok.type == TokenType.DOT
            || self.tok.type == TokenType.TEMPLATE_HEAD || self.tok.is_template
            || self.tok.type == TokenType.SEMICOLON || self.tok.type == TokenType.RPAREN
            || self.tok.type == TokenType.COMMA || self.tok.type == TokenType.LBRACE) return true;
    }
    *self.lex = lexer_saved;
    *self = saved;
    return false;
}

fn bool? Parser.ts_erase_statement(&self, bool in_namespace = false) {
    if (!self.lex.ts_mode) return false;
    self.ts_erased_name = 0;
    uint pos = self.tok.pos;
    if (self.tok.type == TokenType.ENUM) return self.fail("'enum' is not supported (not erasable syntax)")~;
    if (self.tok.type == TokenType.IMPORT && self.peek_type() == TokenType.IDENTIFIER) {
        Token next = self.peek()!;
        if (self.is_word(next, "type") && !next.nl_before) {
            self.next()!;
            self.next()!;
            self.ts_erase_import_export()!;
            return true;
        }
    }
    if (self.tok.type == TokenType.EXPORT) {
        Token next = self.peek()!;
        if (next.type == TokenType.DEFAULT) {
            Parser saved = *self;
            Lexer lexer_saved = *self.lex;
            self.next()!;
            self.next()!;
            if (self.at_word("interface")) return self.ts_erase_statement(in_namespace);
            *self.lex = lexer_saved;
            *self = saved;
        }
        if (self.is_word(next, "type") || self.is_word(next, "interface")
            || self.is_word(next, "declare") || self.is_word(next, "namespace")) {
            self.next()!;
            if (self.at_word("type") && (self.peek_type() == TokenType.LBRACE || self.peek_type() == TokenType.STAR)) {
                self.next()!;
                self.ts_erase_import_export()!;
                return true;
            }
            return self.ts_erase_statement(in_namespace);
        }
    }
    bool iface = self.at_word("interface");
    bool alias_decl = self.at_word("type");
    bool namespace_decl = self.at_word("namespace") || self.at_word("module");
    if (iface || alias_decl || namespace_decl) {
        Token next = self.peek()!;
        if (next.type != TokenType.IDENTIFIER || next.nl_before) return false;
        uint name = self.atom(next.str_value);
        self.next()!;
        self.next()!;
        if (namespace_decl) {
            while (self.eat(TokenType.DOT)!) self.expect(TokenType.IDENTIFIER)!;
            self.expect(TokenType.LBRACE)!;
            while (self.tok.type != TokenType.RBRACE) {
                if (self.eat(TokenType.SEMICOLON)!) continue;
                if (!(self.ts_erase_statement(true)!)) return self.fail_at(pos, "'namespace' / 'module' is not supported (not erasable syntax)")~;
            }
            self.next()!;
        } else {
            if (self.tok.type == TokenType.LT) self.ts_skip_generic_params()!;
            if (iface) {
                if (self.eat(TokenType.EXTENDS)!) {
                    for (;;) {
                        self.ts_skip_type()!;
                        if (!(self.eat(TokenType.COMMA)!)) break;
                    }
                }
                self.ts_skip_body()!;
            } else {
                self.expect(TokenType.ASSIGN)!;
                self.ts_skip_type()!;
            }
        }
        self.eat(TokenType.SEMICOLON)!;
        self.ts_erased_name = name;
        return true;
    }
    if (self.at_word("declare")) {
        Token next = self.peek()!;
        if (next.nl_before) return false;
        if (in_namespace && !self.is_word(next, "namespace") && !self.is_word(next, "module")) return false;
        self.next()!;
        if (in_namespace) return self.ts_erase_statement(true);
        bool body = self.tok.type == TokenType.CLASS || self.at_word("interface")
            || self.tok.type == TokenType.ENUM || self.at_word("namespace")
            || self.at_word("module") || self.at_word("global") || self.at_word("abstract");
        uint depth = 0;
        TokenType prev = self.tok.type;
        while (self.tok.type != TokenType.EOF_TOKEN) {
            TokenType tt = self.tok.type;
            if (depth == 0) {
                if (self.eat(TokenType.SEMICOLON)!) return true;
                if (tt == TokenType.LBRACE && body) {
                    self.ts_skip_body()!;
                    self.eat(TokenType.SEMICOLON)!;
                    return true;
                }
                if (self.tok.nl_before && ts_token_completes_type(prev)) return true;
            }
            if (tt == TokenType.TEMPLATE_HEAD) { self.ts_skip_template()!; continue; }
            if (tt == TokenType.LPAREN || tt == TokenType.LBRACKET || tt == TokenType.LBRACE || tt == TokenType.LT) depth++;
            if (tt == TokenType.RPAREN || tt == TokenType.RBRACKET || tt == TokenType.RBRACE || tt == TokenType.GT) {
                if (depth == 0) return true;
                depth--;
            }
            prev = tt;
            self.next()!;
        }
        return true;
    }
    if (self.at_word("abstract") && self.peek_type() == TokenType.CLASS) self.next()!;
    return false;
}

fn void? Parser.ts_erase_import_export(&self) {
    uint depth = 0;
    while (self.tok.type != TokenType.EOF_TOKEN) {
        TokenType tt = self.tok.type;
        if (depth == 0) {
            if (self.eat(TokenType.SEMICOLON)!) return;
            if (self.tok.nl_before && tt != TokenType.COMMA && !self.at_word("from")
                && tt != TokenType.STRING) return;
        }
        if (tt == TokenType.LBRACE || tt == TokenType.LPAREN || tt == TokenType.LBRACKET) depth++;
        if (tt == TokenType.RBRACE || tt == TokenType.RPAREN || tt == TokenType.RBRACKET) {
            if (depth == 0) return;
            depth--;
        }
        self.next()!;
    }
}

fn bool Parser.ts_index_signature(&self) {
    if (self.tok.type != TokenType.LBRACKET) return false;
    Parser saved = *self;
    Lexer lexer_saved = *self.lex;
    if (try self.ts_read_index_signature()) return true;
    *self.lex = lexer_saved;
    *self = saved;
    return false;
}

fn void? Parser.ts_read_index_signature(&self) {
    self.next()!;
    self.expect(TokenType.IDENTIFIER)!;
    self.expect(TokenType.COLON)!;
    self.ts_skip_type()!;
    self.expect(TokenType.RBRACKET)!;
    self.expect(TokenType.COLON)!;
    self.ts_skip_type()!;
    self.semicolon()!;
}

fn void Parser.ts_arrow_return_annotation(&self) {
    if (!self.lex.ts_mode || self.tok.type != TokenType.COLON) return;
    Parser saved = *self;
    Lexer lexer_saved = *self.lex;
    if (try self.ts_annotation()) {
        if (self.tok.type == TokenType.ARROW) return;
    }
    *self.lex = lexer_saved;
    *self = saved;
}

fn void? Parser.ts_class_modifiers(&self) {
    while (self.lex.ts_mode && (self.at_word("public") || self.at_word("private")
        || self.at_word("protected") || self.at_word("readonly") || self.at_word("override")
        || self.at_word("abstract") || self.at_word("declare"))) {
        TokenType next = self.peek_type();
        if (next == TokenType.LPAREN || next == TokenType.LT || next == TokenType.COLON || next == TokenType.ASSIGN
            || next == TokenType.SEMICOLON || next == TokenType.RBRACE) break;
        self.next()!;
    }
}

fn bool ts_token_completes_type(TokenType tt) @inline {
    switch (tt) {
        case TokenType.IDENTIFIER:
        case TokenType.STRING:
        case TokenType.NUMBER:
        case TokenType.BIGINT:
        case TokenType.TEMPLATE:
        case TokenType.RPAREN:
        case TokenType.RBRACKET:
        case TokenType.RBRACE:
        case TokenType.GT:
        case TokenType.GE:
        case TokenType.SHR:
        case TokenType.USHR:
        case TokenType.THIS:
        case TokenType.VOID:
            return true;
        default:
            return false;
    }
}

fn bool ts_ident_is_type_operator(char[] name) @inline {
    return ident_is(name, "keyof") || ident_is(name, "typeof")
        || ident_is(name, "infer") || ident_is(name, "as")
        || ident_is(name, "satisfies") || ident_is(name, "readonly")
        || ident_is(name, "is") || ident_is(name, "asserts")
        || ident_is(name, "abstract");
}

fn bool ts_token_stops_type(TokenType tt) {
    switch (tt) {
        case TokenType.FUNCTION:
        case TokenType.IF:
        case TokenType.ELSE:
        case TokenType.FOR:
        case TokenType.WHILE:
        case TokenType.DO:
        case TokenType.SWITCH:
        case TokenType.CASE:
        case TokenType.DEFAULT:
        case TokenType.BREAK:
        case TokenType.CONTINUE:
        case TokenType.RETURN:
        case TokenType.TRY:
        case TokenType.CATCH:
        case TokenType.FINALLY:
        case TokenType.THROW:
        case TokenType.DELETE:
        case TokenType.CLASS:
        case TokenType.CONST:
        case TokenType.VAR:
        case TokenType.LET:
        case TokenType.ENUM:
        case TokenType.INTERFACE:
        case TokenType.IMPORT:
        case TokenType.EXPORT:
        case TokenType.SUPER:
        case TokenType.STATIC:
        case TokenType.PACKAGE:
        case TokenType.PRIVATE:
        case TokenType.PROTECTED:
        case TokenType.PUBLIC:
        case TokenType.IMPLEMENTS:
        case TokenType.WITH:
        case TokenType.DEBUGGER:
        case TokenType.YIELD:
        case TokenType.AWAIT:
            return true;
        default:
            return false;
    }
}

fn bool ident_is(char[] name, char[] word) @inline => name == word;

fn bool Parser.ts_type_specifier(&self) {
    if (!self.lex.ts_mode || !self.at_word("type")) return false;
    if (try next = self.peek()) {
        return (next.type == TokenType.IDENTIFIER && !self.is_word(next, "as"))
            || (next.type == TokenType.STRING && !next.is_template);
    }
    return false;
}

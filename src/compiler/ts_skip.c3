module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import libc;
import std::io;

// ============================================================================
// TypeScript type-annotation skipper
// ============================================================================
//
// The engine treats TypeScript type syntax as tokens to consume and discard.
// Nothing is type-checked and no AST is built for types; source positions on
// surrounding runtime tokens are preserved because we only advance the
// token cursor.
//
// Grammar coverage (all skipped by bracket balancing):
//   - Identifiers, dotted names, generics `<...>`
//   - Union `|`, intersection `&`, `keyof`, `typeof`, `infer`, `readonly`
//   - Conditional `T extends U ? A : B`
//   - Function types `(a: T, b: U) => V`
//   - Object types `{ x: T; y(): U; [k: string]: V }`
//   - Tuple types `[T, U, ...V[]]`, rest `...`
//   - Literal types (strings, numbers, template literal types, `-1`)
//   - `null`, `undefined`, `void`, `true`, `false`, `this`
//
// The skipper stops at a delimiter token at depth 0. Delimiters that end a
// type context: `,` `)` `]` `}` `;` `=` `EOF`, and (when arrow-terminating)
// `=>` at depth 0 handled by caller.
// ============================================================================

// Returns true if the token type can appear inside a TypeScript type expression at any depth.
fn bool token_can_start_or_continue_type(TokenType tt) {
    switch (tt) {
        case TokenType.IDENTIFIER:
        case TokenType.STRING:
        case TokenType.NUMBER:
        case TokenType.BIGINT:
        case TokenType.TEMPLATE:
        case TokenType.TEMPLATE_HEAD:
        case TokenType.LBRACE:
        case TokenType.LBRACKET:
        case TokenType.LPAREN:
        case TokenType.LT:
        case TokenType.DOT:
        case TokenType.ELLIPSIS:
        case TokenType.QUESTION:
        case TokenType.COLON:
        case TokenType.BIT_OR:
        case TokenType.BIT_AND:
        case TokenType.MINUS:
        case TokenType.LOG_NOT:
        case TokenType.NEW:
        case TokenType.TYPEOF:
        case TokenType.VOID:
        case TokenType.THIS:
        case TokenType.EXTENDS:
            return true;
        default:
            return false;
    }
}

// True if `tt` can end a TypeScript type expression.
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

// Contextual TypeScript operator keywords are lexed as plain IDENTIFIERs but never END a type.
fn bool ts_ident_is_type_operator(char[] name) @inline {
    return ident_is(name, "keyof") || ident_is(name, "typeof")
        || ident_is(name, "infer") || ident_is(name, "as")
        || ident_is(name, "satisfies") || ident_is(name, "readonly")
        || ident_is(name, "is") || ident_is(name, "asserts")
        || ident_is(name, "abstract");
}

// True if `tt` is a reserved word that can never appear inside a TypeScript type expression.
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

// Consume a full TypeScript type expression by bracket balancing.
fn void? CompilerContext.skip_type(&self) {
    int paren   = 0;
    int bracket = 0;
    int brace   = 0;
    int angle   = 0;
    bool consumed_any = false;
    // Set when the currently open top-level paren group is a parenthesized
    // function type `(...) => R` rather than a parameter list.
    bool paren_has_arrow  = false;
    bool last_group_had_arrow = false;
    bool group_seen_first = false;
    bool top_group_first_is_group = false;
    TokenType prev_tt = TokenType.EOF_TOKEN;
    char[] prev_str = (char[])"";
    bool just_closed_obj = false;

    for (;;) {
        TokenType tt = self.peek_type();
        if (tt == TokenType.TEMPLATE_HEAD) {
            self.skip_template_literal_type()!;
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
            if (self.lexer.seen_line_term && consumed_any && ts_token_completes_type(prev_tt)
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

        if (self.lexer.ts_mode && tt == TokenType.IMPORT) {
            Token _imp = self.advance()!;
            continue;
        }

        if (depth == 0 && ts_token_stops_type(tt)) {
            return;
        }

        Token skip_tok = self.advance()!;
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
            case TokenType.GE:       if (angle > 0) angle--;
            case TokenType.SHR:      if (angle >= 2) { angle -= 2; } else if (angle == 1) angle--;
            case TokenType.USHR:     if (angle >= 3) { angle -= 3; } else if (angle > 0) angle = 0;
            case TokenType.ARROW:
                if (paren == 1 && top_group_first_is_group) paren_has_arrow = true;
                break;
            case TokenType.EOF_TOKEN:
                return;
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

// Skip a TypeScript generic type-parameter list `<T, U extends V, const W>`.
fn void? CompilerContext.skip_generic_params(&self) {
    Token _skip_open = self.expect(TokenType.LT)!;
    int angle = 1;
    int paren = 0;
    int bracket = 0;
    int brace = 0;

    while (angle > 0) {
        TokenType tt = self.peek_type();
        if (tt == TokenType.EOF_TOKEN) {
            return self.fail("unterminated type parameter list")~;
        }
        if (tt == TokenType.TEMPLATE_HEAD) {
            self.skip_template_literal_type()!;
            continue;
        }
        Token _skip = self.advance()!;
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

// Consume a template literal type starting at the TEMPLATE_HEAD token.
fn void? CompilerContext.skip_template_literal_type(&self) {
    for (;;) {
        Token _head = self.advance()!;
        if (catch _e = self.skip_type()) return;
        self.expect(TokenType.RBRACE)!;
        Token tail = self.lexer.scan_template_after_expr()!;
        if (tail.type == TokenType.TEMPLATE_TAIL) return;
        if (tail.type != TokenType.TEMPLATE_MIDDLE) {
            return self.fail("unterminated template literal type")~;
        }
    }
}

// Skip a TypeScript object/interface body `{ ... }`.
fn void? CompilerContext.skip_braced_body(&self) {
    Token _skip_open = self.expect(TokenType.LBRACE)!;
    int brace = 1;
    TemplateScan tscan;
    while (brace > 0) {
        TokenType tt = self.peek_type();
        if (tt == TokenType.EOF_TOKEN) {
            return self.fail("unterminated block")~;
        }
        Token _skip = self.advance()!;
        if (tt == TokenType.LBRACE) {
            tscan.on_lbrace();
            brace++;
        } else if (tt == TokenType.RBRACE) {
            TemplateBrace tb = tscan.classify_rbrace(self.lexer);
            if (tb == TemplateBrace.LEX_ERROR) {
                return self.fail("unterminated template in block")~;
            }
            if (tb == TemplateBrace.BLOCK) brace--;
        } else if (tt == TokenType.TEMPLATE_HEAD) {
            tscan.on_template_head();
        }
    }
}

// True when `name` matches the given ASCII keyword.
fn bool ident_is(char[] name, char[] kw) @inline {
    if (name.len != kw.len) return false;
    for (usz i = 0; i < name.len; i++) {
        if (name[i] != kw[i]) return false;
    }
    return true;
}

// If in ts_mode and the next token is `:`, consume it and skip the type.
fn void? CompilerContext.try_skip_ts_type_annotation(&self) {
    if (!self.lexer.ts_mode) return;
    if (self.peek_type() != TokenType.COLON) return;
    Token _colon = self.advance()!;
    self.skip_type()!;
}

// If in ts_mode and the next token is `?` followed by `:`, `,`, `)`, `=`, or `]`, consume it.
fn void? CompilerContext.try_skip_ts_optional_marker(&self) {
    if (!self.lexer.ts_mode) return;
    if (self.peek_type() != TokenType.QUESTION) return;
    Token q = self.advance()!;
    TokenType next = self.peek_type();
    if (next == TokenType.COLON || next == TokenType.COMMA ||
        next == TokenType.RPAREN || next == TokenType.ASSIGN ||
        next == TokenType.RBRACKET || next == TokenType.SEMICOLON) {
        return;
    }
    self.pushback(q);
}

// If in ts_mode and the next token is `!` (definite-assignment marker), consume it.
fn void? CompilerContext.try_skip_ts_definite_marker(&self) {
    if (!self.lexer.ts_mode) return;
    if (self.peek_type() != TokenType.LOG_NOT) return;
    Token bang = self.advance()!;
    TokenType next = self.peek_type();
    if (next == TokenType.COLON || next == TokenType.ASSIGN ||
        next == TokenType.SEMICOLON) {
        return;
    }
    // Not a definite-assignment marker, put it back.
    self.pushback(bang);
}

// If the current token is an IDENTIFIER with the given contextual-keyword spelling, consume it.
fn bool CompilerContext.match_ts_ident(&self, char[] kw) {
    if (!self.lexer.ts_mode) return false;
    if (self.peek_type() != TokenType.IDENTIFIER) return false;

    Token? cur_opt = self.advance();
    if (catch _e = cur_opt) return false;
    Token cur = cur_opt;
    if (ident_is(cur.str_value, kw)) return true;
    self.pushback(cur);
    return false;
}

// Consume a `declare namespace X { ... }` / `declare module "m" { ... }` nested inside a namespace body.
fn bool CompilerContext.ts_try_declare_namespace(&self) {
    if (!self.lexer.ts_mode) return false;
    if (self.peek_type() != TokenType.IDENTIFIER) return false;
    Lexer saved = *self.lexer;
    Token kw = self.advance()!!;
    if (!ident_is(kw.str_value, "declare")) {
        *self.lexer = saved;
        return false;
    }
    // The namespace/module keyword must follow on the same line, and the
    // name it carries must too (ts_try_type_only_namespace re-checks).
    if (self.peek_type() != TokenType.IDENTIFIER || self.lexer.seen_line_term) {
        *self.lexer = saved;
        return false;
    }
    Token nk = self.advance()!!;
    if (!ident_is(nk.str_value, "namespace") && !ident_is(nk.str_value, "module")) {
        *self.lexer = saved;
        return false;
    }
    // ts_try_type_only_namespace consumes its keyword itself, so put the
    // `namespace`/`module` back (and restore both stacks on failure, since
    // a partial body scan can leave tokens pushed back).
    uint saved_pbc = self.pushback_count;
    Token[4] saved_pbs = self.pushback_stack;
    self.pushback(nk);
    if (self.ts_try_type_only_namespace()) return true;
    self.pushback_count = saved_pbc;
    self.pushback_stack = saved_pbs;
    *self.lexer = saved;
    return false;
}

// Skip a TypeScript `interface Foo<T> extends Bar { ... }` statement.
fn void? CompilerContext.ts_interface_declaration(&self) {
    Token _iface = self.advance()!;
    Token _name = self.expect(TokenType.IDENTIFIER)!;
    if (self.check(TokenType.LT)) self.skip_generic_params()!;
    // Optional `extends A, B<T>`
    if (self.check(TokenType.EXTENDS)) {
        Token _ext = self.advance()!;
        for (;;) {
            self.skip_type()!;
            if (!self.match(TokenType.COMMA)) break;
        }
    }
    self.skip_braced_body()!;
    self.match(TokenType.SEMICOLON);
}

// Try to parse a TypeScript `type X = ...;` alias.
fn bool CompilerContext.ts_try_type_alias(&self) {
    if (!self.lexer.ts_mode) return false;
    if (self.peek_type() != TokenType.IDENTIFIER) return false;

    Token? kw_opt = self.advance();
    if (catch _e = kw_opt) return false;
    Token kw = kw_opt;
    if (!ident_is(kw.str_value, "type")) {
        self.pushback(kw);
        return false;
    }
    // Next must be an IDENTIFIER for a real type-alias declaration.
    if (self.peek_type() != TokenType.IDENTIFIER || self.lexer.seen_line_term) {
        self.pushback(kw);
        return false;
    }
    Token _name = self.advance()!!;
    if (self.check(TokenType.LT)) {
        if (catch _e = self.skip_generic_params()) return true;
    }
    if (!self.match(TokenType.ASSIGN)) return true;
    if (catch _e = self.skip_type()) return true;
    self.match(TokenType.SEMICOLON);
    return true;
}

// Try to parse a TypeScript `declare ...` ambient declaration.
fn bool CompilerContext.ts_try_declare_statement(&self) {
    if (!self.lexer.ts_mode) return false;
    if (self.peek_type() != TokenType.IDENTIFIER) return false;

    Token? kw_opt = self.advance();
    if (catch _e = kw_opt) return false;
    Token kw = kw_opt;
    if (!ident_is(kw.str_value, "declare")) {
        self.pushback(kw);
        return false;
    }
    Token? nt_opt = self.lexer.peek();
    if (catch _e = nt_opt) {
        self.pushback(kw);
        return false;
    }
    Token nt = nt_opt;
    if (self.lexer.seen_line_term) {
        self.pushback(kw);
        return false;
    }
    // Ambient declarations produce no runtime code. Swallow tokens until the
    // declare body ends: a `;` at full depth 0, or the closing `}` of a
    // top-level body (class/interface/enum/namespace/module/global/abstract
    // class). Object types inside signatures (`declare function f(x: {a: T}): T;`)
    // balance their own braces and must not end the statement early, so only a `{`
    // opened by a body-taking declaration counts as the body. Angle brackets are
    // tracked too so `Promise<{...}>` does not close early.
    bool body_kind = nt.type == TokenType.CLASS
        || nt.type == TokenType.INTERFACE
        || nt.type == TokenType.ENUM
        || (nt.type == TokenType.IDENTIFIER
            && (ident_is(nt.str_value, "namespace")
                || ident_is(nt.str_value, "module")
                || ident_is(nt.str_value, "global")
                || ident_is(nt.str_value, "abstract")));
    int paren = 0;
    int bracket = 0;
    int brace = 0;
    int angle = 0;
    bool body_open = false;
    TokenType prev_tt = nt.type;
    for (;;) {
        TokenType tt = self.peek_type();
        int depth = paren + bracket + brace + angle;
        if (tt == TokenType.EOF_TOKEN) return true;
        if (depth == 0) {
            if (tt == TokenType.SEMICOLON && !body_open) {
                Token _semi = self.advance()!!;
                return true;
            }
            if (body_open && brace == 0) {
                return true;
            }
            // ASI: an ambient declaration without a `;` ends at a line break
            // once the tokens so far can terminate it (`declare const x: unique symbol`).
            // The ts_token_completes_type set decides if the break is a real boundary;
            // a break after `|`, `:`, or `extends` continues a multi-line type instead.
            if (!body_open && self.lexer.seen_line_term
                && ts_token_completes_type(prev_tt)) {
                return true;
            }
        }
        // Template literal types in the signature (x: `a${T}`) are not a flat
        // token stream: the substitution's `}` must be consumed and the tail
        // re-scanned, so handle them atomically rather than counting braces here.
        if (tt == TokenType.TEMPLATE_HEAD) {
            if (catch _t = self.skip_template_literal_type()) return true;
            continue;
        }
        Token? adv = self.advance();
        if (catch _e = adv) return true;
        prev_tt = tt;
        switch (tt) {
            case TokenType.LPAREN:   paren++;
            case TokenType.RPAREN:   if (paren > 0) paren--;
            case TokenType.LBRACKET: bracket++;
            case TokenType.RBRACKET: if (bracket > 0) bracket--;
            case TokenType.LBRACE:
                if (body_kind && !body_open && paren == 0 && bracket == 0 && angle == 0) {
                    body_open = true;
                }
                brace++;
            case TokenType.RBRACE:   if (brace > 0) brace--;
            case TokenType.LT:       angle++;
            case TokenType.GT:       if (angle > 0) angle--;
            case TokenType.GE:       if (angle > 0) angle--;
            case TokenType.SHR:      if (angle >= 2) { angle -= 2; } else if (angle == 1) angle--;
            case TokenType.USHR:     if (angle >= 3) { angle -= 3; } else if (angle > 0) angle = 0;
            default: break;
        }
    }
}

// Try to consume a TypeScript `namespace`/`module` declaration whose body
// holds only type declarations (interfaces, type aliases, `declare`
// statements, nested type-only namespaces, empty statements). tsc's
// `--erasableSyntaxOnly` allows such namespaces and they emit no runtime code,
// so the engine erases them.
fn bool CompilerContext.ts_try_type_only_namespace(&self) {
    if (!self.lexer.ts_mode) return false;
    Token kw_tok = self.advance()!!;
    // Name must be on the same line as the keyword. A line terminator in
    // between makes the keyword an ordinary identifier under ASI.
    if (self.peek_type() != TokenType.IDENTIFIER) return false;
    Token _name = self.advance()!!;
    if (_name.line != kw_tok.line) return false;
    while (self.check(TokenType.DOT)) {
        Token _dot = self.advance()!!;
        if (self.peek_type() != TokenType.IDENTIFIER) return false;
        Token _part = self.advance()!!;
    }
    if (!self.check(TokenType.LBRACE)) return false;
    Token _open = self.advance()!!;
    for (;;) {
        TokenType tt = self.peek_type();
        if (tt == TokenType.EOF_TOKEN) return false;
        switch (tt) {
            case TokenType.RBRACE:
                Token _close = self.advance()!!;
                return true;
            case TokenType.SEMICOLON:
                Token _semi = self.advance()!!;
                break;
            case TokenType.INTERFACE:
                if (catch _e = self.ts_interface_declaration()) return false;
                break;
            case TokenType.EXPORT:
                Token _exp = self.advance()!!;
                TokenType nt = self.peek_type();
                if (nt == TokenType.INTERFACE) {
                    if (catch _e = self.ts_interface_declaration()) return false;
                } else if (nt == TokenType.IDENTIFIER) {
                    if (self.ts_try_type_alias()) break;
                    if (self.ts_try_type_only_namespace()) break;
                    return false;
                } else {
                    return false;
                }
                break;
            case TokenType.IDENTIFIER:
                if (self.ts_try_declare_namespace()) break;
                if (self.ts_try_type_alias()) break;
                if (self.ts_try_type_only_namespace()) break;
                return false;
            default:
                // Non-type bodies (var/function/class/enum) make the namespace non-erasable (TS1294).
                return false;
        }
    }
}

// Non-consuming version of match_ts_ident.
// Peeks token text without consuming so statement dispatcher fallthrough is safe.
fn bool CompilerContext.check_ts_ident(&self, char[] kw) {
    if (!self.lexer.ts_mode) return false;
    if (self.peek_type() != TokenType.IDENTIFIER) return false;
    if (self.pushback_count > 0) {
        return ident_is(self.pushback_stack[self.pushback_count - 1].str_value, kw);
    }
    Token? peek_opt = self.lexer.peek();
    if (catch _e = peek_opt) return false;
    return ident_is(peek_opt.str_value, kw);
}

// Swallow all tokens until (and including) the terminating semicolon at depth 0.
// Used to erase `import type ...` and `export type ...` forms.
fn void? CompilerContext.ts_swallow_to_semi(&self) {
    int paren = 0;
    int bracket = 0;
    int brace = 0;
    for (;;) {
        TokenType tt = self.peek_type();
        int depth = paren + bracket + brace;
        if (tt == TokenType.EOF_TOKEN) return;
        // ASI: a line break before the next token at depth 0 ends the erased
        // declaration, unless the token continues the type across the break
        // (union/intersection operators, conditional arms, member access, commas, arrow).
        if (depth == 0 && self.lexer.seen_line_term
            && tt != TokenType.BIT_OR && tt != TokenType.BIT_AND
            && tt != TokenType.QUESTION && tt != TokenType.COLON
            && tt != TokenType.DOT && tt != TokenType.COMMA
            && tt != TokenType.ARROW) {
            return;
        }
        if (depth == 0 && tt == TokenType.SEMICOLON) {
            Token _semi = self.advance()!;
            return;
        }
        if (tt == TokenType.TEMPLATE_HEAD) {
            if (catch _t = self.skip_template_literal_type()) return;
            continue;
        }
        Token _t = self.advance()!;
        switch (tt) {
            case TokenType.LPAREN:   paren++;
            case TokenType.RPAREN:   if (paren > 0) paren--;
            case TokenType.LBRACKET: bracket++;
            case TokenType.RBRACKET: if (bracket > 0) bracket--;
            case TokenType.LBRACE:   brace++;
            case TokenType.RBRACE:   if (brace > 0) brace--;
            default: break;
        }
    }
}

// `import type ...`: consume and discard.
fn bool? CompilerContext.ts_try_skip_type_only_import(&self) {
    if (!self.lexer.ts_mode) return false;
    Token import_tok = self.advance()!;
    if (self.peek_type() != TokenType.IDENTIFIER || self.lexer.seen_line_term) {
        self.pushback(import_tok);
        return false;
    }
    Token maybe_type = self.advance()!;
    if (!ident_is(maybe_type.str_value, "type")) {
        self.pushback(maybe_type);
        self.pushback(import_tok);
        return false;
    }
    self.ts_swallow_to_semi()!;
    return true;
}

// `export interface I { }`, `export declare var x;`, `export namespace N { }`:
// erased type-only declarations that are valid without a module scope.
fn bool? CompilerContext.ts_try_skip_type_only_export_decl(&self) {
    if (!self.lexer.ts_mode) return false;
    Token export_tok = self.advance()!;
    TokenType nt = self.peek_type();
    if (nt == TokenType.INTERFACE) {
        if (catch _e = self.ts_interface_declaration()) { self.pushback(export_tok); return false; }
        return true;
    }
    if (nt == TokenType.IDENTIFIER && !self.lexer.seen_line_term) {
        if (self.ts_try_declare_statement()) return true;
        if (self.ts_try_type_only_namespace()) return true;
    }
    self.pushback(export_tok);
    return false;
}

// `export type X = T;` and `export type { A, B } from "x"`: consume and discard.
// The alias form goes through skip_generic_params + skip_type so multi-line
// generic parameter lists and conditionals parse structurally; the brace-list
// re-export form stays with ts_swallow_to_semi.
fn bool? CompilerContext.ts_try_skip_type_only_export(&self) {
    if (!self.lexer.ts_mode) return false;
    Token export_tok = self.advance()!;
    if (self.peek_type() != TokenType.IDENTIFIER || self.lexer.seen_line_term) {
        self.pushback(export_tok);
        return false;
    }
    Token maybe_type = self.advance()!;
    if (!ident_is(maybe_type.str_value, "type")) {
        self.pushback(maybe_type);
        self.pushback(export_tok);
        return false;
    }
    if (self.peek_type() == TokenType.IDENTIFIER && !self.lexer.seen_line_term) {
        Token _name = self.advance()!!;
        if (self.check(TokenType.LT)) {
            if (catch _e = self.skip_generic_params()) return true;
        }
        if (!self.match(TokenType.ASSIGN)) return true;
        if (catch _e = self.skip_type()) return true;
        self.match(TokenType.SEMICOLON);
        return true;
    }
    self.ts_swallow_to_semi()!;
    return true;
}

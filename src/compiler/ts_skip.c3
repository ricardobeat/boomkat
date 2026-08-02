module duktape::compiler;

import duktape::types;
import duktape::lexer;
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

/// Returns true if the token type can appear inside a TypeScript type expression
/// at any depth. Delimiters like `,` `)` `]` `}` `;` `=` are the type
/// terminators — see skip_type() for stop logic.
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

/// Consume a full TypeScript type expression by bracket balancing.
///
/// Precondition: caller has verified we are at the start of a type context
/// (e.g. just consumed a `:` in an annotation, or `<` opening a generic).
/// Postcondition: cursor is positioned at the first delimiter that ends the
/// type — that delimiter is NOT consumed.
///
/// Depth is tracked for `<>`, `[]`, `{}`, `()`. At depth 0 the skipper stops
/// at `,` `)` `]` `}` `;` `=` `EOF` or an `ARROW` that is not part of a
/// function-type production (function-type `=>` occurs only inside a `(...)`
/// group, so it never appears at depth 0 unless the caller invoked us
/// inside a paren list — in which case the outer skipper counts it as
/// intra-type when a paren depth is open).
fn void? CompilerContext.skip_type(&self) {
    int paren   = 0;
    int bracket = 0;
    int brace   = 0;
    int angle   = 0;
    bool consumed_any = false;

    for (;;) {
        TokenType tt = self.peek_type();
        int depth = paren + bracket + brace + angle;

        if (depth == 0) {
            switch (tt) {
                case TokenType.EOF_TOKEN:
                case TokenType.SEMICOLON:
                case TokenType.COMMA:
                case TokenType.RPAREN:
                case TokenType.RBRACKET:
                case TokenType.RBRACE:
                case TokenType.ASSIGN:
                case TokenType.ARROW:
                    return;
                default:
                    break;
            }
            // `{` at depth 0 after we've already consumed something is the
            // start of the enclosing function/class body, not part of the
            // type. Only allow `{` as the *first* token (object type).
            if (tt == TokenType.LBRACE && consumed_any) {
                return;
            }
        }

        Token _skip = self.advance()!;
        consumed_any = true;

        switch (tt) {
            case TokenType.LPAREN:   paren++;
            case TokenType.RPAREN:   if (paren > 0) paren--;
            case TokenType.LBRACKET: bracket++;
            case TokenType.RBRACKET: if (bracket > 0) bracket--;
            case TokenType.LBRACE:   brace++;
            case TokenType.RBRACE:   if (brace > 0) brace--;
            case TokenType.LT:       angle++;
            // GT and its multi-char cousins that appear when angle-brackets close.
            case TokenType.GT:       if (angle > 0) angle--;
            case TokenType.GE:       if (angle > 0) angle--;  // `>=` at end of generic like `T=>`
            case TokenType.SHR:      if (angle >= 2) { angle -= 2; } else if (angle == 1) angle--;
            case TokenType.USHR:     if (angle >= 3) { angle -= 3; } else if (angle > 0) angle = 0;
            case TokenType.EOF_TOKEN:
                return;  // safety net; loop guard above should have exited
            default:
                break;
        }
    }
}

/// Skip a TypeScript generic type-parameter list `<T, U extends V, const W>`.
/// Precondition: the current token is `<`.
/// Postcondition: the `>` (or `>>`, `>>>`) closing the outermost generic
/// group has been consumed.
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

/// Skip a TypeScript object/interface body `{ ... }`.
/// Precondition: current token is `{`.
/// Postcondition: matching `}` has been consumed.
fn void? CompilerContext.skip_braced_body(&self) {
    Token _skip_open = self.expect(TokenType.LBRACE)!;
    int brace = 1;
    while (brace > 0) {
        TokenType tt = self.peek_type();
        if (tt == TokenType.EOF_TOKEN) {
            return self.fail("unterminated block")~;
        }
        Token _skip = self.advance()!;
        if (tt == TokenType.LBRACE) { brace++; }
        else if (tt == TokenType.RBRACE) { brace--; }
    }
}

/// True when `name` matches the given ASCII keyword. Used for contextual
/// TypeScript keywords (`type`, `as`, `satisfies`, `declare`, `readonly`,
/// `abstract`, `override`, `keyof`, `infer`, `is`, `asserts`, `namespace`,
/// `module`) that the lexer tokenizes as plain IDENTIFIERs.
fn bool ident_is(char[] name, char[] kw) @inline {
    if (name.len != kw.len) return false;
    for (usz i = 0; i < name.len; i++) {
        if (name[i] != kw[i]) return false;
    }
    return true;
}

/// If in ts_mode and the next token is `:`, consume it and skip the type.
/// No-op otherwise. Used at binding sites (variable, parameter, field).
fn void? CompilerContext.try_skip_ts_type_annotation(&self) {
    if (!self.lexer.ts_mode) return;
    if (self.peek_type() != TokenType.COLON) return;
    Token _colon = self.advance()!;
    self.skip_type()!;
}

/// If in ts_mode and the next token is `?` followed by `:`, `,`, `)`, `=`, or `]`,
/// consume the `?` (optional binding marker in params/fields). No-op otherwise.
fn void? CompilerContext.try_skip_ts_optional_marker(&self) {
    if (!self.lexer.ts_mode) return;
    if (self.peek_type() != TokenType.QUESTION) return;
    // Peek two ahead by consuming then pushing back
    Token q = self.advance()!;
    TokenType next = self.peek_type();
    if (next == TokenType.COLON || next == TokenType.COMMA ||
        next == TokenType.RPAREN || next == TokenType.ASSIGN ||
        next == TokenType.RBRACKET || next == TokenType.SEMICOLON) {
        return;
    }
    self.pushback(q);
}

/// If in ts_mode and the next token is `!` (definite-assignment marker on
/// a field or non-null postfix on a name), consume it.
fn void? CompilerContext.try_skip_ts_definite_marker(&self) {
    if (!self.lexer.ts_mode) return;
    if (self.peek_type() != TokenType.LOG_NOT) return;
    Token bang = self.advance()!;
    TokenType next = self.peek_type();
    if (next == TokenType.COLON || next == TokenType.ASSIGN ||
        next == TokenType.SEMICOLON) {
        return;
    }
    // Not a definite-assignment marker — put it back.
    self.pushback(bang);
}

/// If the current token is an IDENTIFIER with the given contextual-keyword
/// spelling, consume it and return true. Otherwise leave input untouched
/// and return false. Only active in `ts_mode`.
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

/// Skip a TypeScript `interface Foo<T> extends Bar { ... }` statement.
/// Precondition: current token is INTERFACE.
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

/// Try to parse a TypeScript `type X = ...;` alias.
/// Precondition: peek is the IDENTIFIER `type`.
/// Returns true if a type alias was consumed. Returns false if `type` was
/// used as an ordinary identifier (leaves input untouched).
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
    // Next must be an IDENTIFIER for a real type-alias declaration; otherwise
    // `type` was a variable reference. Also require the identifier to be on the
    // same line (TS restriction — line terminator between `type` and name
    // treats `type` as an identifier).
    if (self.peek_type() != TokenType.IDENTIFIER || self.lexer.seen_line_term) {
        self.pushback(kw);
        return false;
    }
    Token _name = self.advance()!!;
    if (self.check(TokenType.LT)) {
        if (catch _e = self.skip_generic_params()) return true;
    }
    if (!self.match(TokenType.ASSIGN)) return true;  // best effort — swallow rest until `;`
    if (catch _e = self.skip_type()) return true;
    self.match(TokenType.SEMICOLON);
    return true;
}

/// Try to parse a TypeScript `declare ...` ambient declaration.
/// Precondition: peek is the IDENTIFIER `declare`.
/// Returns true if consumed.
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
    if (self.lexer.seen_line_term) {
        self.pushback(kw);
        return false;
    }
    // Ambient declarations produce no runtime code. Swallow tokens until `;`
    // at depth 0 or a matching `}` if a `{` opens. This intentionally does
    // not distinguish declare var/function/class/module/enum — all yield no
    // runtime effects.
    int paren = 0;
    int bracket = 0;
    int brace = 0;
    bool saw_open = false;
    for (;;) {
        TokenType tt = self.peek_type();
        int depth = paren + bracket + brace;
        if (tt == TokenType.EOF_TOKEN) return true;
        if (depth == 0 && !saw_open && tt == TokenType.SEMICOLON) {
            Token _semi = self.advance()!!;
            return true;
        }
        if (depth == 0 && saw_open && brace == 0) {
            return true;
        }
        Token? adv = self.advance();
        if (catch _e = adv) return true;
        switch (tt) {
            case TokenType.LPAREN:   paren++;
            case TokenType.RPAREN:   if (paren > 0) paren--;
            case TokenType.LBRACKET: bracket++;
            case TokenType.RBRACKET: if (bracket > 0) bracket--;
            case TokenType.LBRACE:   brace++; saw_open = true;
            case TokenType.RBRACE:   if (brace > 0) brace--;
            default: break;
        }
    }
}

/// Non-consuming version of match_ts_ident.
fn bool CompilerContext.check_ts_ident(&self, char[] kw) {
    if (!self.lexer.ts_mode) return false;
    if (self.peek_type() != TokenType.IDENTIFIER) return false;
    // Peek the token text without consuming anything. The consuming variants
    // (match_ts_ident, ts_try_type_alias) are used where a mismatch can be
    // pushed back cleanly; here the check guards the statement dispatcher
    // before the label/expression fallthrough, and leaving a token on the
    // pushback stack would desync the lexer's position cache from the real
    // token stream (the label path refreshes token_start and re-pushes the
    // identifier into the lexer's single-slot pushback).
    if (self.pushback_count > 0) {
        return ident_is(self.pushback_stack[self.pushback_count - 1].str_value, kw);
    }
    Token? peek_opt = self.lexer.peek();
    if (catch _e = peek_opt) return false;
    return ident_is(peek_opt.str_value, kw);
}

/// Swallow all tokens until (and including) the terminating semicolon at
/// depth 0. Used to erase `import type ...` and `export type ...` forms which
/// have no runtime effect but may span multiple tokens including braces.
fn void? CompilerContext.ts_swallow_to_semi(&self) {
    int paren = 0;
    int bracket = 0;
    int brace = 0;
    for (;;) {
        TokenType tt = self.peek_type();
        int depth = paren + bracket + brace;
        if (tt == TokenType.EOF_TOKEN) return;
        if (depth == 0 && tt == TokenType.SEMICOLON) {
            Token _semi = self.advance()!;
            return;
        }
        // Also stop before EOF-adjacent tokens that clearly cannot belong to
        // this erased statement (defensive — TS import/export always end in
        // `;` or a newline-terminated statement per ASI).
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
        // ASI: if we hit a newline at depth 0 with no `;` in sight, stop too.
        if (depth == 0 && self.lexer.seen_line_term) {
            TokenType nt = self.peek_type();
            if (nt != TokenType.COMMA && nt != TokenType.DOT) return;
        }
    }
}

/// `import type ...` — consume and discard.
/// Also handles the mixed form `import { type Foo, bar } from "x"` by
/// only erasing the pure `import type` variant (leaves the mixed form for
/// the normal import_declaration path).
fn bool? CompilerContext.ts_try_skip_type_only_import(&self) {
    if (!self.lexer.ts_mode) return false;
    // We're positioned at `import`. Peek the next token *without consuming*
    // `import` — if it's the identifier `type`, this whole thing is erased.
    Token import_tok = self.advance()!; // consume `import`
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
    // Confirmed `import type ...` — swallow the rest.
    self.ts_swallow_to_semi()!;
    return true;
}

/// `export type X = T;` and `export type { A, B }` — consume and discard.
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
    self.ts_swallow_to_semi()!;
    return true;
}

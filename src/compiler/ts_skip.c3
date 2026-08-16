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

/// True if `tt` can end a TypeScript type expression, i.e. a `{` following
/// it at depth 0 opens the enclosing function/class/interface body rather
/// than an object type. Operator-ish tokens (`extends`, `|`, `&`, `?`, `:`,
/// `,`, `(`, `[`, `=`) expect a type to FOLLOW, so a `{` there is an object
/// type. Identifier-keyword prefixes (`keyof`, `infer`, `readonly`, ...) lex
/// as IDENTIFIER and are misclassified as completing; they are rare enough
/// before a literal `{` that the mis-stop is acceptable.
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

/// Contextual TypeScript operator keywords are lexed as plain IDENTIFIERs
/// but never END a type: `keyof`, `typeof`, `infer` and friends are always
/// followed by more type (`keyof { [k: string]: number }`), so a `{` or a
/// line break after one of them continues the type instead of ending it.
fn bool ts_ident_is_type_operator(char[] name) @inline {
    return ident_is(name, "keyof") || ident_is(name, "typeof")
        || ident_is(name, "infer") || ident_is(name, "as")
        || ident_is(name, "satisfies") || ident_is(name, "readonly")
        || ident_is(name, "is") || ident_is(name, "asserts")
        || ident_is(name, "abstract");
}

/// True if `tt` is a reserved word that can never appear inside a TypeScript
/// type expression (statement keywords like `enum`, `class`, `function`,
/// `if`). skip_type must stop on these: consuming one would swallow the
/// following statement (`type Meters = number\nenum E {...}` would eat
/// `enum E` and orphan the `{ x = 10 }` block). Type keywords (`new`,
/// `typeof`, `void`, `this`, `extends`) and `in` (mapped types) are
/// deliberately absent.
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
    // The token type consumed on the previous iteration. Used to tell a
    // function-type arrow `(a: T) => U` (which follows the group's closing
    // `)`, so it shows up at depth 0) from an arrow that terminates the type
    // context (e.g. the `=>` after a return-type annotation in `(): T => x`).
    TokenType prev_tt = TokenType.EOF_TOKEN;
    // Text of the previous consumed token. Needed where the token type alone
    // is ambiguous: a `{` or line break after an IDENTIFIER ends the type for
    // a type reference (`(): Foo {`, `var x: Foo\n...`) but continues it for
    // a contextual operator keyword (`keyof { ... }`).
    char[] prev_str = (char[])"";
    // Set when the previous iteration consumed a `}` that closed a top-level
    // object/mapped type (all depths 0). A type can only CONTINUE past that
    // with `|`, `&`, `extends`, `?` (conditional) or `[` (indexed access);
    // anything else starts the enclosing statement (`type T03 = ...` after
    // `type T02 = { ... };`), so the skipper must stop.
    bool just_closed_obj = false;

    for (;;) {
        TokenType tt = self.peek_type();
        // Template literal types (`` `text${T}` ``) are not lexed as a flat
        // token stream: the substitution's `}` must be consumed before the
        // lexer can scan the tail, so handle them atomically.
        if (tt == TokenType.TEMPLATE_HEAD) {
            self.skip_template_literal_type()!;
            continue;
        }
        int depth = paren + bracket + brace + angle;

        if (just_closed_obj && depth == 0) {
            // `:` continues a conditional type (`T ? { a: U } : V`), the
            // others continue a union/intersection/extends/indexed-access.
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
                    // `(...) => U` at the top level: the group closed before
                    // the arrow, which belongs to the function type. Continue
                    // only when the arrow directly follows that `)`.
                    if (prev_tt == TokenType.RPAREN) break;
                    return;
                default:
                    break;
            }
            // `{` at depth 0 after we've already consumed something is the
            // start of the enclosing function/class/interface body when the
            // previous token completed a type (`): number {`); after an
            // operator it opens an object type (`T extends { a: U }`,
            // `Foo | { x: T }`, `keyof { ... }`). Only allow `{` as the
            // *first* token unconditionally (object type).
            if (tt == TokenType.LBRACE && consumed_any && ts_token_completes_type(prev_tt)
                && !(prev_tt == TokenType.IDENTIFIER && ts_ident_is_type_operator(prev_str))) {
                return;
            }
            // Line break after a completed type: ASI applies, so the type
            // ends unless the next token clearly continues it (union/
            // intersection/conditional operators, indexed access `[`,
            // function-type `=>`). Without this, `var x: T13` followed by a
            // `declare`/`type` statement on the next line would swallow that
            // statement's first identifier into the type and desync the ASI
            // check (seen_line_term describes the gap before the swallowed
            // token, which is a space, not the newline).
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

        // Import types `import("mod")` / `import("mod").T`: a module-path
        // string follows, so `import` is type syntax here, not a statement
        // keyword (which would otherwise stop the type via
        // ts_token_stops_type). Consume `import` and let the paren/angle
        // balancing below take the rest.
        if (self.lexer.ts_mode && tt == TokenType.IMPORT) {
            Token _imp = self.advance()!;
            continue;
        }

        // Statement keywords never appear inside a type expression; stop so
        // the following statement stays intact (see ts_token_stops_type).
        if (ts_token_stops_type(tt)) {
            return;
        }

        Token skip_tok = self.advance()!;
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
        prev_tt = tt;
        prev_str = skip_tok.str_value;
        if (tt == TokenType.RBRACE && brace == 0 && paren == 0 && bracket == 0 && angle == 0) {
            just_closed_obj = true;
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
        // Template literal types (`` `text${T}` ``) are not a flat token
        // stream: the substitution's `}` must be consumed and the tail
        // re-scanned before the next token is lexable, exactly as in
        // skip_type. The template's own `${`/`}` must not affect the angle
        // count.
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

/// Consume a template literal type `` `text${T}text${U}...` `` starting at
/// the TEMPLATE_HEAD token. Each substitution is skipped as a type, its
/// `${` is closed, and the tail re-scanned, exactly like the expression
/// parser's template handling (which the lexer's substitution state machine
/// requires: the tail is only lexable after the substitution's `}` is
/// consumed).
fn void? CompilerContext.skip_template_literal_type(&self) {
    for (;;) {
        Token _head = self.advance()!;
        // Skip the substitution type, stopping at its closing `}`.
        if (catch _e = self.skip_type()) return;
        self.expect(TokenType.RBRACE)!;
        Token tail = self.lexer.scan_template_after_expr()!;
        if (tail.type == TokenType.TEMPLATE_TAIL) return;
        if (tail.type != TokenType.TEMPLATE_MIDDLE) {
            return self.fail("unterminated template literal type")~;
        }
        // TEMPLATE_MIDDLE: another `${...}` substitution follows.
    }
}

/// Skip a TypeScript object/interface body `{ ... }`.
/// Precondition: current token is `{`.
/// Postcondition: matching `}` has been consumed.
///
/// Template-aware: an interface member can carry a template literal type
/// (`(): `text${T}``) whose substitution `}` must not close the body, and
/// the substitution's tail is only lexable once that `}` is consumed.
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

/// Consume a `declare namespace X { ... }` / `declare module "m" { ... }`
/// nested inside an already-open namespace body (erasable, unlike `declare
/// var`/`function`/`class`/`enum`). Non-destructive. Precondition: the
/// current token is the IDENTIFIER `declare`.
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
    // `declare` is only the ambient-modifier keyword when the declaration it
    // modifies follows on the SAME line; a line terminator in between makes
    // it an ordinary identifier expression. Peek the next token first, so
    // seen_line_term reflects the gap after `declare` (right after advance it
    // still describes the gap BEFORE it, i.e. the statement boundary).
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
    // class). Object types inside signatures (`declare function
    // f(x: {a: T}): T;`, `declare const x: {a: T} & {b: U};`) balance their
    // own braces and must NOT end the statement early, so only a `{` opened
    // by a body-taking declaration counts as the body. Angle brackets are
    // tracked too: `Promise<{...}>` must not close anything early.
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
        }
        // Template literal types in the signature (`` (x: `a${T}`): void ``)
        // are not a flat token stream: the substitution's `}` must be
        // consumed and the tail re-scanned, so handle them atomically (as
        // skip_type does) rather than counting their braces here. Checked
        // BEFORE advancing: skip_template_literal_type consumes the head
        // itself.
        if (tt == TokenType.TEMPLATE_HEAD) {
            if (catch _t = self.skip_template_literal_type()) return true;
            continue;
        }
        Token? adv = self.advance();
        if (catch _e = adv) return true;
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

/// Try to consume a TypeScript `namespace`/`module` declaration whose body
/// holds only type declarations (interfaces, type aliases, `declare`
/// statements, nested type-only namespaces, empty statements). tsc's
/// `--erasableSyntaxOnly` allows such namespaces, they emit no runtime code,
/// so the engine erases them. Returns true when consumed; false when the
/// construct is not a type-only namespace (caller reports the
/// erasable-syntax error) or is not a namespace at all.
/// Precondition: peek is the IDENTIFIER `namespace` or `module`.
fn bool CompilerContext.ts_try_type_only_namespace(&self) {
    if (!self.lexer.ts_mode) return false;
    Token kw_tok = self.advance()!!;
    // Name: identifier or dotted name, on the SAME line as the keyword. A
    // line terminator in between makes the keyword an ordinary identifier
    // (`namespace\nn { }` is `namespace; n { }` under ASI, a runtime block),
    // matching tsc's erasableSyntaxOnly rejection of that shape.
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
                // var/function/class/enum (and `declare` variants of them)
                // bodies make the namespace non-erasable (TS1294), matching
                // tsc: only interface/type-alias/nested-namespace members
                // are allowed.
                return false;
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
        // ASI: a line break before the next token at depth 0 ends the erased
        // declaration, unless the token continues the type across the break
        // (union/intersection operators, conditional-type arms, member
        // access, argument commas, function-type arrow). The check must run
        // before the token is consumed: seen_line_term after peek describes
        // the gap in front of the peeked token, and consuming first would eat
        // the first token of the next statement (`export type A = Str\nconst
        // q = 5` lost its `const`, and a following `console.log(...)` call
        // vanished whole because `.` kept the loop going).
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
        // Template literal types (`` `text${T}` ``) are not a flat token
        // stream: the substitution's `}` must be consumed and the tail
        // re-scanned before the next token is lexable (same as skip_type).
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

/// `export interface I { }`, `export declare var x;`, `export namespace N { }`
/// — erased type-only declarations that, like `export type`, are valid
/// without a module scope. Consume the `export` then hand off to the
/// per-declaration skipper. Non-destructive on failure.
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

/// `export type X = T;` and `export type { A, B } from "x"` — consume and
/// discard. The alias form goes through skip_generic_params + skip_type so
/// multi-line generic parameter lists and multi-line conditional bodies
/// parse structurally; the brace-list re-export form is a flat token run
/// and stays with ts_swallow_to_semi.
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

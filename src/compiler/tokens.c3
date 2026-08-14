module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import std::io;

// ============================================================================
// Error recording helper
// ============================================================================

/// Record a compile error with the current lexer position, then return COMPILE_ERROR~.
/// Callers: `return self.fail("message")!;` or `return self.fail("message");`
macro fault CompilerContext.fail(&self, char[] msg) {
    if (self.lexer.err_msg[0] == 0) {
        self.lexer.err_line = self.lexer.line;
        self.lexer.err_col  = self.lexer.col;
        // Copy msg into fixed buffer (truncate if necessary, always NUL-terminate).
        usz copy_len = msg.len < (self.lexer.err_msg.len - 1) ? msg.len : (self.lexer.err_msg.len - 1);
        mem::copy(&self.lexer.err_msg[0], msg.ptr, (sz)(copy_len));
        self.lexer.err_msg[copy_len] = 0;
    }
    return COMPILE_ERROR;
}

/// Record a lexer error at the current position (first-writer-wins), naming
/// the offending character when it can be identified. Shared by advance()
/// and peek_type() on a failed next_token()/peek(): after a single-char lex
/// error the lexer has already advanced pos/col by one, so back up by one to
/// point at the offending character.
fn void CompilerContext.record_lex_error(&self) {
    if (self.lexer.err_msg[0] != 0) return;
    // An unterminated `/*` comment has no offending character to point at —
    // the lexer stopped at end-of-input — so name the construct instead of
    // reporting whatever byte happens to precede `pos`.
    if (self.lexer.unterminated_comment) {
        self.lexer.err_line = self.lexer.line;
        self.lexer.err_col  = self.lexer.col;
        char[] msg = "unterminated multi-line comment";
        usz copy_len = msg.len < (self.lexer.err_msg.len - 1) ? msg.len : (self.lexer.err_msg.len - 1);
        mem::copy(&self.lexer.err_msg[0], msg.ptr, (sz)(copy_len));
        self.lexer.err_msg[copy_len] = 0;
        return;
    }
    self.lexer.err_line = self.lexer.line;
    self.lexer.err_col  = self.lexer.col > 0 ? self.lexer.col - 1 : 0;
    uint bad_pos = self.lexer.pos > 0 ? self.lexer.pos - 1 : 0;
    if (bad_pos < (uint)self.lexer.source.len) {
        char c = self.lexer.source[bad_pos];
        char[128] buf;
        usz n = (usz)(io::bprintf(&buf, "unexpected character '%c' (not supported)", c) ?? buf[:0]).len;
        usz copy_len = n < (self.lexer.err_msg.len - 1) ? n : (self.lexer.err_msg.len - 1);
        mem::copy(&self.lexer.err_msg[0], &buf[0], (sz)(copy_len));
        self.lexer.err_msg[copy_len] = 0;
    } else {
        char[] msg = "unexpected end of input";
        usz copy_len = msg.len < (self.lexer.err_msg.len - 1) ? msg.len : (self.lexer.err_msg.len - 1);
        mem::copy(&self.lexer.err_msg[0], msg.ptr, (sz)(copy_len));
        self.lexer.err_msg[copy_len] = 0;
    }
}

// ============================================================================
// Token consumption helpers
// ============================================================================

/// Advance: consume the next token from the lexer and return it.
///
/// `as_ident_name` marks the positions whose grammar is an IdentifierName or
/// a BindingIdentifier rather than a ReservedWord terminal: an object-literal
/// or class-member key (`({ break: 1 })`, `class C { break(){} }`), a class
/// name (`class await {}`), and the lookaheads that must consume `static`
/// before they can tell the modifier from a member name. Escapes are legal in
/// all of those (§5.1.5), so the rejection below is skipped for them; a
/// lookahead that then resolves to the terminal re-applies the rule via
/// reject_escaped_reserved_word.
fn Token? CompilerContext.advance(&self, bool as_ident_name = false) {
    // Check pushback buffer first
    if (self.pushback_count > 0) {
        self.pushback_count--;
        return self.pushback_stack[self.pushback_count];
    }
    Token? tok_opt = self.lexer.next_token();
    if (catch _err = tok_opt) {
        self.record_lex_error();
        return COMPILE_ERROR~;
    }
    Token tok = tok_opt;
    // ES2024 §12.7.2: a ReservedWord is a terminal symbol and must appear
    // literally, so a spelling that uses a Unicode escape (`var`,
    // `break`) is neither the keyword nor a usable Identifier — it is
    // always a SyntaxError. The lexer resolves such a token to its keyword
    // type with has_escape set; reject it here, the one gate every
    // keyword-consuming parse path shares.
    //
    // Member-access names (`o.break`) are unaffected: read_property_name
    // reads straight off the lexer rather than through this function.
    if (tok.has_escape && tok.type != TokenType.IDENTIFIER && !as_ident_name) {
        return self.fail("keyword must not contain escaped characters")~;
    }
    return tok;
}

/// Expect the next token to be of the given type; consume and return it.
/// Returns COMPILE_ERROR if the type doesn't match.
fn Token? CompilerContext.expect(&self, TokenType tt) {
    Token tok = self.advance()!;
    if (tok.type != tt) {
        // Only record if no earlier error has already been captured.
        if (self.lexer.err_msg[0] == 0) {
            char[128] buf;
            char[] want = lexer::token_type_name(tt);
            char[] got  = lexer::token_type_name(tok.type);
            usz n = (usz)(io::bprintf(&buf, "expected '%s', got '%s'",
                                        (String)want, (String)got) ?? buf[:0]).len;
            self.lexer.err_line = tok.line;
            self.lexer.err_col  = tok.col;
            usz copy_len = n < (self.lexer.err_msg.len - 1) ? n : (self.lexer.err_msg.len - 1);
            mem::copy(&self.lexer.err_msg[0], &buf[0], (sz)(copy_len));
            self.lexer.err_msg[copy_len] = 0;
        }
        return COMPILE_ERROR~;
    }
    return tok;
}

/// Consume the next token as a BindingIdentifier and return it.
///
/// Per ES2024 §13.1 a BindingIdentifier is an Identifier, or `await` in a
/// context where it is not reserved: outside a module and outside an async
/// function/arrow (§13.1.1). A class static block additionally forbids it as a
/// binding name at its own top level (forbid_await); that flag resets in any
/// nested function/arrow body, matching how the spec's [Await] grammar
/// parameter is re-fixed at each function boundary. So the same `await` that
/// is a SyntaxError directly in a static block is a valid identifier inside a
/// non-async function/arrow nested in that block.
///
/// `yield` is never a BindingIdentifier here: §13.1.1 reserves it in all
/// strict-mode code, and this engine is strict-only (see AGENTS.md), so the
/// non-generator relaxation the spec grants to sloppy code never applies.
///
/// The returned token's str_value carries the name for the keyword token
/// (the lexer fills it in), so callers use it exactly like a plain IDENTIFIER.
///
/// The §13.1.1 restricted names (`eval`, `arguments`, `let`, `static`, the
/// future reserved words, ...) are rejected here rather than at each call
/// site: every BindingIdentifier position shares the restriction, so folding
/// it in is what keeps `function eval(){}` and `for (var eval in o)` from
/// diverging from the parameter lists that already checked by hand. Only the
/// plain IDENTIFIER path is checked, an `await` accepted through
/// await_is_identifier has already had its enclosing-grammar decision made and
/// must not be re-rejected by the context-blind name test.
fn Token? CompilerContext.expect_binding_identifier(&self) {
    TokenType next = self.peek_type();
    if (next == TokenType.IDENTIFIER) {
        Token tok = self.advance()!;
        if (is_restricted_name(tok.str_value)) {
            return self.fail("reserved word cannot be used as a binding identifier")~;
        }
        return tok;
    }
    if (self.await_is_identifier(next)) {
        // A BindingIdentifier position wants an Identifier, not the `await`
        // terminal, so an escaped spelling is a plain name here (§5.1.5) —
        // the mirror of advance()'s rejection where the terminal is required.
        return self.advance(true)!;
    }
    return self.expect(TokenType.IDENTIFIER)!;
}

/// True when an AWAIT token in this context is a plain IdentifierName rather
/// than the start of an AwaitExpression, per the §13.1.1 rule spelled out on
/// expect_binding_identifier: `await` is reserved in a module, in an async
/// function/arrow, and at a class static block's own top level (forbid_await),
/// and is an ordinary identifier everywhere else.
///
/// Callers pass the already-peeked token type so this stays usable from a
/// dispatch switch that has the type in hand.
fn bool CompilerContext.await_is_identifier(&self, TokenType tt) {
    return tt == TokenType.AWAIT && self.await_reserved_here() == false;
}

/// True when this context reserves `await`, i.e. when the [Await] grammar
/// parameter is set: module code, an async function/arrow/method, or a class
/// static block's own top level (forbid_await).
///
/// This is the context half of await_is_identifier, split out for the callers
/// that test a name rather than a token type. is_restricted_name takes the
/// reservation as its `in_async_or_module` argument, so those call sites pass
/// this instead of respelling the three flags — the by-name and by-token-type
/// answers cannot then drift apart.
fn bool CompilerContext.await_reserved_here(&self) {
    return self.is_async || self.is_module || self.forbid_await;
}

/// True when the next token can start an Identifier: a plain IDENTIFIER, or
/// `await` in a context where it is not reserved (§13.1.1). LabelIdentifier
/// (§14.13) and BindingIdentifier (§13.1) both reduce to Identifier, so the
/// label sites (`await: ;` defining it, `break await;` referencing it) and the
/// arrow-head detection scan share this one test and cannot drift apart.
fn bool CompilerContext.peek_is_binding_identifier(&self) {
    TokenType tt = self.peek_type();
    return tt == TokenType.IDENTIFIER || self.await_is_identifier(tt);
}

/// If the next token matches `tt`, consume it and return true.
/// Otherwise leave it unconsumed and return false.
fn bool CompilerContext.match(&self, TokenType tt) {
    if (self.check(tt)) {
        if (try _tok = self.advance()) {
            return true;
        }
    }
    return false;
}

/// Terminate a statement or class field per automatic semicolon insertion
/// (ES2024 §12.10.1). An explicit `;` is consumed. Otherwise termination is
/// only legal when the offending token is `}` or EOF, or a line terminator
/// precedes it, ASI never glues two tokens on the same line together, so
/// anything else is a SyntaxError (e.g. `using x = 1`, `class A { accessor
/// x }`). The do-while trailing semicolon is exempt (§12.10.1 note 1) and
/// does NOT go through this helper.
fn void? CompilerContext.expect_semicolon_or_asi(&self) {
    if (self.match(TokenType.SEMICOLON)) return;
    TokenType next = self.peek_type();
    if (next == TokenType.RBRACE || next == TokenType.EOF_TOKEN) return;
    if (self.lexer.seen_line_term) return;
    return self.fail("expected ';' or line break after statement")~;
}

/// Peek at the next token type without consuming.
fn TokenType CompilerContext.peek_type(&self) {
    // Check pushback buffer first
    if (self.pushback_count > 0) {
        return self.pushback_stack[self.pushback_count - 1].type;
    }
    Token? peek_opt = self.lexer.peek();
    if (catch _peek_err = peek_opt) {
        self.record_lex_error();
        return TokenType.EOF_TOKEN;
    }
    return peek_opt.type;
}

/// Check if the next token is the given type without consuming.
fn bool CompilerContext.check(&self, TokenType tt) {
    return self.peek_type() == tt;
}

/// Check for `=>` as an arrow head terminator.
///
/// ES2024 §15.3: `ArrowFunction : ArrowParameters [no LineTerminator here] =>
/// ConciseBody`. A line terminator between the parameters and `=>` is a
/// SyntaxError, and since ASI cannot insert a semicolon before `=>` (it is
/// never a valid statement start) the whole construct is rejected. Every
/// arrow-detection site must use this instead of `check(TokenType.ARROW)`, so
/// that `x \n => x` fails to parse rather than silently becoming an arrow.
/// `check` forces the lookahead scan, so `seen_line_term` describes the
/// whitespace immediately before the `=>` once it has returned true.
fn bool CompilerContext.check_arrow(&self) {
    return self.check(TokenType.ARROW) && !self.lexer.seen_line_term;
}

/// Read the next token as a property name (IdentifierName).
/// After '.' or other contexts where any keyword can be used as a name,
/// this returns the string value regardless of whether the token is an
/// IDENTIFIER or a keyword token.
fn char[]? CompilerContext.read_property_name(&self) {
    Token? tok_opt = self.lexer.next_token();
    if (catch err = tok_opt) return COMPILE_ERROR~;
    Token tok = tok_opt;
    if (tok.str_value.len > 0) return tok.str_value;
    char[] kw_str = lexer::keyword_to_string(tok.type);
    if (kw_str.len > 0) return kw_str;
    self.record_error("expected a property name after '.'");
    return COMPILE_ERROR~;
}

/// Check if the next token is a template literal token (backtick-originated).
/// Only returns true for tokens that START a template literal (TEMPLATE, TEMPLATE_HEAD,
/// or STRING with is_template). Does NOT return true for TEMPLATE_MIDDLE or TEMPLATE_TAIL
/// which appear only inside an already-in-progress template parse.
fn bool CompilerContext.is_next_template(&self) {
    // Check compiler pushback buffer first
    if (self.pushback_count > 0) {
        Token tok = self.pushback_stack[self.pushback_count - 1];
        return (tok.type == TokenType.STRING && tok.is_template)
            || tok.type == TokenType.TEMPLATE
            || tok.type == TokenType.TEMPLATE_HEAD;
    }
    if (try tok = self.lexer.peek()) {
        return (tok.type == TokenType.STRING && tok.is_template)
            || tok.type == TokenType.TEMPLATE
            || tok.type == TokenType.TEMPLATE_HEAD;
    }
    return false;
}

/// Returns true if we've reached the end of input.
fn bool CompilerContext.is_at_end(&self) {
    return self.peek_type() == TokenType.EOF_TOKEN;
}

/// Peek two tokens ahead: true if the token AFTER the current (unconsumed)
/// token is `(`. Used to distinguish a private method (`#m(...)`) from a
/// private field (`#m = expr` / `#m;`), both start with the same
/// HASH_IDENT current token. Non-destructive: the current token remains
/// unconsumed on return.
fn bool CompilerContext.peek2_is_lparen(&self) {
    Token? cur_opt = self.advance();
    if (catch _e = cur_opt) return false;
    Token cur = cur_opt;
    TokenType next_tt = self.peek_type();
    self.pushback(cur);
    return next_tt == TokenType.LPAREN;
}

/// Conservative lookahead: could the expression starting at the current token
/// write to some local variable's home register before the enclosing binary
/// operator consumes its left operand?
///
/// Used by binary_expr to decide whether `a op b` must copy a's value to a
/// temp before compiling b. Only an assignment (`=`, `+=`, …), an update
/// (`++`/`--`) or a call (which may reach an assignment in a callee that
/// shares no registers, but also covers `eval`-like surprises) can do that.
///
/// Deliberately an over-approximation scanned over raw tokens rather than a
/// parse: a false positive costs one LDREG in an uncommon shape, a false
/// negative is a miscompile. It stops at the first token that cannot be part
/// of the right operand at this precedence, and bails out (returning true) if
/// the scan runs long, so it is O(1) amortised on ordinary code.
///
/// Non-destructive: the lexer, its lookahead and the compiler pushback stack
/// are all restored before returning.
fn bool CompilerContext.rhs_may_write_registers(&self) {
    // A pending pushback would have to be replayed in order; rather than
    // reimplement that, treat it as "unknown" and take the safe answer.
    if (self.pushback_count > 0) return true;

    Lexer saved_lexer = *self.lexer;

    bool result = false;
    int depth = 0;          // nesting of ( [ {; the operand ends at depth 0
    const int SCAN_LIMIT = 64;

    for (int n = 0; n < SCAN_LIMIT; n++) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _e = tok_opt) { result = true; break; }
        Token tok = tok_opt;
        TokenType tt = tok.type;

        if (tt == TokenType.EOF_TOKEN) break;

        if (tt == TokenType.LPAREN || tt == TokenType.LBRACKET ||
            tt == TokenType.LBRACE) {
            depth++;
            continue;
        }
        if (tt == TokenType.RPAREN || tt == TokenType.RBRACKET ||
            tt == TokenType.RBRACE) {
            // Closing past our own start means the operand is over.
            depth--;
            if (depth < 0) break;
            continue;
        }

        if (token_is_assignment_op(tt) ||
            tt == TokenType.INC || tt == TokenType.DEC) {
            result = true;
            break;
        }

        // At depth 0, a comma or a statement terminator ends the operand.
        if (depth == 0 &&
            (tt == TokenType.COMMA || tt == TokenType.SEMICOLON ||
             tt == TokenType.COLON)) {
            break;
        }

        if (n == SCAN_LIMIT - 1) { result = true; }
    }

    self.swap_lexer_preserving_error(saved_lexer);
    return result;
}

/// Swap in a lexer state (speculative scan / re-parse window) while preserving
/// the per-compilation error fields. The error state lives on the Lexer, so a
/// plain `*self.lexer = snapshot` restore would wipe a message a fault
/// recorded inside the window; keep whichever error was recorded first across
/// the swap (the incoming state's err fields are discarded).
fn void CompilerContext.swap_lexer_preserving_error(&self, Lexer incoming) {
    char[512] kept;
    usz kept_len = 0;
    uint kept_line = self.lexer.err_line;
    uint kept_col = self.lexer.err_col;
    if (self.lexer.err_msg[0] != 0) {
        while (kept_len < kept.len - 1 && self.lexer.err_msg[kept_len] != 0) {
            kept[kept_len] = self.lexer.err_msg[kept_len];
            kept_len++;
        }
        kept[kept_len] = 0;
    }
    *self.lexer = incoming;
    if (kept_len > 0) {
        mem::copy(&self.lexer.err_msg[0], &kept[0], (sz)kept_len);
        self.lexer.err_msg[kept_len] = 0;
        self.lexer.err_line = kept_line;
        self.lexer.err_col = kept_col;
    }
}

/// Capture the current scan position as a LexerPos, for a later seek_lexer_to.
/// Only valid at a statement boundary, where no token has been read ahead: a
/// LexerPos records the cursor, not the token stream state (see NameSpan.fn_pos
/// for why the whole Lexer is not copied).
fn LexerPos CompilerContext.capture_lexer_pos(&self) {
    return {
        .pos                     = self.lexer.pos,
        .line                    = self.lexer.line,
        .col                     = self.lexer.col,
        .at_line_start           = self.lexer.at_line_start,
        .force_regex_after_brace = self.lexer.force_regex_after_brace,
        .seen_line_term          = self.lexer.seen_line_term,
    };
}

/// Rewind the lexer to a position captured by capture_lexer_pos, discarding any
/// lookahead/pushback so the next token is re-scanned from `p`. Everything not
/// in LexerPos (error state, arena, ts_mode, ...) is per-compilation and stays
/// as-is. The compiler-level pushback stack is the caller's to reset.
fn void CompilerContext.seek_lexer_to(&self, LexerPos p) {
    self.lexer.pos                     = p.pos;
    self.lexer.line                    = p.line;
    self.lexer.col                     = p.col;
    self.lexer.at_line_start           = p.at_line_start;
    self.lexer.force_regex_after_brace = p.force_regex_after_brace;
    self.lexer.seen_line_term          = p.seen_line_term;
    self.lexer.has_lookahead           = false;
    self.lexer.has_pushed_back         = false;
    self.lexer.token_start             = p.pos;
    self.lexer.lookahead_token_start   = p.pos;
}

/// Push a token back into the input stream for backtracking.
/// The next call to advance() will return this token.
/// Supports up to 4 tokens of lookback.
fn void CompilerContext.pushback(&self, Token tok) {
    if (self.pushback_count < 4) {
        self.pushback_stack[self.pushback_count] = tok;
        self.pushback_count++;
    }
}

/// Detect the `async` prefix for function declarations/expressions
/// (ES2017 §14.7 Async Function Definitions).
/// Returns true and consumes the `async` token if the current token is
/// the identifier "async" (NOT written via Unicode escapes, an escaped
/// `async` is a regular IdentifierName, never the contextual keyword),
/// followed by `function` on the SAME line (the `[no LineTerminator here]`
/// restriction between `async` and `function`).  Returns false and leaves
/// the input untouched otherwise, including when `async` was a method
/// call like `async(x) => ...` or a method named `async`.
fn bool CompilerContext.match_async_function(&self) {
    if (self.peek_type() != TokenType.IDENTIFIER) return false;
    Token? cur_opt = self.advance();
    if (catch _e = cur_opt) return false;
    Token cur = cur_opt;
    // Check the identifier name is "async"
    if (cur.str_value.len != 5) {
        self.pushback(cur);
        return false;
    }
    if (cur.str_value[0] != 'a' || cur.str_value[1] != 's' ||
        cur.str_value[2] != 'y' || cur.str_value[3] != 'n' ||
        cur.str_value[4] != 'c') {
        self.pushback(cur);
        return false;
    }
    // Escaped `async` (`\u0061sync` etc.) is a plain IdentifierName, never
    // the contextual keyword (ES2024 §5.1.5, terminal symbols must appear
    // exactly as written). Backtrack; the parser falls through to identifier
    // handling (the identifier will resolve at runtime, or throw ReferenceError
    // if unbound).
    if (cur.has_escape) {
        self.pushback(cur);
        return false;
    }
    // Look up the next token WITHOUT consuming it: on a true result the
    // function body (and everything after) must remain unconsumed so the
    // inner-function compiler reads it directly off the shared lexer; the
    // compiler pushback stack is invisible to inner contexts.
    Token next_tok;
    if (self.pushback_count > 0) {
        next_tok = self.pushback_stack[self.pushback_count - 1];
    } else {
        Token? peek_opt = self.lexer.peek();
        if (catch _e = peek_opt) {
            self.pushback(cur);
            return false;
        }
        next_tok = peek_opt;
    }
    if (next_tok.type != TokenType.FUNCTION) {
        // `async` was used as a regular identifier (e.g., variable or arrow param)
        self.pushback(cur);
        return false;
    }
    // [no LineTerminator here] between `async` and `function` (ES2017 §14.7).
    // Without this, `async\nfunction f(){}` would parse as an AsyncFunction
    // declaration when the spec requires it to be two statements: an identifier
    // reference (which throws ReferenceError) followed by a regular FunctionDeclaration.
    if (next_tok.line != cur.line) {
        self.pushback(cur);
        return false;
    }
    // Consume was the `async`; next call to advance() will return `function`.
    return true;
}

/// Detect the `async` prefix for arrow functions: `async x => ...` or
/// `async (params) => ...`. Pure lookahead, never consumes any tokens,
/// so the caller decides when to advance past `async` on a true result.
/// Returns true if the current token is the identifier "async" (NOT
/// written via Unicode escapes, ES2024 §5.1.5 forbids escape recognition
/// for terminal symbols), is on the SAME line as the next token, and is
/// followed by either `IDENTIFIER ARROW` (`async x => ...`) or an `LPAREN`
/// (`async (params) => ...`; shape-only, the LPAREN speculative-arrow
/// scan in primary_expr decides if it truly resolves to an arrow).
/// Returns false in all other cases, including any of:
///   - `escaped` (`\u0061sync ...`)
///   - line terminator between `async` and the binding identifier / `(`
///   - `async` followed by anything other than IDENTIFIER or LPAREN on
///     the same line (e.g. `async;`, `async = ...`)
fn bool CompilerContext.is_async_arrow_lookahead(&self) {
    if (self.peek_type() != TokenType.IDENTIFIER) return false;
    Token? cur_opt = self.advance();
    if (catch _e = cur_opt) return false;
    Token cur = cur_opt;
    if (cur.str_value.len != 5 ||
        cur.str_value[0] != 'a' || cur.str_value[1] != 's' ||
        cur.str_value[2] != 'y' || cur.str_value[3] != 'n' ||
        cur.str_value[4] != 'c') {
        self.pushback(cur);
        return false;
    }
    // Escaped `async` is a plain IdentifierName, never the contextual keyword.
    if (cur.has_escape) {
        self.pushback(cur);
        return false;
    }
    // Read the next token WITHOUT consuming it: we must leave `async` and
    // the following tokens in place, the caller's primary_expr() will
    // advance past `async` and re-enter, and on the IDENTIFIER-ARROW path
    // the binding identifier + `=>` are then consumed fresh.
    Token next_tok;
    if (self.pushback_count > 0) {
        next_tok = self.pushback_stack[self.pushback_count - 1];
    } else {
        Token? peek_opt = self.lexer.peek();
        if (catch _e = peek_opt) {
            self.pushback(cur);
            return false;
        }
        next_tok = peek_opt;
    }
    if (next_tok.type == TokenType.LPAREN) {
        // [no LineTerminator here] before the `(`.  When satisfied we treat
        // this as an `async ( ... ) => ...` cover call; when violated the
        // spec's `async` is just an identifier expr statement and the `(`
        // starts a separate expression.
        if (next_tok.line != cur.line) {
            self.pushback(cur);
            return false;
        }
        self.pushback(cur);
        return true;
    }
    if (next_tok.type == TokenType.LT && self.lexer.ts_mode) {
        // `async <T, U>(params) => ...`: a TypeScript generic type-parameter
        // list between `async` and the parameter list. Probe it: skip the
        // list and require `(` on the same line. Non-destructive.
        if (next_tok.line != cur.line) {
            self.pushback(cur);
            return false;
        }
        Lexer saved_lk = *self.lexer;
        bool ok = false;
        if (catch _e = self.skip_generic_params()) {
            *self.lexer = saved_lk;
        } else if (self.check(TokenType.LPAREN)) {
            ok = true;
            *self.lexer = saved_lk;
        } else {
            *self.lexer = saved_lk;
        }
        if (!ok) {
            self.pushback(cur);
            return false;
        }
        self.pushback(cur);
        return true;
    }
    if (next_tok.type == TokenType.IDENTIFIER) {
        // [no LineTerminator here] between `async` and the binding identifier.
        // Without this, `async\nx => {}` would parse as an AsyncArrowFunction,
        // but per ES2017 §14.7 it must be two expression statements: an
        // identifier reference (throws ReferenceError if unbound) and a plain
        // arrow function.
        if (next_tok.line != cur.line) {
            self.pushback(cur);
            return false;
        }
        // Speculative 2-token lookahead: consume the binding identifier, peek
        // at the token after it, then put both back. Restoring via pushback
        // is safe here because the caller's primary_expr() will advance past
        // `async` (which we already pushed back) and reach the binding
        // identifier fresh from the lexer/lookahead.
        Token? next_opt = self.advance();
        if (catch _e = next_opt) {
            self.pushback(cur);
            return false;
        }
        Token second_tok = next_opt;
        bool is_arrow = self.check_arrow();
        self.pushback(second_tok);
        self.pushback(cur);
        return is_arrow;
    }
    self.pushback(cur);
    return false;
}

/// Detect the `async` modifier for method shorthand in class bodies and
/// object literals (ES2017 §14.6): identifier "async" followed, on the
/// same line, per the [no LineTerminator here] restriction, by a token
/// that can start a method name: identifier, keyword, string, number,
/// `[` (computed key), or `*` (async generator method). It is NOT a modifier
/// when followed by `(` (a method
/// literally named `async`), `:` (property key), `,` / `}` (shorthand
/// property), or `=` (cover-initializer).
/// Consumes the `async` token and returns true when it is a modifier;
/// otherwise leaves the input untouched and returns false.
fn bool CompilerContext.match_async_method_prefix(&self) {
    if (self.peek_type() != TokenType.IDENTIFIER) return false;
    Token? cur_opt = self.advance();
    if (catch _e = cur_opt) return false;
    Token cur = cur_opt;
    if (cur.str_value.len != 5 ||
        cur.str_value[0] != 'a' || cur.str_value[1] != 's' ||
        cur.str_value[2] != 'y' || cur.str_value[3] != 'n' ||
        cur.str_value[4] != 'c') {
        self.pushback(cur);
        return false;
    }
    // Escaped `async` (`async m(){}`) is a plain IdentifierName, never
    // the contextual keyword (ES2024 §5.1.5), so it does not introduce an
    // async method — same rule as match_async_function_prefix and
    // is_async_arrow_lookahead.
    if (cur.has_escape) {
        self.pushback(cur);
        return false;
    }
    // Peek the following token WITHOUT consuming it, on a true result the
    // method name (and everything after) must remain unconsumed so that
    // compile_inner_function, which builds a fresh context reading the shared
    // lexer directly, still sees it (compiler-context pushbacks would be
    // invisible to the inner context).
    Token next_tok;
    uint next_src_start = 0xFFFFFFFF;
    if (self.pushback_count > 0) {
        next_tok = self.pushback_stack[self.pushback_count - 1];
    } else {
        Token? peek_opt = self.lexer.peek();
        if (catch _e = peek_opt) {
            self.pushback(cur);
            return false;
        }
        next_tok = peek_opt;
        // The peek stored the element's source start, record it so the
        // class compiler can retain source text that begins at the method
        // (excluding `static`, per §14.6/§19.2.3.5 method source retention).
        next_src_start = self.lexer.lookahead_token_start;
    }
    if (next_tok.line != cur.line) {
        // [no LineTerminator here] between `async` and the method name.
        self.pushback(cur);
        return false;
    }
    bool starts_name = next_tok.type == TokenType.IDENTIFIER
        || next_tok.type == TokenType.STRING
        || next_tok.type == TokenType.NUMBER
        || next_tok.type == TokenType.LBRACKET
        || next_tok.type == TokenType.STAR
        || next_tok.type == TokenType.HASH_IDENT
        || lexer::keyword_to_string(next_tok.type).len > 0;
    if (!starts_name) {
        self.pushback(cur);
        return false;
    }
    return true;  // `async` stays consumed
}

/// Detect the `static` modifier in class bodies: only consume `static` as a
/// modifier when it is followed by a token that can start a method definition
/// (identifier, keyword, string, number, `[` computed key, `*` generator,
/// or the `get`/`set` accessor prefixes followed by a property name).
/// When followed by `(`, `;`, `,`, `}` etc., `static` is the method name
/// itself, NOT a modifier.
/// Returns true and consumes the `static` token if it is a modifier;
/// otherwise leaves the input untouched and returns false.
/// A lexer failure while looking ahead is a hard syntax error, not a
/// "`static` is the member name" signal: reinterpreting it that way would
/// silently accept unlexable member names such as `static # x;`.
fn bool? CompilerContext.match_static_modifier(&self) {
    self.static_elem_src_start = 0xFFFFFFFF;
    if (self.peek_type() != TokenType.STATIC) return false;
    Token cur = self.advance(true)!;
    // Peek the following token WITHOUT consuming it, on a true result the
    // method name (and everything after) must remain unconsumed so that
    // compile_inner_function, which builds a fresh context reading the shared
    // lexer directly, still sees it (compiler-context pushbacks would be
    // invisible to the inner context).
    Token next_tok;
    uint next_src_start = 0xFFFFFFFF;
    if (self.pushback_count > 0) {
        next_tok = self.pushback_stack[self.pushback_count - 1];
    } else {
        next_tok = self.lexer.peek()!;
        // The peek stored the element's source start, record it so the
        // class compiler can retain source text that begins at the method
        // (excluding `static`, per §14.6/§19.2.3.5 method source retention).
        next_src_start = self.lexer.lookahead_token_start;
    }
    if (next_tok.line != cur.line) {
        // [no LineTerminator here] between `static` and the method name.
        self.pushback(cur);
        return false;
    }
    // `get` and `set` are identifiers that can be accessor prefixes.
    // `get static()` means a getter named "static" (NOT a static getter),
    // so we must peek past `get`/`set` to see if there's a property name.
    if (next_tok.type == TokenType.IDENTIFIER) {
        // Check if this identifier is "get" or "set" followed by a property name.
        bool is_accessor = (next_tok.str_value.len == 3
            && next_tok.str_value[0] == 'g'
            && next_tok.str_value[1] == 'e'
            && next_tok.str_value[2] == 't')
            || (next_tok.str_value.len == 3
            && next_tok.str_value[0] == 's'
            && next_tok.str_value[1] == 'e'
            && next_tok.str_value[2] == 't');
        if (is_accessor) {
            // `get`/`set` as accessor prefix: peek at the token AFTER `get`/`set`.
            // If it's followed by a property name token, `static` is a modifier
            // (e.g. `static get foo()`).  If it's followed by `(`, `;`, `,`, `}`,
            // then `get`/`set` is a plain method name, and `static` is also
            // a method name, NOT a modifier (e.g. `get static()`).
            Token after_accessor;
            if (self.pushback_count > 1) {
                after_accessor = self.pushback_stack[self.pushback_count - 2];
            } else {
                // Advance past the `get`/`set` token in the lexer to peek further.
                Token acc_tok = self.advance()!;
                Token? peek2_opt;
                if (self.pushback_count > 0) {
                    peek2_opt = self.pushback_stack[self.pushback_count - 1];
                } else {
                    peek2_opt = self.lexer.peek();
                }
                // Put back the `get`/`set` token before propagating, so a
                // failing lookahead still leaves the lexer well-formed.
                self.pushback(acc_tok);
                after_accessor = peek2_opt!;
            }
            // Whether `get`/`set` turns out to be an accessor prefix
            // (`static get foo()`) or a plain method name (`static get()`),
            // `static` itself is a modifier either way, the method name
            // position after `static` is occupied by `get`/`set`, so
            // `static` cannot be the member name here. Fall through.
            (void)after_accessor;
        }
    }
    bool starts_name = next_tok.type == TokenType.IDENTIFIER
        || next_tok.type == TokenType.STRING
        || next_tok.type == TokenType.NUMBER
        || next_tok.type == TokenType.LBRACKET
        || next_tok.type == TokenType.STAR
        || next_tok.type == TokenType.HASH_IDENT
        || lexer::keyword_to_string(next_tok.type).len > 0;
    if (!starts_name) {
        self.pushback(cur);
        return false;
    }
    self.reject_escaped_reserved_word(cur)!;
    self.static_elem_src_start = next_src_start;
    return true;  // `static` stays consumed as modifier
}

/// Reject a token that has been decided to occupy a *ReservedWord* position
/// once the lookahead that made the decision is complete.
///
/// `advance` gates escaped keywords at the point of consumption, but the two
/// `static` lookaheads must consume the token before they can tell a
/// modifier (`static m(){}`, `static { }` — terminal `static`, escapes
/// illegal) from a member NAME (`static(){}`, `static;` — IdentifierName,
/// escapes legal). They therefore consume with `as_ident_name` and call this
/// on the branches that resolved to the terminal, so both directions of
/// ES2024 §12.7.2 / §5.1.5 hold with one predicate rather than a second copy.
fn void? CompilerContext.reject_escaped_reserved_word(&self, Token tok) {
    if (tok.has_escape) {
        return self.fail("keyword must not contain escaped characters")~;
    }
}

/// Detect a class static initialization block (`static { ... }`, ES2022).
/// `{` can never start a PropertyName, so unlike match_static_modifier there
/// is no ASI ambiguity to resolve with a same-line check, `static` directly
/// followed by `{` (on any line) is always the ClassStaticBlock production,
/// never `static` used as a field/method name. Returns true and consumes the
/// `static` token if this is a static block; otherwise leaves the input
/// untouched and returns false.
/// As in match_static_modifier, a lookahead lexer failure propagates: the
/// failed peek has already advanced past the offending character, so
/// recovering here would resume mid-token and misparse the element.
fn bool? CompilerContext.match_static_block_prefix(&self) {
    if (self.peek_type() != TokenType.STATIC) return false;
    Token cur = self.advance(true)!;
    TokenType next_tt;
    if (self.pushback_count > 0) {
        next_tt = self.pushback_stack[self.pushback_count - 1].type;
    } else {
        next_tt = self.lexer.peek()!.type;
    }
    if (next_tt != TokenType.LBRACE) {
        self.pushback(cur);
        return false;
    }
    self.reject_escaped_reserved_word(cur)!;
    return true;  // `static` stays consumed as the block prefix
}

/// Skip tokens from the **lexer** (not the compiler pushback) until a SEMICOLON
/// or RPAREN is seen at paren/bracket depth 0.  The terminating token is NOT consumed.
/// Used by loop rotation to skip over the for-loop increment without emitting code.
/// Returns true on success, false on unexpected EOF or error.
///
/// Depth tracking: LPAREN/RPAREN increment/decrement a depth counter; the scan stops
/// when a SEMICOLON is seen at depth 0, or when a RPAREN is seen at depth 0.
fn bool CompilerContext.skip_expr_lex(&self) {
    // Skip tokens until matching ')' or ';' is found at depth 0. This must
    // additionally track function expressions (function NAME(args){body}) and
    // braces so an arrow/function body is not mistaken for an enclosing
    // template substitution or unbalanced paren. The function body braces are
    // tracked separately via a depth count so that `while (function() {x;})`
    // skips the body's `;` instead of stopping on it.
    int paren_depth = 0;
    int brace_depth = 0;
    // Template-aware (TemplateScan): a `${...}` substitution's `}` must be
    // consumed by scan_template_after_expr or the lexer re-lexes the template
    // tail as JS and the skip desyncs (e.g. `while (`abc${0}abc`)`).
    TemplateScan tscan;
    for (;;) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) { return false; }
        Token tok = tok_opt;
        switch (tok.type) {
            case TokenType.EOF_TOKEN: return false;
            case TokenType.LPAREN:   paren_depth++; continue;
            case TokenType.LBRACKET: paren_depth++; continue;
            case TokenType.RPAREN: {
                if (paren_depth == 0) {
                    // Put it back via the lexer's single-token pushback
                    self.lexer.pushed_back = tok;
                    self.lexer.has_pushed_back = true;
                    return true;
                }
                paren_depth--;
            }
            case TokenType.RBRACKET: {
                if (paren_depth > 0) { paren_depth--; }
            }
            // Function body `{...}`, keep balanced; its outer closing `}`
            // is consumed by the brace counter. `;` inside the body must
            // not terminate the skip.
            case TokenType.LBRACE:
                tscan.on_lbrace();
                brace_depth++;
                continue;
            case TokenType.RBRACE: {
                TemplateBrace tb = tscan.classify_rbrace(self.lexer);
                if (tb == TemplateBrace.LEX_ERROR) return false;
                if (tb == TemplateBrace.SUBST) continue;
                if (brace_depth > 0) brace_depth--;
                continue;
            }
            // Template literal substitutions: the `${...}` braces are owned
            // by the lexer/parser, not the function-body counter.
            case TokenType.TEMPLATE_HEAD:
                tscan.on_template_head();
                continue;
            case TokenType.SEMICOLON: {
                if (paren_depth == 0 && brace_depth == 0 && tscan.depth == 0) {
                    self.lexer.pushed_back = tok;
                    self.lexer.has_pushed_back = true;
                    return true;
                }
            }
            default: {}
        }
    }
}

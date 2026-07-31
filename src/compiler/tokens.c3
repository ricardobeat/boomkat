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
    if (g_last_err_msg[0] == 0) {
        g_last_err_line = self.lexer.line;
        g_last_err_col  = self.lexer.col;
        // Copy msg into fixed buffer (truncate if necessary, always NUL-terminate).
        usz copy_len = msg.len < (g_last_err_msg.len - 1) ? msg.len : (g_last_err_msg.len - 1);
        mem::copy(&g_last_err_msg[0], msg.ptr, (sz)(copy_len));
        g_last_err_msg[copy_len] = 0;
    }
    return COMPILE_ERROR;
}

/// Record a lexer error at the current position (first-writer-wins), naming
/// the offending character when it can be identified. Shared by advance()
/// and peek_type() on a failed next_token()/peek(): after a single-char lex
/// error the lexer has already advanced pos/col by one, so back up by one to
/// point at the offending character.
fn void CompilerContext.record_lex_error(&self) {
    if (g_last_err_msg[0] != 0) return;
    g_last_err_line = self.lexer.line;
    g_last_err_col  = self.lexer.col > 0 ? self.lexer.col - 1 : 0;
    uint bad_pos = self.lexer.pos > 0 ? self.lexer.pos - 1 : 0;
    if (bad_pos < (uint)self.lexer.source.len) {
        char c = self.lexer.source[bad_pos];
        char[128] buf;
        usz n = (usz)(io::bprintf(&buf, "unexpected character '%c' (not supported)", c) ?? buf[:0]).len;
        usz copy_len = n < (g_last_err_msg.len - 1) ? n : (g_last_err_msg.len - 1);
        mem::copy(&g_last_err_msg[0], &buf[0], (sz)(copy_len));
        g_last_err_msg[copy_len] = 0;
    } else {
        char[] msg = "unexpected end of input";
        usz copy_len = msg.len < (g_last_err_msg.len - 1) ? msg.len : (g_last_err_msg.len - 1);
        mem::copy(&g_last_err_msg[0], msg.ptr, (sz)(copy_len));
        g_last_err_msg[copy_len] = 0;
    }
}

// ============================================================================
// Token consumption helpers
// ============================================================================

/// Advance: consume the next token from the lexer and return it.
///
/// `as_ident_name` marks the few positions whose grammar is IdentifierName
/// rather than a ReservedWord terminal — an object-literal or class-member
/// key. Escapes are legal there (`({ break: 1 })`, `class C { break(){} }`),
/// so the escaped-keyword rejection below is skipped for those callers only.
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
        if (g_last_err_msg[0] == 0) {
            char[128] buf;
            char[] want = lexer::token_type_name(tt);
            char[] got  = lexer::token_type_name(tok.type);
            usz n = (usz)(io::bprintf(&buf, "expected '%s', got '%s'",
                                        (String)want, (String)got) ?? buf[:0]).len;
            g_last_err_line = tok.line;
            g_last_err_col  = tok.col;
            usz copy_len = n < (g_last_err_msg.len - 1) ? n : (g_last_err_msg.len - 1);
            mem::copy(&g_last_err_msg[0], &buf[0], (sz)(copy_len));
            g_last_err_msg[copy_len] = 0;
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
fn Token? CompilerContext.expect_binding_identifier(&self) {
    TokenType next = self.peek_type();
    if (next == TokenType.IDENTIFIER) {
        return self.advance()!;
    }
    if (next == TokenType.AWAIT && !self.is_module && !self.is_async && !self.forbid_await) {
        return self.advance()!;
    }
    return self.expect(TokenType.IDENTIFIER)!;
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

    *self.lexer = saved_lexer;
    return result;
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
        bool is_arrow = self.peek_type() == TokenType.ARROW;
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
fn bool CompilerContext.match_static_modifier(&self) {
    self.static_elem_src_start = 0xFFFFFFFF;
    if (self.peek_type() != TokenType.STATIC) return false;
    Token? cur_opt = self.advance();
    if (catch _e = cur_opt) return false;
    Token cur = cur_opt;
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
                Token? acc_opt = self.advance();
                if (catch _e = acc_opt) {
                    self.pushback(cur);
                    return false;
                }
                Token acc_tok = acc_opt;
                Token? peek2_opt;
                if (self.pushback_count > 0) {
                    peek2_opt = self.pushback_stack[self.pushback_count - 1];
                } else {
                    peek2_opt = self.lexer.peek();
                }
                // Put back the `get`/`set` token
                self.pushback(acc_tok);
                if (catch _e = peek2_opt) {
                    self.pushback(cur);
                    return false;
                }
                after_accessor = peek2_opt;
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
    self.static_elem_src_start = next_src_start;
    return true;  // `static` stays consumed as modifier
}

/// Detect a class static initialization block (`static { ... }`, ES2022).
/// `{` can never start a PropertyName, so unlike match_static_modifier there
/// is no ASI ambiguity to resolve with a same-line check, `static` directly
/// followed by `{` (on any line) is always the ClassStaticBlock production,
/// never `static` used as a field/method name. Returns true and consumes the
/// `static` token if this is a static block; otherwise leaves the input
/// untouched and returns false.
fn bool CompilerContext.match_static_block_prefix(&self) {
    if (self.peek_type() != TokenType.STATIC) return false;
    Token? cur_opt = self.advance();
    if (catch _e = cur_opt) return false;
    Token cur = cur_opt;
    TokenType next_tt;
    if (self.pushback_count > 0) {
        next_tt = self.pushback_stack[self.pushback_count - 1].type;
    } else {
        Token? peek_opt = self.lexer.peek();
        if (catch _e = peek_opt) {
            self.pushback(cur);
            return false;
        }
        next_tt = peek_opt.type;
    }
    if (next_tt != TokenType.LBRACE) {
        self.pushback(cur);
        return false;
    }
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
    int template_depth = 0;
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
            case TokenType.LBRACE:    brace_depth++; continue;
            case TokenType.RBRACE: {
                if (brace_depth > 0) brace_depth--;
            }
            // Template literal substitutions, `}` inside a `${...}` is not
            // a function-body close (matches skip_braced_block convention).
            case TokenType.TEMPLATE_HEAD: template_depth++; continue;
            case TokenType.TEMPLATE_MIDDLE:
            case TokenType.TEMPLATE_TAIL: {
                if (template_depth > 0) template_depth--;
            }
            case TokenType.SEMICOLON: {
                if (paren_depth == 0 && brace_depth == 0 && template_depth == 0) {
                    self.lexer.pushed_back = tok;
                    self.lexer.has_pushed_back = true;
                    return true;
                }
            }
            default: {}
        }
    }
}

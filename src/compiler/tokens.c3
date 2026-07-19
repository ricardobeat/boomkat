module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import libc;
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

// ============================================================================
// Token consumption helpers
// ============================================================================

/// Advance: consume the next token from the lexer and return it.
fn Token? CompilerContext.advance(&self) {
    // Check pushback buffer first
    if (self.pushback_count > 0) {
        self.pushback_count--;
        return self.pushback_stack[self.pushback_count];
    }
    Token? tok_opt = self.lexer.next_token();
    if (catch _err = tok_opt) {
        // Lex error — record position and a descriptive message (only if no prior error).
        if (g_last_err_msg[0] == 0) {
            g_last_err_line = self.lexer.line;
            // After a single-char lex error the lexer has already advanced pos/col by 1;
            // back up by one to report the column of the offending character.
            g_last_err_col  = self.lexer.col > 0 ? self.lexer.col - 1 : 0;
            // Identify the offending character if we can.
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
        return COMPILE_ERROR~;
    }
    return tok_opt;
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

/// Peek at the next token type without consuming.
fn TokenType CompilerContext.peek_type(&self) {
    // Check pushback buffer first
    if (self.pushback_count > 0) {
        return self.pushback_stack[self.pushback_count - 1].type;
    }
    Token? peek_opt = self.lexer.peek();
    if (catch _peek_err = peek_opt) {
        // Lex error during peek — record it now (only if no prior error captured).
        if (g_last_err_msg[0] == 0) {
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
/// private field (`#m = expr` / `#m;`) — both start with the same
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

/// Push a token back into the input stream for backtracking.
/// The next call to advance() will return this token.
/// Supports up to 4 tokens of lookback.
fn void CompilerContext.pushback(&self, Token tok) {
    if (self.pushback_count < 4) {
        self.pushback_stack[self.pushback_count] = tok;
        self.pushback_count++;
    }
}

/// Detect the `async` prefix for function declarations/expressions.
/// Returns true and consumes the `async` token if the current token is
/// the identifier "async" and the next token is "function" (not a
/// function call like `async(x) => ...` or a method like `async(x)`).
/// Returns false and leaves the input untouched otherwise.
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
    // Peek the next token: must be `function`
    TokenType next = self.peek_type();
    if (next != TokenType.FUNCTION) {
        // `async` was used as a regular identifier (e.g., variable or arrow param)
        self.pushback(cur);
        return false;
    }
    // Consume was the `async`; next call to advance() will return `function`.
    return true;
}

/// Detect the `async` prefix for arrow functions: `async x => ...` or
/// `async (params) => ...`. Pure lookahead — never consumes any tokens,
/// so the caller decides when to advance past `async` on a true result.
/// Returns true if the current token is the identifier "async" and is
/// followed by either `IDENTIFIER ARROW` or an `LPAREN` (the latter is
/// only a shape check; whether it truly resolves to an arrow is left to
/// the existing LPAREN speculative-arrow scan in primary_expr).
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
    TokenType next = self.peek_type();
    if (next == TokenType.LPAREN) {
        self.pushback(cur);
        return true;
    }
    if (next == TokenType.IDENTIFIER) {
        Token? next_opt = self.advance();
        if (catch _e = next_opt) {
            self.pushback(cur);
            return false;
        }
        Token next_tok = next_opt;
        bool is_arrow = self.peek_type() == TokenType.ARROW;
        self.pushback(next_tok);
        self.pushback(cur);
        return is_arrow;
    }
    self.pushback(cur);
    return false;
}

/// Detect the `async` modifier for method shorthand in class bodies and
/// object literals (ES2017 §14.6): identifier "async" followed — on the
/// same line, per the [no LineTerminator here] restriction — by a token
/// that can start a method name: identifier, keyword, string, number,
/// `[` (computed key), or `*` (async generator — the callers reject that
/// combination). It is NOT a modifier when followed by `(` (a method
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
    // Peek the following token WITHOUT consuming it — on a true result the
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
        // The peek stored the element's source start — record it so the
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
    // Peek the following token WITHOUT consuming it — on a true result the
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
        // The peek stored the element's source start — record it so the
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
            // a method name — NOT a modifier (e.g. `get static()`).
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
            // `static` itself is a modifier either way — the method name
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
            // Function body `{...}` — keep balanced; its outer closing `}`
            // is consumed by the brace counter. `;` inside the body must
            // not terminate the skip.
            case TokenType.LBRACE:    brace_depth++; continue;
            case TokenType.RBRACE: {
                if (brace_depth > 0) brace_depth--;
            }
            // Template literal substitutions — `}` inside a `${...}` is not
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

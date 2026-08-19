module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import std::io;

// ============================================================================
// Error recording helper
// ============================================================================

// Record a compile error with the current lexer position, then return COMPILE_ERROR~.
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

// Record a lexer error at the current position (first-writer-wins).
fn void CompilerContext.record_lex_error(&self) {
    if (self.lexer.err_msg[0] != 0) return;
    // An unterminated comment has no offending character to point at.
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

// Advance: consume the next token from the lexer and return it.
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
    // ES2024 §12.7.2: a ReservedWord is a terminal symbol and must appear literally.
    if (tok.has_escape && tok.type != TokenType.IDENTIFIER && !as_ident_name) {
        return self.fail("keyword must not contain escaped characters")~;
    }
    return tok;
}

// Expect the next token to be of the given type; consume and return it.
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

// Consume the next token as a BindingIdentifier and return it.
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
        return self.advance(true)!;
    }
    return self.expect(TokenType.IDENTIFIER)!;
}

// True when an AWAIT token in this context is a plain IdentifierName.
fn bool CompilerContext.await_is_identifier(&self, TokenType tt) {
    return tt == TokenType.AWAIT && self.await_reserved_here() == false;
}

// True when this context reserves `await` (module, async function, or static block).
fn bool CompilerContext.await_reserved_here(&self) {
    return self.is_async || self.is_module || self.forbid_await;
}

// True when the next token can start an Identifier.
fn bool CompilerContext.peek_is_binding_identifier(&self) {
    TokenType tt = self.peek_type();
    return tt == TokenType.IDENTIFIER || self.await_is_identifier(tt);
}

// If the next token matches `tt`, consume it and return true.
fn bool CompilerContext.match(&self, TokenType tt) {
    if (self.check(tt)) {
        if (try _tok = self.advance()) {
            return true;
        }
    }
    return false;
}

// Terminate a statement or class field per automatic semicolon insertion (ES2024 §12.10.1).
fn void? CompilerContext.expect_semicolon_or_asi(&self) {
    if (self.match(TokenType.SEMICOLON)) return;
    TokenType next = self.peek_type();
    if (next == TokenType.RBRACE || next == TokenType.EOF_TOKEN) return;
    if (self.lexer.seen_line_term) return;
    return self.fail("expected ';' or line break after statement")~;
}

// Peek at the next token type without consuming.
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

// Check if the next token is the given type without consuming.
fn bool CompilerContext.check(&self, TokenType tt) {
    return self.peek_type() == tt;
}

// Check for `=>` as an arrow head terminator.
fn bool CompilerContext.check_arrow(&self) {
    return self.check(TokenType.ARROW) && !self.lexer.seen_line_term;
}

// Read the next token as a property name (IdentifierName).
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

// Check if the next token starts a template literal.
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

// Returns true if we've reached the end of input.
fn bool CompilerContext.is_at_end(&self) {
    return self.peek_type() == TokenType.EOF_TOKEN;
}

// Peek two tokens ahead: true if the token AFTER the current token is `(`.
fn bool CompilerContext.peek2_is_lparen(&self) {
    Token? cur_opt = self.advance();
    if (catch _e = cur_opt) return false;
    Token cur = cur_opt;
    TokenType next_tt = self.peek_type();
    self.pushback(cur);
    return next_tt == TokenType.LPAREN;
}

// Conservative lookahead: could the expression starting at the current token
// write to some local variable's home register before the enclosing binary
// operator consumes its left operand?
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

// Swap in a lexer state (speculative scan / re-parse window) while preserving
// the per-compilation error fields.
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

// Capture the current scan position as a LexerPos, for a later seek_lexer_to.
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

// Rewind the lexer to a position captured by capture_lexer_pos.
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

// Push a token back into the input stream for backtracking.
// Supports up to 4 tokens of lookback.
fn void CompilerContext.pushback(&self, Token tok) {
    if (self.pushback_count < 4) {
        self.pushback_stack[self.pushback_count] = tok;
        self.pushback_count++;
    }
}

// Detect the `async` prefix for function declarations/expressions (ES2017 §14.7).
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
    // Escaped `async` (`\u0061sync` etc.) is a plain IdentifierName, never the contextual keyword.
    if (cur.has_escape) {
        self.pushback(cur);
        return false;
    }
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
    if (next_tok.line != cur.line) {
        self.pushback(cur);
        return false;
    }
    return true;
}

// Detect the `async` prefix for arrow functions: `async x => ...` or `async (params) => ...`.
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
        // [no LineTerminator here] before the `(`.
        if (next_tok.line != cur.line) {
            self.pushback(cur);
            return false;
        }
        self.pushback(cur);
        return true;
    }
    if (next_tok.type == TokenType.LT && self.lexer.ts_mode) {
        // `async <T, U>(params) => ...`: TypeScript generic type-parameter list.
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
        if (next_tok.line != cur.line) {
            self.pushback(cur);
            return false;
        }
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

// Detect the `async` modifier for method shorthand in class bodies and object literals (ES2017 §14.6).
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
    // Escaped `async` is a plain IdentifierName, never the contextual keyword.
    if (cur.has_escape) {
        self.pushback(cur);
        return false;
    }
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

// Detect the `static` modifier in class bodies.
fn bool? CompilerContext.match_static_modifier(&self) {
    self.static_elem_src_start = 0xFFFFFFFF;
    if (self.peek_type() != TokenType.STATIC) return false;
    Token cur = self.advance(true)!;
    Token next_tok;
    uint next_src_start = 0xFFFFFFFF;
    if (self.pushback_count > 0) {
        next_tok = self.pushback_stack[self.pushback_count - 1];
    } else {
        next_tok = self.lexer.peek()!;
        // The peek stored the element's source start. Record it so the class
        // compiler can retain source text beginning at the method (excluding
        // `static`, per §14.6/§19.2.3.5 method source retention).
        next_src_start = self.lexer.lookahead_token_start;
    }
    if (next_tok.line != cur.line) {
        // [no LineTerminator here] between `static` and the method name.
        self.pushback(cur);
        return false;
    }
    if (next_tok.type == TokenType.IDENTIFIER) {
        // `get` and `set` can be accessor prefixes or plain method names.
        // `static` is a modifier either way, since the method name position
        // after `static` is occupied by `get`/`set`.
        bool is_accessor = (next_tok.str_value.len == 3
            && next_tok.str_value[0] == 'g'
            && next_tok.str_value[1] == 'e'
            && next_tok.str_value[2] == 't')
            || (next_tok.str_value.len == 3
            && next_tok.str_value[0] == 's'
            && next_tok.str_value[1] == 'e'
            && next_tok.str_value[2] == 't');
        if (is_accessor) {
            Token after_accessor;
            if (self.pushback_count > 1) {
                after_accessor = self.pushback_stack[self.pushback_count - 2];
            } else {
                Token acc_tok = self.advance()!;
                Token? peek2_opt;
                if (self.pushback_count > 0) {
                    peek2_opt = self.pushback_stack[self.pushback_count - 1];
                } else {
                    peek2_opt = self.lexer.peek();
                }
                self.pushback(acc_tok);
                after_accessor = peek2_opt!;
            }
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

// Reject a token that has been decided to occupy a ReservedWord position
// once lookahead completes.
// `advance` gates escaped keywords at the point of consumption, but the two
// `static` lookaheads must consume the token before they can tell a modifier
// (`static m(){}`, `static { }` terminal `static`, escapes illegal) from a
// member name (`static(){}`, `static;` IdentifierName, escapes legal).
// Both directions of ES2024 §12.7.2 / §5.1.5 hold through this check.
fn void? CompilerContext.reject_escaped_reserved_word(&self, Token tok) {
    if (tok.has_escape) {
        return self.fail("keyword must not contain escaped characters")~;
    }
}

// Detect a class static initialization block (`static { ... }`, ES2022).
// `{` cannot start a PropertyName, so `static` followed by `{` (on any line)
// is always the ClassStaticBlock production.
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

// Skip tokens from the lexer until a SEMICOLON or RPAREN is seen at paren/bracket depth 0.
// Used by loop rotation to skip over the for-loop increment without emitting code.
// Tracks nested braces, function bodies, and template substitutions atomically.
fn bool CompilerContext.skip_expr_lex(&self) {
    int paren_depth = 0;
    int brace_depth = 0;
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
                    self.lexer.pushed_back = tok;
                    self.lexer.has_pushed_back = true;
                    return true;
                }
                paren_depth--;
            }
            case TokenType.RBRACKET: {
                if (paren_depth > 0) { paren_depth--; }
            }
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

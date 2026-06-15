module tinyduck::compiler;

import tinyduck::types;
import tinyduck::lexer;
import tinyduck::bytecode;
import tinyduck::hstring;
import tinyduck::hobject;
import tinyduck::heap;
import libc;
import std::io;

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
    Token tok = self.lexer.next_token()!;
    return tok;
}

/// Expect the next token to be of the given type; consume and return it.
/// Returns COMPILE_ERROR if the type doesn't match.
fn Token? CompilerContext.expect(&self, TokenType tt) {
    Token tok = self.advance()!;
    if (tok.type != tt) {
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
    if (try tok = self.lexer.peek()) {
        return tok.type;
    }
    return TokenType.EOF_TOKEN;
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

/// Push a token back into the input stream for backtracking.
/// The next call to advance() will return this token.
/// Supports up to 4 tokens of lookback.
fn void CompilerContext.pushback(&self, Token tok) {
    if (self.pushback_count < 4) {
        self.pushback_stack[self.pushback_count] = tok;
        self.pushback_count++;
    }
}

/// Skip tokens from the **lexer** (not the compiler pushback) until a SEMICOLON
/// or RPAREN is seen at paren/bracket depth 0.  The terminating token is NOT consumed.
/// Used by loop rotation to skip over the for-loop increment without emitting code.
/// Returns true on success, false on unexpected EOF or error.
///
/// Depth tracking: LPAREN/RPAREN increment/decrement a depth counter; the scan stops
/// when a SEMICOLON is seen at depth 0, or when a RPAREN is seen at depth 0.
fn bool CompilerContext.skip_expr_lex(&self) {
    int depth = 0;
    for (;;) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) { return false; }
        Token tok = tok_opt;
        switch (tok.type) {
            case TokenType.EOF_TOKEN: return false;
            case TokenType.LPAREN:   depth++; continue;
            case TokenType.LBRACKET: depth++; continue;
            case TokenType.RPAREN: {
                if (depth == 0) {
                    // Put it back via the lexer's single-token pushback
                    self.lexer.pushed_back = tok;
                    self.lexer.has_pushed_back = true;
                    return true;
                }
                depth--;
            }
            case TokenType.RBRACKET: {
                if (depth > 0) { depth--; }
            }
            case TokenType.SEMICOLON: {
                if (depth == 0) {
                    self.lexer.pushed_back = tok;
                    self.lexer.has_pushed_back = true;
                    return true;
                }
            }
            default: {}
        }
    }
}

// Recursive-descent parser producing the flat AST (plan 101, stage 3).
//
// The parser streams tokens from the existing Lexer in `ast_mode`: `/` always
// lexes as a punctuator and `}` as RBRACE, and the parser rescans a token as a
// regular expression or a template continuation where the grammar says so, so
// no source byte is lexed twice outside a rescan. Strictness never changes how
// a token lexes: octal literals and escapes decode leniently and the parser or
// resolver rejects them in strict code.
module boomkat::ast;

import boomkat::lexer;
import boomkat::ast::vec;
import boomkat::compiler;
import std::io;

faultdef PARSE_ERROR;

struct ParseOptions {
    bool is_module;     // the Module goal: strict, `await` is reserved, import/export are legal
    bool strict;        // the code is strict from the start (strict eval, class bodies)
    // The code is a function body (Function constructor, direct eval inside a function).
    bool in_function;
    bool allow_new_target;
    bool allow_super_property;
    bool allow_super_call;
    bool in_class_field_init;
}

// Per-function parse context, saved and restored around every function body.
struct FnCtx {
    bool strict;
    bool is_async;
    bool is_generator;
    bool in_function;          // `return` is legal
    bool is_arrow;
    bool allow_new_target;
    bool allow_super_property;
    bool allow_super_call;
    bool in_static_block;
    bool in_field_init;
    bool in_params;            // parsing a formal parameter list
    // Module code at its own top level: `await` is an operator.
    bool top_level_await;
}

struct Parser {
    Ast* ast;
    Lexer* lex;
    Token tok;               // the current, unconsumed token
    Token prev;              // the last consumed token
    Token peek_tok;
    bool has_peek;
    FnCtx ctx;
    bool is_module;
    // `in` is not an operator while a for-statement head's init expression parses.
    bool no_in;
    // Offset of the first `{a = 1}` cover initialiser not yet claimed by a pattern, or 0.
    uint cover_init;
    // Depth of array / object literals and parenthesised lists that a pattern may still claim.
    uint cover_depth;
    Vec{uint} scratch;       // child-id stack for building lists
    uint label_depth;
    char[256] err_msg;
    uint err_len;
    uint err_pos;
    bool failed;
}

// ---- errors ----

fn fault Parser.fail_at(&self, uint pos, String msg) {
    if (!self.failed) {
        self.failed = true;
        self.err_pos = pos;
        usz n = msg.len < self.err_msg.len ? msg.len : self.err_msg.len;
        for (usz i = 0; i < n; i++) self.err_msg[i] = msg[i];
        self.err_len = (uint)n;
    }
    return PARSE_ERROR;
}

fn fault Parser.fail(&self, String msg) {
    return self.fail_at(self.tok.pos, msg);
}

fn fault Parser.unexpected(&self) {
    if (self.tok.type == TokenType.EOF_TOKEN) return self.fail("unexpected end of input");
    return self.fail("unexpected token");
}

fn String Parser.error_message(&self) {
    return (String)self.err_msg[:self.err_len];
}

// Guards the parser's own recursion against the native stack, as the legacy
// compiler's check_stack does.
fn void? Parser.check_stack(&self) {
    char marker;
    uptr sp = (uptr)&marker;
    if (compiler::g_compile_stack_floor == 0) {
        uptr low = compiler::boomkat_stack_low();
        compiler::g_compile_stack_floor = low != 0 ? low + compiler::COMPILE_STACK_RESERVE
                                                   : sp - compiler::COMPILE_STACK_FALLBACK;
    }
    if (sp < compiler::g_compile_stack_floor) return self.fail("code nested too deeply")~;
}

// ---- tokens ----

fn Token? Parser.lex_one(&self) {
    Token? t = self.lex.scan_token();
    if (catch err = t) {
        uint at = self.lex.pos > 0 ? self.lex.pos - 1 : 0;
        if (self.lex.unterminated_comment) {
            return self.fail_at(at, "unterminated multi-line comment")~;
        }
        return self.fail_at(at, "invalid or unexpected token")~;
    }
    return t;
}

// Consume the current token and load the next.
fn void? Parser.next(&self) {
    self.prev = self.tok;
    if (self.has_peek) {
        self.has_peek = false;
        self.tok = self.peek_tok;
        return;
    }
    self.tok = self.lex_one()!;
}

// The token after the current one.
fn Token? Parser.peek(&self) {
    if (!self.has_peek) {
        self.peek_tok = self.lex_one()!;
        self.has_peek = true;
    }
    return self.peek_tok;
}

fn TokenType Parser.peek_type(&self) {
    Token? t = self.peek();
    if (catch err = t) return TokenType.EOF_TOKEN;
    return t.type;
}

// Re-lex the current `/` or `/=` token as a RegularExpressionLiteral.
fn void? Parser.rescan_regex(&self) {
    self.has_peek = false;
    Token? t = self.lex.rescan_regexp(self.tok);
    if (catch err = t) return self.fail("invalid regular expression literal")~;
    self.tok = t;
}

// Re-lex the current `}` token, which closes a template substitution, as the
// template text that follows it.
fn void? Parser.rescan_template(&self) {
    self.has_peek = false;
    Token? t = self.lex.rescan_template_part(self.tok);
    if (catch err = t) return self.fail("unterminated template literal")~;
    self.tok = t;
}

fn bool Parser.at(&self, TokenType tt) @inline {
    return self.tok.type == tt;
}

// Consume the current token if it has type `tt`.
fn bool? Parser.eat(&self, TokenType tt) {
    if (self.tok.type != tt) return false;
    self.next()!;
    return true;
}

fn Token? Parser.expect(&self, TokenType tt) {
    if (self.tok.type != tt) {
        char[96] buf;
        String want = (String)lexer::token_type_name(tt);
        String m = (String)(io::bprintf(&buf, "expected '%s'", want) ?? "unexpected token");
        return self.fail(m)~;
    }
    Token t = self.tok;
    self.next()!;
    return t;
}

// The token is an identifier whose text is `word`, spelled without escapes.
fn bool Parser.is_word(&self, Token t, String word) @inline {
    if (t.type != TokenType.IDENTIFIER || t.has_escape) return false;
    if (t.str_value.len != word.len) return false;
    for (usz i = 0; i < word.len; i++) {
        if (t.str_value[i] != word[i]) return false;
    }
    return true;
}

fn bool Parser.at_word(&self, String word) @inline {
    return self.is_word(self.tok, word);
}

// A Semicolon or an automatic semicolon (ES2024 §12.10).
fn void? Parser.semicolon(&self) {
    if (self.tok.type == TokenType.SEMICOLON) {
        self.next()!;
        return;
    }
    if (self.tok.type == TokenType.RBRACE || self.tok.type == TokenType.EOF_TOKEN || self.tok.nl_before) return;
    return self.unexpected()~;
}

// ---- tokens that name things ----

// A token that may be an IdentifierName: an identifier or any reserved word.
fn bool is_name_token(TokenType tt) @inline {
    return tt >= TokenType.IDENTIFIER && tt <= TokenType.PUBLIC;
}

// A token that can be an IdentifierReference or BindingIdentifier here. `yield` and `await` are
// identifiers only outside generator and async code; `let` and `static` are identifiers in sloppy
// code (the resolver rejects them where strict code forbids them).
fn bool Parser.is_ident_token(&self, Token t) {
    switch (t.type) {
        case TokenType.IDENTIFIER:
        case TokenType.LET:
        case TokenType.STATIC:
            return true;
        case TokenType.YIELD:
            return !self.ctx.is_generator;
        case TokenType.AWAIT:
            return !self.await_is_operator() && !self.is_module;
        default:
            return false;
    }
}

fn bool Parser.await_is_operator(&self) {
    return self.ctx.is_async || self.ctx.top_level_await;
}

fn uint Parser.atom(&self, char[] s) @inline {
    return self.ast.atoms.intern(s);
}

// ---- node building ----

fn uint Parser.node(&self, NodeTag tag, uint tok, uint lhs = 0, uint rhs = 0, char flags = 0) @inline {
    return self.ast.add(tag, flags, tok, lhs, rhs);
}

// Start collecting children: returns the scratch mark.
fn uint Parser.scratch_mark(&self) @inline {
    return (uint)self.scratch.len;
}

fn void Parser.scratch_push(&self, uint id) @inline {
    self.scratch.push(id);
}

// Move the scratch items from `mark` to the top into a `extra` list and return its index.
fn uint Parser.scratch_list(&self, uint mark) {
    uint n = (uint)self.scratch.len - mark;
    uint at = self.ast.add_list(self.scratch.data[mark:n]);
    self.scratch.truncate(mark);
    return at;
}

fn uint Parser.pair(&self, uint a, uint b) {
    uint at = (uint)self.ast.extra.len;
    self.ast.extra.push(a);
    self.ast.extra.push(b);
    return at;
}

fn uint Parser.triple(&self, uint a, uint b, uint c) {
    uint at = (uint)self.ast.extra.len;
    self.ast.extra.push(a);
    self.ast.extra.push(b);
    self.ast.extra.push(c);
    return at;
}

fn uint Parser.quad(&self, uint a, uint b, uint c, uint d) {
    uint at = (uint)self.ast.extra.len;
    self.ast.extra.push(a);
    self.ast.extra.push(b);
    self.ast.extra.push(c);
    self.ast.extra.push(d);
    return at;
}

// ---- line table ----

// Line terminators are \n, \r, \r\n, U+2028 and U+2029, as the lexer counts them.
fn void build_line_table(Ast* ast) {
    char[] src = ast.source;
    usz i = 0;
    while (i < src.len) {
        char c = src[i];
        if (c == '\n') {
            ast.line_starts.push((uint)i + 1);
        } else if (c == '\r') {
            if (i + 1 < src.len && src[i + 1] == '\n') i++;
            ast.line_starts.push((uint)i + 1);
        } else if (c == 0xE2 && i + 2 < src.len && src[i + 1] == 0x80 && (src[i + 2] == 0xA8 || src[i + 2] == 0xA9)) {
            i += 2;
            ast.line_starts.push((uint)i + 1);
        }
        i++;
    }
}

// ---- entry point ----

struct ParseResult {
    uint root;        // the PROGRAM node, 0 on failure
    String error;     // valid until the Parser is gone; empty on success
    uint err_line;
    uint err_col;
}

// Parse a whole Script or Module into `ast`. The lexer must be freshly initialised on `ast.source`;
// it is put in ast_mode and left there.
fn uint? parse_program(Parser* p, Ast* ast, Lexer* lex, ParseOptions opts) {
    p.ast = ast;
    p.lex = lex;
    p.is_module = opts.is_module;
    p.scratch.init(256);
    build_line_table(ast);
    lex.ast_mode = true;
    lex.set_strict(false);
    lex.html_comments = !opts.is_module;
    lex.skip_hashbang();
    p.ctx.strict = opts.strict || opts.is_module;
    p.ctx.in_function = opts.in_function;
    p.ctx.allow_new_target = opts.allow_new_target;
    p.ctx.allow_super_property = opts.allow_super_property;
    p.ctx.allow_super_call = opts.allow_super_call;
    p.ctx.in_field_init = opts.in_class_field_init;
    p.ctx.top_level_await = opts.is_module;
    p.next()!;
    return p.program(opts);
}

fn void Parser.destroy(&self) {
    self.scratch.free();
}

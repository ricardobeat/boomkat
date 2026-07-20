/// Lexer module for the Duktape JavaScript engine.
///
/// Tokenizes ECMAScript source code (ES2015+ subset) into a stream of
/// tokens.  Handles UTF-8 source, numeric literals (decimal, hex, octal,
/// binary, float, exponent), string literals with full escape sequence
/// support, template literals, regular expression literals, and all
/// ES2015+ punctuators and keywords.
module duktape::lexer;

import duktape::types;
import duktape::dtoa_bindings;
import duktape::unicode_bindings;
import std::math;
import std::io;

// ============================================================================
// Fault codes
// ============================================================================

/// Raised when the lexer encounters invalid or unexpected input.
faultdef LEX_ERROR;

/// Returned when a keyword lookup does not match.
faultdef NOT_A_KEYWORD;

// ============================================================================
// Constants
// ============================================================================

/// Maximum size for the string escape-processing buffer.
const uint STRING_BUF_SIZE = 65536;

// ============================================================================
// Token types
// ============================================================================

enum TokenType : ushort {
    // Literals
    EOF_TOKEN,
    NUMBER,
    BIGINT,
    STRING,
    REGEXP,
    TEMPLATE,
    TEMPLATE_HEAD,
    TEMPLATE_MIDDLE,
    TEMPLATE_TAIL,

    // Identifiers and keywords
    IDENTIFIER,

    // Keywords (alphabetical)
    BREAK, CASE, CATCH, CONTINUE, DEBUGGER, DEFAULT, DELETE, DO, ELSE,
    FINALLY, FOR, FUNCTION, IF, IN, INSTANCEOF, NEW, RETURN, SWITCH,
    THIS, THROW, TRY, TYPEOF, VAR, VOID, WHILE, WITH,

    // ES2015+ keywords
    CLASS, CONST, EXPORT, EXTENDS, IMPORT, SUPER, YIELD, LET, STATIC,

    // Future reserved
    ENUM, AWAIT,

    // Strict mode reserved
    IMPLEMENTS, INTERFACE, PACKAGE, PRIVATE, PROTECTED, PUBLIC,

    // Punctuators
    LBRACE, RBRACE, LPAREN, RPAREN, LBRACKET, RBRACKET,
    DOT, ELLIPSIS, SEMICOLON, COMMA,
    LT, GT, LE, GE, EQ, NE, SEQ, SNE,
    PLUS, MINUS, STAR, SLASH, PERCENT, STARSTAR,
    INC, DEC,
    SHL, SHR, USHR,
    BIT_AND, BIT_OR, BIT_XOR, BIT_NOT,
    LOG_AND, LOG_OR, LOG_NOT, NULLISH,
    QUESTION, COLON,
    ASSIGN, PLUS_ASSIGN, MINUS_ASSIGN, STAR_ASSIGN, SLASH_ASSIGN,
    PERCENT_ASSIGN, STARSTAR_ASSIGN, SHL_ASSIGN, SHR_ASSIGN, USHR_ASSIGN,
    BIT_AND_ASSIGN, BIT_OR_ASSIGN, BIT_XOR_ASSIGN,
    LOG_AND_ASSIGN, LOG_OR_ASSIGN, NULLISH_ASSIGN,
    ARROW,
    OPT_CHAIN,
    HASH_IDENT,   // #name — private identifier (text excludes the '#')
}

// ============================================================================
// Token
// ============================================================================

struct Token {
    TokenType type;
    uint line;
    uint col;
    double num_value;
    char[] str_value;
    char[] raw_value;
    bool str_owns_memory;
    bool has_octal_escape;
    bool is_template;
    bool has_invalid_escape;
}

/// Create a simple token with no value payload.
fn Token make_token(TokenType tt, uint line, uint col) {
    Token t;
    t.type = tt;
    t.line = line;
    t.col = col;
    t.num_value = 0.0;
    t.str_value = {};
    t.raw_value = {};
    t.str_owns_memory = false;
    t.has_octal_escape = false;
    t.is_template = false;
    t.has_invalid_escape = false;
    return t;
}

// ============================================================================
// Keyword table
// ============================================================================

struct KeywordEntry {
    char[] name;
    TokenType type;
    bool strict_only;
}

const KeywordEntry[*] KEYWORDS = {
    { "break",       TokenType.BREAK,       false },
    { "case",        TokenType.CASE,        false },
    { "catch",       TokenType.CATCH,       false },
    { "continue",    TokenType.CONTINUE,    false },
    { "debugger",    TokenType.DEBUGGER,    false },
    { "default",     TokenType.DEFAULT,     false },
    { "delete",      TokenType.DELETE,      false },
    { "do",          TokenType.DO,          false },
    { "else",        TokenType.ELSE,        false },
    { "finally",     TokenType.FINALLY,     false },
    { "for",         TokenType.FOR,         false },
    { "function",    TokenType.FUNCTION,    false },
    { "if",          TokenType.IF,          false },
    { "in",          TokenType.IN,          false },
    { "instanceof",  TokenType.INSTANCEOF,  false },
    { "new",         TokenType.NEW,         false },
    { "return",      TokenType.RETURN,      false },
    { "switch",      TokenType.SWITCH,      false },
    { "this",        TokenType.THIS,        false },
    { "throw",       TokenType.THROW,       false },
    { "try",         TokenType.TRY,         false },
    { "typeof",      TokenType.TYPEOF,      false },
    { "var",         TokenType.VAR,         false },
    { "void",        TokenType.VOID,        false },
    { "while",       TokenType.WHILE,       false },
    { "with",        TokenType.WITH,        false },
    { "class",       TokenType.CLASS,       false },
    { "const",       TokenType.CONST,       false },
    { "export",      TokenType.EXPORT,      false },
    { "extends",     TokenType.EXTENDS,     false },
    { "import",      TokenType.IMPORT,      false },
    { "super",       TokenType.SUPER,       false },
    { "yield",       TokenType.YIELD,       false },
    { "let",         TokenType.LET,         false },
    { "static",      TokenType.STATIC,      false },
    { "enum",        TokenType.ENUM,        false },
    { "await",       TokenType.AWAIT,       false },
    { "implements",  TokenType.IMPLEMENTS,  true  },
    { "interface",   TokenType.INTERFACE,   true  },
    { "package",     TokenType.PACKAGE,     true  },
    { "private",     TokenType.PRIVATE,     true  },
    { "protected",   TokenType.PROTECTED,   true  },
    { "public",      TokenType.PUBLIC,      true  },
};

/// Look up an identifier to see if it is a keyword.
/// Returns the keyword token type, or NOT_A_KEYWORD fault if not a keyword.
/// Dispatches on the identifier's first character for faster lookup, then
/// compares length before full byte comparison within candidates.
fn TokenType? lookup_keyword(char[] name, bool strict_mode) {
    if (name.len == 0) {
        return NOT_A_KEYWORD~;
    }

    // Filter on first character, then length, before the full byte compare.
    foreach (&kw : KEYWORDS) {
        if (kw.name[0] != name[0]) continue;

        if (kw.name.len == name.len) {
            bool match = true;
            for (usz i = 0; i < name.len; i++) {
                if (kw.name[i] != name[i]) {
                    match = false;
                    break;
                }
            }
            if (match) {
                if (kw.strict_only && !strict_mode) {
                    return NOT_A_KEYWORD~;
                }
                return kw.type;
            }
        }
    }
    return NOT_A_KEYWORD~;
}

/// Reverse lookup: given a keyword TokenType, return its string representation.
/// Returns an empty string if the token type is not a keyword.
fn char[] keyword_to_string(TokenType tt) {
    foreach (&kw : KEYWORDS) {
        if (kw.type == tt) return kw.name;
    }
    return "";
}

/// Return a human-readable name for a token type (for error messages).
fn char[] token_type_name(TokenType tt) {
    // Try keyword table first
    char[] kw = keyword_to_string(tt);
    if (kw.len > 0) return kw;
    switch (tt) {
        case TokenType.EOF_TOKEN:       return "<end of input>";
        case TokenType.NUMBER:          return "<number>";
        case TokenType.BIGINT:          return "<bigint>";
        case TokenType.STRING:          return "<string>";
        case TokenType.REGEXP:          return "<regexp>";
        case TokenType.TEMPLATE:        return "<template>";
        case TokenType.TEMPLATE_HEAD:   return "<template>";
        case TokenType.TEMPLATE_MIDDLE: return "<template>";
        case TokenType.TEMPLATE_TAIL:   return "<template>";
        case TokenType.IDENTIFIER:      return "<identifier>";
        case TokenType.LBRACE:          return "{";
        case TokenType.RBRACE:          return "}";
        case TokenType.LPAREN:          return "(";
        case TokenType.RPAREN:          return ")";
        case TokenType.LBRACKET:        return "[";
        case TokenType.RBRACKET:        return "]";
        case TokenType.DOT:             return ".";
        case TokenType.ELLIPSIS:        return "...";
        case TokenType.SEMICOLON:       return ";";
        case TokenType.COMMA:           return ",";
        case TokenType.LT:              return "<";
        case TokenType.GT:              return ">";
        case TokenType.LE:              return "<=";
        case TokenType.GE:              return ">=";
        case TokenType.EQ:              return "==";
        case TokenType.NE:              return "!=";
        case TokenType.SEQ:             return "===";
        case TokenType.SNE:             return "!==";
        case TokenType.PLUS:            return "+";
        case TokenType.MINUS:           return "-";
        case TokenType.STAR:            return "*";
        case TokenType.SLASH:           return "/";
        case TokenType.PERCENT:         return "%";
        case TokenType.STARSTAR:        return "**";
        case TokenType.INC:             return "++";
        case TokenType.DEC:             return "--";
        case TokenType.SHL:             return "<<";
        case TokenType.SHR:             return ">>";
        case TokenType.USHR:            return ">>>";
        case TokenType.BIT_AND:         return "&";
        case TokenType.BIT_OR:          return "|";
        case TokenType.BIT_XOR:         return "^";
        case TokenType.BIT_NOT:         return "~";
        case TokenType.LOG_AND:         return "&&";
        case TokenType.LOG_OR:          return "||";
        case TokenType.LOG_NOT:         return "!";
        case TokenType.NULLISH:         return "??";
        case TokenType.QUESTION:        return "?";
        case TokenType.COLON:           return ":";
        case TokenType.ASSIGN:          return "=";
        case TokenType.PLUS_ASSIGN:     return "+=";
        case TokenType.MINUS_ASSIGN:    return "-=";
        case TokenType.STAR_ASSIGN:     return "*=";
        case TokenType.SLASH_ASSIGN:    return "/=";
        case TokenType.PERCENT_ASSIGN:  return "%=";
        case TokenType.STARSTAR_ASSIGN: return "**=";
        case TokenType.SHL_ASSIGN:      return "<<=";
        case TokenType.SHR_ASSIGN:      return ">>=";
        case TokenType.USHR_ASSIGN:     return ">>>=";
        case TokenType.BIT_AND_ASSIGN:  return "&=";
        case TokenType.BIT_OR_ASSIGN:   return "|=";
        case TokenType.BIT_XOR_ASSIGN:  return "^=";
        case TokenType.LOG_AND_ASSIGN:  return "&&=";
        case TokenType.LOG_OR_ASSIGN:   return "||=";
        case TokenType.NULLISH_ASSIGN:  return "??=";
        case TokenType.ARROW:           return "=>";
        case TokenType.OPT_CHAIN:       return "?.";
        case TokenType.HASH_IDENT:      return "#<identifier>";
        default:                        return "<unknown>";
    }
}

// ============================================================================
// Character classification helpers
// ============================================================================

fn bool is_digit(char c) {
    return c >= '0' && c <= '9';
}

fn bool is_hex_digit(char c) {
    return (c >= '0' && c <= '9') ||
           (c >= 'a' && c <= 'f') ||
           (c >= 'A' && c <= 'F');
}

fn uint hex_value(char c) {
    if (c >= '0' && c <= '9') return (uint)(c - '0');
    if (c >= 'a' && c <= 'f') return (uint)(c - 'a') + 10;
    if (c >= 'A' && c <= 'F') return (uint)(c - 'A') + 10;
    return 0;
}

fn bool is_octal_digit(char c) {
    return c >= '0' && c <= '7';
}

fn bool is_binary_digit(char c) {
    return c == '0' || c == '1';
}

fn bool is_line_terminator(char c) {
    return c == '\n' || c == '\r';
}

/// Check if a Unicode codepoint is a valid identifier start character.
///
/// Backed by libregexp's vendored ID_Start property tables (per Unicode
/// 15.1 / ES2024 spec), so it covers the full ID_Start set including
/// Other_ID_Start grandfathered characters (U+2118 ℘, U+212E ℮, etc.)
/// and astral-plane ID_Start. ASCII path is fast; >= 128 goes through
/// the full Unicode table.
fn bool is_identifier_start(uint cp) @inline {
    return unicode_bindings::unicode_is_identifier_start(cp) != 0;
}

/// Check if a Unicode codepoint is a valid identifier continuation character.
///
/// Per Unicode 15.1 / ES2024: includes ID_Start + digits + Other_ID_Continue
/// grandfathered characters (e.g. U+00B7 ·, U+0387 ·, U+1369-1371 Ethiopic
/// digits, U+19DA ᧚) + combining marks (U+0300-036F) + ZWNJ (U+200C) +
/// ZWJ (U+200D).  ASCII path is fast; >= 128 goes through the table.
fn bool is_identifier_part(uint cp) @inline {
    return unicode_bindings::unicode_is_identifier_continue(cp) != 0;
}

/// Check if a character is ASCII whitespace (space, tab, VT, FF, NBSP).
fn bool is_whitespace(char c) {
    // Single-byte ASCII WhiteSpace (ES §12.2): TAB, VT, FF, SP. Multi-byte
    // whitespace (NBSP U+00A0, BOM U+FEFF, U+2028/U+2029) is handled by
    // byte-sequence checks in skip_whitespace_and_comments.
    return c == ' ' || c == '\t' || c == 0x0B || c == 0x0C;
}

// ============================================================================
// UTF-8 encoding helper
// ============================================================================

/// Encode a Unicode codepoint as UTF-8 into the buffer at the given offset.
/// Returns the new offset.
fn uint encode_utf8_to_buf(char[STRING_BUF_SIZE]* buf, uint offset, uint cp) {
    if (cp < 0x80) {
        (*buf)[offset] = (char)cp;
        return offset + 1;
    }
    if (cp < 0x800) {
        (*buf)[offset]     = (char)(0xC0 | (cp >> 6));
        (*buf)[offset + 1] = (char)(0x80 | (cp & 0x3F));
        return offset + 2;
    }
    if (cp < 0x10000) {
        (*buf)[offset]     = (char)(0xE0 | (cp >> 12));
        (*buf)[offset + 1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        (*buf)[offset + 2] = (char)(0x80 | (cp & 0x3F));
        return offset + 3;
    }
    // Supplementary plane: ECMAScript strings are UTF-16 code unit
    // sequences (spec §6.1.4) — encode `\u{H+}` astral escapes as a
    // surrogate pair (CESU-8 storage: each half gets its own 3-byte UTF-8
    // sequence) so `"\u{1F600}".length === 2`, matching a real JS engine.
    uint v = cp - 0x1_0000;
    uint high = 0xD800 + (v >> 10);
    uint low  = 0xDC00 + (v & 0x3FF);
    (*buf)[offset]     = (char)(0xE0 | (high >> 12));
    (*buf)[offset + 1] = (char)(0x80 | ((high >> 6) & 0x3F));
    (*buf)[offset + 2] = (char)(0x80 | (high & 0x3F));
    (*buf)[offset + 3] = (char)(0xE0 | (low >> 12));
    (*buf)[offset + 4] = (char)(0x80 | ((low >> 6) & 0x3F));
    (*buf)[offset + 5] = (char)(0x80 | (low & 0x3F));
    return offset + 6;
}

// ============================================================================
// Lexer state
// ============================================================================

struct Lexer {
    char[] source;
    uint pos;
    uint line;
    uint col;
    Token current;
    Token lookahead;
    bool has_lookahead;
    /// Byte position at the start of the most recently produced token.
    /// Updated on each `next_token()` call so callers can capture the source
    /// span of a just-consumed token by reading `source[token_start..pos-1]`.
    /// Used by Function.prototype.toString source-text retention.
    uint token_start;
    /// Byte position at the start of the token stored in `lookahead`, when
    /// the lookahead was created by `peek()`. Set inside peek, used inside
    /// next_token's lookahead-consume path to keep `token_start` correct
    /// when a peek-then-advance sequence consumes the lookahead.
    uint lookahead_token_start;
    /// Single-token pushback buffer for limited backtracking (e.g. label detection).
    Token pushed_back;
    bool has_pushed_back;
    bool strict_mode;
    /// True if a line terminator was skipped between the previous and next token.
    bool seen_line_term;
    /// Set by the parser after consuming a `}` that closes a Block/function/
    /// class body in statement position; makes the next `/` a RegExp literal
    /// (not division). Cleared by the next `next_token()`.
    bool force_regex_after_brace;
    /// True when, since the start of source or the most recent real line
    /// terminator, only whitespace and/or comments have been produced (i.e.
    /// no real token has appeared yet on the current line). Persists across
    /// `skip_whitespace_and_comments` calls so it correctly reflects
    /// same-line token history; used to gate AnnexB `-->` HTMLCloseComment,
    /// which is only a comment-starter at the beginning of a line.
    bool at_line_start;
    void* heap;

    char[4096] ident_buf;
}

// ============================================================================
// Lexer — initialisation
// ============================================================================

/// Create a new lexer for the given source text.
fn Lexer lexer_init(char[] source, void* heap) {
    Lexer lex;
    lex.source = source;
    lex.pos = 0;
    lex.line = 1;
    lex.col = 1;
    lex.current = make_token(TokenType.EOF_TOKEN, 1, 1);
    lex.lookahead = make_token(TokenType.EOF_TOKEN, 1, 1);
    lex.has_lookahead = false;
    lex.token_start = 0;
    lex.lookahead_token_start = 0;
    lex.has_pushed_back = false;
    lex.strict_mode = true;
    lex.seen_line_term = false;
    lex.at_line_start = true;
    lex.heap = heap;
    return lex;
}

/// Skip a leading HashbangComment (`#!` up to but not including the first
/// LineTerminator) per ECMAScript §12.5. Must be called, if at all, before
/// any tokens are produced — it only matches when `pos == 0` and the first
/// two bytes are the literal ASCII characters `#` and `!` (escape sequences
/// like `#!` must NOT match, since they are not the literal source
/// characters). Callers opt into this for Script, Module, and eval source
/// text; it must never be applied to Function-constructor bodies or nested
/// function/class bodies, which is why it is not folded into `lexer_init`.
fn void Lexer.skip_hashbang(&self) {
    if (self.pos != 0) return;
    if (self.source.len < 2) return;
    if (self.source[0] != '#' || self.source[1] != '!') return;
    self.pos = 2;
    self.col = 3;
    while (!self.at_end()) {
        char c = self.peek_char();
        if (c == '\n' || c == '\r') break;
        // U+2028 / U+2029 (UTF-8: E2 80 A8 / E2 80 A9) also terminate the
        // hashbang comment, same as SingleLineComment.
        if (c == (char)0xE2 && self.remaining() >= 3) {
            char n1 = self.source[self.pos + 1];
            char n2 = self.source[self.pos + 2];
            if (n1 == (char)0x80 && (n2 == (char)0xA8 || n2 == (char)0xA9)) break;
        }
        self.pos++;
        self.col++;
    }
}

/// Reinitialize a lexer with new source text.
fn void Lexer.reset(&self, char[] source) {
    self.source = source;
    self.pos = 0;
    self.line = 1;
    self.col = 1;
    self.current = make_token(TokenType.EOF_TOKEN, 1, 1);
    self.lookahead = make_token(TokenType.EOF_TOKEN, 1, 1);
    self.has_lookahead = false;
    self.at_line_start = true;
    self.token_start = 0;
    self.lookahead_token_start = 0;
    self.has_pushed_back = false;
    self.force_regex_after_brace = false;
}

// ============================================================================
// Lexer — low-level source reading
// ============================================================================

/// Peek at the current character without advancing.  Returns 0 at EOF.
fn char Lexer.peek_char(&self) {
    if (self.pos >= (uint)self.source.len) return 0;
    return self.source[self.pos];
}

/// Peek at the character at offset `n` from the current position.
fn char Lexer.peek_char_at(&self, uint n) {
    uint idx = self.pos + n;
    if (idx >= (uint)self.source.len) return 0;
    return self.source[idx];
}

/// Advance one byte and return the consumed character.
fn char Lexer.advance_char(&self) {
    if (self.pos >= (uint)self.source.len) return 0;
    char c = self.source[self.pos];
    self.pos++;
    if (c == '\n') {
        self.line++;
        self.col = 1;
    } else {
        self.col++;
    }
    return c;
}

/// Decode a UTF-8 codepoint at the current position.
/// Returns the codepoint and advances past it.
fn uint Lexer.read_codepoint(&self) {
    if (self.pos >= (uint)self.source.len) return 0;
    char b0 = self.source[self.pos];

    // ASCII fast path
    if (b0 < 0x80) {
        self.pos++;
        if (b0 == '\n') {
            self.line++;
            self.col = 1;
        } else {
            self.col++;
        }
        return (uint)b0;
    }

    uint cp;
    uint seq_len;
    if ((b0 & 0xE0) == 0xC0) {
        cp = (uint)(b0 & 0x1F);
        seq_len = 2;
    } else if ((b0 & 0xF0) == 0xE0) {
        cp = (uint)(b0 & 0x0F);
        seq_len = 3;
    } else if ((b0 & 0xF8) == 0xF0) {
        cp = (uint)(b0 & 0x07);
        seq_len = 4;
    } else {
        // Invalid UTF-8 lead byte
        self.pos++;
        self.col++;
        return 0xFFFD;
    }

    self.pos++;
    self.col++;

    for (uint i = 1; i < seq_len; i++) {
        if (self.pos >= (uint)self.source.len) return 0xFFFD;
        char cb = self.source[self.pos];
        if ((cb & 0xC0) != 0x80) return 0xFFFD;
        cp = (cp << 6) | (uint)(cb & 0x3F);
        self.pos++;
    }

    return cp;
}

/// Peek at the current UTF-8 codepoint without advancing.
fn uint Lexer.peek_codepoint(&self) {
    uint saved_pos = self.pos;
    uint saved_line = self.line;
    uint saved_col = self.col;
    uint cp = self.read_codepoint();
    self.pos = saved_pos;
    self.line = saved_line;
    self.col = saved_col;
    return cp;
}

/// Returns true if the lexer has reached the end of source.
fn bool Lexer.at_end(&self) {
    return self.pos >= (uint)self.source.len;
}

/// Returns the number of source bytes remaining.
fn uint Lexer.remaining(&self) {
    if (self.pos >= (uint)self.source.len) return 0;
    return (uint)self.source.len - self.pos;
}

// ============================================================================
// Lexer — skip whitespace and comments
// ============================================================================

/// Skip whitespace, line terminators, single-line comments (//),
/// multi-line comments (/* ... */), and AnnexB §B.1.3 HTML-like comments
/// (`<!--` and `-->`).
///
/// NOTE: HTML-like comments are script-only per the spec (they must be a
/// SyntaxError in module code). The lexer has no reachable module/script
/// flag, so this is applied unconditionally to all source. See the task
/// report for this limitation.
fn void Lexer.skip_whitespace_and_comments(&self) {
    self.seen_line_term = false;
    // `self.at_line_start` persists across calls: it reflects whether, since
    // the start of source or the most recent real line terminator, only
    // whitespace and/or comments have been seen (i.e. no real token has
    // started on the current line yet). This gates `-->` (HTMLCloseComment):
    // it is only a comment-starter at the beginning of a line.
    while (!self.at_end()) {
        char c = self.peek_char();

        // Whitespace
        if (is_whitespace(c) || c == '\n' || c == '\r') {
            if (c == '\r' && self.peek_char_at(1) == '\n') {
                // CR+LF counts as one line terminator
                self.pos += 2;
                self.line++;
                self.col = 1;
                self.seen_line_term = true;
                self.at_line_start = true;
            } else {
                self.advance_char();
                if (c == '\n' || c == '\r') {
                    self.seen_line_term = true;
                    self.at_line_start = true;
                }
            }
            continue;
        }

        // U+2028 (line separator) and U+2029 (paragraph separator) — UTF-8: E2 80 A8 / E2 80 A9
        if (c == (char)0xE2 && self.remaining() >= 3) {
            char n1 = self.source[self.pos + 1];
            char n2 = self.source[self.pos + 2];
            if ((n1 == (char)0x80 && (n2 == (char)0xA8 || n2 == (char)0xA9))) {
                self.pos += 3;
                self.line++;
                self.col = 1;
                self.seen_line_term = true;
                self.at_line_start = true;
                continue;
            }
        }

        // U+00A0 no-break space — UTF-8: C2 A0. WhiteSpace (ES §12.2), not a
        // line terminator, so it does not set seen_line_term.
        if (c == (char)0xC2 && self.remaining() >= 2 && self.source[self.pos + 1] == (char)0xA0) {
            self.pos += 2;
            self.col++;
            continue;
        }

        // Other Zs whitespace (ES §12.2):
        //   U+1680 OGHAM SPACE MARK           — UTF-8: E1 9A 80
        //   U+2000..U+200A                    — UTF-8: E2 80 80..E2 80 8A
        //   U+202F NARROW NO-BREAK SPACE      — UTF-8: E2 80 AF
        //   U+205F MEDIUM MATHEMATICAL SPACE  — UTF-8: E2 81 9F
        //   U+3000 IDEOGRAPHIC SPACE          — UTF-8: E3 80 80
        if (c == (char)0xE1 && self.remaining() >= 3
            && self.source[self.pos + 1] == (char)0x9A
            && self.source[self.pos + 2] == (char)0x80) {
            self.pos += 3;
            self.col++;
            continue;
        }
        if (c == (char)0xE2 && self.remaining() >= 3
            && self.source[self.pos + 1] == (char)0x80) {
            char e2b = self.source[self.pos + 2];
            if ((e2b >= (char)0x80 && e2b <= (char)0x8A) || e2b == (char)0xAF) {
                self.pos += 3;
                self.col++;
                continue;
            }
        }
        if (c == (char)0xE2 && self.remaining() >= 3
            && self.source[self.pos + 1] == (char)0x81
            && self.source[self.pos + 2] == (char)0x9F) {
            self.pos += 3;
            self.col++;
            continue;
        }
        if (c == (char)0xE3 && self.remaining() >= 3
            && self.source[self.pos + 1] == (char)0x80
            && self.source[self.pos + 2] == (char)0x80) {
            self.pos += 3;
            self.col++;
            continue;
        }

        // U+FEFF zero-width no-break space (BOM) — UTF-8: EF BB BF. WhiteSpace
        // (ES §12.2), not a line terminator.
        if (c == (char)0xEF && self.remaining() >= 3
            && self.source[self.pos + 1] == (char)0xBB && self.source[self.pos + 2] == (char)0xBF) {
            self.pos += 3;
            self.col++;
            continue;
        }

        // Single-line comment
        if (c == '/' && self.peek_char_at(1) == '/') {
            self.pos += 2;
            self.col += 2;
            while (!self.at_end()) {
                char cc = self.peek_char();
                if (cc == '\n' || cc == '\r') break;
                // U+2028 / U+2029 (UTF-8: E2 80 A8 / E2 80 A9) also
                // terminate single-line comments.
                if (cc == (char)0xE2 && self.remaining() >= 3) {
                    char cn1 = self.source[self.pos + 1];
                    char cn2 = self.source[self.pos + 2];
                    if (cn1 == (char)0x80 && (cn2 == (char)0xA8 || cn2 == (char)0xA9)) break;
                }
                self.pos++;
                self.col++;
            }
            continue;
        }

        // Multi-line comment
        if (c == '/' && self.peek_char_at(1) == '*') {
            self.pos += 2;
            self.col += 2;
            bool comment_had_newline = false;
            while (!self.at_end()) {
                if (self.peek_char() == '*' && self.peek_char_at(1) == '/') {
                    self.pos += 2;
                    self.col += 2;
                    break;
                }
                char bc = self.peek_char();
                if (bc == '\n' || bc == '\r') comment_had_newline = true;
                self.advance_char();
            }
            // A block comment that itself contains a line terminator counts
            // as a line boundary for the purposes of allowing a following
            // `-->` HTMLCloseComment, even though it does not set
            // `seen_line_term` (ASI only cares about real line terminators).
            if (comment_had_newline) self.at_line_start = true;
            continue;
        }

        // AnnexB §B.1.3 SingleLineHTMLOpenComment: `<!--` starts a
        // single-line comment anywhere it appears.
        if (c == '<' && self.peek_char_at(1) == '!' &&
            self.peek_char_at(2) == '-' && self.peek_char_at(3) == '-') {
            self.pos += 4;
            self.col += 4;
            while (!self.at_end()) {
                char cc = self.peek_char();
                if (cc == '\n' || cc == '\r') break;
                // U+2028 / U+2029 (UTF-8: E2 80 A8 / E2 80 A9) also
                // terminate single-line comments.
                if (cc == (char)0xE2 && self.remaining() >= 3) {
                    char cn1 = self.source[self.pos + 1];
                    char cn2 = self.source[self.pos + 2];
                    if (cn1 == (char)0x80 && (cn2 == (char)0xA8 || cn2 == (char)0xA9)) break;
                }
                self.pos++;
                self.col++;
            }
            continue;
        }

        // AnnexB §B.1.3 SingleLineHTMLCloseComment: `-->` starts a
        // single-line comment, but only when it occurs at the start of a
        // line (optionally preceded by whitespace and/or comments since the
        // last real line terminator, or since the start of source).
        if (self.at_line_start && c == '-' && self.peek_char_at(1) == '-' &&
            self.peek_char_at(2) == '>') {
            self.pos += 3;
            self.col += 3;
            while (!self.at_end()) {
                char cc = self.peek_char();
                if (cc == '\n' || cc == '\r') break;
                // U+2028 / U+2029 (UTF-8: E2 80 A8 / E2 80 A9) also
                // terminate single-line comments.
                if (cc == (char)0xE2 && self.remaining() >= 3) {
                    char cn1 = self.source[self.pos + 1];
                    char cn2 = self.source[self.pos + 2];
                    if (cn1 == (char)0x80 && (cn2 == (char)0xA8 || cn2 == (char)0xA9)) break;
                }
                self.pos++;
                self.col++;
            }
            continue;
        }

        // Unicode BOM (U+FEFF encoded as EF BB BF) treated as whitespace
        if (c == (char)0xEF && self.remaining() >= 3) {
            if (self.source[self.pos + 1] == (char)0xBB &&
                self.source[self.pos + 2] == (char)0xBF) {
                self.pos += 3;
                self.col++;
                continue;
            }
        }

        self.at_line_start = false;
        break;
    }
}

// ============================================================================
// Lexer — scan numeric literal
// ============================================================================

/// Parse a numeric literal token.
/// Supports: decimal, hex (0x/0X), octal (0o/0O), binary (0b/0B),
/// floating point with optional exponent.
fn Token? Lexer.scan_number(&self) {
    uint start_line = self.line;
    uint start_col = self.col;
    uint start_pos = self.pos;
    double value = 0.0;

    char c = self.peek_char();

    // Check for hex, octal, or binary prefix
    if (c == '0' && self.remaining() >= 2) {
        char next = self.peek_char_at(1);

        // Hexadecimal: 0x or 0X
        if (next == 'x' || next == 'X') {
            self.pos += 2;
            self.col += 2;
            if (self.at_end() || !is_hex_digit(self.peek_char())) {
                return LEX_ERROR~;
            }
            bool prev_was_digit = false;
            while (!self.at_end()) {
                c = self.peek_char();
                if (c == '_') {
                    if (!prev_was_digit) return LEX_ERROR~;
                    self.pos++;
                    self.col++;
                    prev_was_digit = false;
                    continue;
                }
                if (!is_hex_digit(c)) break;
                value = value * 16.0 + (double)hex_value(c);
                self.pos++;
                self.col++;
                prev_was_digit = true;
            }
            if (!prev_was_digit) return LEX_ERROR~;
            // Check for BigInt suffix 'n'
            if (!self.at_end() && self.peek_char() == 'n') {
                self.pos++;
                self.col++;
                Token tok = make_token(TokenType.BIGINT, start_line, start_col);
                tok.str_value = self.source[start_pos..self.pos-2]; // exclude 'n'
                return tok;
            }
            Token tok = make_token(TokenType.NUMBER, start_line, start_col);
            tok.num_value = value;
            tok.str_value = self.source[start_pos..self.pos-1];
            return tok;
        }

        // Octal: 0o or 0O
        if (next == 'o' || next == 'O') {
            self.pos += 2;
            self.col += 2;
            if (self.at_end() || !is_octal_digit(self.peek_char())) {
                return LEX_ERROR~;
            }
            bool prev_was_digit = false;
            while (!self.at_end()) {
                c = self.peek_char();
                if (c == '_') {
                    if (!prev_was_digit) return LEX_ERROR~;
                    self.pos++;
                    self.col++;
                    prev_was_digit = false;
                    continue;
                }
                if (!is_octal_digit(c)) break;
                value = value * 8.0 + (double)(c - '0');
                self.pos++;
                self.col++;
                prev_was_digit = true;
            }
            if (!prev_was_digit) return LEX_ERROR~;
            // Check for BigInt suffix 'n'
            if (!self.at_end() && self.peek_char() == 'n') {
                self.pos++;
                self.col++;
                Token tok = make_token(TokenType.BIGINT, start_line, start_col);
                tok.str_value = self.source[start_pos..self.pos-2];
                return tok;
            }
            Token tok = make_token(TokenType.NUMBER, start_line, start_col);
            tok.num_value = value;
            tok.str_value = self.source[start_pos..self.pos-1];
            return tok;
        }

        // Binary: 0b or 0B
        if (next == 'b' || next == 'B') {
            self.pos += 2;
            self.col += 2;
            if (self.at_end() || !is_binary_digit(self.peek_char())) {
                return LEX_ERROR~;
            }
            bool prev_was_digit = false;
            while (!self.at_end()) {
                c = self.peek_char();
                if (c == '_') {
                    if (!prev_was_digit) return LEX_ERROR~;
                    self.pos++;
                    self.col++;
                    prev_was_digit = false;
                    continue;
                }
                if (!is_binary_digit(c)) break;
                value = value * 2.0 + (double)(c - '0');
                self.pos++;
                self.col++;
                prev_was_digit = true;
            }
            if (!prev_was_digit) return LEX_ERROR~;
            // Check for BigInt suffix 'n'
            if (!self.at_end() && self.peek_char() == 'n') {
                self.pos++;
                self.col++;
                Token tok = make_token(TokenType.BIGINT, start_line, start_col);
                tok.str_value = self.source[start_pos..self.pos-2];
                return tok;
            }
            Token tok = make_token(TokenType.NUMBER, start_line, start_col);
            tok.num_value = value;
            tok.str_value = self.source[start_pos..self.pos-1];
            return tok;
        }
    }

    // Decimal: scan digits (integer + optional fraction + optional exponent)
    // to advance pos, then use strtod for precise parsing.
    bool dec_prev_was_digit = false;

    // Handle numbers starting with '.' (e.g., .5, .5e3)
    if (c == '.') {
        dec_prev_was_digit = true;  // implicit "0" before decimal point
    } else {
        while (!self.at_end()) {
            c = self.peek_char();
            if (c == '_') {
                if (!dec_prev_was_digit) return LEX_ERROR~;
                self.pos++;
                self.col++;
                dec_prev_was_digit = false;
                continue;
            }
            if (!is_digit(c)) break;
            self.pos++;
            self.col++;
            dec_prev_was_digit = true;
        }
        if (!dec_prev_was_digit) return LEX_ERROR~;
    }

    // Fractional part
    if (!self.at_end() && self.peek_char() == '.') {
        // Only skip if this is truly ... (ellipsis): three consecutive dots
        // 0..toString is valid: 0. is the number, .toString is property access
        char next1 = self.peek_char_at(1);
        char next2 = self.peek_char_at(2);
        bool is_ellipsis = (next1 == '.' && next2 == '.');
        if (!is_ellipsis) {
            self.pos++;
            self.col++;
            bool frac_prev_was_digit = false;
            while (!self.at_end()) {
                c = self.peek_char();
                if (c == '_') {
                    if (!frac_prev_was_digit) return LEX_ERROR~;
                    self.pos++;
                    self.col++;
                    frac_prev_was_digit = false;
                    continue;
                }
                if (!is_digit(c)) break;
                self.pos++;
                self.col++;
                frac_prev_was_digit = true;
            }
            // Fraction digits optional: "0." is a valid numeric literal (ES5 §7.8.3)
        }
    }

    // Exponent part
    if (!self.at_end() && (self.peek_char() == 'e' || self.peek_char() == 'E')) {
        self.pos++;
        self.col++;
        if (!self.at_end() && (self.peek_char() == '+' || self.peek_char() == '-')) {
            self.pos++;
            self.col++;
        }
        bool exp_prev_was_digit = false;
        while (!self.at_end()) {
            c = self.peek_char();
            if (c == '_') {
                if (!exp_prev_was_digit) return LEX_ERROR~;
                self.pos++;
                self.col++;
                exp_prev_was_digit = false;
                continue;
            }
            if (!is_digit(c)) break;
            self.pos++;
            self.col++;
            exp_prev_was_digit = true;
        }
        if (!exp_prev_was_digit) return LEX_ERROR~;
    }

    // Use js_atod for precise parsing (handles subnormals, avoids frac*=0.1 rounding).
    // QuickJS' js_atod is a David-Gay-style parser that matches V8/SpiderMonkey,
    // so "8.3 - 1 === 7.3" is true and literals round-trip consistently with
    // parseFloat().
    {
        uint len = self.pos - start_pos;
        char[64] buf;
        if (len < 64) {
            mem::copy(&buf, &self.source[start_pos], (sz)(len));
            // Strip numeric separators (_) before passing to js_atod
            uint j = 0;
            for (uint i = 0; i < len; i++) {
                if (buf[i] != '_') {
                    buf[j] = buf[i];
                    j++;
                }
            }
            buf[j] = 0;
            char* endptr;
            char[dtoa_bindings::DTOA_TMP_SIZE] tmp;
            value = dtoa_bindings::duktape_js_atod(&buf[0], &endptr, 0, 0, &tmp);
        } else {
            // Fallback: should never happen for valid JS number literals
            value = 0.0;
        }
    }

    // Check for BigInt suffix 'n'
    if (!self.at_end() && self.peek_char() == 'n') {
        // BigInt cannot have decimal point or exponent
        bool has_dot_or_exp = false;
        for (usz si = start_pos; si < self.pos; si++) {
            char sc = self.source[si];
            if (sc == '.' || sc == 'e' || sc == 'E') { has_dot_or_exp = true; break; }
        }
        if (has_dot_or_exp) return LEX_ERROR~;
        // ES2020 §11.8.3.1: a decimal BigInt literal must be `0n` or a
        // NonZeroDigit-led sequence.  A leading `0` followed by more digits
        // (legacy-octal-like `00n`/`07n` or non-octal `08n`/`012n`) is a
        // SyntaxError.  (0x/0o/0b prefixes are handled in earlier paths.)
        usz dec_len = (usz)self.pos - (usz)start_pos;
        if (dec_len > 1 && self.source[start_pos] == '0') {
            return LEX_ERROR~;
        }
        self.pos++;
        self.col++;
        Token tok = make_token(TokenType.BIGINT, start_line, start_col);
        tok.str_value = self.source[start_pos..self.pos-2]; // exclude 'n'
        return tok;
    }

    Token tok = make_token(TokenType.NUMBER, start_line, start_col);
    tok.num_value = value;
    tok.str_value = self.source[start_pos..self.pos-1];
    return tok;
}

// ============================================================================
// Lexer — scan string literal
// ============================================================================

/// Parse a string literal ('...' or "...").
/// Handles escape sequences: \n \r \t \b \f \v \\ \' \" \0
/// \xHH  \uHHHH  \u{H..H}  line continuation (\<newline>)
fn Token? Lexer.scan_string(&self) {
    uint start_line = self.line;
    uint start_col = self.col;
    char quote = self.advance_char();

    // Fast path: scan ahead to see if there are any escape sequences.
    // If not, we can return a slice directly into the source.
    uint scan_pos = self.pos;
    bool has_escapes = false;
    while (scan_pos < (uint)self.source.len) {
        char sc = self.source[scan_pos];
        if (sc == quote) break;
        if (sc == '\\') { has_escapes = true; break; }
        if (sc == '\n' || sc == '\r') {
            return LEX_ERROR~;
        }
        scan_pos++;
    }

    if (!has_escapes) {
        // No escapes — return slice into source
        uint str_start = self.pos;
        self.pos = scan_pos;
        self.col += scan_pos - str_start;
        if (self.at_end() || self.peek_char() != quote) {
            return LEX_ERROR~;
        }
        self.advance_char(); // consume closing quote
        Token tok = make_token(TokenType.STRING, start_line, start_col);
        if (scan_pos > str_start) {
            tok.str_value = self.source[str_start..scan_pos-1];
        } else {
            tok.str_value = {};
        }
        tok.str_owns_memory = false;
        return tok;
    }

    // Slow path: build decoded string in stack buffer.
    char[STRING_BUF_SIZE] buf;
    uint buf_len = 0;
    bool found_octal = false;

    while (!self.at_end()) {
        char ch = self.peek_char();

        if (ch == quote) {
            self.advance_char(); // consume closing quote
            Token tok = make_token(TokenType.STRING, start_line, start_col);
            if (buf_len > 0) {
                tok.str_value = buf[0..buf_len-1];
            } else {
                tok.str_value = {};
            }
            tok.str_owns_memory = false;
            tok.has_octal_escape = found_octal;
            return tok;
        }

        if (ch == '\n' || ch == '\r') {
            return LEX_ERROR~;
        }

        if (ch == '\\') {
            self.advance_char(); // consume backslash
            if (self.at_end()) return LEX_ERROR~;

            char esc = self.advance_char();
            switch (esc) {
                case 'n':  buf[buf_len] = '\n'; buf_len++;
                case 'r':  buf[buf_len] = '\r'; buf_len++;
                case 't':  buf[buf_len] = '\t'; buf_len++;
                case 'b':  buf[buf_len] = 0x08; buf_len++;
                case 'f':  buf[buf_len] = 0x0C; buf_len++;
                case 'v':  buf[buf_len] = 0x0B; buf_len++;
                case '0':
                    buf[buf_len] = 0;
                    buf_len++;
                    if (self.strict_mode && !self.at_end() && self.peek_char() >= '0' && self.peek_char() <= '9') {
                        found_octal = true;
                    }
                case '\'': buf[buf_len] = '\''; buf_len++;
                case '"':  buf[buf_len] = '"';  buf_len++;
                case '\\': buf[buf_len] = '\\'; buf_len++;

                case 'x':
                    // \xHH — Unicode codepoint U+00HH, encoded as UTF-8.
                    // Values >= 0x80 need a 2-byte UTF-8 sequence; storing
                    // the raw byte would produce invalid CESU-8 and cause
                    // str_intern to emit replacement characters.
                    if (self.remaining() < 2) return LEX_ERROR~;
                    char h1 = self.advance_char();
                    char h2 = self.advance_char();
                    if (!is_hex_digit(h1) || !is_hex_digit(h2)) return LEX_ERROR~;
                    uint hval = hex_value(h1) * 16 + hex_value(h2);
                    buf_len = encode_utf8_to_buf(&buf, buf_len, hval);

                case 'u':
                    if (self.at_end()) return LEX_ERROR~;
                    if (self.peek_char() == '{') {
                        // \u{H..H} — variable length Unicode escape
                        self.advance_char(); // consume {
                        uint ucp = 0;
                        uint udigits = 0;
                        while (!self.at_end() && self.peek_char() != '}') {
                            if (!is_hex_digit(self.peek_char())) return LEX_ERROR~;
                            ucp = ucp * 16 + hex_value(self.peek_char());
                            self.advance_char();
                            udigits++;
                            if (ucp > 0x10FFFF) return LEX_ERROR~;
                        }
                        if (self.at_end() || udigits == 0) return LEX_ERROR~;
                        self.advance_char(); // consume }
                        buf_len = encode_utf8_to_buf(&buf, buf_len, ucp);
                    } else {
                        // \uHHHH — exactly 4 hex digits
                        if (self.remaining() < 4) return LEX_ERROR~;
                        uint ucp4 = 0;
                        for (int i = 0; i < 4; i++) {
                            char hc = self.advance_char();
                            if (!is_hex_digit(hc)) return LEX_ERROR~;
                            ucp4 = ucp4 * 16 + hex_value(hc);
                        }
                        buf_len = encode_utf8_to_buf(&buf, buf_len, ucp4);
                    }

                case '\n':
                    // Line continuation — just skip the newline
                    break;
                case '\r':
                    // Line continuation — also skip following \n if present
                    if (!self.at_end() && self.peek_char() == '\n') {
                        self.advance_char();
                    }

                case 0xE2:
                    // LineContinuation also allows LS (U+2028 = 0xE2 0x80 0xA8)
                    // and PS (U+2029 = 0xE2 0x80 0xA9). The first byte (0xE2)
                    // was already consumed as `esc`; if the next two bytes form
                    // an LS/PS sequence, consume them as a line continuation
                    // (produces the empty code unit sequence). Otherwise fall
                    // through and emit 0xE2 as a literal character.
                    if (self.remaining() >= 2
                        && self.peek_char() == 0x80
                        && (self.peek_char_at(1) == 0xA8 || self.peek_char_at(1) == 0xA9)) {
                        self.advance_char(); // consume 0x80
                        self.advance_char(); // consume 0xA8 or 0xA9
                    } else {
                        buf[buf_len] = esc;
                        buf_len++;
                    }

                default:
                    // Non-escape: in non-strict mode, treat as literal.
                    // In strict mode, digit escapes (\1-\9) are octal/identity escapes
                    // that are SyntaxErrors per ES5 §7.8.4 + Annex B.1.2.
                    if (self.strict_mode && esc >= '1' && esc <= '9') {
                        found_octal = true;
                    }
                    buf[buf_len] = esc;
                    buf_len++;
            }
        } else {
            // Regular character
            buf[buf_len] = ch;
            buf_len++;
            self.advance_char();
        }

        if (buf_len >= STRING_BUF_SIZE - 6) {
            return LEX_ERROR~;
        }
    }

    // Reached end of source without closing quote
    return LEX_ERROR~;
}

// ============================================================================
// Lexer — scan identifier or keyword
// ============================================================================

/// Parse an identifier or keyword.
/// Unicode escapes (\uXXXX, \u{H+}) are decoded. Escaped identifiers
/// are never recognised as keywords.
fn Token? Lexer.scan_identifier(&self) {
    uint start_line = self.line;
    uint start_col = self.col;
    uint start_pos = self.pos;

    // Fast path: consume first char, scan for backslash.
    // Check the first character for backslash before consuming.
    bool has_escape = (self.peek_char() == 0x5C);
    if (!has_escape) {
        self.read_codepoint();
    }
    while (!self.at_end()) {
        uint cp = self.peek_codepoint();
        if (cp == 0x5C) { has_escape = true; break; }
        if (!is_identifier_part(cp)) break;
        self.read_codepoint();
    }

    if (!has_escape) {
        char[] name = self.source[start_pos..self.pos-1];
        if (try kw = lookup_keyword(name, self.strict_mode)) {
            Token tok = make_token(kw, start_line, start_col);
            tok.str_value = name;
            return tok;
        }
        Token tok = make_token(TokenType.IDENTIFIER, start_line, start_col);
        tok.str_value = name;
        return tok;
    }

    // Slow path: rewind and decode into ident_buf.
    self.pos = start_pos;
    char[] name = self.scan_ident_body_decoded()!;

    // Per ES2024 §12.6.1, an IdentifierName written via Unicode escapes that
    // resolves to a reserved word still behaves like that reserved word — a
    // parser trying to use it as a binding identifier (var \u{62}reak) must
    // reject it just like the unescaped form. The fast path above already
    // catches the unescaped form; mirror that here so the slow path produces
    // the same token (the parser relies on keyword tokens to reject reserved
    // words in declaration positions; IDENTIFIER would slip through).
    if (try kw = lookup_keyword(name, self.strict_mode)) {
        Token tok = make_token(kw, start_line, start_col);
        tok.str_value = name;
        return tok;
    }
    Token tok = make_token(TokenType.IDENTIFIER, start_line, start_col);
    tok.str_value = name;
    return tok;
}

/// Decode an identifier body (possibly containing \uXXXX / \u{H+} escapes)
/// from the current lexer position into `ident_buf`, re-encoding each
/// escaped or literal codepoint as UTF-8. Used by both plain identifiers
/// and private names (`#name`) since both allow Unicode escapes per spec.
/// Every codepoint (escaped or not) is validated against
/// is_identifier_start/is_identifier_part as it is decoded.
fn char[]? Lexer.scan_ident_body_decoded(&self) {
    uint buf_len = 0;
    bool first = true;

    while (!self.at_end() && buf_len < 4090) {
        uint cp = self.peek_codepoint();
        if (cp == 0x5C) {
            self.read_codepoint();
            if (self.at_end() || self.peek_char() != 'u') return LEX_ERROR~;
            self.advance_char();
            uint ucp;
            if (!self.at_end() && self.peek_char() == '{') {
                self.advance_char();
                ucp = 0;
                uint udigits = 0;
                while (!self.at_end() && self.peek_char() != '}') {
                    char hc = self.peek_char();
                    if (!is_hex_digit(hc)) return LEX_ERROR~;
                    ucp = ucp * 16 + hex_value(hc);
                    self.advance_char();
                    udigits++;
                    if (ucp > 0x10FFFF) return LEX_ERROR~;
                }
                if (self.at_end() || udigits == 0) return LEX_ERROR~;
                self.advance_char();
            } else {
                if (self.remaining() < 4) return LEX_ERROR~;
                ucp = 0;
                for (int i = 0; i < 4; i++) {
                    char hc = self.advance_char();
                    if (!is_hex_digit(hc)) return LEX_ERROR~;
                    ucp = ucp * 16 + hex_value(hc);
                }
            }
            if (first) { if (!is_identifier_start(ucp)) return LEX_ERROR~; }
            else { if (!is_identifier_part(ucp)) return LEX_ERROR~; }
            if (ucp < 0x80) { self.ident_buf[buf_len++] = (char)ucp; }
            else if (ucp < 0x800) { self.ident_buf[buf_len]=(char)(0xC0|(ucp>>6)); self.ident_buf[buf_len+1]=(char)(0x80|(ucp&0x3F)); buf_len+=2; }
            else if (ucp < 0x10000) { self.ident_buf[buf_len]=(char)(0xE0|(ucp>>12)); self.ident_buf[buf_len+1]=(char)(0x80|((ucp>>6)&0x3F)); self.ident_buf[buf_len+2]=(char)(0x80|(ucp&0x3F)); buf_len+=3; }
            else { self.ident_buf[buf_len]=(char)(0xF0|(ucp>>18)); self.ident_buf[buf_len+1]=(char)(0x80|((ucp>>12)&0x3F)); self.ident_buf[buf_len+2]=(char)(0x80|((ucp>>6)&0x3F)); self.ident_buf[buf_len+3]=(char)(0x80|(ucp&0x3F)); buf_len+=4; }
        } else if (is_identifier_part(cp)) {
            self.read_codepoint();
            if (cp < 0x80) { self.ident_buf[buf_len++] = (char)cp; }
            else if (cp < 0x800) { self.ident_buf[buf_len]=(char)(0xC0|(cp>>6)); self.ident_buf[buf_len+1]=(char)(0x80|(cp&0x3F)); buf_len+=2; }
            else if (cp < 0x10000) { self.ident_buf[buf_len]=(char)(0xE0|(cp>>12)); self.ident_buf[buf_len+1]=(char)(0x80|((cp>>6)&0x3F)); self.ident_buf[buf_len+2]=(char)(0x80|(cp&0x3F)); buf_len+=3; }
            else { self.ident_buf[buf_len]=(char)(0xF0|(cp>>18)); self.ident_buf[buf_len+1]=(char)(0x80|((cp>>12)&0x3F)); self.ident_buf[buf_len+2]=(char)(0x80|((cp>>6)&0x3F)); self.ident_buf[buf_len+3]=(char)(0x80|(cp&0x3F)); buf_len+=4; }
        } else {
            break;
        }
        first = false;
    }

    // Build name slice. C3's .. is inclusive, so [0..buf_len-1] gives buf_len bytes.
    //
    // NOTE: callers MUST treat this slice as a borrow only — ident_buf is a
    // per-Lexer scratch reused by every subsequent scan, so the parser can
    // only use the slice until the next token is scanned. Anything kept
    // across scans (PrivateNameEntry.name, scope_stack[i].name, label names,
    // module imports, etc.) MUST be interned at the storage site via
    // str_intern / add_string_constant so it points at stable heap memory.
    if (buf_len > 0) {
        return self.ident_buf[0..buf_len-1];
    }
    return {};
}

// ============================================================================
// Lexer — scan punctuator
// ============================================================================

/// Parse a punctuator (operator or delimiter).
/// Handles all single, double, triple, and quad-character operators.
fn Token? Lexer.scan_punctuator(&self) {
    uint start_line = self.line;
    uint start_col = self.col;
    char c = self.peek_char();
    char c2 = self.peek_char_at(1);
    char c3 = self.peek_char_at(2);
    char c4 = self.peek_char_at(3);

    // ---- Four-character operators ----

    // >>>= (unsigned right shift assign)
    if (c == '>' && c2 == '>' && c3 == '>' && c4 == '=') {
        self.pos += 4; self.col += 4;
        return make_token(TokenType.USHR_ASSIGN, start_line, start_col);
    }

    // ---- Three-character operators ----

    if (c == '=' && c2 == '=' && c3 == '=') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.SEQ, start_line, start_col);
    }
    if (c == '!' && c2 == '=' && c3 == '=') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.SNE, start_line, start_col);
    }
    if (c == '>' && c2 == '>' && c3 == '>') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.USHR, start_line, start_col);
    }
    if (c == '*' && c2 == '*' && c3 == '=') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.STARSTAR_ASSIGN, start_line, start_col);
    }
    if (c == '.' && c2 == '.' && c3 == '.') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.ELLIPSIS, start_line, start_col);
    }
    if (c == '<' && c2 == '<' && c3 == '=') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.SHL_ASSIGN, start_line, start_col);
    }
    if (c == '>' && c2 == '>' && c3 == '=') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.SHR_ASSIGN, start_line, start_col);
    }
    if (c == '&' && c2 == '&' && c3 == '=') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.LOG_AND_ASSIGN, start_line, start_col);
    }
    if (c == '|' && c2 == '|' && c3 == '=') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.LOG_OR_ASSIGN, start_line, start_col);
    }
    if (c == '?' && c2 == '?' && c3 == '=') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.NULLISH_ASSIGN, start_line, start_col);
    }

    // ---- Two-character operators ----

    if (c == '=' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.EQ, start_line, start_col);
    }
    if (c == '!' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.NE, start_line, start_col);
    }
    if (c == '=' && c2 == '>') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.ARROW, start_line, start_col);
    }
    if (c == '<' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.LE, start_line, start_col);
    }
    if (c == '>' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.GE, start_line, start_col);
    }
    if (c == '<' && c2 == '<') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.SHL, start_line, start_col);
    }
    if (c == '>' && c2 == '>') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.SHR, start_line, start_col);
    }
    if (c == '+' && c2 == '+') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.INC, start_line, start_col);
    }
    if (c == '-' && c2 == '-') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.DEC, start_line, start_col);
    }
    if (c == '+' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.PLUS_ASSIGN, start_line, start_col);
    }
    if (c == '-' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.MINUS_ASSIGN, start_line, start_col);
    }
    if (c == '*' && c2 == '*') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.STARSTAR, start_line, start_col);
    }
    if (c == '*' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.STAR_ASSIGN, start_line, start_col);
    }
    if (c == '/' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.SLASH_ASSIGN, start_line, start_col);
    }
    if (c == '%' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.PERCENT_ASSIGN, start_line, start_col);
    }
    if (c == '&' && c2 == '&') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.LOG_AND, start_line, start_col);
    }
    if (c == '|' && c2 == '|') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.LOG_OR, start_line, start_col);
    }
    if (c == '?' && c2 == '?') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.NULLISH, start_line, start_col);
    }
    if (c == '?' && c2 == '.') {
        // Optional chaining: ?. but NOT ?.digit (that would be ternary + .5)
        if (!is_digit(c3)) {
            self.pos += 2; self.col += 2;
            return make_token(TokenType.OPT_CHAIN, start_line, start_col);
        }
    }
    if (c == '&' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.BIT_AND_ASSIGN, start_line, start_col);
    }
    if (c == '|' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.BIT_OR_ASSIGN, start_line, start_col);
    }
    if (c == '^' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.BIT_XOR_ASSIGN, start_line, start_col);
    }

    // ---- Single-character operators ----

    self.pos++;
    self.col++;
    switch (c) {
        case '{': return make_token(TokenType.LBRACE, start_line, start_col);
        case '}': return make_token(TokenType.RBRACE, start_line, start_col);
        case '(': return make_token(TokenType.LPAREN, start_line, start_col);
        case ')': return make_token(TokenType.RPAREN, start_line, start_col);
        case '[': return make_token(TokenType.LBRACKET, start_line, start_col);
        case ']': return make_token(TokenType.RBRACKET, start_line, start_col);
        case '.': return make_token(TokenType.DOT, start_line, start_col);
        case ';': return make_token(TokenType.SEMICOLON, start_line, start_col);
        case ',': return make_token(TokenType.COMMA, start_line, start_col);
        case '<': return make_token(TokenType.LT, start_line, start_col);
        case '>': return make_token(TokenType.GT, start_line, start_col);
        case '=': return make_token(TokenType.ASSIGN, start_line, start_col);
        case '!': return make_token(TokenType.LOG_NOT, start_line, start_col);
        case '+': return make_token(TokenType.PLUS, start_line, start_col);
        case '-': return make_token(TokenType.MINUS, start_line, start_col);
        case '*': return make_token(TokenType.STAR, start_line, start_col);
        case '/': return make_token(TokenType.SLASH, start_line, start_col);
        case '%': return make_token(TokenType.PERCENT, start_line, start_col);
        case '&': return make_token(TokenType.BIT_AND, start_line, start_col);
        case '|': return make_token(TokenType.BIT_OR, start_line, start_col);
        case '^': return make_token(TokenType.BIT_XOR, start_line, start_col);
        case '~': return make_token(TokenType.BIT_NOT, start_line, start_col);
        case '?': return make_token(TokenType.QUESTION, start_line, start_col);
        case ':': return make_token(TokenType.COLON, start_line, start_col);
        case '#':
            // Private identifier: #name. The '#' is already consumed; scan
            // the identifier body and return HASH_IDENT with the text
            // *excluding* the '#'. Bypasses keyword lookup by construction.
            // Like plain identifiers, the name may contain \uXXXX / \u{H+}
            // Unicode escapes: fast-scan first, and if a backslash turns up
            // anywhere, rewind and decode the whole name via the shared
            // helper (same slow path as scan_identifier).
            if (self.at_end()) return LEX_ERROR~;
            uint name_start = self.pos;
            bool has_escape = (self.peek_char() == 0x5C);
            if (!has_escape) {
                uint cp2 = self.peek_codepoint();
                if (!is_identifier_start(cp2)) return LEX_ERROR~;
                self.read_codepoint();
            }
            while (!has_escape && !self.at_end()) {
                uint cp3 = self.peek_codepoint();
                if (cp3 == 0x5C) { has_escape = true; break; }
                if (!is_identifier_part(cp3)) break;
                self.read_codepoint();
            }
            Token tok = make_token(TokenType.HASH_IDENT, start_line, start_col);
            if (has_escape) {
                self.pos = name_start;
                tok.str_value = self.scan_ident_body_decoded()!;
            } else {
                tok.str_value = self.source[name_start..self.pos-1];
            }
            return tok;
        default:  return LEX_ERROR~;
    }
}

// ============================================================================
// Lexer — scan regular expression literal
// ============================================================================

/// Parse a regular expression literal: /pattern/flags
/// This should be called when the parser context indicates a regexp is
/// expected (i.e., not a division operator).
fn Token? Lexer.scan_regexp(&self) {
    uint start_line = self.line;
    uint start_col = self.col;
    uint start_pos = self.pos;

    // Consume the opening /
    self.advance_char();

    // Scan the pattern
    bool in_char_class = false;
    while (!self.at_end()) {
        char c = self.peek_char();

        if (c == '\n' || c == '\r') {
            return LEX_ERROR~;
        }

        if (c == '\\') {
            // Escape sequence — consume backslash and next char
            self.advance_char();
            if (self.at_end() || self.peek_char() == '\n') {
                return LEX_ERROR~;
            }
            self.advance_char();
            continue;
        }

        if (c == '[') {
            in_char_class = true;
            self.advance_char();
            continue;
        }

        if (c == ']' && in_char_class) {
            in_char_class = false;
            self.advance_char();
            continue;
        }

        if (c == '/' && !in_char_class) {
            break;
        }

        self.advance_char();
    }

    if (self.at_end() || self.peek_char() != '/') {
        return LEX_ERROR~;
    }

    // Consume the closing /
    self.advance_char();

    // Scan flags: g, i, m, s, u, y, d
    while (!self.at_end()) {
        char fc = self.peek_char();
        if ((fc >= 'a' && fc <= 'z') || (fc >= 'A' && fc <= 'Z')) {
            self.advance_char();
        } else {
            break;
        }
    }

    Token tok = make_token(TokenType.REGEXP, start_line, start_col);
    tok.str_value = self.source[start_pos..self.pos-1];
    return tok;
}

// ============================================================================
// Lexer — scan template literal
// ============================================================================

/// Scan the content of a template string part (between delimiters).
/// Processes escape sequences and returns the decoded ("cooked") string.
/// Reads until it encounters `, $, or the end of input.
/// Returns the decoded text (may be empty) and sets `end_char` to the
/// character that terminated the scan: '`' for backtick, '$' for "${",
/// or 0 for end-of-input (error).
/// For tagged templates, invalid escape sequences are allowed; in that
/// case `has_invalid_escape` is set and the returned string is the raw
/// (uncooked) source text of the part.
fn char[]? Lexer.scan_template_content(&self, char* end_char, bool* has_escapes, bool* has_invalid_escape, char[]* raw_out) {
    uint start_pos = self.pos;
    *has_invalid_escape = false;
    *raw_out = {};

    // Fast path: scan ahead to see if there are any escape sequences
    // or special characters (`, $). A bare CR also routes to the slow
    // path so CR / CRLF can be normalized to LF (TV/TRV of
    // LineTerminatorSequence, ES2015 11.8.6.1) in both cooked and raw text.
    uint scan_pos = self.pos;
    bool found_escapes = false;
    while (scan_pos < (uint)self.source.len) {
        char sc = self.source[scan_pos];
        if (sc == '`') {
            *end_char = '`';
            break;
        }
        if (sc == '$' && scan_pos + 1 < (uint)self.source.len && self.source[scan_pos + 1] == '{') {
            *end_char = '$';
            break;
        }
        if (sc == '\\' || sc == '\r') {
            found_escapes = true;
            break;
        }
        if (sc == '\n') {
            // Line terminator is allowed in templates
            scan_pos++;
            continue;
        }
        scan_pos++;
    }

    if (scan_pos == (uint)self.source.len) {
        *end_char = 0;
        *has_escapes = found_escapes;
        return {};
    }

    if (!found_escapes) {
        // No escapes — return slice into source
        uint text_len = scan_pos - start_pos;
        self.pos = scan_pos;
        self.col += text_len;
        // Count newlines in the text
        for (uint i = start_pos; i < scan_pos; i++) {
            if (self.source[i] == '\n') {
                self.line++;
                self.col = 1;
            }
        }
        *has_escapes = false;
        if (text_len > 0) {
            char[] slice = self.source[start_pos..scan_pos - 1];
            *raw_out = slice;
            return slice;
        }
        return {};
    }

    // Slow path: build decoded (cooked) and raw text in parallel stack buffers.
    // The raw buffer mirrors the source text exactly except that bare CR and
    // CRLF sequences are normalized to LF, per the TRV of LineTerminatorSequence
    // (ES2015 11.8.6.1) — this applies to raw text just as much as cooked.
    char[STRING_BUF_SIZE] buf;
    uint buf_len = 0;
    char[STRING_BUF_SIZE] raw_buf;
    uint raw_len = 0;

    while (!self.at_end()) {
        char ch = self.peek_char();

        if (ch == '`') {
            *end_char = '`';
            break;
        }
        if (ch == '$' && self.peek_char_at(1) == '{') {
            *end_char = '$';
            break;
        }
        if (ch == '\n' || ch == '\r') {
            self.advance_char();
            if (ch == '\r' && !self.at_end() && self.peek_char() == '\n') {
                self.advance_char();
            }
            buf[buf_len] = '\n'; buf_len++;
            raw_buf[raw_len] = '\n'; raw_len++;
            continue;
        }

        if (ch == '\\') {
            uint esc_start = self.pos;
            self.advance_char(); // consume backslash
            if (self.at_end()) {
                *has_invalid_escape = true;
                break;
            }

            char esc = self.peek_char();

            // Line continuation: \<LF> or \<CR><LF>
            if (esc == '\n') {
                self.advance_char();
                raw_buf[raw_len] = '\\'; raw_len++;
                raw_buf[raw_len] = '\n'; raw_len++;
                continue;
            }
            if (esc == '\r') {
                self.advance_char();
                if (!self.at_end() && self.peek_char() == '\n') {
                    self.advance_char();
                }
                raw_buf[raw_len] = '\\'; raw_len++;
                raw_buf[raw_len] = '\n'; raw_len++;
                continue;
            }
            // Line continuation: \<LS> or \<PS> (UTF-8: E2 80 A8 / E2 80 A9).
            // Unlike CR/CRLF, these are kept as-is (not normalized to LF) in
            // both cooked (elided) and raw text.
            if (esc == (char)0xE2 && self.remaining() >= 3
                && self.peek_char_at(1) == (char)0x80
                && (self.peek_char_at(2) == (char)0xA8 || self.peek_char_at(2) == (char)0xA9)) {
                raw_buf[raw_len] = '\\'; raw_len++;
                raw_buf[raw_len] = self.advance_char(); raw_len++;
                raw_buf[raw_len] = self.advance_char(); raw_len++;
                raw_buf[raw_len] = self.advance_char(); raw_len++;
                continue;
            }

            // Invalid legacy octal / decimal escapes: \1-\9 and \0 followed by a digit.
            if ((esc >= '1' && esc <= '9') ||
                (esc == '0' && !self.at_end() && self.peek_char_at(1) >= '0' && self.peek_char_at(1) <= '9')) {
                *has_invalid_escape = true;
                break;
            }

            self.advance_char(); // consume escape char
            switch (esc) {
                case 'n':  buf[buf_len] = '\n'; buf_len++;
                case 'r':  buf[buf_len] = '\r'; buf_len++;
                case 't':  buf[buf_len] = '\t'; buf_len++;
                case 'b':  buf[buf_len] = 0x08; buf_len++;
                case 'f':  buf[buf_len] = 0x0C; buf_len++;
                case 'v':  buf[buf_len] = 0x0B; buf_len++;
                case '0':  buf[buf_len] = 0; buf_len++;
                case '\'': buf[buf_len] = '\''; buf_len++;
                case '"':  buf[buf_len] = '"';  buf_len++;
                case '\\': buf[buf_len] = '\\'; buf_len++;
                case '`':  buf[buf_len] = '`';  buf_len++;
                case '$':  buf[buf_len] = '$';  buf_len++;  // \$ escapes dollar

                case 'x':
                    // \xHH in template literals — same UTF-8 encoding fix as
                    // in regular string literals: the value is a Unicode codepoint.
                    if (self.remaining() < 2 ||
                        !is_hex_digit(self.peek_char()) ||
                        !is_hex_digit(self.peek_char_at(1))) {
                        *has_invalid_escape = true;
                        break;
                    }
                    {
                        char h1 = self.advance_char();
                        char h2 = self.advance_char();
                        uint hval = hex_value(h1) * 16 + hex_value(h2);
                        buf_len = encode_utf8_to_buf(&buf, buf_len, hval);
                    }

                case 'u':
                    if (self.at_end()) { *has_invalid_escape = true; break; }
                    if (self.peek_char() == '{') {
                        // Peek the braced unicode escape without consuming so
                        // we can fall back to raw text on invalid input.
                        uint peek_pos = self.pos + 1; // after '{'
                        uint ucp = 0;
                        uint udigits = 0;
                        bool uvalid = true;
                        while (peek_pos < (uint)self.source.len && self.source[peek_pos] != '}') {
                            if (!is_hex_digit(self.source[peek_pos])) { uvalid = false; break; }
                            ucp = ucp * 16 + hex_value(self.source[peek_pos]);
                            peek_pos++;
                            udigits++;
                            if (ucp > 0x10FFFF) { uvalid = false; break; }
                        }
                        if (!uvalid || udigits == 0 || peek_pos >= (uint)self.source.len) {
                            *has_invalid_escape = true;
                            break;
                        }
                        // Valid \u{H+}; consume it.
                        self.advance_char(); // {
                        for (uint i = 0; i < udigits; i++) {
                            self.advance_char();
                        }
                        self.advance_char(); // }
                        buf_len = encode_utf8_to_buf(&buf, buf_len, ucp);
                    } else {
                        if (self.remaining() < 4 ||
                            !is_hex_digit(self.peek_char()) ||
                            !is_hex_digit(self.peek_char_at(1)) ||
                            !is_hex_digit(self.peek_char_at(2)) ||
                            !is_hex_digit(self.peek_char_at(3))) {
                            *has_invalid_escape = true;
                            break;
                        }
                        uint ucp4 = 0;
                        for (int i = 0; i < 4; i++) {
                            char hc = self.advance_char();
                            ucp4 = ucp4 * 16 + hex_value(hc);
                        }
                        buf_len = encode_utf8_to_buf(&buf, buf_len, ucp4);
                    }

                default:
                    // Other non-standard escape (e.g. \q) — emit the character as-is.
                    buf[buf_len] = esc; buf_len++;
            }
            if (*has_invalid_escape) break;
            // Raw text mirrors the literal escape sequence verbatim (backslash
            // plus whatever followed it), since none of the cases above are
            // LineTerminatorSequences (already handled earlier as \<LF>/\<CR>).
            for (uint ri = esc_start; ri < self.pos; ri++) {
                raw_buf[raw_len] = self.source[ri]; raw_len++;
            }
            continue;
        }

        char plain = self.advance_char();
        buf[buf_len] = plain; buf_len++;
        raw_buf[raw_len] = plain; raw_len++;
    }

    if (*has_invalid_escape) {
        // Invalid escape in a template part. For tagged templates this is
        // allowed and the cooked value is undefined; the raw value is the
        // literal source text. Scan the rest of the part as raw text.
        while (!self.at_end()) {
            char ch = self.peek_char();
            if (ch == '`') {
                *end_char = '`';
                break;
            }
            if (ch == '$' && self.peek_char_at(1) == '{') {
                *end_char = '$';
                break;
            }
            self.advance_char();
        }
        if (self.at_end()) {
            *end_char = 0;
        }
        uint raw_end = self.at_end() ? (uint)self.source.len : self.pos;
        if (raw_end > start_pos) {
            // Normalize CR / CRLF to LF in the raw text (TRV of
            // LineTerminatorSequence), same as the cooked-scanning path above.
            uint out_len = 0;
            uint ri = start_pos;
            while (ri < raw_end) {
                char rc = self.source[ri];
                if (rc == '\r') {
                    raw_buf[out_len] = '\n'; out_len++;
                    ri++;
                    if (ri < raw_end && self.source[ri] == '\n') { ri++; }
                    continue;
                }
                raw_buf[out_len] = rc; out_len++;
                ri++;
            }
            char[] slice = self.source[start_pos..raw_end - 1];
            if (out_len > 0) {
                *raw_out = raw_buf[0..out_len - 1];
            } else {
                *raw_out = {};
            }
            return slice;
        }
        return {};
    }

    *has_escapes = true;
    *end_char = (self.at_end()) ? 0 : self.peek_char();
    if (raw_len > 0) {
        *raw_out = raw_buf[0..raw_len - 1];
    }
    if (buf_len > 0) {
        return buf[0..buf_len - 1];
    }
    return {};
}

/// Parse a template literal heading (opening backtick to first "${" or closing backtick).
/// Returns TEMPLATE_HEAD if we found "${", or STRING if no substitutions (simple template).
fn Token? Lexer.scan_template_head(&self) {
    uint start_line = self.line;
    uint start_col = self.col;

    // Consume the opening backtick
    self.advance_char();

    char end_char = 0;
    bool has_escapes = false;
    bool has_invalid_escape = false;
    char[] raw_text = {};
    char[]? content = self.scan_template_content(&end_char, &has_escapes, &has_invalid_escape, &raw_text);

    if (catch err = content) {
        return LEX_ERROR~;
    }

    if (end_char == '`') {
        // No substitutions — this is a simple string template
        self.advance_char(); // consume closing backtick
        Token tok = make_token(TokenType.STRING, start_line, start_col);
        tok.str_value = content;
        tok.raw_value = raw_text;
        tok.str_owns_memory = false;
        tok.is_template = true;
        tok.has_invalid_escape = has_invalid_escape;
        return tok;
    }

    if (end_char == '$') {
        // Template expression start: "${"
        self.advance_char(); // $
        self.advance_char(); // {
        Token tok = make_token(TokenType.TEMPLATE_HEAD, start_line, start_col);
        tok.str_value = content;
        tok.raw_value = raw_text;
        tok.str_owns_memory = false;
        tok.is_template = true;
        tok.has_invalid_escape = has_invalid_escape;
        return tok;
    }

    // Unterminated template literal
    return LEX_ERROR~;
}

/// Scan the part of a template literal after a closing "}" of an expression.
/// Produces TEMPLATE_MIDDLE or TEMPLATE_TAIL.
fn Token? Lexer.scan_template_after_expr(&self) {
    uint start_line = self.line;
    uint start_col = self.col;

    char end_char = 0;
    bool has_escapes = false;
    bool has_invalid_escape = false;
    char[] raw_text = {};
    char[]? content = self.scan_template_content(&end_char, &has_escapes, &has_invalid_escape, &raw_text);

    if (catch err = content) {
        return LEX_ERROR~;
    }

    if (end_char == '`') {
        // End of template literal
        self.advance_char(); // consume closing backtick
        Token tok = make_token(TokenType.TEMPLATE_TAIL, start_line, start_col);
        tok.str_value = content;
        tok.raw_value = raw_text;
        tok.str_owns_memory = false;
        tok.is_template = true;
        tok.has_invalid_escape = has_invalid_escape;
        return tok;
    }

    if (end_char == '$') {
        // Another template expression: "${"
        self.advance_char(); // $
        self.advance_char(); // {
        Token tok = make_token(TokenType.TEMPLATE_MIDDLE, start_line, start_col);
        tok.str_value = content;
        tok.raw_value = raw_text;
        tok.str_owns_memory = false;
        tok.is_template = true;
        tok.has_invalid_escape = has_invalid_escape;
        return tok;
    }

    // Unterminated template literal
    return LEX_ERROR~;
}

/// Called by the parser immediately after consuming a `}` that closes a
/// BlockStatement, function body, or class body in statement position —
/// contexts where a following `/` must be read as a RegularExpressionLiteral
/// rather than division.
fn void Lexer.note_block_close(&self) {
    self.force_regex_after_brace = true;
}

/// Check if the previous token was an operand, meaning `/` should be
/// treated as division rather than the start of a regexp literal.
/// Follows the ECMAScript lexical grammar: after identifiers, literals,
/// closing brackets, `this`, `true`, `false`, `null`, the `/` is
/// division; otherwise it starts a regexp.
fn bool Lexer.prev_was_operand(&self) {
    switch (self.current.type) {
        case TokenType.RPAREN:
        case TokenType.RBRACKET:
        case TokenType.RBRACE:
        case TokenType.IDENTIFIER:
        case TokenType.NUMBER:
        case TokenType.BIGINT:
        case TokenType.STRING:
        case TokenType.REGEXP:
        case TokenType.TEMPLATE:
        case TokenType.TEMPLATE_HEAD:
        case TokenType.TEMPLATE_MIDDLE:
        case TokenType.TEMPLATE_TAIL:
        case TokenType.THIS:
            return true;
        default:
            return false;
    }
}

// ============================================================================
// Lexer — main tokenisation entry point
// ============================================================================

/// Advance to the next token and return it.
fn Token? Lexer.next_token(&self) {
    // Check pushback buffer first
    if (self.has_pushed_back) {
        self.has_pushed_back = false;
        self.current = self.pushed_back;
        // No token_start update — pushback is purely speculative; the prior
        // token_start still reflects the most recently *consumed* token.
        return self.current;
    }

    // If we have a lookahead token, consume it.
    if (self.has_lookahead) {
        self.has_lookahead = false;
        self.current = self.lookahead;
        // Restore the token-start saved when peek() built the lookahead so
        // that `token_start` reflects the position of the token we're now
        // actually consuming (matches the non-lookahead path's contract).
        self.token_start = self.lookahead_token_start;
        return self.current;
    }

    self.skip_whitespace_and_comments();

    // Capture the start of the upcoming token so callers can recover the source
    // span after consumption (Function.prototype.toString retention).
    self.token_start = self.pos;

    // Consume the block-close regex hint: it only affects the immediately
    // following token's `/` disambiguation, so clear it now.
    bool force_regex = self.force_regex_after_brace;
    self.force_regex_after_brace = false;

    if (self.at_end()) {
        Token tok = make_token(TokenType.EOF_TOKEN, self.line, self.col);
        self.current = tok;
        return tok;
    }

    char c = self.peek_char();

    // Number: starts with a digit, or . followed by a digit
    if (is_digit(c) || (c == '.' && self.remaining() >= 2 && is_digit(self.peek_char_at(1)))) {
        Token tok = self.scan_number()!;
        self.current = tok;
        return tok;
    }

    // String literal
    if (c == '\'' || c == '"') {
        Token tok = self.scan_string()!;
        self.current = tok;
        return tok;
    }

    // Template literal
    if (c == '`') {
        Token tok = self.scan_template_head()!;
        self.current = tok;
        return tok;
    }

    // Identifier or keyword
    uint cp = self.peek_codepoint();
    if (is_identifier_start(cp) || cp == '\\') {
        Token tok = self.scan_identifier()!;
        self.current = tok;
        return tok;
    }

    // Check for regexp literal vs division operator
    if (c == '/') {
        // /= is always division-assign, handle normally via scan_punctuator
        if (self.peek_char_at(1) != '=' && (force_regex || !self.prev_was_operand())) {
            Token tok = self.scan_regexp()!;
            self.current = tok;
            return tok;
        }
    }

    // Punctuator
    Token tok = self.scan_punctuator()!;
    self.current = tok;
    return tok;
}

/// Peek at the next token without consuming it.
fn Token? Lexer.peek(&self) {
    // Check pushback buffer first
    if (self.has_pushed_back) {
        return self.pushed_back;
    }

    if (self.has_lookahead) {
        return self.lookahead;
    }

    // Save current state — including token_start so peek doesn't shift it.
    // Without this guard, after peeking the lookahead, `lexer.token_start`
    // would reflect the *peeked* token rather than the most recently *consumed*
    // one — so e.g. capturing `lexer.token_start` after `check(ARROW)` for an
    // `IDENT ARROW` arrow head would yield the arrow's position, not `IDENT`'s.
    Token saved_current = self.current;
    uint saved_token_start = self.token_start;

    // The lookahead token's source start is whatever `next_token` set
    // `token_start` to (position after skip_whitespace). Capture it AFTER
    // `next_token` returns so we get the actual start of the scanned token,
    // not whatever stale value `token_start` held before. The lookahead
    // consume path in next_token() restores this via lookahead_token_start.
    Token tok = self.next_token()!;
    self.lookahead = tok;
    self.has_lookahead = true;
    self.lookahead_token_start = self.token_start;

    // Restore current and token_start (next_token overwrote them)
    self.current = saved_current;
    self.token_start = saved_token_start;

    return tok;
}

/// Expect the next token to be of the given type.
/// If it matches, advance past it and return the consumed token.
/// Otherwise return LEX_ERROR.
fn Token? Lexer.expect(&self, TokenType expected) {
    Token tok = self.next_token()!;
    if (tok.type != expected) {
        return LEX_ERROR~;
    }
    return tok;
}

/// Refresh `token_start` to point at the start of the next-to-be-consumed
/// token. Call when the caller wants to remember the source position of the
/// next token without committing the consume; subsequent calls to
/// `next_token` will return that same token unchanged.
///
/// Use case: class-body loops where each iteration needs to remember the
/// offset of its *first* token (e.g. for Function.prototype.toString), but
/// `token_start` may be stale from the previous iteration (reflects the last
/// consumed token's position).
fn void Lexer.refresh_token_start(&self) {
    if (self.has_pushed_back) return;
    if (self.has_lookahead) {
        // The lookahead was produced by peek(); its source start is saved in
        // lookahead_token_start. Copy it over so token_start agrees.
        self.token_start = self.lookahead_token_start;
        return;
    }
    // No cached token — scan one forward, then pushback so the lexer state
    // appears unchanged for the next consumer.
    if (try tok = self.next_token()) {
        self.pushed_back = tok;
        self.has_pushed_back = true;
        // next_token() set token_start to the start of `tok`'s source text —
        // keep it.
    }
    // On lex failure, leave token_start stale; the next consumer will fail
    // anyway.
}

/// Check if the next token is of the given type without consuming it.
fn bool Lexer.check(&self, TokenType tt) {
    if (try tok = self.peek()) {
        return tok.type == tt;
    }
    return false;
}

/// If the next token matches the given type, consume it and return true.
/// Otherwise leave the lexer state unchanged and return false.
fn bool Lexer.match_token(&self, TokenType tt) {
    if (self.check(tt)) {
        if (try _tok = self.next_token()) {
            return true;
        }
    }
    return false;
}

/// Push a token back into the input stream for limited backtracking.
/// The next call to next_token() will return this token.
fn void Lexer.pushback(&self, Token tok) {
    self.pushed_back = tok;
    self.has_pushed_back = true;
}

/// Enable or disable strict-mode keyword recognition.
/// When enabled, FutureReservedWords (implements, interface, package,
/// private, protected, public) are recognised as keywords.
fn void Lexer.set_strict(&self, bool s) {
    self.strict_mode = s;
}

// Statement-structure tracking for the compiler's token pre-scans.
//
// The lexer decides regex versus division from the previous token, and the
// parser overrides that where the grammar says otherwise. A pre-scan runs the
// lexer ahead of the parser without those overrides, so it needs the same
// answers from the token stream alone:
//
//   if (x) /re/.test(s)     `/` after the `)` of an if/while/for/with head
//   { } /re/.test(s)        `/` after the `}` of a statement block
//   for (a of /re/.exec(s)) `/` after the contextual `of`
//
// and it must not read a template substitution's closing `}` as a block end:
//
//   `a${b}c`                the `}` resumes template text
//
// ScanHint is that tracking. It is off outside the pre-scans. A pre-scan turns
// it on right after taking its lexer snapshot and the snapshot restore turns
// it off again, so the real parse never sees it.
module boomkat::lexer;

// Frames beyond this depth are not tracked: their bits read as zero, which is
// the default (division after `)` and `}`, no template substitution).
const uint SCAN_HINT_MAX_DEPTH = 64;

struct ScanHint {
    bool on;
    // The lexer itself consumes the template text after a substitution's `}`
    // and returns TEMPLATE_MIDDLE or TEMPLATE_TAIL in place of RBRACE. Scans
    // that classify `}` with a TemplateScan leave this off.
    bool auto_template;
    // The next `/` starts a regex literal.
    bool regex_next;
    // The next token begins a statement.
    bool stmt_start;
    // A function or class declaration's body `{` is the next one seen at
    // paren depth decl_paren_depth.
    bool decl_pending;
    // The most recent `)` closed an if/while/for/with/switch/catch head.
    bool last_rparen_head;
    TokenType prev;
    TokenType prev2;
    uint paren_depth;
    uint brace_depth;
    uint decl_paren_depth;
    // Bit n describes the frame at depth n.
    ulong paren_head;   // `(` opened a statement head
    ulong paren_for;    // `(` opened a `for` head
    ulong brace_block;  // `{` opened a statement block
    ulong brace_subst;  // slot is a template substitution
}

fn ScanHint scan_hint_start(TokenType prev, bool auto_template) {
    ScanHint h;
    h.on = true;
    h.auto_template = auto_template;
    h.stmt_start = true;
    h.prev = prev;
    return h;
}

macro bool ScanHint.bit(&self, ulong mask, uint depth) {
    return depth < SCAN_HINT_MAX_DEPTH && ((mask >> depth) & 1) != 0;
}

macro ulong ScanHint.with_bit(&self, ulong mask, uint depth, bool value) {
    if (depth >= SCAN_HINT_MAX_DEPTH) return mask;
    ulong one = (ulong)1 << depth;
    return value ? (mask | one) : (mask & ~one);
}

// The next `}` closes a template substitution.
fn bool ScanHint.top_is_subst(&self) {
    return self.brace_depth > 0 && self.bit(self.brace_subst, self.brace_depth - 1);
}

// A TEMPLATE_MIDDLE or TEMPLATE_TAIL token was produced after a substitution.
fn void ScanHint.on_template_part(&self, TokenType part) {
    if (!self.on) return;
    self.regex_next = false;
    self.stmt_start = false;
    if (part == TokenType.TEMPLATE_TAIL && self.top_is_subst()) {
        self.brace_depth--;
        self.brace_subst = self.with_bit(self.brace_subst, self.brace_depth, false);
        self.brace_block = self.with_bit(self.brace_block, self.brace_depth, false);
    }
    self.prev2 = self.prev;
    self.prev = part;
}

fn bool token_text_is(Token* tok, String text) {
    if (tok.str_value.len != text.len) return false;
    for (usz i = 0; i < text.len; i++) {
        if (tok.str_value[i] != text[i]) return false;
    }
    return true;
}

// Account for one token the lexer just produced.
fn void ScanHint.update(&self, Token* tok) {
    TokenType tt = tok.type;
    bool was_stmt_start = self.stmt_start;
    bool prev_is_for = self.prev == TokenType.FOR
        || (self.prev == TokenType.AWAIT && self.prev2 == TokenType.FOR);
    self.regex_next = false;
    self.stmt_start = false;

    switch (tt) {
        case TokenType.LPAREN:
            bool head = self.prev == TokenType.IF || self.prev == TokenType.WHILE
                || self.prev == TokenType.FOR || self.prev == TokenType.WITH
                || self.prev == TokenType.SWITCH || self.prev == TokenType.CATCH
                || prev_is_for;
            self.paren_head = self.with_bit(self.paren_head, self.paren_depth, head);
            self.paren_for = self.with_bit(self.paren_for, self.paren_depth, prev_is_for);
            self.paren_depth++;
        case TokenType.RPAREN:
            bool head = false;
            if (self.paren_depth > 0) {
                self.paren_depth--;
                head = self.bit(self.paren_head, self.paren_depth);
            }
            self.last_rparen_head = head;
            self.regex_next = head;
            self.stmt_start = head;
        case TokenType.LBRACE:
            bool block = was_stmt_start
                || (self.decl_pending && self.paren_depth == self.decl_paren_depth)
                || (self.prev == TokenType.RPAREN && self.last_rparen_head)
                || self.prev == TokenType.ELSE || self.prev == TokenType.DO
                || self.prev == TokenType.TRY || self.prev == TokenType.FINALLY;
            if (self.decl_pending && self.paren_depth == self.decl_paren_depth) {
                self.decl_pending = false;
            }
            // What follows the `{` is a statement list for a block and for a
            // function, method, arrow or static-block body. Whether the closing
            // `}` ends a statement (regex next) is only true of `block`: a
            // function expression's `}` ends an operand.
            bool statements = block || self.prev == TokenType.RPAREN
                || self.prev == TokenType.ARROW || self.prev == TokenType.STATIC;
            self.brace_block = self.with_bit(self.brace_block, self.brace_depth, block);
            self.brace_subst = self.with_bit(self.brace_subst, self.brace_depth, false);
            self.brace_depth++;
            self.stmt_start = statements;
        case TokenType.RBRACE:
            // A substitution's `}` stays on the stack until the template part
            // after it arrives (on_template_part).
            if (self.brace_depth > 0 && !self.top_is_subst()) {
                self.brace_depth--;
                bool block = self.bit(self.brace_block, self.brace_depth);
                self.regex_next = block;
                self.stmt_start = block;
            }
        case TokenType.TEMPLATE_HEAD:
            self.brace_block = self.with_bit(self.brace_block, self.brace_depth, false);
            self.brace_subst = self.with_bit(self.brace_subst, self.brace_depth, true);
            self.brace_depth++;
        case TokenType.FUNCTION:
        case TokenType.CLASS:
            if (was_stmt_start) {
                self.decl_pending = true;
                self.decl_paren_depth = self.paren_depth;
            }
        case TokenType.SEMICOLON:
        case TokenType.ELSE:
        case TokenType.DO:
        case TokenType.EXPORT:
            self.stmt_start = true;
        case TokenType.IDENTIFIER:
            // `async function f() {}` is a declaration when `async` starts a
            // statement.
            if (token_text_is(tok, "async")) {
                self.stmt_start = was_stmt_start;
            } else if (token_text_is(tok, "of") && self.paren_depth > 0
                && self.bit(self.paren_for, self.paren_depth - 1)) {
                self.regex_next = true;
            }
        default:
    }
    self.prev2 = self.prev;
    self.prev = tt;
}

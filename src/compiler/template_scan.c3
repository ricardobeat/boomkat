module boomkat::compiler;
import boomkat::lexer;

// ============================================================================
// Template-aware brace classification for token-level scanners
// ============================================================================
//
// The skip/hoist/prescan helpers walk raw tokens without building an AST, so
// they must decide for every `}` whether it closes a JS block or a `${...}`
// template substitution (whose following template part must be consumed via
// scan_template_after_expr, since the lexer cannot know on its own that a
// `}` resumes template text). Two things make a naive `template_depth > 0`
// test wrong:
//
//   - a substitution expression can itself contain `{...}` (object literals,
//     block-bodied arrows: `${ (() => { ... })() }`), whose braces are
//     ordinary JS braces, not the substitution's close;
//   - template literals nest (`${ `inner ${x}` }`), and each nesting level
//     tracks its own count of open expression braces.
//
// TemplateScan keeps a per-level count of JS braces opened inside each
// substitution expression. Call on_template_head / on_lbrace / classify_rbrace
// for the corresponding tokens; every other token is none of its business.
// Expression-internal braces are still reported as BLOCK so each scanner's
// own depth and region logic sees them exactly like braces outside a template,
// they always come in balanced pairs, so caller-side counters net to zero.

// Substitution nesting beyond this depth shares the last slot, so behavior
// degrades to a per-32-levels shared counter instead of failing. Real code
// never nests 32 template substitutions.
const uint TEMPLATE_SCAN_MAX_DEPTH = 32;

struct TemplateScan {
    // Open `${` substitution levels.
    uint depth;
    // Per-level count of JS `{` opened inside the substitution expression.
    uint[TEMPLATE_SCAN_MAX_DEPTH] expr_braces;
}

enum TemplateBrace : char {
    // Ordinary JS brace (outside any substitution, or expression-internal):
    // the caller applies its own block/depth logic.
    BLOCK,
    // The `}` closed a template substitution; the following template part
    // (middle or tail) has been consumed. The caller skips its block logic.
    SUBST,
    // The lexer failed while consuming the template part; the caller should
    // bail out the same way it does for any other lex error.
    LEX_ERROR,
}

macro uint TemplateScan.level_idx(&self) {
    return (self.depth < TEMPLATE_SCAN_MAX_DEPTH ? self.depth : TEMPLATE_SCAN_MAX_DEPTH) - 1;
}

// TEMPLATE_HEAD token: the lexer consumed `` `...${ `` and substitution
// expression tokens follow.
fn void TemplateScan.on_template_head(&self) {
    self.depth++;
    if (self.depth <= TEMPLATE_SCAN_MAX_DEPTH) {
        self.expr_braces[self.depth - 1] = 0;
    }
}

// LBRACE token. Callers still run their own brace logic afterwards, since this
// only records expression-internal opens so classify_rbrace can match them.
fn void TemplateScan.on_lbrace(&self) {
    if (self.depth > 0) {
        self.expr_braces[self.level_idx()]++;
    }
}

// RBRACE token: classify it, consuming the next template part when it
// closes a substitution.
fn TemplateBrace TemplateScan.classify_rbrace(&self, Lexer* lex) {
    if (self.depth == 0) return TemplateBrace.BLOCK;
    uint li = self.level_idx();
    if (self.expr_braces[li] > 0) {
        self.expr_braces[li]--;
        return TemplateBrace.BLOCK;
    }
    Token? part = lex.scan_template_after_expr();
    if (catch _e = part) return TemplateBrace.LEX_ERROR;
    if (part.type != TokenType.TEMPLATE_MIDDLE) {
        // TEMPLATE_TAIL: this template literal is done.
        self.depth--;
    }
    // TEMPLATE_MIDDLE: another substitution follows at the same level.
    return TemplateBrace.SUBST;
}

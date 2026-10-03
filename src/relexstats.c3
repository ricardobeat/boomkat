// Re-lexing counters (feature RELEX_STATS).
//
// The compiler's token pre-scans run the lexer ahead of the parser and then
// rewind it, and the parser itself re-parses loop conditions and speculates
// over cover grammars, so source inside nested scopes is tokenised more than
// once. relex_lexed_bytes[k] sums the bytes the lexer scans while the
// compiler is inside activity `k`, counted at the one place that scans (not
// at the many places that rewind). Dividing the total by relex_source_bytes
// gives how many times the average source byte was lexed; 1.0 is the floor.
//
// PARSE is everything outside a named pre-scan, so its excess over 1.0 is the
// parser's own speculation and loop re-parsing.
//
// Gated on RELEX_STATS. Default builds omit the counters and increments.
module boomkat::relexstats;

import std::io;

enum RelexKind : char {
    PARSE,
    LEX_DECLS,
    BLOCK_DECLS,
    VAR_DECLS,
    HOIST_DECLS,
    HOIST_FN_DECLS,
    CAPTURES,
    GLOBAL_VAR_SLOTS,
}

const String[*] RELEX_KIND_NAMES = {
    "parse", "lex_decls", "block_decls", "var_decls",
    "hoist_decls", "hoist_fn_decls", "captures", "global_var_slots",
};

ulong relex_source_bytes;
ulong[RELEX_KIND_NAMES.len] relex_lexed_bytes;
RelexKind relex_current;

macro void relex_source(usz bytes) {
    $if $feat(RELEX_STATS):
        relex_source_bytes += bytes;
    $endif
}

// Marks the start of a pre-scan; returns the activity to hand to relex_leave.
macro RelexKind relex_enter(RelexKind kind) {
    $if $feat(RELEX_STATS):
        RelexKind prev = relex_current;
        relex_current = kind;
        return prev;
    $else
        return kind;
    $endif
}

macro void relex_leave(RelexKind prev) {
    $if $feat(RELEX_STATS):
        relex_current = prev;
    $endif
}

// `from` and `to` are the lexer offsets around one token scan.
macro void relex_lexed(uint from, uint to) {
    $if $feat(RELEX_STATS):
        if (to > from) { relex_lexed_bytes[relex_current.ordinal] += (ulong)(to - from); }
    $endif
}

fn void relex_dump() {
$if $feat(RELEX_STATS):
    ulong src = relex_source_bytes;
    ulong total = 0;
    foreach (n : relex_lexed_bytes) { total += n; }
    double denom = src > 0 ? (double)src : 1.0;
    io::eprintfn("# RELEX source_bytes=%d lexed_bytes=%d ratio=%.2f", src, total, (double)total / denom);
    foreach (i, n : relex_lexed_bytes) {
        if (n == 0) continue;
        io::eprintfn("#   %-16s %12d  %6.2fx", RELEX_KIND_NAMES[i], n, (double)n / denom);
    }
$endif
}

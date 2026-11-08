// Re-lexing counters (feature RELEX_STATS).
//
// Pre-scans and parser speculation (loop conditions, cover grammars) lex the
// same source more than once. relex_lexed_bytes[k] sums the bytes the lexer
// scans while the compiler is in activity k, counted where the lexer scans, not
// where it rewinds. Dividing the total by relex_source_bytes gives how many
// times the average source byte was lexed; 1.0 is the floor.
//
// PARSE covers everything outside a named pre-scan, so its excess over 1.0 is
// the parser's own speculation and loop re-parsing. MATERIALIZE covers the
// re-lex of a deferred body on first call; materialize_function_body enters it.
//
// relex_source counts each lexer_init's full source slice, so a unit that
// creates both an outer and an inner lexer counts its bytes twice and the
// per-kind ratio can fall below 1.0. Compare lexed_bytes across kinds instead.
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
    MATERIALIZE,
}

const String[*] RELEX_KIND_NAMES = {
    "parse", "lex_decls", "block_decls", "var_decls",
    "hoist_decls", "hoist_fn_decls", "captures", "global_var_slots",
    "materialize",
};

tlocal ulong relex_source_bytes;
tlocal ulong[RELEX_KIND_NAMES.len] relex_source_by_kind;
tlocal ulong[RELEX_KIND_NAMES.len] relex_lexed_bytes;
tlocal RelexKind relex_current;

macro void relex_source(usz bytes) {
    $if $feat(RELEX_STATS):
        relex_source_bytes += bytes;
        relex_source_by_kind[relex_current.ordinal] += bytes;
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
        io::eprintfn("#   %-16s %12d  %6.2fx  src=%d", RELEX_KIND_NAMES[i], n,
            (double)n / denom, relex_source_by_kind[i]);
    }
$endif
}

// Re-lexing counters (feature RELEX_STATS).
//
// The compiler's token pre-scans run the lexer ahead of the parser and then
// rewind it with restore_lhs_snapshot, so source inside nested scopes is
// tokenised once per enclosing scan. relex_rewound_bytes sums the distance of
// every forward rewind; dividing by relex_source_bytes gives how many extra
// times the average source byte was lexed.
//
// Gated on RELEX_STATS. Default builds omit the counters and increments.
module boomkat::relexstats;

import std::io;

ulong relex_source_bytes;
ulong relex_rewound_bytes;
ulong relex_restores;

macro void relex_source(usz bytes) @builtin {
    $if $feat(RELEX_STATS):
        relex_source_bytes += bytes;
    $endif
}

// `from` is the lexer offset before the rewind, `to` the offset restored.
macro void relex_restore(uint from, uint to) @builtin {
    $if $feat(RELEX_STATS):
        relex_restores++;
        if (from > to) { relex_rewound_bytes += (ulong)(from - to); }
    $endif
}

fn void relex_dump() {
$if $feat(RELEX_STATS):
    ulong src = relex_source_bytes;
    io::eprintfn("# RELEX source_bytes=%d rewound_bytes=%d restores=%d ratio=%.1f",
        src, relex_rewound_bytes, relex_restores,
        src > 0 ? (double)relex_rewound_bytes / (double)src : 0.0);
$endif
}

// Frontend phase and liveness counters (feature FRONTEND_STATS).
//
// A stats build answers two questions that a leaf-only sample profile cannot:
// how much compile time goes into the initial full eval AST/resolution pass
// versus deferred body materialization, and whether register liveness is
// paying for too many sweeps, too many bits, or too many calls.
//
// Gated on FRONTEND_STATS. Default builds omit every counter and increment.
module boomkat::frontendstats;

import std::io;

// index_begin timing, split on ParseOptions.function_body.
tlocal ulong initial_units;
tlocal ulong initial_us;
tlocal ulong materialize_units;
tlocal ulong materialize_us;
// Whole materialize_function_body timing, including emit and finish.
tlocal ulong materialize_calls;
tlocal ulong materialize_total_us;
// CompilerContext.finish timing, across every compiled function.
tlocal ulong finish_calls;
tlocal ulong finish_us;

tlocal ulong liveness_calls;
tlocal ulong liveness_sweeps;
tlocal ulong liveness_visited;
tlocal ulong liveness_backedge_calls;
tlocal ulong liveness_word_traversals;
tlocal ulong liveness_max_words;
const uint LIVENESS_WORD_BUCKETS = 17;
tlocal ulong[LIVENESS_WORD_BUCKETS] liveness_word_hist;

macro void fs_liveness_call(uint code_count, uint words) {
    $if $feat(FRONTEND_STATS):
        liveness_calls++;
        liveness_word_traversals += (ulong)code_count * words;
        if (words > liveness_max_words) liveness_max_words = words;
        uint bucket = words < LIVENESS_WORD_BUCKETS ? words : LIVENESS_WORD_BUCKETS - 1;
        liveness_word_hist[bucket]++;
    $endif
}

macro void fs_liveness_backedge() {
    $if $feat(FRONTEND_STATS):
        liveness_backedge_calls++;
    $endif
}

macro void fs_liveness_sweep() {
    $if $feat(FRONTEND_STATS):
        liveness_sweeps++;
    $endif
}

macro void fs_liveness_visit() {
    $if $feat(FRONTEND_STATS):
        liveness_visited++;
    $endif
}

fn void frontend_dump() {
$if $feat(FRONTEND_STATS):
    io::eprintfn("# FRONTEND initial_units=%d initial_us=%d materialize_units=%d materialize_us=%d materialize_calls=%d materialize_total_us=%d finish_calls=%d finish_us=%d",
        initial_units, initial_us, materialize_units, materialize_us,
        materialize_calls, materialize_total_us, finish_calls, finish_us);
    io::eprintfn("# FRONTEND liveness_calls=%d sweeps=%d visited=%d backedge_calls=%d word_traversals=%d max_words=%d",
        liveness_calls, liveness_sweeps, liveness_visited, liveness_backedge_calls,
        liveness_word_traversals, liveness_max_words);
    foreach (i, n : liveness_word_hist) {
        if (n == 0) continue;
        if (i == LIVENESS_WORD_BUCKETS - 1) {
            io::eprintfn("#   words>=%d calls=%d", i, n);
        } else {
            io::eprintfn("#   words=%d calls=%d", i, n);
        }
    }
$endif
}

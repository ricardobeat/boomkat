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
// Whole materialize_function timing, including emit and finish.
tlocal ulong materialize_calls;
tlocal ulong materialize_total_us;
// CompilerContext.finish timing, across every compiled function.
tlocal ulong finish_calls;
tlocal ulong finish_us;

// Function bodies parsed in the initial pass. Nodes and time are charged to the
// innermost body that holds them, so a body's own cost excludes its nested
// bodies. A node-free preparser would not build the nodes charged here. The
// kinds split by what `gen` defers: plain declarations and unnamed function
// expressions (unless one is the immediate callee of a call) versus methods and
// named function expressions, which are compiled eagerly.
tlocal ulong initial_nodes;
tlocal ulong decl_units;
tlocal ulong decl_nodes;
tlocal ulong decl_us;
tlocal ulong uexpr_units;
tlocal ulong uexpr_nodes;
tlocal ulong uexpr_us;
tlocal ulong other_units;
tlocal ulong other_nodes;
tlocal ulong other_us;
// Bodies nest; each body's span includes its nested bodies, whose cost the
// nested accumulator below has already taken out.
tlocal ulong body_depth;
const uint FS_BODY_MAX_DEPTH = 96;
tlocal ulong[FS_BODY_MAX_DEPTH] fs_nested_nodes;
tlocal ulong[FS_BODY_MAX_DEPTH] fs_nested_us;

const uint FS_BODY_DECL = 0;
const uint FS_BODY_UEXPR = 1;
const uint FS_BODY_OTHER = 2;
// A named function expression; counted with FS_BODY_OTHER.
const uint FS_BODY_NEXPR = 3;

tlocal ulong liveness_calls;
tlocal ulong liveness_sweeps;
tlocal ulong liveness_visited;
tlocal ulong liveness_backedge_calls;
tlocal ulong liveness_word_traversals;
tlocal ulong liveness_max_words;
const uint LIVENESS_WORD_BUCKETS = 17;
tlocal ulong[LIVENESS_WORD_BUCKETS] liveness_word_hist;

macro void fs_body_enter() {
    $if $feat(FRONTEND_STATS):
        body_depth++;
    $endif
}

macro void fs_body_leave(uint kind, uint nodes, ulong elapsed_us) {
    $if $feat(FRONTEND_STATS):
        ulong d = body_depth;
        body_depth = d - 1;
        ulong inner_nodes = nodes;
        ulong inner_us = elapsed_us;
        if (d >= 1 && d <= FS_BODY_MAX_DEPTH) {
            inner_nodes -= fs_nested_nodes[d - 1];
            inner_us -= fs_nested_us[d - 1];
            fs_nested_nodes[d - 1] = 0;
            fs_nested_us[d - 1] = 0;
        }
        if (d > 1 && d <= FS_BODY_MAX_DEPTH) {
            fs_nested_nodes[d - 2] += nodes;
            fs_nested_us[d - 2] += elapsed_us;
        }
        if (kind == FS_BODY_DECL) {
            decl_units++; decl_nodes += inner_nodes; decl_us += inner_us;
        } else if (kind == FS_BODY_UEXPR) {
            uexpr_units++; uexpr_nodes += inner_nodes; uexpr_us += inner_us;
        } else {
            other_units++; other_nodes += inner_nodes; other_us += inner_us;
        }
    $endif
}

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
    io::eprintfn("# FRONTEND initial_nodes=%d decl_units=%d decl_nodes=%d decl_us=%d uexpr_units=%d uexpr_nodes=%d uexpr_us=%d other_units=%d other_nodes=%d other_us=%d",
        initial_nodes, decl_units, decl_nodes, decl_us,
        uexpr_units, uexpr_nodes, uexpr_us,
        other_units, other_nodes, other_us);
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

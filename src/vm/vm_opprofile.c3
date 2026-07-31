/// Execution-weighted opcode-pair profiler (feature OP_PROFILE).
///
/// Static disasm histograms rank a sequence by how often it is COMPILED,
/// which says nothing about how often it runs: a pair in a hot loop body is
/// worth thousands of times one in top-level setup code. Fusion only pays
/// back on executed sequences, so candidate ranking needs the dynamic count.
///
/// The counters are a dense [LAST_OP][LAST_OP] matrix of the (previous op,
/// current op) pair, incremented once per dispatch and dumped at exit. Both
/// the counters and the dispatch-loop hook are gated on OP_PROFILE, which no
/// shipping target enables, so the default build carries neither.
module duktape::vm;

import duktape::bytecode;
import std::io;
import std::sort;

const uint OPPROF_N = (uint)Opcode.LAST_OP.ordinal + 1;

/// opprof_pairs[prev][cur] over every dispatched instruction. Pairs are
/// counted across a call boundary too (the callee's first op follows the
/// caller's CALL). A fusion pass only ever rewrites within one function
/// body, so those cross-frame pairs are noise to be ignored when reading
/// the dump rather than candidates.
ulong[OPPROF_N][OPPROF_N] opprof_pairs;
ulong[OPPROF_N] opprof_singles;
uint opprof_prev = OPPROF_N - 1;

fn void opprof_record(Opcode op) @inline {
    uint cur = (uint)op.ordinal;
    opprof_singles[cur]++;
    opprof_pairs[opprof_prev][cur]++;
    opprof_prev = cur;
}

struct OpprofRow {
    ulong count;
    uint  prev;
    uint  cur;
}

fn int opprof_row_cmp(OpprofRow a, OpprofRow b) {
    if (a.count > b.count) { return -1; }
    if (a.count < b.count) { return 1; }
    return 0;
}

/// Dump the hottest executed singles and pairs to stderr.
fn void opprof_dump() {
$if $feature(OP_PROFILE):
    ulong total = 0;
    for (uint i = 0; i < OPPROF_N; i++) { total += opprof_singles[i]; }
    io::eprintfn("# OP_PROFILE total_dispatches=%d", total);

    OpprofRow[] rows = mem::new_array(OpprofRow, OPPROF_N * OPPROF_N);
    defer free(rows);
    uint n = 0;
    for (uint p = 0; p < OPPROF_N; p++) {
        for (uint c = 0; c < OPPROF_N; c++) {
            if (opprof_pairs[p][c] != 0) {
                rows[n] = { .count = opprof_pairs[p][c], .prev = p, .cur = c };
                n++;
            }
        }
    }
    sort::quicksort(rows[:n], &opprof_row_cmp);

    OpprofRow[] srows = mem::new_array(OpprofRow, OPPROF_N);
    defer free(srows);
    uint sn = 0;
    for (uint i = 0; i < OPPROF_N; i++) {
        if (opprof_singles[i] != 0) {
            srows[sn] = { .count = opprof_singles[i], .prev = i, .cur = i };
            sn++;
        }
    }
    sort::quicksort(srows[:sn], &opprof_row_cmp);

    io::eprintn("## dynamic singles");
    for (uint i = 0; i < sn && i < 40; i++) {
        io::eprintfn("%d\t%s", srows[i].count,
                     (ZString)bytecode::get_opcode_name((Opcode)srows[i].prev));
    }

    io::eprintn("## dynamic pairs");
    for (uint i = 0; i < n && i < 80; i++) {
        io::eprintfn("%d\t%s -> %s", rows[i].count,
                     (ZString)bytecode::get_opcode_name((Opcode)rows[i].prev),
                     (ZString)bytecode::get_opcode_name((Opcode)rows[i].cur));
    }
$endif
}

// Execution-weighted opcode-pair profiler (feature OP_PROFILE).
//
// Counts bytecodes across the switch and threaded interpreter, including the
// second bytecode consumed by a fused handler. A threaded instruction is charged
// only when it commits; a refusal is charged by the switch that executes it.
// Pairs follow execution order across calls and dispatch boundaries.
// All hooks are gated on OP_PROFILE, so shipping builds carry no profiling work.
module boomkat::vm;

import boomkat::bytecode;
import boomkat::hobject;
import boomkat::hstring;
import std::io;
import std::sort;

const uint OPPROF_N = (uint)Opcode.LAST_OP.ordinal + 1;

// opprof_pairs[prev][cur] includes bytecodes consumed by fused handlers. Pairs are
// counted across a call boundary too (the callee's first op follows the
// caller's CALL). A fusion pass only ever rewrites within one function
// body, so those cross-frame pairs are noise to be ignored when reading
// the dump rather than candidates.
tlocal ulong[OPPROF_N][OPPROF_N] opprof_pairs;
tlocal ulong[OPPROF_N] opprof_singles;
tlocal ulong opprof_switch_dispatches;
tlocal ulong opprof_threaded_dispatches;
tlocal ulong opprof_fused_bytecodes;
tlocal Opcode opprof_pending_op;
tlocal bool opprof_pending_valid;
tlocal bool opprof_pending_fused;
tlocal uint opprof_prev = OPPROF_N - 1;

// Why a threaded call handler sent its instruction to the switch, by reason.
enum CallBail : char {
    NOT_LEAN_FN,     // compiled function not classified lean
    FIRST_RUN,       // no caches yet, other realm
    FRAME,           // with scope, no activation slot or stack room
    RECEIVER,        // receiver slot untracked or not an object
    PLAIN_THIS,      // undefined receiver to a sloppy callee that reads this
    GATE_GC,         // safepoint due
    GATE_BURST,      // TH_CALL_BURST reached
    ENTER,           // th_enter_lean declined
    NOT_COMPILED,    // callee not an object, or a native or bound function
}
const String[*] CALL_BAIL_NAMES = { "not_lean_fn", "first_run", "frame", "receiver", "plain_this", "gate_gc", "gate_burst", "enter", "not_compiled" };
tlocal ulong[CALL_BAIL_NAMES.len] opprof_call_bail;

macro void opprof_bail(CallBail why) {
    $if $feat(OP_PROFILE):
        opprof_call_bail[why.ordinal]++;
    $endif
}

fn void opprof_record(Opcode op, bool threaded = false, bool fused = false) @inline {
    if (fused) { opprof_fused_bytecodes++; }
    else if (threaded) { opprof_threaded_dispatches++; }
    else { opprof_switch_dispatches++; }
    uint cur = (uint)op.ordinal;
    opprof_singles[cur]++;
    opprof_pairs[opprof_prev][cur]++;
    opprof_prev = cur;
}

// A handler's th_next call proves its pending instruction completed. Returning
// directly to the switch leaves it uncharged, so a slow-path retry counts once.
fn void opprof_thread_complete() @inline {
    if (!opprof_pending_valid) return;
    opprof_record(opprof_pending_op, true, opprof_pending_fused);
    opprof_pending_valid = false;
}

fn void opprof_thread_begin(Opcode op, bool fused = false) @inline {
    opprof_pending_op = op;
    opprof_pending_fused = fused;
    opprof_pending_valid = true;
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

struct OpprofName {
    void* key;
    char[] name;
    Opcode op;
    ulong count;
    ulong no_entry;
    ulong head_miss;
    ulong epoch_miss;
}
tlocal OpprofName[256] opprof_names;

fn void opprof_name(Opcode op, void* key, hobject::VarICEntry* vic, void* lex_env) {
    OpprofName* slot = null;
    foreach (&n : opprof_names) {
        if (n.key == key && n.op == op) { slot = n; break; }
        if (n.key == null) {
            // The exit dump runs after heap teardown, so it owns the bytes.
            hstring::HString* text = (hstring::HString*)key;
            char[] name = mem::new_array(char, text.blen);
            mem::copy(name.ptr, text.get_cstr(), (sz)text.blen);
            *n = { .key = key, .name = name, .op = op };
            slot = n;
            break;
        }
    }
    if (slot == null) return;
    slot.count++;
    if (vic == null || vic.slot_ptr == null) { slot.no_entry++; return; }
    if (vic.search_head != lex_env) { slot.head_miss++; return; }
    slot.epoch_miss++;
}

// Dump every executed single and the hottest pairs to stderr.
fn void opprof_dump() {
$if $feat(OP_PROFILE):
    io::eprintfn("## epoch bumps: shape_reuse=%d compact=%d layout_moved=%d", hobject::opprof_epoch[0], hobject::opprof_epoch[1], hobject::opprof_epoch[2]);
    io::eprintfn("## shape sites: private=%d delete=%d dict=%d free_private=%d", hobject::opprof_shape_site[0], hobject::opprof_shape_site[1], hobject::opprof_shape_site[2], hobject::opprof_shape_site[3]);
    for (uint i = 0; i < 64; i++) if (hobject::opprof_private_class[i]) io::eprintfn("##   private class %d: %d", i, hobject::opprof_private_class[i]);
    io::eprintn("## switch name reads (count no_entry head_miss other op name)");
    foreach (&n : opprof_names) {
        if (n.key == null) break;
        io::eprintfn("%d\t%d\t%d\t%d\t%s\t%s", n.count, n.no_entry, n.head_miss, n.epoch_miss,
                     (ZString)bytecode::get_opcode_name(n.op), (String)n.name);
        mem::free(n.name.ptr);
        *n = {};
    }
    io::eprintn("## threaded call bails (count reason)");
    foreach (i, c : opprof_call_bail) {
        if (c != 0) io::eprintfn("%d\t%s", c, CALL_BAIL_NAMES[i]);
    }
    ulong total = 0;
    for (uint i = 0; i < OPPROF_N; i++) { total += opprof_singles[i]; }
    io::eprintfn("# OP_PROFILE total_dispatches=%d executed_bytecodes=%d threaded_dispatches=%d switch_dispatches=%d fused_bytecodes=%d",
        opprof_switch_dispatches + opprof_threaded_dispatches, total,
        opprof_threaded_dispatches, opprof_switch_dispatches, opprof_fused_bytecodes);

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
    for (uint i = 0; i < sn; i++) {
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

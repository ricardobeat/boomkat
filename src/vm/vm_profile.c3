module duktape::vm;

import duktape::bytecode;
import std::io;

// ============================================================================
// OPCODE_PROFILE — per-opcode and per-call-phase cycle attribution.
//
// Gated entirely behind $feature(OPCODE_PROFILE). The default duktape_c3
// build does not link mach_absolute_time or carry any profiling state;
// verify with `objdump -t out/duktape_c3 | grep -i profile`.
//
// Method A: a cycle timestamp is read at the top of the dispatch loop (right
// before decoding the next instruction) and the delta since the previous
// timestamp is attributed to the PREVIOUS opcode's body.
//
// Method B: a handful of named sub-phases inside the CALL fast path and RET
// handling are bracketed with the same timestamp reader.
// ============================================================================

extern fn ulong mach_absolute_time();

const uint N_OPS = Opcode.LAST_OP.ordinal + 1;

enum CallPhase : uint {
    ACTIVATION_SETUP,
    LEX_ENV_RESOLVE,
    VALSTACK_ENSURE,
    ARG_MOVE,
    REFCOUNT_THIS,
    RET_REFCOUNT,
    RET_RESTORE,
    LAST_PHASE,
}

struct OpcodeProfile {
    ulong[N_OPS] cycles;
    ulong[N_OPS] count;
    ulong[CallPhase.LAST_PHASE.ordinal + 1] phase_cycles;
    ulong[CallPhase.LAST_PHASE.ordinal + 1] phase_count;
    ulong last_ts;
    Opcode last_op;
    bool have_last;
}

OpcodeProfile g_profile;

/// Called at the very top of the dispatch loop, before decoding `insn`.
/// Attributes elapsed cycles since the previous call to the opcode that
/// was *just* decoded last iteration (g_profile.last_op).
fn void profile_tick() @inline {
$if $feature(OPCODE_PROFILE):
    ulong now = mach_absolute_time();
    if (g_profile.have_last) {
        ulong delta = now - g_profile.last_ts;
        g_profile.cycles[g_profile.last_op.ordinal] += delta;
        g_profile.count[g_profile.last_op.ordinal] += 1;
    }
    g_profile.last_ts = now;
$endif
}

/// Record which opcode was just decoded, so the *next* profile_tick() call
/// attributes elapsed cycles to it.
fn void profile_mark_op(Opcode op) @inline {
$if $feature(OPCODE_PROFILE):
    g_profile.last_op = op;
    g_profile.have_last = true;
$endif
}

fn ulong profile_now() @inline {
$if $feature(OPCODE_PROFILE):
    return mach_absolute_time();
$else
    return 0;
$endif
}

fn void profile_phase(CallPhase phase, ulong start) @inline {
$if $feature(OPCODE_PROFILE):
    ulong now = mach_absolute_time();
    g_profile.phase_cycles[phase.ordinal] += (now - start);
    g_profile.phase_count[phase.ordinal] += 1;
$endif
}

const char*[CallPhase.LAST_PHASE.ordinal + 1] PHASE_NAMES = {
    [CallPhase.ACTIVATION_SETUP.ordinal] = "activation_setup",
    [CallPhase.LEX_ENV_RESOLVE.ordinal]  = "lex_env_resolve",
    [CallPhase.VALSTACK_ENSURE.ordinal]  = "valstack_ensure",
    [CallPhase.ARG_MOVE.ordinal]         = "arg_move",
    [CallPhase.REFCOUNT_THIS.ordinal]    = "refcount_this_binding",
    [CallPhase.RET_REFCOUNT.ordinal]     = "ret_refcount_callee_regs",
    [CallPhase.RET_RESTORE.ordinal]      = "ret_restore_caller_state",
};

fn void profile_dump() {
$if $feature(OPCODE_PROFILE):
    // Simple insertion-sort index array by descending cycles (N_OPS is small).
    uint[N_OPS] idx;
    for (uint i = 0; i < N_OPS; i++) { idx[i] = i; }
    for (uint i = 1; i < N_OPS; i++) {
        uint key = idx[i];
        ulong keyval = g_profile.cycles[key];
        int j = (int)i - 1;
        while (j >= 0 && g_profile.cycles[idx[j]] < keyval) {
            idx[j + 1] = idx[j];
            j--;
        }
        idx[j + 1] = key;
    }

    ulong total = 0;
    for (uint i = 0; i < N_OPS; i++) { total += g_profile.cycles[i]; }

    io::eprintfn("=== OPCODE_PROFILE: Method A (per-opcode) ===");
    io::eprintfn("total_attributed_cycles=%d", total);
    io::eprintfn("%-16s %14s %12s %10s %8s", "opcode", "cycles", "count", "cyc/op", "pct");
    for (uint i = 0; i < N_OPS && i < 20; i++) {
        uint op_idx = idx[i];
        if (g_profile.cycles[op_idx] == 0) continue;
        ZString name = (ZString)bytecode::get_opcode_name((Opcode)op_idx);
        double pct = total > 0 ? (100.0 * (double)g_profile.cycles[op_idx] / (double)total) : 0.0;
        double per_op = g_profile.count[op_idx] > 0
            ? ((double)g_profile.cycles[op_idx] / (double)g_profile.count[op_idx]) : 0.0;
        io::eprintfn("%-16s %14d %12d %10.2f %7.2f%%",
            name, g_profile.cycles[op_idx], g_profile.count[op_idx], per_op, pct);
    }

    io::eprintfn("");
    io::eprintfn("=== OPCODE_PROFILE: Method B (call-path sub-phases) ===");
    ulong phase_total = 0;
    for (uint i = 0; i < CallPhase.LAST_PHASE.ordinal; i++) { phase_total += g_profile.phase_cycles[i]; }
    io::eprintfn("%-28s %14s %12s %10s %8s", "phase", "cycles", "count", "cyc/call", "pct_of_phases");
    for (uint i = 0; i < CallPhase.LAST_PHASE.ordinal; i++) {
        if (g_profile.phase_cycles[i] == 0) continue;
        double pct = phase_total > 0 ? (100.0 * (double)g_profile.phase_cycles[i] / (double)phase_total) : 0.0;
        double per_call = g_profile.phase_count[i] > 0
            ? ((double)g_profile.phase_cycles[i] / (double)g_profile.phase_count[i]) : 0.0;
        io::eprintfn("%-28s %14d %12d %10.2f %7.2f%%",
            (ZString)PHASE_NAMES[i], g_profile.phase_cycles[i], g_profile.phase_count[i], per_call, pct);
    }
$endif
}

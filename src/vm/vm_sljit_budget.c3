module boomkat::vm;

import boomkat::heap;
import boomkat::bytecode;

const usz JIT_INITIAL_CODE_LIMIT = 256 * 1024;
const usz JIT_MAX_CODE_LIMIT = 1024 * 1024;

fn usz sljit_code_limit(Heap* h) @feat(SLJIT) @inline {
    $if $feat(SLJIT_ADAPTIVE):
    if (h.jit_code_limit == 0) h.jit_code_limit = JIT_INITIAL_CODE_LIMIT;
    return h.jit_code_limit;
    $else
    return JIT_MAX_CODE_LIMIT;
    $endif
}

// Completed spans and taken edges count native progress, not compilation or
// speculative entry attempts. Grow only when the current arena is both used
// and productive. The cap bounds an individual runtime's executable memory.
fn void sljit_budget_progress(Heap* h, uint edges) @feat(SLJIT) @inline {
    $if $feat(SLJIT_ADAPTIVE):
    h.jit_native_work += edges;
    usz limit = sljit_code_limit(h);
    if (limit >= JIT_MAX_CODE_LIMIT || h.jit_code_bytes < limit * 3 / 4
        || h.jit_native_work < limit / 8) return;
    sljit_budget_grow(h, limit * 2);
    $endif
}

fn void sljit_budget_grow(Heap* h, usz limit) @feat(SLJIT) @noinline {
    h.jit_code_limit = limit;
    sljit_budget_retry(h);
}

fn void sljit_budget_retry(Heap* h) @feat(SLJIT) {
    for (uint i = 0; i < h.compiled_func_count; i++) {
        CompiledFunction* cf = h.compiled_funcs[i];
        if (cf == null) continue;
        if (cf.sljit_budget_wait) {
            cf.sljit_budget_wait = false;
            if (cf.sljit_function == null) cf.sljit_function_calls = 0;
        }
        cf.sljit_loop_rejected &= ~cf.sljit_loop_budget_wait;
        cf.sljit_loop_budget_wait = 0;
    }
}

fn bool sljit_code_room(Heap* h, usz bytes) @feat(SLJIT) @inline {
    if (h.jit_code_bytes + bytes < sljit_code_limit(h)) return true;
    $if $feat(SLJIT_ADAPTIVE): return sljit_budget_reclaim(h, bytes); $else return false; $endif
}

// Only compilation calls this, after every generated machine frame has
// unwound. Native callees stamp their last use too; a hot linked callee cannot
// look cold merely because it never crosses the C gateway. Unlink before free.
fn bool sljit_budget_reclaim(Heap* h, usz bytes) @feat(SLJIT) @noinline {
    if (bytes >= sljit_code_limit(h)) return false;
    bool reclaimed;
    while (h.jit_code_bytes + bytes >= sljit_code_limit(h)) {
        CompiledFunction* victim;
        ulong oldest = h.jit_clock > 65536 ? h.jit_clock - 65536 : 0;
        for (uint i = 0; i < h.compiled_func_count; i++) {
            CompiledFunction* cf = h.compiled_funcs[i];
            if (cf == null || cf.sljit_function == null) continue;
            FunctionPlan* plan = cf.sljit_function;
            if (plan.last_use >= oldest) continue;
            oldest = plan.last_use;
            victim = cf;
        }
        if (victim == null) break;
        sljit_function_free(h, victim);
        // An unproductive entry that was already disabled must not be
        // repeatedly recompiled merely because its code was reclaimed.
        if (victim.sljit_function_calls != uint::max) victim.sljit_function_calls = 0;
        h.jit_evictions++;
        reclaimed = true;
    }
    if (reclaimed) sljit_budget_retry(h);
    return h.jit_code_bytes + bytes < sljit_code_limit(h);
}

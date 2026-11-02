module boomkat::vm;

import boomkat::heap;
import boomkat::bytecode;
import std::core::mem;

const usz JIT_INITIAL_CODE_LIMIT = 256 * 1024;
const usz JIT_MAX_CODE_LIMIT = 2 * 1024 * 1024;
// A bounded reserve for hot standalone loops after function admission
// saturates. The adaptive policy retains its independent limit.
const usz JIT_LOOP_RESERVE_LIMIT = 2 * JIT_MAX_CODE_LIMIT;

fn usz sljit_code_limit(Heap* h) @feat(SLJIT) @inline {
    $if $feat(SLJIT_ADAPTIVE):
    if (h.jit_code_limit == 0) h.jit_code_limit = JIT_INITIAL_CODE_LIMIT;
    return h.jit_code_limit;
    $else
    return $feat(SLJIT_LOOP_RESERVE) ? JIT_LOOP_RESERVE_LIMIT : JIT_MAX_CODE_LIMIT;
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
    if (limit <= h.jit_code_limit) return;
    h.jit_code_limit = limit;
    sljit_budget_retry(h);
}

fn void sljit_budget_retry(Heap* h) @feat(SLJIT) {
    h.jit_capacity_generation++;
}

// A temporary capacity rejection is reconsidered lazily at the next relevant
// gateway. Unsupported code keeps its rejection; an unchanged budget never
// causes repeated compilation attempts or a full function-registry sweep.
// Releasing code frees capacity, so a rejected plan may be reconsidered, but
// only once the arena can hold the plan that was rejected. Retrying earlier
// would repeat the whole compilation for a rejection that cannot change.
fn void sljit_budget_retry_function(Heap* h, CompiledFunction* cf) @feat(SLJIT) @inline {
    if (cf.sljit_capacity_seen == h.jit_capacity_generation) return;
    cf.sljit_capacity_seen = h.jit_capacity_generation;
    if (cf.sljit_budget_wait) {
        if (!sljit_code_room(h, cf.sljit_budget_bytes, true)) return;
        cf.sljit_budget_wait = false;
        if (cf.sljit_function == null) cf.sljit_function_calls = 0;
    }
    if (cf.sljit_template_budget_wait) {
        if (!sljit_code_room(h, 0, true)) return;
        cf.sljit_template_budget_wait = false;
        if (cf.sljit_template == null) cf.sljit_template_calls = 0;
    }
    if (cf.sljit_loop_budget_wait && cf.sljit_loop_admission != null) {
        if (!sljit_code_room(h, 0)) return;
        for (uint pc = 0; pc < cf.code_count; pc++) cf.sljit_loop_admission[pc] &= 0xFD;
        cf.sljit_loop_budget_wait = false;
    }
}

// Admission is indexed by the exact bytecode PC. Hash collisions must not
// disable another loop or turn an unsupported site into a budget retry.
fn bool sljit_loop_blocked(CompiledFunction* cf, uint pc) @feat(SLJIT) @inline {
    return cf.sljit_loop_admission_oom || pc >= cf.code_count
        || (cf.sljit_loop_admission != null && cf.sljit_loop_admission[pc] != 0);
}
fn void sljit_loop_decline(Heap* h, CompiledFunction* cf, uint pc, bool capacity = false) @feat(SLJIT) {
    if (pc >= cf.code_count || cf.sljit_loop_admission_oom) return;
    if (cf.sljit_loop_admission == null) {
        cf.sljit_loop_admission = (char*)h.alloc_func(h.heap_udata, cf.code_count);
        if (cf.sljit_loop_admission == null) { cf.sljit_loop_admission_oom = true; return; }
        mem::clear(cf.sljit_loop_admission, (sz)cf.code_count);
    }
    cf.sljit_loop_admission[pc] |= capacity ? 2 : 1;
    if (capacity) cf.sljit_loop_budget_wait = true;
}

fn bool sljit_code_room(Heap* h, usz bytes, bool function = false) @feat(SLJIT) @inline {
    $if $feat(SLJIT_LOOP_RESERVE) && !$feat(SLJIT_ADAPTIVE):
    // Keep the reserve for loop candidates, which have reached a hot
    // backedge and passed the loop analyzer. No existing code is retired.
    if (function && (h.jit_code_bytes >= JIT_MAX_CODE_LIMIT
        || bytes >= JIT_MAX_CODE_LIMIT - h.jit_code_bytes)) return false;
    $endif
    if (h.jit_code_bytes + bytes < sljit_code_limit(h)) return true;
    $if $feat(SLJIT_ADAPTIVE): return sljit_budget_reclaim(h, bytes); $else return false; $endif
}

// Only compilation calls this, after every generated machine frame has
// unwound. Native callees stamp their last use too; a hot linked callee cannot
// look cold merely because it never crosses the C gateway. Unlink before free.
fn bool sljit_budget_reclaim(Heap* h, usz bytes) @feat(SLJIT) @noinline {
    if (bytes >= sljit_code_limit(h) || h.jit_native_active != 0) return false;
    while (h.jit_code_bytes + bytes >= sljit_code_limit(h)) {
        JitArtifact* victim;
        ulong oldest = h.jit_clock > 65536 ? h.jit_clock - 65536 : 0;
        for (JitArtifact* artifact = h.jit_artifacts; artifact != null; artifact = artifact.next) {
            if (artifact.pins != 0) continue;
            ulong last_use = artifact.last_use;
            if (artifact.kind == FUNCTION_CODE) {
                // Linked calls stamp the plan directly from generated code.
                FunctionPlan* plan = artifact.payload;
                if (plan.last_use > last_use) last_use = plan.last_use;
            }
            if (last_use >= oldest) continue;
            oldest = last_use;
            victim = artifact;
        }
        if (victim == null) break;
        CompiledFunction* cf = victim.function;
        switch (victim.kind) {
            case FUNCTION_CODE:
                FunctionPlan* plan = victim.payload;
                bool disabled = plan.begin == 0 && plan.short_runs[0] >= 8;
                sljit_function_free(h, cf);
                if (!disabled) cf.sljit_function_calls = 0;
            case LOOP_CODE:
                LoopPlan* plan = victim.payload;
                LoopPlan** link = &cf.sljit_loops;
                while (*link != null && *link != plan) link = &(*link).next;
                assert(*link == plan);
                *link = plan.next;
                cf.sljit_loop_ready &= ~(1U << (plan.end & 31));
                sljit_artifact_retire(h, victim);
            case TEMPLATE_CODE:
                sljit_template_free(h, cf);
                cf.sljit_template_calls = 0;
        }
        h.jit_evictions++;
    }
    // Each actual artifact release already advances capacity generation.
    return h.jit_code_bytes + bytes < sljit_code_limit(h);
}

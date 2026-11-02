module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::jit;
import std::core::mem;

// Whole-function metadata follows decoded prefix PCs. Legacy loop plans keep
// their inline adapters; these arrays are owned by the same FunctionPlan.
struct SsaPlanData @feat(SLJIT) {
    uint reg_count;
    uint word_count;
    uint spill_count;
    uint edge_count;
    uint native_accesses;
    uint native_bindings;
    uint native_integer_bindings;
    ulong binding_reads @if($feat(SLJIT_STATS));
    ulong field_reads @if($feat(SLJIT_STATS));
    ulong array_reads @if($feat(SLJIT_STATS));
    ulong field_writes @if($feat(SLJIT_STATS));
    uint bounds_proofs;
    uint rematerialized;
    uint* resume_words;
    usz bytes;
    bool decoded_body;
}
fn bool ssa_plan_data_init(LoopPlan* plan, CompiledFunction* cf, Heap* h) @feat(SLJIT) {
    if (plan.ssa_data != null) return true;
    if (cf.code_count > SSA_DEFAULT_BUDGET.max_words || cf.num_regs == 0) return false;
    usz words = ((usz)cf.code_count + 31) / 32;
    usz bytes = SsaPlanData::size + words * uint::size;
    if (bytes > SSA_DEFAULT_BUDGET.max_bytes) return false;
    SsaPlanData* data = (SsaPlanData*)h.alloc_func(h.heap_udata, bytes);
    if (data == null) return false;
    mem::clear(data, (sz)bytes);
    data.reg_count = cf.num_regs;
    data.word_count = cf.code_count;
    data.resume_words = (uint*)((char*)data + SsaPlanData::size);
    data.bytes = bytes;
    plan.ssa_data = data;
    return true;
}
fn void ssa_plan_data_free(Heap* h, LoopPlan* plan) @feat(SLJIT) {
    if (plan.ssa_data != null) h.free_func(h.heap_udata, plan.ssa_data);
    plan.ssa_data = null;
}
fn bool ssa_plan_resumes(LoopPlan* plan, uint pc) @feat(SLJIT) {
    if (plan.ssa_data != null) {
        return pc < plan.ssa_data.word_count
            && (plan.ssa_data.resume_words[pc / 32] & (1U << (pc % 32))) != 0;
    }
    return pc < SSA_SPAN && (plan.ssa_resume_pcs[pc / 64] & (1UL << (pc % 64))) != 0;
}

// A full SSA body uses the existing FunctionPlan owner and interpreter
// gateway. It has no baseline template entry or separate call cache.
fn FunctionPlan* ssa_function_wrap(CompiledFunction* cf, ColdCtx* cold, LoopPlan* body) @feat(SLJIT) {
    Heap* h = cold.heap;
    usz bytes = FunctionPlan::size + (usz)cf.code_count * (void*::size + char::size);
    bool room = sljit_code_room(h, body.code_bytes, true);
    if (!room) {
        cf.sljit_budget_wait = true;
        cf.sljit_budget_bytes = (uint)body.code_bytes;
    }
    if (bytes > SSA_DEFAULT_BUDGET.max_bytes || !room) {
        if (body.native != null) jit::sljit_free_code((void*)body.native, null);
        ssa_helper_sites_free(h, body);
        ssa_deopt_free(h, body);
        ssa_plan_data_free(h, body);
        h.free_func(h.heap_udata, body);
        return null;
    }
    FunctionPlan* plan = (FunctionPlan*)h.alloc_func(h.heap_udata, bytes);
    if (plan == null) {
        if (body.native != null) jit::sljit_free_code((void*)body.native, null);
        ssa_helper_sites_free(h, body);
        ssa_deopt_free(h, body);
        ssa_plan_data_free(h, body);
        h.free_func(h.heap_udata, body);
        return null;
    }
    mem::clear(plan, (sz)bytes);
    plan.count = cf.code_count;
    plan.min_span = 1;
    plan.heap_regs = cf.num_regs;
    plan.dependencies_live = true;
    plan.entries = (void**)((char*)plan + FunctionPlan::size);
    plan.short_runs = (char*)(plan.entries + plan.count);
    plan.ssa_region = body;
    plan.code_bytes = body.code_bytes;
    for (uint pc = 0; pc < plan.count; pc++) {
        if (ssa_plan_resumes(body, pc)) plan.entries[pc] = (void*)body.native;
    }
    plan.shape_clock = h.shape_gen_clock;
    plan.shape_epoch = h.shape_recycle_epoch;
    body.code_owner = &plan.artifact;
    ssa_function_call_entry(cf, cold, plan);
    cf.sljit_function = plan;
    sljit_artifact_publish(h, &plan.artifact, cf, plan, FUNCTION_CODE,
        plan.code_bytes, sljit_function_metadata_bytes(plan, bytes), &sljit_function_release);
    // Incoming native links and interpreter entries execute the same SSA body.
    sljit_relink_calls(h, cf);
    cf.sljit_function_calls = uint::max - 1;
    return plan;
}

// Decoded bodies use generic helpers instead of indexing legacy per-window
// descriptor tables. Larger PCs never enter those fixed inline adapters.
fn uint ssa_memory_site(LoopPlan* plan, uint at) @feat(SLJIT) => plan.ssa_data != null && plan.ssa_data.decoded_body
    ? 0 : at < LOOP_SPAN ? (uint)plan.memory_at[at] : 0;
fn uint ssa_binding_site(LoopPlan* plan, uint at) @feat(SLJIT) => plan.ssa_data != null && plan.ssa_data.decoded_body
    ? 0 : at < LOOP_SPAN ? (uint)plan.binding_at[at] : 0;
fn uint ssa_intrinsic_site(LoopPlan* plan, uint at) @feat(SLJIT) => plan.ssa_data != null && plan.ssa_data.decoded_body
    ? 0 : at < LOOP_SPAN ? (uint)plan.intrinsic_at[at] : 0;

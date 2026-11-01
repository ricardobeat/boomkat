module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import std::core::mem;

// Whole-function metadata follows decoded prefix PCs. Legacy loop plans keep
// their inline adapters; these arrays are owned by the same FunctionPlan.
struct SsaPlanData @feat(SLJIT) {
    uint reg_count;
    uint word_count;
    uint spill_count;
    uint edge_count;
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

module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::types;
import boomkat::jit;
import std::io;

// Initial function-region adapter. The graph, optimizer, allocation, machine
// emitter and publication logic are shared with loop SSA. Keep this opt-in
// while measuring the cost of the explicit runtime boundary.
fn LoopPlan* sljit_function_ssa_compile(CompiledFunction* cf, ColdCtx* cold) @feat(SLJIT) {
    if (cf.num_regs > LOOP_REGS || cf.code_count > LOOP_OPS || cf.code_count < 9) return null;
    for (uint pc = 0; pc < cf.code_count; pc++) {
        if (function_call_op(cf.code[pc].op)) return null;
    }
    uint terminal;
    for (uint pc = 0; pc < cf.code_count; pc++) {
        if (cf.code[pc].op == Opcode.RET) {
            terminal = pc;
            break;
        }
    }
    if (terminal < 8) return null;
    LoopPlan draft;
    if (!loop_analyze(&draft, terminal - 1, cold.act.bottom, cold, 0)) return null;
    // Read descriptors are rebuilt from the live frame on each entry. Keep
    // writes out of the first region tier so a guard cannot replay effects.
    for (uint i = 0; i < draft.memory_count; i++) {
        if (draft.memory[i].written) return null;
    }
    // Loop cache hints are irrelevant to the region allocator and may name
    // old VM temporaries that are not live inputs of this single-pass graph.
    foreach (&cache : draft.cache) *cache = 0;
    foreach (&cache : draft.float_cache) *cache = 0;
    draft.canonical = 0;
    draft.native = ssa_region_emit(&draft, cf, cold.heap);
    if (draft.native == null) return null;
    LoopPlan* plan = (LoopPlan*)cold.heap.alloc_func(cold.heap.heap_udata, LoopPlan::size);
    if (plan == null) {
        jit::sljit_free_code((void*)draft.native, null);
        return null;
    }
    *plan = draft;
    $if $feat(SLJIT_STATS):
        io::eprintfn(
            "SLJIT function SSA line=%d begin=%d end=%d bytes=%d",
            cf.get_line(0),
            plan.begin,
            plan.end,
            plan.code_bytes
        );
    $endif
    return plan;
}

fn void sljit_function_ssa_free(Heap* h, FunctionPlan* plan) @feat(SLJIT) {
    if (plan.ssa_region == null) return;
    $if $feat(SLJIT_STATS):
        io::eprintfn("SLJIT function SSA hits=%d", plan.ssa_region.hits);
    $endif
    jit::sljit_free_code((void*)plan.ssa_region.native, null);
    h.free_func(h.heap_udata, plan.ssa_region);
    plan.ssa_region = null;
}

// Return null on normal completion, or the exact interpreter replay PC after
// a failed guard. There are no allocations or observable helper calls here.
fn Instruction* sljit_function_ssa_run(ColdCtx* cold, LoopPlan* plan) @feat(SLJIT) {
    CompiledFunction* cf = cold.vm.current_func;
    TVal* regs           = cold.act.bottom;
    // Prologue arguments and every defined spill are written before use.
    // Exits publish a fresh dirty mask; untouched interpreter slots stay owned
    // by the original frame, so no blanket scratch clear/copy is necessary.
    LoopState state @noinit;
    for (uint i = 0; i < cf.num_regs; i++) {
        if ((plan.ssa_inputs & (1UL << i)) != 0) state.values[i] = regs[i];
    }
    if ((plan.binding_count != 0 || plan.memory_count != 0) && !loop_prepare(plan, &state, cold)) return cf.code;
    uint resume = plan.native(&state, 1);
    sljit_publish_state(cold, regs, &state, cf.num_regs);
    plan.hits++;
    return resume == plan.end + 1 ? null : cf.code + resume;
}
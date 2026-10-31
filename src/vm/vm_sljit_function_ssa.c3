module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import boomkat::types;
import boomkat::jit;
import std::io;

// Function regions share graph construction, optimization and allocation with
// loop SSA. Pure regions use a shared-register entry when no binding snapshot
// preparation is needed: guards can
// restart the untouched baseline frame, and only the result is published.
fn LoopPlan* sljit_function_ssa_compile(CompiledFunction* cf, ColdCtx* cold) @feat(SLJIT) {
    if (cf.num_regs > LOOP_REGS || cf.code_count > SSA_SPAN || cf.code_count < 9) return null;
    for (uint pc = 0; pc < cf.code_count; pc++) {
        if (function_call_op(cf.code[pc].op) && function_inline_ssa_candidate(cf, pc, cold.heap) == null) return null;
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
    if (!loop_analyze(&draft, terminal - 1, cold.act.bottom, cold, 0, true)) return null;
    // Only immutable own-field layouts can be prepared entirely in generated
    // code. A global recycle-epoch guard prevents shape-id reuse.
    for (uint i = 0; i < draft.memory_count; i++) {
        LoopMemorySpec spec = draft.memory[i];
        Shape* shape = cold.heap.get_shape(spec.shape);
        if ((spec.kind != FIELD && spec.kind != SHAPE_FIELD) || spec.written || spec.cls != OBJECT || shape == null || shape.dict || shape.generation != spec.shape_gen) return null;
    }
    draft.ssa_fields = draft.memory_count != 0;
    draft.ssa_shape_epoch = cold.heap.shape_recycle_epoch;
    // Loop cache hints are irrelevant to the region allocator and may name
    // old VM temporaries that are not live inputs of this single-pass graph.
    foreach (&cache : draft.cache) *cache = 0;
    foreach (&cache : draft.float_cache) *cache = 0;
    draft.canonical = 0;
    if (draft.binding_count == 0) { draft.ssa_entry = ssa_function_emit(&draft, cf, cold.heap); }
    else { draft.native = ssa_region_emit(&draft, cf, cold.heap); }
    if (draft.native == null && draft.ssa_entry == null) return null;
    LoopPlan* plan = (LoopPlan*)cold.heap.alloc_func(cold.heap.heap_udata, LoopPlan::size);
    if (plan == null) {
        jit::sljit_free_code(draft.ssa_entry != null ? draft.ssa_entry : (void*)draft.native, null);
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
    while (plan.ssa_leaves != null) {
        LoopPlan* leaf = plan.ssa_leaves;
        plan.ssa_leaves = leaf.next;
        if (leaf.ssa_entry != null) jit::sljit_free_code(leaf.ssa_entry, null);
        h.free_func(h.heap_udata, leaf);
    }
    if (plan.ssa_region == null) return;
    $if $feat(SLJIT_STATS):
        io::eprintfn("SLJIT function SSA hits=%d", plan.ssa_region.hits);
    $endif
    jit::sljit_free_code(plan.ssa_region.ssa_entry != null ? plan.ssa_region.ssa_entry : (void*)plan.ssa_region.native, null);
    h.free_func(h.heap_udata, plan.ssa_region);
    plan.ssa_region = null;
}

// Refresh only outside generated code. An invalid shape poisons the patch
// with a value that can never equal the zero-extended runtime epoch.
fn bool sljit_function_ssa_live(Heap* h, LoopPlan* plan) @feat(SLJIT) {
    if (plan.ssa_invalid) return false;
    if (plan.ssa_fields && plan.ssa_shape_epoch != h.shape_recycle_epoch) {
        for (uint memory = 0; memory < plan.memory_count; memory++) {
            LoopMemorySpec spec = plan.memory[memory];
            if (!ssa_memory_layout_live(h, &spec)) {
                plan.ssa_invalid = true;
                jit::sljit_set_const(plan.ssa_epoch_patch, jit::SLJIT_MOV, 1L << 32, plan.ssa_executable_offset);
                return false;
            }
        }
        // No SSA region frame is active: patch through SLJIT's executable
        // alias API before entering it, retaining the code until plan free.
        jit::sljit_set_const(plan.ssa_epoch_patch, jit::SLJIT_MOV,
            h.shape_recycle_epoch, plan.ssa_executable_offset);
        plan.ssa_shape_epoch = h.shape_recycle_epoch;
        $if $feat(SLJIT_STATS): plan.ssa_epoch_updates++; $endif
    }
    return true;
}

// Linked callees can bypass their C gateway. Refresh all field regions once
// per heap epoch, before any generated frames are active; otherwise one recycle
// leaves those callees permanently using their baseline fallback.
fn void sljit_function_ssa_refresh(Heap* h) @feat(SLJIT) {
    $if $feat(SLJIT_FUNCTION_SSA) || !$feat(SLJIT_NO_SSA_LEAVES) || !$feat(SLJIT_NO_SSA_CALL_ENTRY):
        if (h.jit_ssa_epoch == h.shape_recycle_epoch) return;
        for (uint i = 0; i < h.compiled_func_count; i++) {
            CompiledFunction* cf = (CompiledFunction*)h.compiled_funcs[i];
            if (cf == null) continue;
            FunctionPlan* plan = cf.sljit_function;
            if (plan == null) continue;
            if (plan.ssa_region != null) sljit_function_ssa_live(h, plan.ssa_region);
            for (LoopPlan* leaf = plan.ssa_leaves; leaf != null; leaf = leaf.next) sljit_function_ssa_live(h, leaf);
        }
        h.jit_ssa_epoch = h.shape_recycle_epoch;
    $endif
}

// Return null on normal completion, or the exact interpreter replay PC after
// a failed guard. There are no allocations or observable helper calls here.
fn Instruction* sljit_function_ssa_run(ColdCtx* cold, LoopPlan* plan) @feat(SLJIT) {
    CompiledFunction* cf = cold.vm.current_func;
    TVal* regs           = cold.act.bottom;
    if (!sljit_function_ssa_live(cold.heap, plan)) return cf.code;
    // Prologue arguments and every defined spill are written before use.
    // Exits publish a fresh dirty mask; untouched interpreter slots stay owned
    // by the original frame, so no blanket scratch clear/copy is necessary.
    LoopState state @noinit;
    if (plan.ssa_fields) {
        state.receiver = cold.act.this_binding;
        state.shape_epoch = cold.heap.shape_recycle_epoch;
    }
    for (uint i = 0; i < cf.num_regs; i++) {
        if ((plan.ssa_inputs & (1UL << i)) != 0) state.values[i] = regs[i];
    }
    if (plan.binding_count != 0 && !loop_prepare(plan, &state, cold, plan.ssa_fields)) return cf.code;
    cold.heap.jit_native_active++;
    uint resume = plan.native(&state, 1);
    cold.heap.jit_native_active--;
    sljit_publish_state(cold, regs, &state, cf.num_regs, plan);
    plan.hits++;
    $if $feat(SLJIT_STATS):
        if (resume == plan.end + 1) { plan.ssa_completed++; }
        else if (resume == plan.begin) { plan.ssa_entry_misses++; }
        else { plan.ssa_body_misses++; }
    $endif
    return resume == plan.end + 1 ? null : cf.code + resume;
}
// R0 carries the result across these counters.
fn void ssa_counter(TemplateEmitter* e, ulong* counter) @feat(SLJIT) {
    int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2);
    e.mov(r1, 0, jit::SLJIT_IMM, (long)counter);
    e.mov(r2, 0, jit::SLJIT_MEM | r1, 0);
    e.op(jit::SLJIT_ADD, r2, r2, 0, jit::SLJIT_IMM, 1);
    e.mov(jit::SLJIT_MEM | r1, 0, r2, 0);
}

fn void FunctionEmitter.ssa_entry(&self) @feat(SLJIT) {
    FunctionPlan* plan = self.plan;
    CompiledFunction* cf = self.cf;
    TemplateEmitter* e = &self.out.e;
    LoopEmitter* out = &self.out;
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int mem = jit::SLJIT_MEM;
    int imm = jit::SLJIT_IMM;
    if (plan.ssa_region.ssa_entry != null) {
        $if $feat(SLJIT_STATS): ssa_counter(e, &plan.ssa_region.hits); $endif
        if (jit::sljit_emit_icall(e.compiler, jit::SLJIT_CALL_REG_ARG, 1,
                imm, (long)plan.ssa_region.ssa_entry) != 0) e.failed = true;
        void* refused = e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, (long)SSA_REFUSED);
        uint result = cf.code[plan.ssa_region.end + 1].a;
        e.mov(r1, 0, mem | jit::reg_s(0), loop_value_offset(result));
        e.op(jit::SLJIT_LSHR, r1, r1, 0, imm, 48);
        void* counted = e.cmp(jit::SLJIT_EQUAL, r1, 0, imm, (long)types::TAG_STRING);
        $if $feat(SLJIT_STATS):
            ssa_counter(e, &plan.ssa_region.ssa_completed);
        $endif
        e.mov(mem | jit::reg_s(0), loop_value_offset(result), r0, 0);
        self.flow_reload(plan.ssa_region.end + 1);
        out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), plan.ssa_region.end + 1, false);
        e.bind(refused);
        e.bind(counted);
        $if $feat(SLJIT_STATS):
            ssa_counter(e, &plan.ssa_region.ssa_entry_misses);
        $endif
        self.flow_reload(0);
    } else {
        e.mov(r0, 0, jit::reg_s(1), 0);
        e.mov(r1, 0, imm, (long)plan.ssa_region);
        if (jit::sljit_emit_icall(e.compiler, jit::SLJIT_CALL, jit::SLJIT_ARGS2WWW,
                imm, (long)&sljit_function_ssa_run) != 0) e.failed = true;
        void* completed = e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, 0);
        void* refused = e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, (long)cf.code);
        if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, r0, 0) != 0) e.failed = true;
        e.bind(completed);
        self.flow_reload(plan.ssa_region.end + 1);
        out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), plan.ssa_region.end + 1, false);
        e.bind(refused);
        self.flow_reload(0);
    }
}

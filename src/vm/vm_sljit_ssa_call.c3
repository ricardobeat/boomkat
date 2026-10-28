module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::jit;
import boomkat::types;

// Call-entry checks have established exact arity, realm, budget and this.
// A bounded SSA body borrows parameters from the caller without publishing a
// VM activation. It cannot allocate, invoke JS or collect. Refusal precedes
// every effect; the ordinary entry below owns all fallback semantics.
fn void FunctionEmitter.ssa_call_entry(&self, CompiledFunction* view) @feat(SLJIT) {
    if (!SSA_ENABLED || $feat(SLJIT_NO_SSA_FIELD_IR) || self.cold == null
        || view.num_args != view.num_formals || view.call_flags.rest_length_only) return;
    CompiledFunction* cf = self.cold.vm.current_func;
    if (cf.code != view.code || cf.code_count != view.code_count) return;
    Heap* h = self.cold.heap;
    LoopPlan* region = self.ssa_leaf(cf, h, true);
    if (region == null) return;
    // Pure leaves already have a cheaper inline path. Spend another native
    // body only on compound regions that remove calls and frame publication.
    if (!region.ssa_commit || !region.ssa_calls) {
        self.plan.ssa_leaves = region.next;
        h.free_func(h.heap_udata, region);
        return;
    }
    TemplateEmitter* e = &self.out.e;
    SsaGraph* graph = ssa_prepare(region, cf, h, true, true, e, 0, 0, true);
    if (graph == null || (cf.num_args < LOOP_REGS && (region.ssa_inputs >> cf.num_args) != 0)) {
        if (graph != null) h.free_func(h.heap_udata, graph);
        self.plan.ssa_leaves = region.next;
        h.free_func(h.heap_udata, region);
        return;
    }
    defer h.free_func(h.heap_udata, graph);
    LoopPlan layout;
    LoopEmitter checks = { .e = *e, .plan = &layout };
    int r0 = jit::reg_r(0);
    int r3 = jit::reg_r(3);
    int regs = jit::reg_s(0);
    int cold = jit::reg_s(1);
    int run = jit::reg_s(2);
    int object = jit::reg_s(3);
    int bottom = jit::reg_s(4);
    int result = jit::reg_s(5);
    int receiver = jit::reg_r(6);
    int mem = jit::SLJIT_MEM;
    int imm = jit::SLJIT_IMM;
    void* begin = e.label();
    $if $feat(SLJIT_MAP): region.ssa_map_begin = begin; $endif
    // The result slot must accept an uncounted result after a terminal write.
    e.mov(r0, 0, mem | result, 0);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    checks.guard(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_STRING, 0);
    e.mov(mem | run, $reflect(FunctionRun.ssa_callee).offset, object, 0);
    e.mov(mem | run, $reflect(FunctionRun.ssa_receiver).offset, receiver, 0);
    e.mov(regs, 0, bottom, 0);
    e.mov(object, 0, receiver, 0);
    if (ssa_emit_graph(graph, e) == null) { e.failed = true; return; }
    void* refused = e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, (long)SSA_REFUSED);
    {
        // No guard, helper or allocation after the body has committed.
        e.mov(mem | result, 0, r0, 0);
        e.mov(r0, 0, mem | run, $reflect(FunctionRun.budget).offset);
        e.op(jit::SLJIT_SUB, r0, r0, 0, imm, 1);
        e.mov(mem | run, $reflect(FunctionRun.budget).offset, r0, 0);
        e.mov(r0, 0, mem | cold, $reflect(ColdCtx.act).offset);
        e.mov(regs, 0, mem | r0, $reflect(Activation.bottom).offset);
        $if $feat(SLJIT_STATS):
            ssa_counter(e, &region.hits);
            ssa_counter(e, &region.ssa_completed);
            ssa_counter(e, &self.plan.direct_calls);
            ssa_counter(e, &self.plan.direct_returns);
            ssa_counter(e, &self.plan.ssa_fast_calls);
            ssa_counter(e, &h.jit_ssa_call_commits);
        $endif
        if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, imm, 0) != 0) e.failed = true;
        e.bind(refused);
    }
    e.mov(object, 0, mem | run, $reflect(FunctionRun.ssa_callee).offset);
    e.mov(receiver, 0, mem | run, $reflect(FunctionRun.ssa_receiver).offset);
    e.mov(r0, 0, mem | cold, $reflect(ColdCtx.act).offset);
    e.mov(regs, 0, mem | r0, $reflect(Activation.bottom).offset);
    e.mov(jit::reg_r(4), 0, mem | cold, $reflect(ColdCtx.vm).offset);
    void* fallback = e.label();
    for (uint i = 0; i < checks.link_count; i++) checks.bind_to(checks.link_at(i).jump, fallback);
    $if $feat(SLJIT_MAP): region.ssa_map_end = e.label(); $endif
    if (checks.e.failed) e.failed = true;
}

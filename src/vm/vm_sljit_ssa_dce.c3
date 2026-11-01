module boomkat::vm;

import std::core::mem;

struct SsaMark @feat(SLJIT) {
    SsaGraph* graph;
    bool* live;
    uint* work;
    uint count;
}
fn void SsaMark.keep(&self, int id) @feat(SLJIT) {
    if (id < 0 || (uint)id >= self.graph.value_count || self.live[id]) return;
    self.live[id] = true;
    self.work[self.count++] = (uint)id;
}

// This pass deliberately retains implicit deoptimization/coercion guards.
// A dead floating result can disappear; a boxed-to-number conversion that
// could invoke valueOf after replay cannot. Recovery frames and edge inputs
// are real users independent of ordinary instruction operands.
fn uint ssa_dce(SsaGraph* g) @feat(SLJIT) {
    if (g.value_count == 0) return 0;
    bool* live = (bool*)g.heap.alloc_func(g.heap.heap_udata, (usz)g.value_count * bool::size);
    if (live == null) return 0;
    defer g.heap.free_func(g.heap.heap_udata, live);
    mem::clear(live, (sz)(g.value_count * bool::size));
    uint* work = (uint*)g.heap.alloc_func(g.heap.heap_udata, (usz)g.value_count * uint::size);
    if (work == null) return 0;
    defer g.heap.free_func(g.heap.heap_udata, work);
    SsaMark mark = { .graph = g, .live = live, .work = work };
    for (uint id = 0; id < g.value_count; id++) {
        SsaValue value = g.values[id];
        SsaOpTraits traits = ssa_op_traits(g, value);
        if (!traits.total() || value.op == ARG || value.op == PHI || value.op == JOIN) mark.keep((int)id);
    }
    if (!g.direct) {
        for (uint pc = g.plan.begin; pc <= g.plan.end; pc++) {
            foreach (entry : ssa_frame_entries(g, ssa_frame_at_pc(g, pc))) mark.keep(entry.value);
        }
    }
    // Explicit after-effect and helper states are recovery users too; they
    // need not coincide with the ordinary pre-bytecode frame table.
    for (uint frame = 0; frame < g.frame_count; frame++) {
        foreach (entry : ssa_frame_entries(g, frame)) mark.keep(entry.value);
    }
    if (g.single_pass && g.direct && g.result_reg < g.reg_count) mark.keep(g.current[g.result_reg]);
    if (g.single_pass && g.plan.ssa_function == null && !g.direct) {
        foreach (value : g.current[:g.reg_count]) mark.keep(value);
    }
    mark.keep(g.cmp_lhs);
    mark.keep(g.cmp_rhs);
    for (uint next = 0; next < mark.count; next++) {
        SsaValue value = g.values[mark.work[next]];
        if (value.op == JOIN) {
            SsaJoin* join = &g.joins[value.a];
            for (uint p = 0; p < join.pred_count; p++) mark.keep(join.incoming[p][value.b]);
            if (join.entry) mark.keep(join.entry_incoming[value.b]);
        } else if (value.op == PHI) {
            mark.keep(value.a);
        } else {
            int[3] operands;
            uint count = ssa_value_operands(value, &operands);
            for (uint i = 0; i < count; i++) mark.keep(operands[i]);
        }
    }
    uint removed;
    for (uint id = 0; id < g.value_count; id++) {
        if (live[id] || g.values[id].op == NOP) continue;
        // Keep the stable ID. Nothing can reference an unmarked definition.
        g.values[id].op = NOP;
        removed++;
    }
    return removed;
}

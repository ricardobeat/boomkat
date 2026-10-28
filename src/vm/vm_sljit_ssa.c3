module boomkat::vm;

import boomkat::bytecode;
import boomkat::compiler;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::builtins;
import boomkat::jit;
import std::core::mem;
import std::io;

// SSA compilation pipeline: build representations, optimize, allocate, emit.

fn LoopNative ssa_loop_emit(LoopPlan* plan, CompiledFunction* cf, Heap* h) @feat(SLJIT) {
    SsaGraph* graph = (SsaGraph*)h.alloc_func(h.heap_udata, SsaGraph::size);
    if (graph == null) return null;
    defer h.free_func(h.heap_udata, graph);
    mem::clear(graph, (sz)SsaGraph::size);
    graph.plan = plan;
    graph.cf = cf;
    graph.heap = h;
    if (!ssa_build(graph)) return null;
    // A register can gain a double representation only after its definitions
    // are built, so rebuild the graph when the first pass asks for one.
    for (uint round = 0; round < 3 && graph.force_f64 != 0; round++) {
        ulong forced = graph.force_f64;
        mem::clear(graph, (sz)SsaGraph::size);
        graph.plan = plan;
        graph.cf = cf;
        graph.heap = h;
        graph.force_f64 |= forced;
        if (!ssa_build(graph)) return null;
        if (graph.force_f64 == forced) break;
    }
    ssa_cse(graph);
    ssa_numeric_loads(graph);
    ssa_allocate(graph);
    uint phi_count;
    for (uint reg = 0; reg < cf.num_regs && reg < LOOP_REGS; reg++) if (graph.phi[reg] >= 0) phi_count++;
    if (graph.spill_count + phi_count + 2 > SSA_MAX_SPILL) return null;
    SsaEmitter self    = { .g = graph, .plan = plan, .cf = cf };
    TemplateEmitter* e = &self.e;
    e.compiler = jit::sljit_create_compiler(null);
    if (e.compiler == null) return null;
    defer jit::sljit_free_compiler(e.compiler);
    if (jit::sljit_emit_enter(e.compiler, 0, jit::SLJIT_ARGS2WWW_R, 8 | (10 << 8), 9, 0) != 0) return null;
    int r0 = jit::reg_r(0);
    self.state = jit::reg_s(0);
    self.budget = jit::reg_s(1);
    self.dirty = jit::reg_s(2);
    self.at_def = 0;
    for (uint i = 0; i < LOOP_REGS; i++) self.live[i] = graph.header[i];
    e.mov(self.state, 0, r0, 0);
    e.mov(self.budget, 0, jit::reg_r(1), 0);
    // Prologue guards must not publish anything: the interpreter resumes at
    // the loop header with its original frame.
    int saved_count = (int)graph.exit_count;
    self.header_guards();
    self.prologue();
    for (uint i = (uint)saved_count; i < graph.exit_count; i++) {
        for (uint reg = 0; reg < LOOP_REGS; reg++) graph.exits[i].regs[reg] = -1;
    }
    self.header = e.label();
    self.body();
    self.latch();
    self.resolve_blocks();
    // Normal completion falls through the backedge condition.
    self.at_def = graph.stamp;
    int[LOOP_REGS] final;
    for (uint rr = 0; rr < LOOP_REGS; rr++) final[rr] = graph.phi[rr];
    self.publish(&final, plan.end + 1);
    self.exit_stubs();
    if (e.failed) return null;
    LoopNative native = (LoopNative)jit::sljit_generate_code(e.compiler, 0, null);
    if (native != null) plan.code_bytes = jit::sljit_shim_code_size(e.compiler);
    return native;
}

fn void SsaEmitter.trunc_int_f64(&self, int freg, int dst, uint pc) @feat(SLJIT) {
    int r1          = jit::reg_r(1);
    void* unordered = jit::sljit_emit_fcmp(self.e.compiler, jit::SLJIT_UNORDERED, freg, 0, freg, 0);
    self.snapshot(unordered, pc);
    self.e.mov(r1, 0, jit::SLJIT_IMM, (long)bitcast(-2147483648.0, ulong));
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r1) != 0) self.e.failed = true;
    self.snapshot(jit::sljit_emit_fcmp(self.e.compiler, jit::SLJIT_ORDERED_LESS, freg, 0, 2, 0), pc);
    self.e.mov(r1, 0, jit::SLJIT_IMM, (long)bitcast(2147483648.0, ulong));
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r1) != 0) self.e.failed = true;
    self.snapshot(jit::sljit_emit_fcmp(self.e.compiler, jit::SLJIT_ORDERED_GREATER_EQUAL, freg, 0, 2, 0), pc);
    if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_SW_FROM_F64, dst, 0, freg, 0) != 0) self.e.failed = true;
    self.e.mov(dst, 0, dst, 0, jit::SLJIT_MOV_S32);
}
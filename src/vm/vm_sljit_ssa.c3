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

fn LoopNative ssa_loop_emit(LoopPlan* plan, CompiledFunction* cf, Heap* h) @feat(SLJIT) => (LoopNative)ssa_emit(plan, cf, h, false);

// The caller owns the region's descriptor preparation and frame publication.
// A span excludes its terminal RET and may contain forward branches only.
fn bool ssa_region_supported(LoopPlan* plan, CompiledFunction* cf, Heap* h) @feat(SLJIT) {
    if (plan.begin > plan.end || plan.end >= cf.code_count || plan.end - plan.begin >= LOOP_OPS
        || cf.num_regs > LOOP_REGS
        || !ssa_loop_eligible(
        plan,
        cf,
        h
    )) return false;
    for (uint pc = plan.begin; pc <= plan.end; pc++) {
        int target = loop_target(cf.code[pc], pc);
        if (target >= 0 && (target <= (int)pc || target > (int)plan.end)) return false;
    }
    return true;
}

fn LoopNative ssa_region_emit(LoopPlan* plan, CompiledFunction* cf, Heap* h) @feat(SLJIT) {
    return ssa_region_supported(plan, cf, h) ? (LoopNative)ssa_emit(plan, cf, h, true) : null;
}

fn void* ssa_function_emit(LoopPlan* plan, CompiledFunction* cf, Heap* h) @feat(SLJIT) {
    if (!ssa_region_supported(plan, cf, h) || plan.end + 1 >= cf.code_count || cf.code[plan.end + 1].op != Opcode.RET || plan.binding_count != 0) return null;
    return ssa_emit(plan, cf, h, true, true);
}

fn void* ssa_emit(LoopPlan* plan, CompiledFunction* cf, Heap* h, bool single_pass, bool direct = false) @feat(SLJIT) {
    SsaGraph* graph = (SsaGraph*)h.alloc_func(h.heap_udata, SsaGraph::size);
    if (graph == null) return null;
    defer h.free_func(h.heap_udata, graph);
    mem::clear(graph, (sz)SsaGraph::size);
    graph.plan = plan;
    graph.cf = cf;
    graph.heap = h;
    graph.single_pass = single_pass;
    graph.direct = direct;
    graph.result_reg = direct ? cf.code[plan.end + 1].a : 0;
    graph.registers = ssa_register_budget(direct);
    if (!ssa_build(graph)) return null;
    // A register can gain a double representation only after its definitions
    // are built, so rebuild the graph when the first pass asks for one.
    for (uint round = 0; round < 3 && graph.force_f64 != 0; round++) {
        ulong forced = graph.force_f64;
        mem::clear(graph, (sz)SsaGraph::size);
        graph.plan = plan;
        graph.cf = cf;
        graph.heap = h;
        graph.single_pass = single_pass;
        graph.direct = direct;
        graph.result_reg = direct ? cf.code[plan.end + 1].a : 0;
        graph.registers = ssa_register_budget(direct);
        graph.force_f64 |= forced;
        if (!ssa_build(graph)) return null;
        if (graph.force_f64 == forced) break;
    }
    if (single_pass) {
        if (plan.ssa_fields) {
            for (uint memory = 0; memory < plan.memory_count; memory++) if (!graph.invariant[memory]) return null;
        }
        for (uint reg = 0; reg < cf.num_regs; reg++) {
            if (graph.arg[reg] >= 0) plan.ssa_inputs |= 1UL << reg;
        }
        for (uint memory = 0; memory < plan.memory_count; memory++) {
            uint source = plan.memory[memory].source;
            if (source < LOOP_REGS) plan.ssa_inputs |= 1UL << source;
        }
    }
    ssa_cse(graph);
    ssa_numeric_loads(graph);
    ssa_allocate(graph);
    uint phi_count;
    for (uint reg = 0; reg < cf.num_regs && reg < LOOP_REGS; reg++) if (graph.phi[reg] >= 0) phi_count++;
    if (graph.spill_count + phi_count + 2 > SSA_MAX_SPILL) return null;
    // Allocation uses the target's maximum budget; the ABI context needs
    // only the homes and optional descriptor caches that were actually used.
    uint scratches = 4;
    uint saveds = direct ? 6 : 2;
    uint floats = 2;
    for (uint value = 0; value < graph.value_count; value++) {
        SsaValue v = graph.values[value];
        if (v.home == 0 || (direct && v.op == ARG && v.last == v.def)) continue;
        if (v.rep == F64) {
            if ((uint)v.home > floats) floats = (uint)v.home;
        } else {
            for (uint reg = 0; reg < graph.registers.scratches; reg++) {
                if (v.home == jit::reg_r((int)reg) && reg + 1 > scratches) scratches = reg + 1;
            }
            for (uint reg = 0; reg < graph.registers.saveds; reg++) {
                if (v.home == jit::reg_s((int)reg) && reg + 1 > saveds) saveds = reg + 1;
            }
        }
    }
    for (uint memory = 0; memory < plan.memory_count && memory < 2; memory++) {
        if (graph.invariant[memory] && plan.memory[memory].kind != FIELD
            && plan.memory[memory].kind != SHAPE_FIELD
            && graph.registers.saveds >= 7 + memory * 2 && saveds < 7 + memory * 2) saveds = 7 + memory * 2;
    }
    if (!single_pass) {
        scratches = graph.registers.scratches;
        saveds = graph.registers.saveds;
        floats = 10;
    }
    SsaEmitter self    = { .g = graph, .plan = plan, .cf = cf };
    TemplateEmitter* e = &self.e;
    e.compiler = jit::sljit_create_compiler(null);
    if (e.compiler == null) return null;
    defer jit::sljit_free_compiler(e.compiler);
    if (jit::sljit_emit_enter(
        e.compiler,
        direct ? jit::SLJIT_ENTER_REG_ARG | jit::enter_keep(3) : 0,
        direct ? 1 : jit::SLJIT_ARGS2WWW_R,
        (int)scratches | ((int)floats << 8),
        (int)saveds,
        0
    ) != 0) return null;
    int r0 = jit::reg_r(0);
    self.state = jit::reg_s(direct ? 5 : 0);
    self.regs = jit::reg_s(0);
    self.budget = jit::reg_s(1);
    self.at_def = 0;
    for (uint i = 0; i < LOOP_REGS; i++) self.live[i] = graph.header[i];
    if (direct) {
        e.mov(self.state, 0, jit::SLJIT_MEM | jit::reg_s(2), $reflect(FunctionRun.ssa_state).offset);
    } else {
        e.mov(self.state, 0, r0, 0);
        e.mov(self.budget, 0, jit::reg_r(1), 0);
    }
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
    if (!single_pass) self.latch();
    self.resolve_blocks();
    // Normal completion falls through the backedge condition.
    self.at_def = graph.stamp;
    int[LOOP_REGS] final;
    final = single_pass ? graph.current : graph.phi;
    self.publish(&final, plan.end + 1);
    self.exit_stubs();
    if (e.failed) return null;
    void* native = jit::sljit_generate_code(e.compiler, 0, null);
    if (native != null) {
        plan.code_bytes = jit::sljit_shim_code_size(e.compiler);
        if (self.epoch_constant != null) {
            plan.ssa_epoch_patch = jit::sljit_shim_const_addr(self.epoch_constant);
            plan.ssa_executable_offset = jit::sljit_shim_executable_offset(e.compiler);
        }
    }
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
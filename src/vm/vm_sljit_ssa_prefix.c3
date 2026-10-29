module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import boomkat::types;
import boomkat::jit;
import std::io;

// An acyclic function prefix ends just before the first generic call. Its
// standalone SSA entry publishes exact pre-instruction frames on refusal.
fn LoopPlan* sljit_effect_prefix_compile(CompiledFunction* cf, ColdCtx* cold, uint begin = 0) @feat(SLJIT) {
    if (!$feat(SLJIT_EFFECT_REGION) || cf.num_regs > LOOP_REGS || cf.code_count > LOOP_OPS
        || cf.capture_count != 0 || cf.flags.needs_env || cf.flags.has_direct_eval
        || cf.flags.needs_lex_bridge || cf.mapped_arguments()) return null;
    // Exceptional edges and wide operand payloads need their own liveness
    // treatment before pruning frame states.
    for (uint pc = 0; pc < cf.code_count; pc++) {
        if (cf.code[pc].op == Opcode.TRY || cf.code[pc].op == Opcode.WIDE) return null;
    }
    uint end;
    bool found;
    uint pending_proto = uint::max;
    for (uint pc = begin; pc < cf.code_count; pc++) {
        if (function_call_op(cf.code[pc].op)) {
            if (begin != 0 && function_inline_ssa_candidate(cf, pc, cold.heap, true) != null) { pending_proto = uint::max; continue; }
            end = pending_proto != uint::max ? pending_proto : pc; found = true; break;
        }
        // Leave inherited reads to the baseline polymorphic continuation.
        if ((cf.code[pc].op == Opcode.GETPROPC || cf.code[pc].op == Opcode.GETPROPC_CACHED)
            && cf.ic_entries != null && ((hobject::ICEntry*)cf.ic_entries)[pc].has_proto) {
            if (begin == 0) { end = pc; found = true; break; }
            if (pending_proto == uint::max) pending_proto = pc;
        }
        int target = loop_target(cf.code[pc], pc);
        if (begin != 0 && target >= 0 && target <= (int)pc) { end = pc; found = true; break; }
        if (cf.code[pc].op == Opcode.RET || cf.code[pc].op == Opcode.RETUNDEF) return null;
    }
    if (!found || end < begin + 8) {
        $if $feat(SLJIT_STATS): if (begin != 0) io::eprintfn("SLJIT effect selection reject line=%d begin=%d end=%d found=%d", cf.get_line(0), begin, end, found); $endif
        return null;
    }
    $if $feat(SLJIT_STATS): io::eprintfn("SLJIT effect attempt line=%d end=%d", cf.get_line(0), end); $endif
    LoopPlan draft;
    draft.ssa_effect_prefix = true;
    if (!loop_analyze(&draft, end - 1, cold.act.bottom, cold, (int)begin, true, cf) || !draft.ssa_commit) {
        $if $feat(SLJIT_STATS): io::eprintfn("SLJIT effect analysis reject line=%d", cf.get_line(0)); $endif
        return null;
    }
    draft.ssa_function = cf;
    draft.ssa_shape_epoch = cold.heap.shape_recycle_epoch;
    foreach (&home : draft.cache) *home = 0;
    foreach (&home : draft.float_cache) *home = 0;
    draft.canonical = 0;
    LoopPlan* plan = cold.heap.alloc_func(cold.heap.heap_udata, LoopPlan::size);
    if (plan == null) return null;
    *plan = draft;
    return plan;
}

// Emit into the current function body. A refusal publishes its saved frame and
// returns the exact interpreter PC; success jumps to the baseline continuation.
fn bool FunctionEmitter.ssa_effect_entry(&self, LoopPlan* selected = null) @feat(SLJIT) {
    if (self.plan.numeric_homes != 0 || self.cold == null) return false;
    LoopPlan* region = selected != null ? selected : self.plan.ssa_region;
    region.dependency_owner = self.plan;
    JitWriteDependency* checkpoint = self.plan.dependencies;
    TemplateEmitter* e = &self.out.e;
    SsaGraph* graph = ssa_prepare(region, self.cf, self.cold.heap, true, false, e, 0, 0, false);
    if (graph == null) {
        sljit_dependencies_rollback(self.cold.heap, self.plan, checkpoint);
        return false;
    }
    graph.effect_out = &self.out;
    graph.effect_blocks = &self.blocks[0];
    defer self.cold.heap.free_func(self.cold.heap.heap_udata, graph);
    $if $feat(SLJIT_STATS):
        uint live;
        foreach (value : graph.frames[region.end + 1 - region.begin]) if (value >= 0) live++;
        io::eprintfn("SLJIT effect live line=%d end=%d published=%d regs=%d", self.cf.get_line(0), region.end, live, self.cf.num_regs);
    $endif
    self.flow_materialize();
    $if $feat(SLJIT_MAP): region.ssa_map_begin = e.label(); $endif
    int r0 = jit::reg_r(0);
    int r3 = jit::reg_r(3);
    int imm = jit::SLJIT_IMM;
    // Fresh native call entries clear local slots before entering this label.
    // Ordinary entries must first check those slots for counted strings.
    if ($feat(SLJIT_EFFECT_FRESH_ENTRY) && region.begin == 0) {
        for (uint reg = self.cf.num_formals; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
            e.mov(r0, 0, jit::SLJIT_MEM | jit::reg_s(0), loop_value_offset(reg));
            e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
            self.out.link(e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_STRING), 0, false);
        }
        self.plan.fresh_entry = e.label();
    }
    uint checked = $feat(SLJIT_EFFECT_FRESH_ENTRY) && region.begin == 0 ? self.cf.num_formals : self.cf.num_regs;
    for (uint reg = 0; reg < checked && reg < LOOP_REGS; reg++) {
        e.mov(r0, 0, jit::SLJIT_MEM | jit::reg_s(0), loop_value_offset(reg));
        e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
        void* counted = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_STRING);
        if (region.begin == 0) { self.out.link(counted, 0, false); }
        else {
            if (graph.effect_retry_count == graph.effect_retries.len) { e.failed = true; return true; }
            graph.effect_retries[graph.effect_retry_count++] = counted;
        }
    }
    $if $feat(SLJIT_STATS): ssa_counter(e, &region.hits); $endif
    if (ssa_emit_graph(graph, e) == null) { e.failed = true; return true; }
    $if $feat(SLJIT_STATS): ssa_counter(e, &region.ssa_completed); $endif
    self.flow_reload(region.end + 1);
    self.out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), region.end + 1, false);
    $if $feat(SLJIT_MAP): region.ssa_map_end = e.label(); $endif
    if (region.begin != 0) {
        void* baseline = e.label();
        for (uint i = 0; i < graph.effect_retry_count; i++) jit::sljit_set_label(graph.effect_retries[i], baseline);
    }
    return true;
}

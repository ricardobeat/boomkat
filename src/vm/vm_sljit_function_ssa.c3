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
// A published frame is the authority for ownership and exception state.
// Native effects commit in bytecode order; every refusal publishes the frame
// before the next unperformed operation rather than replaying the function.
fn LoopPlan* sljit_function_ssa_recoverable_compile(CompiledFunction* cf, ColdCtx* cold) @feat(SLJIT) {
    if (cf.code_count < 4 || cf.code_count > SSA_DEFAULT_BUDGET.max_words || cf.is_class_ctor()) return null;
    bool effect, cyclic, wide;
    for (uint pc = 0; pc < cf.code_count;) {
        DecodedBytecode view = bytecode::decode_bytecode(cf.code, cf.code_count, pc);
        if (!view.valid) return null;
        Opcode op = view.insn.op;
        if (op == Opcode.PUTPROP || op == Opcode.PUTPROPC || op == Opcode.PUTTHISC) effect = true;
        int target = ssa_decoded_target(view);
        if (target >= 0 && target <= (int)pc) cyclic = true;
        wide |= view.wide;
        pc = view.next_pc;
    }
    bool decoded_body = wide || cf.num_regs > LOOP_REGS || cf.code_count > SSA_SPAN;
    if (!decoded_body && (!effect || !cyclic)) return null;
    LoopPlan draft;
    if (!ssa_plan_data_init(&draft, cf, cold.heap)) return null;
    bool retained;
    defer if (!retained) ssa_plan_data_free(cold.heap, &draft);
    draft.ssa_recoverable = true;
    draft.ssa_function = cf;
    draft.begin = 0;
    draft.end = cf.code_count - 1;
    draft.ssa_data.decoded_body = decoded_body;
    if (decoded_body ? !ssa_decoded_body_supported(&draft, cf)
        : !loop_analyze(&draft, cf.code_count - 1, cold.act.bottom, cold, 0, true, cf, true)) {
        $if $feat(SLJIT_STATS): io::eprintfn("SLJIT recoverable reject name=%s stage=analysis", (String)cf.get_name()); $endif
        return null;
    }
    for (uint i = 0; i < draft.memory_count; i++) {
        LoopMemorySpec spec = draft.memory[i];
        // Prototype reads need dependency tracking across observable writes.
        // Calls and exotic reads instead leave to the ordinary interpreter.
        if (spec.kind == PROTO_FIELD || spec.kind == ASCII || spec.kind == INTRINSIC) return null;
        if (spec.kind == FIELD || spec.kind == SHAPE_FIELD) draft.ssa_fields = true;
    }
    draft.ssa_shape_epoch = cold.heap.shape_recycle_epoch;
    foreach (&cache : draft.cache) *cache = 0;
    foreach (&cache : draft.float_cache) *cache = 0;
    draft.canonical = 0;
    draft.native = ssa_region_emit(&draft, cf, cold.heap);
    if (draft.native == null) {
        $if $feat(SLJIT_STATS): io::eprintfn("SLJIT recoverable reject name=%s stage=emission", (String)cf.get_name()); $endif
        return null;
    }
    LoopPlan* plan = cold.heap.alloc_func(cold.heap.heap_udata, LoopPlan::size);
    if (plan == null) {
        jit::sljit_free_code((void*)draft.native, null);
        ssa_helper_sites_free(cold.heap, &draft);
        ssa_deopt_free(cold.heap, &draft);
        return null;
    }
    *plan = draft;
    retained = true;
    $if $feat(SLJIT_STATS):
        io::eprintfn("SLJIT recoverable SSA line=%d begin=%d end=%d bytes=%d", cf.get_line(0), plan.begin, plan.end, plan.code_bytes);
    $endif
    return plan;
}

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
        ssa_helper_sites_free(h, leaf);
        ssa_deopt_free(h, leaf);
        ssa_plan_data_free(h, leaf);
        ssa_scratch_free_all(h, leaf);
        h.free_func(h.heap_udata, leaf);
    }
    if (plan.ssa_region == null) return;
    $if $feat(SLJIT_STATS):
        io::eprintfn("SLJIT function SSA hits=%d helpers=%d continued=%d", plan.ssa_region.hits,
            plan.ssa_region.ssa_helper_calls, plan.ssa_region.ssa_helper_continued);
    $endif
    jit::sljit_free_code(plan.ssa_region.ssa_entry != null ? plan.ssa_region.ssa_entry : (void*)plan.ssa_region.native, null);
    ssa_helper_sites_free(h, plan.ssa_region);
    ssa_deopt_free(h, plan.ssa_region);
    ssa_plan_data_free(h, plan.ssa_region);
    ssa_scratch_free_all(h, plan.ssa_region);
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
            if (plan.ssa_recoverable && spec.kind != FIELD && spec.kind != SHAPE_FIELD && spec.kind != PROTO_FIELD) continue;
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
fn Instruction* sljit_function_ssa_run(ColdCtx* cold, LoopPlan* plan, FunctionRun* run = null, uint resume_pc = 0) @feat(SLJIT) {
    CompiledFunction* cf = cold.vm.current_func;
    TVal* regs           = cold.act.bottom;
    Instruction* entry_pc = cf.code + resume_pc;
    if (!sljit_function_ssa_live(cold.heap, plan)) return entry_pc;
    // Prologue arguments and every defined spill are written before use.
    // Exits publish a fresh dirty mask; untouched interpreter slots stay owned
    // by the original frame, so no blanket scratch clear/copy is necessary.
    LoopState legacy_state @noinit;
    LoopState* state = &legacy_state;
    SsaExecution execution;
    state.execution = null;
    if (plan.ssa_data != null || plan.ssa_helpers != null) {
        uint spills = plan.ssa_data == null ? 0 : plan.ssa_data.spill_count;
        uint edges = plan.ssa_data == null ? 0 : plan.ssa_data.edge_count;
        if (!ssa_execution_init(&execution, cold, plan, plan.ssa_value_capacity, spills, edges)) return entry_pc;
        execution.run = run;
        if (run != null && run.budget_base < run.budget) run.budget_base = run.budget;
        state = execution.state_storage;
        state.execution = &execution;
    }
    defer if (state.execution != null) ssa_execution_dispose(&execution);
    state.receiver = cold.act.this_binding;
    state.shape_epoch = cold.heap.shape_recycle_epoch;
    state.resume_pc = resume_pc;
    state.dirty = 0;
    state.budget = plan.ssa_recoverable && run != null ? run.budget : 1;
    for (uint i = 0; i < cf.num_regs && i < LOOP_REGS; i++) {
        if (plan.ssa_recoverable || (plan.ssa_inputs & (1UL << i)) != 0) state.values[i] = regs[i];
    }
    if ((plan.ssa_recoverable || plan.binding_count != 0)
        && !loop_prepare(plan, state, cold, plan.ssa_fields)) return entry_pc;
    if (state.execution == null && sljit_artifact_enter(cold.heap, plan.code_owner) == 0) return entry_pc;
    defer if (state.execution == null) sljit_artifact_leave(cold.heap, plan.code_owner);
    long budget = plan.ssa_recoverable && run != null ? run.budget : 1;
    uint resume = plan.native(state, budget);
    if (plan.ssa_recoverable && run != null) run.budget = state.budget;
    if (state.execution != null && execution.caller_lost) {
        // An interpreter control transfer abandoned this activation. Its
        // frame may already belong to a catch/finally handler or a callee;
        // publishing old SSA outputs or returning entry_pc would replay effects.
        plan.hits++;
        return execution.vm_resume;
    }
    // A collecting callback may have relocated every VM register window.
    regs = cold.act.bottom;
    if (plan.ssa_data != null) {
        if (!ssa_execution_publish(&execution)) {
            // Publication refusal after native progress cannot replay entry.
            // An activation-changing helper already carries its actual VM PC.
            return execution.vm_resume != null ? execution.vm_resume : cf.code + resume;
        }
    } else { sljit_publish_state(cold, regs, state, cf.num_regs, plan); }
    plan.hits++;
    Opcode exit_op = sljit_function_exit_op(cf, resume);
    bool completed = resume == plan.end + 1 || (plan.ssa_recoverable
        && (exit_op == Opcode.RET || exit_op == Opcode.RETUNDEF));
    if (completed) { plan.ssa_completed++; }
    else if (resume == plan.begin) { plan.ssa_entry_misses++; }
    else { plan.ssa_body_misses++; }
    // A body that never gets past its own first PC cannot execute at all: a
    // register or binding assumption from compile time does not hold for the
    // frames that enter it, and it must not keep the baseline tier away.
    plan.ssa_entry_streak = resume == plan.begin && !completed ? plan.ssa_entry_streak + 1 : 0;
    // A whole-body specialization earns its entry only if it executes real
    // work between helpers. A body that spends more calls in helpers than in
    // its own body pays the publication/root cost per bytecode, so the
    // baseline tier is faster. The sample must be big enough for the ratio to
    // mean something.
    bool unproductive = plan.ssa_entry_streak >= SSA_REFUSE_STREAK
        || (plan.ssa_helper_calls >= SSA_DEMOTE_HELPERS && plan.ssa_helper_calls >= plan.hits);
    if (unproductive && !cold.vm.current_func.sljit_ssa_disabled && !cold.heap.jit_hold_tier) {
        cold.vm.current_func.sljit_ssa_disabled = true;
        plan.ssa_demote = true;
        $if $feat(SLJIT_STATS): io::eprintfn("SLJIT SSA demote line=%d hits=%d helpers=%d streak=%d",
            cold.vm.current_func.get_line(0), plan.hits, plan.ssa_helper_calls, plan.ssa_entry_streak); $endif
    }
    if (plan.ssa_recoverable) {
        cold.act.curr_pc = cf.code + resume;
        return cf.code + resume;
    }
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

fn void FunctionEmitter.ssa_entry(&self, uint entry_pc = 0) @feat(SLJIT) {
    FunctionPlan* plan = self.plan;
    CompiledFunction* cf = self.cf;
    TemplateEmitter* e = &self.out.e;
    LoopEmitter* out = &self.out;
    if (plan.ssa_region.ssa_recoverable) self.flow_materialize();
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
        e.mov(jit::reg_r(2), 0, jit::reg_s(2), 0);
        e.mov(jit::reg_r(3), 0, imm, entry_pc);
        if (jit::sljit_emit_icall(e.compiler, jit::SLJIT_CALL, jit::SLJIT_ARGS4WWWW,
                imm, (long)&sljit_function_ssa_run) != 0) e.failed = true;
        if (plan.ssa_region.ssa_recoverable) {
            // Nested JS can grow the value stack while this baseline native
            // frame remains active. Its register-base saved register must be
            // reloaded before flow_reload or any bytecode label reads slots.
            e.mov(jit::reg_s(0), 0, jit::SLJIT_MEM | jit::reg_s(1), $reflect(ColdCtx.act).offset);
            e.mov(jit::reg_s(0), 0, jit::SLJIT_MEM | jit::reg_s(0), $reflect(Activation.bottom).offset);
            // A helper throw is already committed. Return to the threaded
            // exception handoff before a call label can execute it again.
            $if $feat(THREADED_DISPATCH):
                e.mov(r1, 0, jit::SLJIT_MEM | jit::reg_s(1), $reflect(ColdCtx.vm).offset);
                e.mov(r1, 0, jit::SLJIT_MEM | r1, $reflect(Vm.threaded_handoff).offset, jit::SLJIT_MOV_U8);
                void* ordinary = e.cmp(jit::SLJIT_EQUAL, r1, 0, imm, 0);
                if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, r0, 0) != 0) e.failed = true;
                e.bind(ordinary);
            $endif
            // A normal return and a pending call can use the native baseline
            // with the fully published VM slots. Keep every FP lane canonical
            // before jumping to its bytecode label.
            for (uint pc = 0; pc < cf.code_count; pc++) {
                if (pc == entry_pc) continue;
                Opcode op = cf.code[pc].op;
                if (op != Opcode.RET && op != Opcode.RETUNDEF && !function_call_op(op)) continue;
                void* other = e.cmp(jit::SLJIT_NOT_EQUAL, r0, 0, imm, (long)(cf.code + pc));
                self.flow_reload(pc);
                out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), pc, false);
                e.bind(other);
            }
            // Entry refusal continues after this hook, avoiding recursion into
            // the same SSA entry. Every other guard leaves at its precise PC.
            void* entry_refused = e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, (long)(cf.code + entry_pc));
            if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, r0, 0) != 0) e.failed = true;
            e.bind(entry_refused);
            self.flow_reload(entry_pc);
            return;
        }
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

module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::jit;

// The bytecode registry owns targets until heap reset. Patch addresses and
// executable offsets survive the temporary SLJIT compiler, not its handles.
struct FunctionCallLink @feat(SLJIT) {
    FunctionCallLink* next;
    CompiledFunction* target;
    void* jump;
    usz patch;
    void* fallback;
    long executable_offset;
}

fn void sljit_link_target(FunctionCallLink* link, bool invalidate = false) @feat(SLJIT) {
    FunctionPlan* target = invalidate ? null : link.target.sljit_function;
    void* entry = target != null && target.call_entry != null ? target.call_entry : link.fallback;
    jit::sljit_set_jump_addr(link.patch, (usz)entry, link.executable_offset);
}

// Compilation and retirement occur only after native frames have unwound.
// Unlink incoming calls before freeing their destination, then relink when a
// replacement plan is published. A cold/missing plan resumes the original call.
fn void sljit_relink_calls(Heap* h, CompiledFunction* target, bool invalidate = false) @feat(SLJIT) {
    for (uint i = 0; i < h.compiled_func_count; i++) {
        CompiledFunction* cf = h.compiled_funcs[i];
        if (cf == null || cf.sljit_function == null) continue;
        FunctionPlan* plan = cf.sljit_function;
        for (FunctionCallLink* link = plan.calls; link != null; link = link.next) {
            if (link.target == target) sljit_link_target(link, invalidate);
        }
    }
}

fn void sljit_call_links_free(Heap* h, FunctionPlan* plan) @feat(SLJIT) {
    while (plan.calls != null) {
        FunctionCallLink* link = plan.calls;
        plan.calls = link.next;
        h.free_func(h.heap_udata, link);
    }
}

fn void* FunctionEmitter.call_fallback(&self) @feat(SLJIT) {
    if (self.plan.calls == null) return null;
    TemplateEmitter* e = &self.out.e;
    void* label = e.label();
    if (jit::sljit_emit_enter(e.compiler, jit::SLJIT_ENTER_REG_ARG | jit::enter_keep(3),
            jit::SLJIT_ARGS4WWWW_R, 7 | (6 << 8), 6, 0) != 0) e.failed = true;
    e.mov(jit::reg_r(0), 0, jit::SLJIT_MEM | jit::reg_s(2), $reflect(FunctionRun.start).offset);
    if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, jit::reg_r(0), 0) != 0) e.failed = true;
    for (FunctionCallLink* link = self.plan.calls; link != null; link = link.next) {
        jit::sljit_set_label(link.jump, label);
    }
    return label;
}

fn void sljit_calls_generated(FunctionPlan* plan, void* compiler, void* fallback) @feat(SLJIT) {
    for (FunctionCallLink* link = plan.calls; link != null; link = link.next) {
        link.patch = jit::sljit_shim_jump_addr(link.jump);
        link.jump = null;
        link.fallback = (void*)jit::sljit_shim_label_addr(fallback);
        link.executable_offset = jit::sljit_shim_executable_offset(compiler);
        sljit_link_target(link);
    }
}

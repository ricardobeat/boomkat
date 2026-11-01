module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::jit;

// The bytecode registry owns targets until heap reset. Patch addresses and
// executable offsets survive the temporary SLJIT compiler, not its handles.
struct FunctionCallLink @feat(SLJIT) {
    FunctionCallLink* next;
    FunctionCallLink* target_previous;
    FunctionCallLink* target_next;
    bool registered;
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

// Each published caller registers its patch sites with their target. A target
// replacement visits only real incoming edges, including suspended retired
// callers whose owner still pins their patch storage.
fn void sljit_register_call(FunctionCallLink* link) @feat(SLJIT) {
    assert(!link.registered);
    link.target_next = link.target.sljit_incoming_calls;
    if (link.target_next != null) link.target_next.target_previous = link;
    link.target.sljit_incoming_calls = link;
    link.registered = true;
    sljit_link_target(link);
}
fn void sljit_unregister_call(FunctionCallLink* link) @feat(SLJIT) {
    if (!link.registered) return;
    if (link.target_previous != null) { link.target_previous.target_next = link.target_next; }
    else { link.target.sljit_incoming_calls = link.target_next; }
    if (link.target_next != null) link.target_next.target_previous = link.target_previous;
    link.registered = false;
}
fn void sljit_relink_calls(Heap* h, CompiledFunction* target, bool invalidate = false) @feat(SLJIT) {
    for (FunctionCallLink* link = target.sljit_incoming_calls; link != null; link = link.target_next) {
        sljit_link_target(link, invalidate);
    }
}

fn void sljit_call_links_free(Heap* h, FunctionPlan* plan) @feat(SLJIT) {
    while (plan.calls != null) {
        FunctionCallLink* link = plan.calls;
        plan.calls = link.next;
        sljit_unregister_call(link);
        h.free_func(h.heap_udata, link);
    }
}

fn void* FunctionEmitter.call_fallback(&self) @feat(SLJIT) {
    if (self.plan.calls == null) return null;
    TemplateEmitter* e = &self.out.e;
    void* label = e.label();
    if (jit::sljit_emit_enter(e.compiler, jit::SLJIT_ENTER_REG_ARG | jit::enter_keep(3),
            jit::SLJIT_ARGS4WWWW_R, jit::scratch_register_count(6) | (6 << 8), 6, 0) != 0) e.failed = true;
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
        // Keep the fallback until publication: the code-budget check may
        // retire a destination while this caller is still unpublished.
    }
}

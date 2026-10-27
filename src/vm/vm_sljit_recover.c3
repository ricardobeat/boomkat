module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::env;

// Immutable description of an expanded call. Values live in the run's
// per-depth windows until an exit reconstructs the ordinary VM frames.
struct FunctionInlineFrame @feat(SLJIT) {
    FunctionInlineFrame* next;
    FunctionInlineFrame* parent;
    CompiledFunction* target;
    Instruction* call_pc;
    ushort id;
    uint depth;
    uint bottom_offset;
    ulong[49] exits @if($feat(SLJIT_STATS));
}
const uint INLINE_CALLEE_SLOT = 31;

fn FunctionInlineFrame* sljit_inline_frame(FunctionPlan* plan, ushort id) @feat(SLJIT) {
    for (FunctionInlineFrame* frame = plan.inline_frames; frame != null; frame = frame.next) {
        if (frame.id == id) return frame;
    }
    unreachable("missing inline frame");
}

fn void sljit_inline_frames_free(Heap* h, FunctionPlan* plan) @feat(SLJIT) {
    while (plan.inline_frames != null) {
        FunctionInlineFrame* frame = plan.inline_frames;
        plan.inline_frames = frame.next;
        h.free_func(h.heap_udata, frame);
    }
}

// Native machine frames have already unwound. Entry guards reserved enough
// activation/value-stack space for every virtual frame. Reconstruction does
// not allocate or collect, and each inline value is inert or GC-traced.
fn Instruction* sljit_inline_recover(ColdCtx* cold, FunctionRun* run) @feat(SLJIT) {
    FunctionInlineFrame*[INLINE_DEPTH] frames;
    uint count;
    for (FunctionInlineFrame* f = run.recover_frame; f != null; f = f.parent) frames[count++] = f;
    Vm* vm = cold.vm;
    Heap* h = cold.heap;
    while (count > 0) {
        FunctionInlineFrame* f = frames[--count];
        CompiledFunction* cf = f.target;
        Instruction call = *f.call_pc;
        uint base = call.op == Opcode.CALL_VAR || call.op == Opcode.CALL_GLOBAL ? call.a : call.b;
        TVal* values = (TVal*)((char*)run + function_inline_window(f.depth));
        HObject* function = values[INLINE_CALLEE_SLOT].get_heapptr();
        Activation* caller = cold.act;
        TVal* bottom = caller.bottom + base + 2;
        // The real call would take ownership of this overlapping window.
        // Release only slots the caller owns before replacing their contents.
        uint owned = caller.heap_reg_count > base + 2 ? caller.heap_reg_count - base - 2 : 0;
        if (owned > cf.num_regs) owned = cf.num_regs;
        for (uint i = 0; i < owned; i++) h.decref_tval(bottom + i);
        for (uint i = 0; i < cf.num_regs; i++) bottom[i] = values[i];
        for (uint i = 0; i < FRAME_SCRATCH_SLOTS; i++) bottom[cf.num_regs + i].set_undefined();
        caller.bottom[base] = values[INLINE_CALLEE_SLOT];
        caller.curr_pc = f.call_pc + 1;
        Activation* act = &vm.activations[vm.activation_count++];
        act.parent = caller;
        act.func = cf;
        act.var_env = function.extra.func.var_env;
        EnvRecord* cap = function.extra.func.lex_env;
        act.lex_env = cap == null || !cap.flags.is_declarative ? act.var_env : cap;
        act.cat = null;
        act.forin = null;
        act.async_gen_state = null;
        act.async_promise = null;
        act.new_target = null;
        act.curr_pc = count == 0 ? cf.code + run.recover_pc : cf.code;
        act.bottom = bottom;
        act.retval = caller.bottom + call.a;
        act.flags = cf.call_flags.ignores_this ? 0 : ACT_FLAG_THIS_VALID;
        act.heap_reg_count = cf.num_regs;
        act.this_binding = values[INLINE_THIS_SLOT];
        act.tv_func = values[INLINE_CALLEE_SLOT];
        act.caller_valstack_top = vm.valstack_top;
        vm.valstack_top = bottom + cf.num_regs;
        vm.valstack_bottom = bottom;
        vm.current_func = cf;
        cold.act = act;
    }
    *cold.regs_base_ptr = cold.act.bottom;
    CompiledFunction* active = vm.current_func;
    th_bind_ic_bias(cold, active.code, active.ic_entries, active.var_ic_entries);
    return active.code + run.recover_pc;
}

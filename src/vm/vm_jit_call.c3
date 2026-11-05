// Native calls of the baseline tier (src/jit/baseline.c3): a call site in
// generated code publishes a lean callee's frame through the threaded call
// shapes and runs the callee's native code on the C stack.
module boomkat::vm @feat(SLJIT);

import boomkat::jit;
import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::env;

// Native calls nested on one Dispatch's C stack before a call takes the
// slow path, which leaves through Vm.run.
const uint JIT_NATIVE_DEPTH_CAP = 100;

// A call site's result when the callee completed without a frame.
const usz JIT_CALL_DONE = 1;

// Publish the frame of the call at the instruction before `next` and return
// the callee's native entry, JIT_CALL_DONE for a trivial callee, or null when
// the call takes its thunk. On a native entry ds describes the callee's frame
// and ds.jit_floor the caller's depth.
fn void* jit_call_enter(Dispatch* ds, ulong next_arg) {
    Instruction* next = (Instruction*)(usz)next_arg;
    Instruction* pc = next - 1;
    Vm* vm = ds.vm;
    jit::JitStats* st = &ds.heap.jit_stats;
    if (ds.jit_depth >= JIT_NATIVE_DEPTH_CAP) { st.calls_depth++; return null; }
    if (ds.ic_base == null || ds.var_ic_base == null) { st.calls_declined++; return null; }
    ds.curr_pc = next;
    ColdCtx* cold = &ds.cold;
    th_bind_ic_bias(cold, ds.code_base, ds.ic_base, ds.var_ic_base);
    TVal* regs = ds.regs_base;
    LeanCall r;
    uint nargs = pc.op == Opcode.CALL || pc.op == Opcode.CALL_UNDEF_THIS ? pc.c : pc.b;
    switch (pc.op) {
        case CALL: r = @lean_call_method(pc, regs, cold, true);
        case CALL_UNDEF_THIS: r = @lean_call_undef_this(pc, regs, cold, true);
        case CALL_VAR: r = @lean_call_var(pc, regs, cold, true);
        case CALL_GLOBAL: r = @lean_call_global(pc, regs, cold, true);
        default: unreachable("not a native call shape");
    }
    switch (r) {
        case DONE:
            st.calls_trivial++;
            return (void*)JIT_CALL_DONE;
        case NO_CODE:
            st.calls_no_code++;
            return null;
        case NATIVE:
            st.calls_builtin++;
            return null;
        case ENTERED:
        case ENTERED_ARGS:
            break;
        default:
            st.calls_declined++;
            return null;
    }
    Activation* la = ds.act;
    CompiledFunction* target = (CompiledFunction*)la.func;
    if (r == ENTERED_ARGS) {
        bind_register_arguments(vm, la, target, (HObject*)la.tv_func.get_heapptr(), la.bottom, nargs);
    }
    ds.load_frame();
    ds.jit_floor = vm.activation_count - 1;
    ds.jit_depth++;
    st.calls_native++;
    return jit::baseline_entry(target);
}

// Finish a native call: restore the floor the call site saved and, when the
// callee returned to it, reload the caller's frame. Returns 0 to continue at
// `next`, BASELINE_REDISPATCH when the caller resumes elsewhere (a handler
// caught a throw), or the callee's status for Vm.run.
fn long jit_call_return(Dispatch* ds, long status, ulong old_floor, ulong next_arg) {
    ds.jit_floor = (uint)old_floor;
    ds.jit_depth--;
    if (status != jit::BASELINE_RETURNED) return status;
    Instruction* pc = ds.curr_pc;
    ds.load_frame();
    ds.curr_pc = pc;
    return pc == (Instruction*)(usz)next_arg ? 0 : jit::BASELINE_REDISPATCH;
}

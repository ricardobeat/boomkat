module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import boomkat::types;
import std::core::mem;

enum SsaNativeCallOutcome : char { DECLINE, COMPLETE, YIELD }

// Refusal is legal only before the existing native entry publishes a callee.
// A partial callee keeps its activation and exact PC; the SSA caller unwinds
// to the VM and resumes after the call when that callee eventually returns.
fn SsaNativeCallOutcome ssa_helper_native_call(SsaExecution* execution, SsaHelperSite* site,
    DecodedBytecode view, TVal callee, uint base, uint argc) @feat(SLJIT) {
    $if $feat(SLJIT_NO_NATIVE_HELPER_CALLS): return DECLINE; $endif
    ColdCtx* cold = execution.cold;
    Heap* h = cold.heap;
    FunctionRun* run = execution.run;
    if (run == null || !callee.is_object() || callee.get_heapptr() == null
        || h.gc_pending || h.gc_phase != heap::GcPhase.IDLE || h.interrupt_due || h.uncatchable_throw
        || mem::@atomic_load(h.interrupt_requested) != 0 || cold.vm.throw_pending
        || cold.vm.has_error || h.has_error) return DECLINE;
    HObject* object = callee.get_heapptr();
    if (object.get_class() != ObjClass.FUNCTION || !object.is_callable() || object.is_bound() || object.is_proxy()) return DECLINE;
    CompiledFunction* target = object.extra.func.comp_func;
    if (target == null || target.realm != h.realm || target.num_formals != argc) return DECLINE;
    if (view.insn.op != Opcode.CALL && !target.call_flags.lean_plain) return DECLINE;
    FunctionPlan* plan = target.sljit_function;
    if (plan == null || plan.call_entry == null || plan.call_from_c == null || plan.entries[0] == null
        || !plan.dependencies_live || plan.artifact.state != LIVE) return DECLINE;
    // The native ABI borrows the argument window and clears the whole callee
    // window on return. Arbitrary valid bytecode may keep a caller slot there:
    // preserve that case through call_fn's separate VM frame, even on deopt.
    uint first = base + 2;
    uint end = first + target.num_regs + FRAME_SCRATCH_SLOTS;
    foreach (entry : site.after_entries[:site.after_count]) {
        if (entry.reg != (uint)site.result_reg && entry.reg >= first && entry.reg < end) {
            $if $feat(SLJIT_STATS): execution.plan.ssa_native_overlaps++; $endif
            return DECLINE;
        }
    }
    long remaining = execution.state_storage.budget;
    long original_base = run.budget_base;
    long pending = original_base > remaining ? original_base - remaining : 0;
    long allowance = remaining;
    long heap_remaining = h.bwd_gc_budget - pending;
    if (heap_remaining < allowance) allowance = heap_remaining;
    if (h.capi_runtime != null || h.capi_interrupt_fn != null) {
        long interrupt_remaining = (long)h.interrupt_budget - pending;
        if (interrupt_remaining < allowance) allowance = interrupt_remaining;
    }
    if (allowance <= 1) return DECLINE;
    // Clip the base and remaining together: nested native helpers can still
    // distinguish real uncharged work from this temporary budget restriction.
    run.budget_base = original_base - (remaining - allowance);
    run.budget = allowance;
    run.start = execution.function.code + view.payload_pc;
    FunctionNativeCall call = { object, cold.act.bottom + first,
        cold.act.bottom + view.insn.a, argc | (view.insn.op == Opcode.CALL ? 0 : 256) };
    Activation* caller = cold.act;
    if (caller.heap_reg_count < execution.register_count) caller.heap_reg_count = execution.register_count;
    $if $feat(SLJIT_STATS): execution.plan.ssa_native_calls++; $endif
    Instruction* resume = plan.call_from_c(cold, run, &call);
    bool recovered = run.recover_frame != null;
    if (recovered) {
        resume = sljit_inline_recover(cold, run);
        run.recover_frame = null; // the outer gateway must not materialize twice
    }
    long consumed = allowance - run.budget;
    assert(consumed >= 0 && consumed <= allowance);
    run.budget_base = original_base;
    run.budget = remaining - consumed;
    execution.state_storage.budget = run.budget;
    if (resume == null) {
        $if $feat(SLJIT_STATS): execution.plan.ssa_native_returns++; $endif
        return COMPLETE;
    }
    bool restart = cold.dispatch_ptr != null && ((Dispatch*)cold.dispatch_ptr).needs_restart;
    if (!recovered && cold.act == caller && cold.vm.current_func == execution.function && !restart
        && cold.vm.threaded_handoff == ThreadedHandoff.NONE
        && resume == execution.function.code + view.payload_pc) return DECLINE;
    execution.caller_lost = true;
    $if $feat(SLJIT_STATS): execution.plan.ssa_native_exits++; $endif
    execution.vm_resume = resume;
    execution.phase = AFTER;
    execution.outcome = SsaHelperOutcome.YIELD;
    if (cold.dispatch_ptr != null) ((Dispatch*)cold.dispatch_ptr).needs_restart = true;
    cold.act.curr_pc = resume;
    return YIELD;
}

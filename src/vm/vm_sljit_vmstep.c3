module boomkat::vm;

import boomkat::bytecode;

// Borrow the existing interpreter for exactly one instruction. Its switch is
// the semantic implementation; this does not add a second opcode dispatcher.
// Calls are synchronous call_fn boundaries instead. Return/handler/suspension
// instructions retain explicit VM exits until their control states are modeled.
fn bool ssa_vm_step_supported(Opcode op) @feat(SLJIT) {
    switch (op) {
        case CLOSURE: case INIT_SLOT:
        case NEWCELLS: case GETCELL: case SETCELL: case MOVECELL:
        case GETVAR: case GETGLOBAL: case GETCAP: case GETBOUND: case TYPEOFIDENT:
        case DECLVAR: case DECLVAR_HOIST: case DECLGLOBALFUNC: case DECLB33GLOBAL:
        case PUTVAR: case PUTVAR_ASSIGN: case PUTGLOBAL: case PUTCAP:
        case GETPROP: case GETPROP_CACHE: case GETPROPC: case GETPROPC_CACHED:
        case GETTHISC: case PUTPROP: case PUTPROPC: case PUTTHISC:
        case DELPROP: case TOSTR: case TOPROPKEY:
        case NEWOBJ: case NEWOBJ_SHAPE: case NEWARR: case NEWARR_CONST:
        case UNM: case UNP: case LNOT: case INSTANCEOF:
            return true;
        default: return false;
    }
}

fn SsaHelperOutcome ssa_vm_step(SsaExecution* execution, SsaHelperSite* site) @feat(SLJIT) {
    ColdCtx* cold = execution.cold;
    Vm* vm = cold.vm;
    DecodedBytecode view = bytecode::decode_bytecode(execution.function.code, execution.function.code_count, site.pc);
    if (!view.valid || !ssa_vm_step_supported(view.insn.op)) return REPLAY;
    Dispatch step;
    step.init(vm);
    step.load_frame();
    step.needs_restart = false;
    step.single_step = true;
    step.curr_pc = execution.function.code + site.pc;
    Activation* prior_step = vm.native_step_activation;
    vm.native_step_activation = step.act;
    defer vm.native_step_activation = prior_step;
    bool failed;
    if (catch err = vm_dispatch(&step)) failed = true;
    // Cached property reads may only downgrade their opcode and ask the VM
    // to retry, without reading a value. Re-enter the original WIDE prefix,
    // never its payload, and finish that same semantic instruction once.
    if (!failed && !step.needs_restart && view.insn.op == Opcode.GETPROPC_CACHED
        && (step.curr_pc == execution.function.code + view.pc
            || step.curr_pc == execution.function.code + view.payload_pc)) {
        step.curr_pc = execution.function.code + view.pc;
        if (catch err = vm_dispatch(&step)) failed = true;
    }
    if (step.needs_restart || step.halt || !ssa_execution_rebind(execution)) {
        // A future supported opcode may transfer control. Never continue or
        // replay a native caller that is no longer the active VM activation.
        ((Dispatch*)cold.dispatch_ptr).needs_restart = true;
        execution.caller_lost = true;
        execution.vm_resume = step.curr_pc;
        execution.phase = AFTER;
        if (vm.activation_count != 0) {
            cold.act = &vm.activations[vm.activation_count - 1];
            vm.current_func = (CompiledFunction*)cold.act.func;
            execution.vm_resume = cold.act.curr_pc;
            cold.capture_refs = null;
            if (cold.regs_base_ptr != null) *cold.regs_base_ptr = cold.act.bottom;
        }
        return YIELD;
    }
    if (failed || vm.throw_pending || vm.has_error || vm.heap.has_error) {
        (void)vm_check_call_fn_error(vm);
        return THROW;
    }
    execution.after_pc = (uint)(step.curr_pc - execution.function.code);
    return COMPLETE;
}

module jit_test;

import boomkat;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::types;
import boomkat::vm;
import std::io;

fn void scalable_abc(Instruction* code, uint* count, Opcode op, uint a, uint b, uint c) {
    if ((a | b | c) > 255) code[(*count)++] = bytecode::make_wide(a >> 8, b >> 8, c >> 8);
    code[(*count)++] = bytecode::make_abc(op, a & 255, b & 255, c & 255);
}
fn void scalable_int(Instruction* code, uint* count, uint reg, int value) {
    if (reg > 255) code[(*count)++] = bytecode::make_wide(reg >> 8, 0, 0);
    code[(*count)++] = bytecode::make_a_sbx(Opcode.LDINT, reg & 255, value);
}

// Exercise the real shared FunctionPlan gateway with exact bytecode shapes.
// 150 live loop values occupy registers157..306; the full body exceeds512
// words, imports high WIDE operands, spills beyond128 and copies over64 phis.
fn void check_scalable_ssa_gateway() {
    Instruction[2] invalid = { bytecode::make_wide(1, 0, 0), bytecode::make_abc(Opcode.RET, 0, 0, 0) };
    CompiledFunction malformed = { .code = &invalid[0], .code_count = 2, .num_regs = 4 };
    LoopPlan malformed_plan = { .end = 1 };
    @check(!vm::ssa_decoded_body_supported(&malformed_plan, &malformed));
    invalid[0] = bytecode::make_abc(Opcode.CALL_UNDEF_THIS, 0, 3, 0);
    invalid[1] = bytecode::make_abc(Opcode.RETUNDEF, 0, 0, 0);
    @check(!vm::ssa_decoded_body_supported(&malformed_plan, &malformed));
    invalid[0] = bytecode::make_abc(Opcode.INIT_SLOT, 0, 0, 7);
    @check(!vm::ssa_decoded_body_supported(&malformed_plan, &malformed));
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    check_ssa_alias_queries(&runtime);
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    eval(&context, "function scalableRaw(n){return n;}");
    CompiledFunction* cf = named_function(&runtime, "scalableRaw");
    @check(cf != null);
    Instruction* original_code = cf.code;
    uint original_count = cf.code_count;
    ushort original_regs = cf.num_regs;
    Heap* h = runtime.rt.heap;
    defer {
        if (cf.sljit_function != null) vm::sljit_function_free(h, cf);
        cf.code = original_code;
        cf.code_count = original_count;
        cf.num_regs = original_regs;
    }
    Instruction[1400] code;
    uint count;
    for (uint i = 0; i < 150; i++) scalable_int(&code[0], &count, 157 + i, (int)i + 1);
    scalable_int(&code[0], &count, 307, 0);
    scalable_int(&code[0], &count, 308, 0);
    uint header = count;
    for (uint i = 0; i < 150; i++) scalable_abc(&code[0], &count, Opcode.ADDI, 157 + i, 157 + i, 1);
    scalable_abc(&code[0], &count, Opcode.ADDI, 307, 307, 1);
    scalable_abc(&code[0], &count, Opcode.LT, 309, 307, 0);
    code[count++] = bytecode::make_wide(1, 0, 0);
    code[count] = bytecode::make_a_sbx(Opcode.IF_TRUE, 309 & 255, (int)header - (int)count - 1);
    count++;
    for (uint i = 0; i < 150; i++) scalable_abc(&code[0], &count, Opcode.ADD, 308, 308, 157 + i);
    scalable_abc(&code[0], &count, Opcode.RET, 308, 0, 0);
    @check(count > 512 && count < code.len && header > 128);
    cf.code = &code[0]; cf.code_count = count; cf.num_regs = 310;
    @check(runtime.set_jit());
    h.jit_stress = true;
    // The fixture is call-dominated, so the tier policy would move it to the
    // baseline tier and replace the specialization under test.
    h.jit_hold_tier = true;
    eval(&context, "for(var q=0;q<128;q++){if(scalableRaw(3)!==11775)throw 'scalable raw result';}");
    FunctionPlan* plan = cf.sljit_function;
    @check(plan != null && plan.native == null && plan.ssa_region != null);
    @check(plan.count == count && plan.ssa_region.hits > 0);
    // Successful WIDE RET exits are completions, including short resumed
    // regions that must not be classified as repeated unproductive entries.
    @check(plan.ssa_region.ssa_completed > 0);
    @check(vm::sljit_function_exit_op(cf, count - 2) == Opcode.RET);
    @check(plan.ssa_region.ssa_data != null && plan.ssa_region.ssa_data.reg_count == 310);
    @check(plan.ssa_region.ssa_data.spill_count > 128 && plan.ssa_region.ssa_data.edge_count > 64);
    @check(plan.call_entry != null && plan.ssa_call_code != null);
    @check(vm::ssa_plan_resumes(plan.ssa_region, header));
    $if $feat(SLJIT_MAP): vm::sljit_address_map(plan, cf, 0); $endif
    @check(!vm::ssa_plan_resumes(plan.ssa_region, count - 1)); // WIDE RET payload
    eval(&context, "function scalableNativeDriver(fn,n){return fn(n);}for(var q=0;q<128;q++){if(scalableNativeDriver(scalableRaw,3)!==11775)throw 'scalable native call result';}");
    CompiledFunction* driver = named_function(&runtime, "scalableNativeDriver");
    @check(driver != null && driver.sljit_function != null);
    FunctionPlan* driver_plan = driver.sljit_function;
    @check(driver_plan.direct_calls > 0 && plan.direct_returns > 0);
    io::printfn("scalable native call ABI: PASS calls=%d returns=%d", driver_plan.direct_calls, plan.direct_returns);
    // Fractional input traverses the same high-register loop and exact prefix
    // recovery. Every local must be reimported when an interpreter poll resumes.
    ulong prior_hits = plan.ssa_region.hits;
    h.jit_stress = false;
    eval(&context, "for(var q=0;q<64;q++){if(scalableRaw(3.5)!==11925)throw 'scalable fractional result';}");
    @check(plan.ssa_region.hits > prior_hits);
    eval(&context, "if(scalableRaw('3')!==11775)throw 'scalable coercion recovery';");
    io::printfn("scalable SSA gateway: PASS words=%d registers=%d spills=%d edges=%d hits=%d", count,
        cf.num_regs, plan.ssa_region.ssa_data.spill_count, plan.ssa_region.ssa_data.edge_count, plan.ssa_region.hits);

    // Acyclic full SSA still needs CFG helper liveness and the dynamic result
    // import. Its CALL destination is WIDE and the post-call entry is above512.
    vm::sljit_function_free(h, cf);
    cf.sljit_function_calls = 0;
    count = 0;
    for (uint i = 0; i < 600; i++) code[count++] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
    scalable_abc(&code[0], &count, Opcode.LDUNDEF, 1, 0, 0);
    scalable_abc(&code[0], &count, Opcode.CALL_UNDEF_THIS, 300, 0, 0);
    uint after_call = count;
    scalable_abc(&code[0], &count, Opcode.RET, 300, 0, 0);
    cf.code_count = count;
    h.jit_stress = true;
    eval(&context, "function scalableCallback(){return 17;}for(var q=0;q<128;q++){if(scalableRaw(scalableCallback)!==17)throw 'scalable helper result';}");
    plan = cf.sljit_function;
    @check(plan != null && plan.native == null && plan.ssa_region != null);
    @check(plan.ssa_region.hits > 0 && plan.ssa_region.ssa_helpers != null);
    @check(plan.ssa_region.ssa_helper_calls > 0 && plan.ssa_region.ssa_helper_continued > 0);
    @check(plan.ssa_region.ssa_native_returns > 0);
    @check(vm::ssa_plan_resumes(plan.ssa_region, after_call));
    eval(&context, "for(var q=0;q<64;q++){if(scalableNativeDriver(scalableRaw,scalableCallback)!==17)throw 'native helper return';}function scalableNativeGrow(n){if(n===0)return 17;var a0=n,a1=n+1,a2=n+2,a3=n+3,a4=n+4,a5=n+5,a6=n+6,a7=n+7,a8=n+8,a9=n+9;return scalableNativeGrow(n-1)+(a0-a0)+(a1-a1)+(a2-a2)+(a3-a3)+(a4-a4)+(a5-a5)+(a6-a6)+(a7-a7)+(a8-a8)+(a9-a9);}function scalableGrowCallback(){return scalableNativeGrow(40);}if(scalableNativeDriver(scalableRaw,scalableGrowCallback)!==17)throw 'native helper stack growth';var nativeThrows=0;function scalableThrowCallback(){nativeThrows++;throw 'native helper throw';}try{scalableNativeDriver(scalableRaw,scalableThrowCallback);throw 'missing native helper throw';}catch(error){if(error!=='native helper throw')throw error;}if(nativeThrows!==1)throw 'native helper replay';");
    eval(&context, "var nativeStringCalls=0;function scalableStringCallback(){nativeStringCalls++;return 'native-owned-'+nativeStringCalls;}if(scalableNativeDriver(scalableRaw,scalableStringCallback)!=='native-owned-1'||nativeStringCalls!==1)throw 'native owned return';");
    eval(&context, "globalThis.scalablePlainMarker=17;function scalablePlainThis(){return this.scalablePlainMarker;}for(var q=0;q<32;q++){if(scalableRaw(scalablePlainThis)!==17)throw 'plain native this';}");
    h.jit_stress = false;
    eval(&context, "var scalablePartialState={calls:0,throws:0,budgets:0};function scalablePartial(){scalablePartialState.calls=scalablePartialState.calls+1;return Object.keys({x:1}).length+16;}function scalablePartialThrow(){scalablePartialState.throws=scalablePartialState.throws+1;throw 'partial native throw';}function scalablePartialBudget(){scalablePartialState.budgets=scalablePartialState.budgets+1;var sum=0;for(var i=0;i<4096;i++)sum=sum+1;return sum-4079;}scalablePartial();try{scalablePartialThrow();}catch(error){}scalablePartialBudget();scalablePartialState.calls=0;scalablePartialState.throws=0;scalablePartialState.budgets=0;");
    h.jit_stress = true;
    eval(&context, "for(var q=0;q<32;q++){if(scalableRaw(scalablePartial)!==17)throw 'partial native result';}if(scalablePartialState.calls!==32)throw 'partial native replay';for(var q=0;q<32;q++){try{scalableRaw(scalablePartialThrow);throw 'missing partial throw';}catch(error){if(error!=='partial native throw')throw error;}}if(scalablePartialState.throws!==32)throw 'partial throw replay';");
    @check(plan.ssa_region.ssa_native_exits > 0);
    ulong before_budget = plan.ssa_region.ssa_native_exits;
    eval(&context, "for(var q=0;q<8;q++){if(scalableRaw(scalablePartialBudget)!==17)throw 'partial native budget';}if(scalablePartialState.budgets!==8)throw 'native budget replay';");
    @check(plan.ssa_region.ssa_native_exits > before_budget);
    @check(plan.direct_returns > 0);
    io::printfn("scalable acyclic helper: PASS words=%d calls=%d continuations=%d", count,
        plan.ssa_region.ssa_helper_calls, plan.ssa_region.ssa_helper_continued);
    io::printfn("SSA native helper calls: PASS calls=%d returns=%d partial=%d", plan.ssa_region.ssa_native_calls,
        plan.ssa_region.ssa_native_returns, plan.ssa_region.ssa_native_exits);

}

// Dead VM slots still own counted strings until their frame releases them.
fn void check_ssa_native_scratch_ownership() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    @check(runtime.set_jit());
    Heap* h = runtime.rt.heap;
    Vm* vm = runtime.rt.vm;
    h.jit_stress = true;
    eval(&context, "function nativeScratchTarget(value){return value;}for(var q=0;q<16;q++)nativeScratchTarget(17);");
    CompiledFunction* target = named_function(&runtime, "nativeScratchTarget");
    @check(target != null && target.sljit_function != null);
    heap::Realm* prior_realm = h.realm;
    h.enter_realm(target.realm);
    defer h.enter_realm(prior_realm);
    h.mark_and_sweep(true, true);
    @check(h.gc_phase == heap::GcPhase.IDLE && !h.gc_pending);
    @check(target.num_formals == 1 && target.call_flags.lean_plain);
    FunctionPlan* target_plan = target.sljit_function;
    @check(target_plan.call_from_c != null && target_plan.entries[0] != null && target_plan.shape_count == 0);
    target_plan.shape_clock = h.shape_gen_clock;
    target_plan.shape_epoch = h.shape_recycle_epoch;
    int index = vm.global_env.bindings.find_prop_idx((void*)h.str_intern("nativeScratchTarget"), h);
    @check(index >= 0);
    TVal callee = vm.global_env.bindings.prop_values()[index].get();
    Instruction[3] code = { bytecode::make_wide(1, 0, 0),
        bytecode::make_abc(Opcode.CALL_UNDEF_THIS, 300 & 255, 0, 1), bytecode::make_abc(Opcode.RETUNDEF, 0, 0, 0) };
    CompiledFunction caller_function = { .num_regs = 900, .realm = h.realm, .code = &code[0], .code_count = 3 };
    FunctionPlan caller_plan;
    caller_function.sljit_function = &caller_plan;
    CompiledFunction* prior_function = vm.current_func;
    Activation prior_activation = vm.activation_storage[0];
    uint prior_count = vm.activation_count;
    uint prior_budget = h.bwd_gc_budget;
    defer { vm.current_func = prior_function; vm.activation_storage[0] = prior_activation;
        vm.activation_count = prior_count; h.bwd_gc_budget = prior_budget; }
    vm.current_func = &caller_function;
    vm.activation_storage[0] = { .func = &caller_function, .bottom = vm.valstack,
        .var_env = vm.global_env, .lex_env = vm.global_env, .heap_reg_count = 900 };
    vm.activation_count = 1;
    h.bwd_gc_budget = 1024;
    ColdCtx cold = { .vm = vm, .heap = h, .act = &vm.activation_storage[0] };
    JitArtifact owner = { .state = LIVE, .generation = 1 };
    LoopPlan plan = { .code_owner = &owner };
    SsaExecution execution;
    @check(vm::ssa_execution_init(&execution, &cold, &plan, 1, 0, 0));
    defer vm::ssa_execution_dispose(&execution);
    FunctionRun run = { .root = cold.act, .budget = 128, .budget_base = 128 };
    execution.run = &run;
    execution.state_storage.budget = 128;
    SsaFrameEntry[1] after = { { .reg = 2, .value = 0 } };
    SsaHelperSite site = { .pc = 0, .next_pc = 2, .result_reg = 300, .after_entries = &after[0], .after_count = 1 };
    // Refuse overlapping live arguments and scratch without entering a VM
    // callee. The ordinary interpreter's borrowed CALL convention itself does
    // not promise to preserve arbitrary after-live slots in this window.
    @check(vm::ssa_helper_native_call(&execution, &site, bytecode::decode_bytecode(&code[0], 3, 0), callee, 0, 1) == SsaNativeCallOutcome.DECLINE);
    after[0].reg = 2 + target.num_regs;
    @check(vm::ssa_helper_native_call(&execution, &site, bytecode::decode_bytecode(&code[0], 3, 0), callee, 0, 1) == SsaNativeCallOutcome.DECLINE);
    @check(plan.ssa_native_overlaps == 2 && plan.ssa_native_calls == 0);
    after[0].reg = 300;
    uint scratch = 2 + target.num_regs;
    TVal string = types::make_string(h.alloc_text("owned dead native scratch"));
    HeapHeader* header = string.get_heapptr();
    h.tval_copy_ref(vm.valstack + scratch, &string);
    defer { h.decref_tval(vm.valstack + scratch); vm.valstack[scratch].set_undefined(); h.decref_tval(&string); }
    @check(vm::ssa_helper_native_call(&execution, &site, bytecode::decode_bytecode(&code[0], 3, 0), callee, 0, 1) == SsaNativeCallOutcome.DECLINE);
    @check(plan.ssa_native_calls == 1 && plan.ssa_native_exits == 0 && vm.activation_count == 1);
    @check(vm.valstack[scratch].get_heapptr() == header && header.refcount == 2);
    io::printn("SSA native scratch: PASS live arguments/scratch and dead owned string refuse before clearing");
}

// COPY queries share the graph's work ceiling and never return an invalid
// negative ID on exhaustion; deopt freezing uses this same query contract.
fn void check_ssa_alias_queries(JsRuntime* runtime) {
    SsaGraph graph = { .heap = runtime.rt.heap, .budget = vm::SSA_DEFAULT_BUDGET, .value_count = 1025 };
    graph.values = vm::ssa_storage_alloc(&graph, graph.value_count, SsaValue::size);
    @check(graph.values != null);
    defer vm::ssa_storage_free(&graph);
    graph.values[0] = { .op = SsaOp.CONST_I, .rep = SsaRep.INT32, .imm = 7 };
    for (uint id = 1; id < graph.value_count; id++) {
        graph.values[id] = { .op = SsaOp.COPY, .rep = SsaRep.INT32, .a = (int)id - 1 };
    }
    @check(vm::ssa_alias(&graph, 1024) == 0 && !graph.failed);
    graph.budget.max_work = graph.work + 4;
    @check(vm::ssa_alias(&graph, 1024) == 1024 && graph.failed);
    graph.failed = false;
    graph.work = 0;
    graph.budget.max_work = vm::SSA_DEFAULT_BUDGET.max_work;
    graph.values[1].a = 2;
    @check(vm::ssa_alias(&graph, 1024) == 1024 && graph.failed);
    io::printn("SSA alias work budget: PASS");
}

fn void check_scalable_ssa_closure_startup() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    @check(runtime.set_jit());
    runtime.rt.heap.jit_stress = true;
    eval(&context, $embed("../jit_ssa_closure_startup.js"));
    CompiledFunction* cf = named_function(&runtime, "closureStartupFactory");
    @check(cf != null && cf.num_regs > vm::LOOP_REGS && cf.code[0].op == Opcode.CLOSURE);
    FunctionPlan* plan = cf.sljit_function;
    @check(plan != null && plan.ssa_region != null && plan.ssa_region.ssa_recoverable);
    LoopPlan* body = plan.ssa_region;
    @check(body.hits > 0 && body.ssa_helper_calls > 0 && body.ssa_helper_continued > 0);
    SsaHelperSite* closure;
    for (SsaHelperSite* site = body.ssa_helpers; site != null; site = site.next) {
        if (site.pc == 0) { closure = site; break; }
    }
    @check(closure != null && closure.native_resume);
    bool imported;
    foreach (entry : closure.after_entries[0:closure.after_count]) {
        if (entry.reg == cf.code[0].a) imported = true;
    }
    @check(imported);
    // A normal entry into the already-hot artifact must preserve the same
    // constructor result and prototype ownership as stress compilation.
    ulong prior = body.hits;
    runtime.rt.heap.jit_stress = false;
    eval(&context, "for(var q=0;q<128;q++){var F=closureStartupFactory();if((new F(q)).value!==q||F.prototype.m15!==7)throw 'normal closure startup';}");
    @check(body.hits > prior);
    io::printfn("scalable SSA closure startup: PASS registers=%d hits=%d helpers=%d continuations=%d", cf.num_regs,
        body.hits, body.ssa_helper_calls, body.ssa_helper_continued);
}

module jit_test;

import boomkat;
import boomkat::bytecode;
import boomkat::heap;
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
    eval(&context, "for(var q=0;q<128;q++){if(scalableRaw(3)!==11775)throw 'scalable raw result';}");
    FunctionPlan* plan = cf.sljit_function;
    @check(plan != null && plan.native == null && plan.ssa_region != null);
    @check(plan.count == count && plan.ssa_region.hits > 0);
    @check(plan.ssa_region.ssa_data != null && plan.ssa_region.ssa_data.reg_count == 310);
    @check(plan.ssa_region.ssa_data.spill_count > 128 && plan.ssa_region.ssa_data.edge_count > 64);
    @check(vm::ssa_plan_resumes(plan.ssa_region, header));
    $if $feat(SLJIT_MAP): vm::sljit_address_map(plan, cf, 0); $endif
    @check(!vm::ssa_plan_resumes(plan.ssa_region, count - 1)); // WIDE RET payload
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
    @check(vm::ssa_plan_resumes(plan.ssa_region, after_call));
    io::printfn("scalable acyclic helper: PASS words=%d calls=%d continuations=%d", count,
        plan.ssa_region.ssa_helper_calls, plan.ssa_region.ssa_helper_continued);
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

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
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
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
}

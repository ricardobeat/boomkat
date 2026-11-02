module jit_test;

import boomkat;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::vm;
import std::io;

fn void check_ssa_boolean_equality() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    @check(runtime.set_jit());
    runtime.rt.heap.jit_stress = true;
    // The fixture is call-dominated, so the tier policy would move it to the
    // baseline tier and replace the specialization under test.
    runtime.rt.heap.jit_hold_tier = true;
    eval(&context, "var booleanEqOnlyNative=true;");
    eval(&context, $embed("../jit_ssa_boolean_equality.js"));
    CompiledFunction* cf = named_function(&runtime, "nativeBooleanEquality");
    @check(cf != null && cf.code_count > vm::SSA_SPAN && cf.code_count < vm::FUNCTION_OPS);
    FunctionPlan* plan = cf.sljit_function;
    @check(plan != null && plan.ssa_region != null && plan.ssa_region.ssa_completed > 100);
    uint comparisons;
    for (uint pc = 0; pc < cf.code_count;) {
        DecodedBytecode view = bytecode::decode_bytecode(cf.code, cf.code_count, pc);
        @check(view.valid);
        if (view.insn.op == Opcode.EQ || view.insn.op == Opcode.NEQ
            || view.insn.op == Opcode.SEQ || view.insn.op == Opcode.SNEQ) {
            comparisons++;
            @check(plan.exit_pcs[pc] == 0);
        }
        pc = view.next_pc;
    }
    @check(comparisons >= 8);
    // The short effect fixture also exercises the decoded recovery path. Its
    // extra unused register changes storage/admission, not the bytecode or its
    // operand types, and avoids relying on legacy loop-analyzer eligibility.
    CompiledFunction* effect = named_function(&runtime, "booleanEqualityEffects");
    @check(effect != null && effect.num_regs <= vm::LOOP_REGS);
    ushort effect_regs = effect.num_regs;
    if (effect.sljit_function != null) vm::sljit_function_free(runtime.rt.heap, effect);
    effect.sljit_function_calls = 0;
    effect.num_regs = (ushort)(vm::LOOP_REGS + 1);
    defer {
        if (effect.sljit_function != null) vm::sljit_function_free(runtime.rt.heap, effect);
        effect.num_regs = effect_regs;
    }
    eval(&context, "for(var q=0;q<32;q++){if(booleanEqualityEffects(false,booleanEffectState,false)!==true)throw 'native effect equality';}");
    FunctionPlan* effect_plan = effect.sljit_function;
    @check(effect_plan != null && effect_plan.ssa_region != null && effect_plan.ssa_region.ssa_completed > 10);
    eval(&context, "checkBooleanEqualityFallbacks();");
    runtime.rt.heap.jit_stress = false;
    eval(&context, "for(var q=0;q<32;q++){if(nativeBooleanEquality((q&1)===0,booleanEqOutput,2)!==52)throw 'normal boolean equality';}");
    io::printfn("SSA boolean equality: PASS sites=%d native completions=%d, no boolean EQ exits", comparisons, plan.ssa_region.ssa_completed);
}

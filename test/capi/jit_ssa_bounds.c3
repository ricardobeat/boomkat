module jit_test;

import boomkat;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import boomkat::vm;
import std::io;

// WIDE operands force the scalable lowering. The first successful access to
// index7 proves the live length for the later masked index; no length sample
// or raw pointer becomes compilation authority.
fn void check_scalable_ssa_bounds() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    eval(&context, "function boundsRaw(a,n,callback){return n;}");
    CompiledFunction* cf = named_function(&runtime, "boundsRaw");
    @check(cf != null);
    Instruction* saved_code = cf.code;
    uint saved_count = cf.code_count;
    ushort saved_regs = cf.num_regs;
    void* saved_ic = cf.ic_entries;
    void* saved_var_ic = cf.var_ic_entries;
    uint saved_ic_count = cf.ic_count;
    uint saved_var_ic_count = cf.var_ic_count;
    Heap* h = runtime.rt.heap;
    defer {
        if (cf.sljit_function != null) vm::sljit_function_free(h, cf);
        cf.code = saved_code; cf.code_count = saved_count; cf.num_regs = saved_regs;
        cf.ic_entries = saved_ic; cf.ic_count = saved_ic_count;
        cf.var_ic_entries = saved_var_ic; cf.var_ic_count = saved_var_ic_count;
    }
    Instruction[64] code;
    ICEntry[64] caches;
    VarICEntry[64] bindings;
    @check(runtime.set_jit());
    for (uint helper = 0; helper < 2; helper++) {
        if (cf.sljit_function != null) vm::sljit_function_free(h, cf);
        cf.sljit_function_calls = 0;
        uint count;
        scalable_int(&code[0], &count, 300, 7);
        scalable_abc(&code[0], &count, Opcode.GETPROP, 301, 0, 300);
        if (helper != 0) {
            scalable_abc(&code[0], &count, Opcode.LDUNDEF, 3, 0, 0);
            scalable_abc(&code[0], &count, Opcode.CALL_UNDEF_THIS, 305, 2, 0);
        }
        scalable_abc(&code[0], &count, Opcode.BANDI, 302, 1, 7);
        scalable_abc(&code[0], &count, Opcode.GETPROP, 303, 0, 302);
        scalable_abc(&code[0], &count, Opcode.ADD, 304, 301, 303);
        scalable_abc(&code[0], &count, Opcode.RET, 304, 0, 0);
        cf.code = &code[0]; cf.code_count = count; cf.num_regs = 306;
        cf.ic_entries = &caches[0]; cf.ic_count = count;
        cf.var_ic_entries = &bindings[0]; cf.var_ic_count = count;
        h.jit_stress = true;
        eval(&context, "function boundsNoop(){};for(var q=0;q<128;q++){var a=[1,2,3,4,5,6,7,8];if(boundsRaw(a,5,boundsNoop)!==14)throw 'bounds native result';}");
        FunctionPlan* plan = cf.sljit_function;
        @check(plan != null && plan.ssa_region != null && plan.ssa_region.hits > 0);
        @check(plan.ssa_region.ssa_data.native_accesses == 2);
        @check(plan.ssa_region.ssa_data.bounds_proofs == (helper == 0 ? 1U : 0U));
        if (helper == 0) {
            @check(plan.ssa_region.ssa_helpers == null);
            // A shorter receiver must fail the first check, before using the
            // downstream proof, and reproduce ordinary undefined arithmetic.
            eval(&context, "var shortResult=boundsRaw([1,2],7,boundsNoop);if(shortResult===shortResult)throw 'bounds short receiver';");
        } else {
            @check(plan.ssa_region.ssa_helper_calls > 0 && plan.ssa_region.ssa_helper_continued > 0);
            eval(&context, "var boundsChanged=[1,2,3,4,5,6,7,8];var boundsCalls=0;function boundsShrink(){boundsCalls++;boundsChanged.length=2;}var changedResult=boundsRaw(boundsChanged,7,boundsShrink);if(changedResult===changedResult||boundsCalls!==1||boundsChanged.length!==2)throw 'bounds callback invalidation';");
        }
        h.jit_stress = false;
        eval(&context, "for(var q=0;q<32;q++){if(boundsRaw([1,2,3,4,5,6,7,8],15,boundsNoop)!==16)throw 'bounds normal result';}");
        io::printfn("scalable SSA bounds: PASS helper=%d proofs=%d hits=%d", helper,
            plan.ssa_region.ssa_data.bounds_proofs, plan.ssa_region.hits);
    }
}

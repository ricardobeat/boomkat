module jit_test;

import boomkat;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::vm;
import boomkat::types;
import std::io;

// Constants remain live across a collecting-capable unknown call, then a late
// numeric guard can reconstruct all of them from immutable recovery bits.
fn void check_scalable_ssa_remat() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    eval(&context, "function rematRaw(callback){var half=1.25;return callback+half;}");
    CompiledFunction* cf = named_function(&runtime, "rematRaw");
    @check(cf != null);
    Instruction* saved_code = cf.code;
    uint saved_count = cf.code_count;
    ushort saved_regs = cf.num_regs;
    TVal* saved_constants = cf.constants;
    uint saved_const_count = cf.const_count;
    Heap* h = runtime.rt.heap;
    defer {
        if (cf.sljit_function != null) vm::sljit_function_free(h, cf);
        cf.code = saved_code; cf.code_count = saved_count; cf.num_regs = saved_regs;
        cf.constants = saved_constants; cf.const_count = saved_const_count;
    }
    TVal[70] constants;
    for (uint i = 0; i < 70; i++) constants[i] = types::make_number((double)i + 1.25);
    cf.constants = &constants[0]; cf.const_count = 70;
    Instruction[900] code;
    uint count;
    for (uint i = 0; i < 70; i++) {
        scalable_int(&code[0], &count, 200 + i, (int)i + 1);
        scalable_abc(&code[0], &count, Opcode.LDCONST, 400 + i, i, 0);
    }
    scalable_int(&code[0], &count, 700, 0);
    scalable_abc(&code[0], &count, Opcode.LDUNDEF, 1, 0, 0);
    scalable_abc(&code[0], &count, Opcode.CALL_UNDEF_THIS, 800, 0, 0);
    for (uint i = 0; i < 70; i++) {
        scalable_abc(&code[0], &count, Opcode.ADD, 700, 700, 200 + i);
        scalable_abc(&code[0], &count, Opcode.ADD, 700, 700, 400 + i);
    }
    scalable_abc(&code[0], &count, Opcode.ADD, 700, 700, 800);
    scalable_abc(&code[0], &count, Opcode.RET, 700, 0, 0);
    cf.code = &code[0]; cf.code_count = count; cf.num_regs = 900;
    @check(runtime.set_jit());
    h.jit_stress = true;
    eval(&context, "var rematCalls=0;function rematCallback(){rematCalls++;return 17;}for(var q=0;q<128;q++){if(rematRaw(rematCallback)!==5004.5)throw 'rematerialized callback';}if(rematCalls!==128)throw 'remat callback count';");
    FunctionPlan* plan = cf.sljit_function;
    @check(plan != null && plan.ssa_region != null && plan.ssa_region.hits > 0);
    @check(plan.ssa_region.ssa_data.rematerialized >= 140);
    @check(plan.ssa_region.ssa_helper_calls > 0 && plan.ssa_region.ssa_helper_continued > 0);
    eval(&context, "var rematConversions=0;var rematObject={valueOf:function(){rematConversions++;return 17;}};function rematObjectCallback(){rematCalls++;return rematObject;}var beforeRemat=rematCalls;if(rematRaw(rematObjectCallback)!==5004.5||rematConversions!==1||rematCalls!==beforeRemat+1)throw 'remat precise guard';");
    h.jit_stress = false;
    eval(&context, "for(var q=0;q<32;q++){if(rematRaw(rematCallback)!==5004.5)throw 'remat normal';}var rematThrown=0;function rematThrowCallback(){rematCalls++;return {valueOf:function(){rematThrown++;throw 'remat throw';}};}try{rematRaw(rematThrowCallback);throw 'missing remat throw';}catch(error){if(error!=='remat throw')throw error;}if(rematThrown!==1)throw 'remat throw count';");
    io::printfn("scalable SSA rematerialization: PASS constants=%d hits=%d helpers=%d continued=%d", plan.ssa_region.ssa_data.rematerialized,
        plan.ssa_region.hits, plan.ssa_region.ssa_helper_calls, plan.ssa_region.ssa_helper_continued);
}

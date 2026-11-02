module jit_test;

import boomkat;
import boomkat::bytecode;
import boomkat::vm;
import std::io;

fn void check_ssa_integer_captures() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    @check(runtime.set_jit());
    eval(&context, "var console={log:function(){}};");
    eval(&context, $embed("../jit_ssa_integer_captures.js"));
    CompiledFunction* cf = named_function(&runtime, "nativeCaptureInteger");
    @check(cf != null && cf.code_count > vm::SSA_SPAN);
    FunctionPlan* plan = cf.sljit_function;
    @check(plan != null && plan.ssa_region != null && plan.ssa_region.ssa_data != null);
    LoopPlan* body = plan.ssa_region;
    @check(body.ssa_data.native_integer_bindings > 0);
    ulong completed = body.ssa_completed;
    eval(&context, "for(var q=0;q<64;q++){resetCaptureIntegerOutput();if(captureInteger.run(captureIntegerArray,captureIntegerOutput,2,null)!==27)throw 'integer capture native activation';}");
    @check(body.ssa_completed >= completed + 32);
    eval(&context, "checkCaptureIntegerRecovery();");
    io::printfn("SSA integer captures: PASS typed=%d completed=%d", body.ssa_data.native_integer_bindings, body.ssa_completed);
}

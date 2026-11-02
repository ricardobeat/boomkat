module jit_test;

import boomkat;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import boomkat::vm;
import std::io;

fn void check_native_ssa_bindings() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    @check(runtime.set_jit());
    runtime.rt.heap.jit_stress = true;
    eval(&context, "var console={log:function(){}};");
    eval(&context, $embed("../jit_ssa_native_bindings.js"));
    CompiledFunction* cf = named_function(&runtime, "nativeScalarRead");
    @check(cf != null);
    FunctionPlan* plan = cf.sljit_function;
    @check(plan != null && plan.ssa_region != null);
    LoopPlan* region = plan.ssa_region;
    @check(region.hits != 0 && region.ssa_data.native_bindings >= 2);
    @check(region.ssa_helpers == null);
    $if $feat(SLJIT_STATS): @check(region.ssa_data.binding_reads > 0); $endif
    $if $feat(SLJIT_STATS):
        io::printfn("native SSA captures: PASS sites=%d reads=%d hits=%d", region.ssa_data.native_bindings, region.ssa_data.binding_reads, region.hits);
    $endif

    // WIDE destination forces the descriptor-free body. A later getter must
    // fail before its read, after the earlier native array store committed.
    eval(&context, "globalThis.nativeBindingGlobal=3;function nativeGlobalBindingRaw(output){return nativeBindingGlobal;}");
    cf = named_function(&runtime, "nativeGlobalBindingRaw");
    @check(cf != null);
    uint name = uint::max;
    Opcode read_op = Opcode.GETGLOBAL;
    for (uint i = 0; i < cf.code_count; i++) {
        if (cf.code[i].op == Opcode.GETGLOBAL || cf.code[i].op == Opcode.GETVAR) {
            name = cf.code[i].get_bc(); read_op = cf.code[i].op; break;
        }
    }
    @check(name != uint::max);
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
    Instruction[32] code;
    ICEntry[32] caches;
    VarICEntry[32] bindings;
    uint count;
    scalable_int(&code[0], &count, 300, 0);
    scalable_int(&code[0], &count, 301, 1);
    scalable_abc(&code[0], &count, Opcode.PUTPROP, 0, 300, 301);
    scalable_abc(&code[0], &count, read_op, 302, name & 255, name >> 8);
    scalable_abc(&code[0], &count, Opcode.RET, 302, 0, 0);
    cf.code = &code[0]; cf.code_count = count; cf.num_regs = 304;
    cf.ic_entries = &caches[0]; cf.ic_count = count;
    cf.var_ic_entries = &bindings[0]; cf.var_ic_count = count;
    eval(&context, "var nativeGlobalOutput=[0];for(var q=0;q<128;q++){nativeGlobalOutput[0]=0;if(nativeGlobalBindingRaw(nativeGlobalOutput)!==3||nativeGlobalOutput[0]!==1)throw 'native global read';}");
    plan = cf.sljit_function;
    region = plan != null ? plan.ssa_region : null;
    @check(region != null && region.hits != 0 && region.ssa_data.native_bindings == 1);
    @check(region.ssa_helpers == null);
    $if $feat(SLJIT_STATS): @check(region.ssa_data.binding_reads > 0); $endif
    eval(&context, "var nativeGetterCalls=0;Object.defineProperty(globalThis,'nativeBindingGlobal',{get:function(){nativeGetterCalls++;throw 'binding getter';},configurable:true});nativeGlobalOutput[0]=0;try{nativeGlobalBindingRaw(nativeGlobalOutput);throw 'missing getter';}catch(error){if(error!=='binding getter')throw error;}if(nativeGetterCalls!==1||nativeGlobalOutput[0]!==1)throw 'binding getter phase';");
    eval(&context, "Object.defineProperty(globalThis,'nativeBindingGlobal',{value:7,writable:true,configurable:true});for(var q=0;q<64;q++){if(nativeGlobalBindingRaw(nativeGlobalOutput)!==7)throw 'binding refreshed IC';}");
    $if $feat(SLJIT_STATS):
        io::printfn("native SSA variable IC: PASS sites=%d reads=%d hits=%d", region.ssa_data.native_bindings, region.ssa_data.binding_reads, region.hits);
    $endif
}

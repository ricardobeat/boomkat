module jit_test;

import boomkat;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::types;
import boomkat::vm;
import std::io;

fn TVal boxed_field_key(CompiledFunction* cf, String name) {
    for (uint i = 0; i < cf.const_count; i++) {
        TVal value = cf.constants[i];
        if (value.is_string() && ((HString*)value.get_heapptr()).equals(name)) return value;
    }
    @check(false);
    return types::make_undefined();
}

fn void check_native_ssa_boxed_this() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    eval(&context, "function boxedThisRaw(){this.count=this.count+1;this.flag=this.flag;this.optional=this.optional;return this.child.slotValue;}");
    CompiledFunction* cf = named_function(&runtime, "boxedThisRaw");
    @check(cf != null);
    TVal[261] constants;
    foreach (&value : constants) value.set_undefined();
    constants[0] = boxed_field_key(cf, "slotValue");
    constants[257] = boxed_field_key(cf, "count");
    constants[258] = boxed_field_key(cf, "child");
    constants[259] = boxed_field_key(cf, "flag");
    constants[260] = boxed_field_key(cf, "optional");
    Instruction* saved_code = cf.code;
    uint saved_count = cf.code_count;
    ushort saved_regs = cf.num_regs;
    TVal* saved_constants = cf.constants;
    uint saved_const_count = cf.const_count;
    void* saved_ic = cf.ic_entries;
    void* saved_var_ic = cf.var_ic_entries;
    uint saved_ic_count = cf.ic_count;
    uint saved_var_ic_count = cf.var_ic_count;
    Heap* h = runtime.rt.heap;
    defer {
        if (cf.sljit_function != null) vm::sljit_function_free(h, cf);
        cf.code = saved_code; cf.code_count = saved_count; cf.num_regs = saved_regs;
        cf.constants = saved_constants; cf.const_count = saved_const_count;
        cf.ic_entries = saved_ic; cf.ic_count = saved_ic_count;
        cf.var_ic_entries = saved_var_ic; cf.var_ic_count = saved_var_ic_count;
    }
    Instruction[48] code;
    ICEntry[48] caches;
    VarICEntry[48] bindings;
    uint count;
    scalable_abc(&code[0], &count, Opcode.GETTHISC, 305, 0, 257); // K257
    scalable_abc(&code[0], &count, Opcode.ADDI, 305, 305, 1);
    scalable_abc(&code[0], &count, Opcode.PUTTHISC, 305, 0, 257);
    scalable_abc(&code[0], &count, Opcode.GETTHISC, 306, 0, 259); // K259
    scalable_abc(&code[0], &count, Opcode.PUTTHISC, 306, 0, 259);
    scalable_abc(&code[0], &count, Opcode.GETTHISC, 307, 0, 260); // K260
    scalable_abc(&code[0], &count, Opcode.PUTTHISC, 307, 0, 260);
    scalable_abc(&code[0], &count, Opcode.GETTHISC, 301, 0, 258); // K258
    scalable_abc(&code[0], &count, Opcode.GETPROPC, 302, 301, 0);
    scalable_abc(&code[0], &count, Opcode.RET, 301, 0, 0);
    cf.code = &code[0]; cf.code_count = count; cf.num_regs = 308;
    cf.constants = &constants[0]; cf.const_count = constants.len;
    cf.ic_entries = &caches[0]; cf.ic_count = count;
    cf.var_ic_entries = &bindings[0]; cf.var_ic_count = count;
    eval(&context, "var boxedThisProto={run:boxedThisRaw};var boxedThisReceiver=Object.create(boxedThisProto);boxedThisReceiver.count=0;boxedThisReceiver.flag=true;boxedThisReceiver.optional=undefined;boxedThisReceiver.child={slotValue:7};for(var q=0;q<4;q++)boxedThisReceiver.run();boxedThisReceiver.count=0;");
    @check(runtime.set_jit());
    h.jit_stress = true;
    eval(&context, "for(var q=0;q<128;q++){if(boxedThisReceiver.run()!==boxedThisReceiver.child||boxedThisReceiver.count!==q+1)throw 'boxed this';}");
    FunctionPlan* plan = cf.sljit_function;
    LoopPlan* body = plan != null ? plan.ssa_region : null;
    @check(body != null && body.hits > 0 && body.ssa_data.native_accesses == 8);
    @check(body.ssa_helpers == null);
    $if $feat(SLJIT_STATS):
        io::printfn("native SSA boxed this warm: reads=%d writes=%d completed=%d", body.ssa_data.field_reads, body.ssa_data.field_writes, body.ssa_completed);
        @check(body.ssa_completed > 0 && body.ssa_data.field_reads > 0 && body.ssa_data.field_writes > 0);
    $endif
    eval(&context, "boxedThisReceiver.flag=false;boxedThisReceiver.optional=null;for(var q=0;q<32;q++){if(boxedThisReceiver.run()!==boxedThisReceiver.child||boxedThisReceiver.flag!==false||boxedThisReceiver.optional!==null)throw 'boxed primitives';}boxedThisReceiver.optional=undefined;boxedThisReceiver.run();var beforeBoxed=boxedThisReceiver.count;boxedThisReceiver.child='string';if(boxedThisReceiver.run()!=='string'||boxedThisReceiver.count!==beforeBoxed+1)throw 'boxed string phase';");
    eval(&context, "boxedThisReceiver.child={slotValue:9,extra:1};var beforeBoxed=boxedThisReceiver.count;if(boxedThisReceiver.run()!==boxedThisReceiver.child||boxedThisReceiver.count!==beforeBoxed+1)throw 'boxed shape phase';var boxedGetterCalls=0;Object.defineProperty(boxedThisReceiver.child,'slotValue',{get:function(){boxedGetterCalls++;throw 'boxed getter';},configurable:true});beforeBoxed=boxedThisReceiver.count;try{boxedThisReceiver.run();throw 'missing boxed getter';}catch(error){if(error!=='boxed getter')throw error;}if(boxedGetterCalls!==1||boxedThisReceiver.count!==beforeBoxed+1)throw 'boxed getter phase';");
    h.jit_stress = false;
    eval(&context, "boxedThisReceiver.child={slotValue:7};for(var q=0;q<32;q++){if(boxedThisReceiver.run()!==boxedThisReceiver.child)throw 'boxed this normal';}");
    $if $feat(SLJIT_STATS):
        io::printfn("native SSA boxed this: PASS accesses=%d reads=%d writes=%d completed=%d", body.ssa_data.native_accesses,
            body.ssa_data.field_reads, body.ssa_data.field_writes, body.ssa_completed);
    $endif
}

fn void check_native_ssa_boxed_arrays() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    eval(&context, "function boxedArrayRaw(table,index,callback){return table[index].slotValue;}");
    CompiledFunction* cf = named_function(&runtime, "boxedArrayRaw");
    @check(cf != null);
    TVal[1] constants = { boxed_field_key(cf, "slotValue") };
    Instruction* saved_code = cf.code;
    uint saved_count = cf.code_count;
    ushort saved_regs = cf.num_regs;
    TVal* saved_constants = cf.constants;
    uint saved_const_count = cf.const_count;
    void* saved_ic = cf.ic_entries;
    void* saved_var_ic = cf.var_ic_entries;
    uint saved_ic_count = cf.ic_count;
    uint saved_var_ic_count = cf.var_ic_count;
    Heap* h = runtime.rt.heap;
    defer {
        if (cf.sljit_function != null) vm::sljit_function_free(h, cf);
        cf.code = saved_code; cf.code_count = saved_count; cf.num_regs = saved_regs;
        cf.constants = saved_constants; cf.const_count = saved_const_count;
        cf.ic_entries = saved_ic; cf.ic_count = saved_ic_count;
        cf.var_ic_entries = saved_var_ic; cf.var_ic_count = saved_var_ic_count;
    }
    Instruction[32] code;
    ICEntry[32] caches;
    VarICEntry[32] bindings;
    @check(runtime.set_jit());
    eval(&context, "function boxedArrayNoop(){};var boxedCallableTable=[function(){return 17;}];");
    for (uint mode = 0; mode < 3; mode++) {
        if (cf.sljit_function != null) vm::sljit_function_free(h, cf);
        cf.sljit_function_calls = 0;
        foreach (&entry : caches) *entry = {};
        foreach (&entry : bindings) *entry = {};
        uint count;
        scalable_abc(&code[0], &count, Opcode.GETPROP, 300, 0, 1);
        if (mode == 1) {
            scalable_abc(&code[0], &count, Opcode.LDUNDEF, 301, 0, 0);
            scalable_abc(&code[0], &count, Opcode.CALL_UNDEF_THIS, 302, 300, 0);
        } else if (mode == 2) {
            scalable_abc(&code[0], &count, Opcode.LDUNDEF, 3, 0, 0);
            scalable_abc(&code[0], &count, Opcode.CALL_UNDEF_THIS, 305, 2, 0);
            scalable_abc(&code[0], &count, Opcode.GETPROPC, 304, 300, 0);
        }
        scalable_abc(&code[0], &count, Opcode.RET, mode == 0 ? 300 : mode == 1 ? 302 : 304, 0, 0);
        cf.code = &code[0]; cf.code_count = count; cf.num_regs = 308;
        cf.constants = &constants[0]; cf.const_count = 1;
        cf.ic_entries = &caches[0]; cf.ic_count = count;
        cf.var_ic_entries = &bindings[0]; cf.var_ic_count = count;
        @check(runtime.set_jit(false));
        if (mode == 0) { eval(&context, "boxedArrayRaw([{slotValue:7}],0,boxedArrayNoop);"); }
        else if (mode == 1) { eval(&context, "boxedArrayRaw(boxedCallableTable,0,boxedArrayNoop);"); }
        else { eval(&context, "boxedArrayRaw([{slotValue:23}],0,boxedArrayNoop);"); }
        @check(runtime.set_jit());
        h.jit_stress = true;
        if (mode == 0) {
            eval(&context, "var boxedTable=[{slotValue:7},true,null,boxedCallableTable[0],9];for(var q=0;q<128;q++){var index=q%5;if(boxedArrayRaw(boxedTable,index,boxedArrayNoop)!==boxedTable[index])throw 'boxed array value';}");
        } else if (mode == 1) {
            eval(&context, "for(var q=0;q<128;q++){if(boxedArrayRaw(boxedCallableTable,0,boxedArrayNoop)!==17)throw 'boxed array call';}");
        } else {
            eval(&context, "var boxedObjectTable=[{slotValue:23}];for(var q=0;q<128;q++){if(boxedArrayRaw(boxedObjectTable,0,boxedArrayNoop)!==23)throw 'boxed object continuation';}");
        }
        FunctionPlan* plan = cf.sljit_function;
        LoopPlan* body = plan != null ? plan.ssa_region : null;
        @check(body != null && body.hits > 0 && body.ssa_data.native_accesses == (mode == 2 ? 2U : 1U));
        $if $feat(SLJIT_STATS): @check(body.ssa_completed > 0 && body.ssa_data.array_reads > 0); $endif
        if (mode == 0) {
            @check(body.ssa_helpers == null);
            eval(&context, "var boxedHoleGetter=0;var boxedArrayProto=Object.create(Array.prototype);Object.defineProperty(boxedArrayProto,'0',{get:function(){boxedHoleGetter++;return true;},configurable:true});var boxedHole=new Array(1);Object.setPrototypeOf(boxedHole,boxedArrayProto);if(boxedArrayRaw(boxedHole,0,boxedArrayNoop)!==true||boxedHoleGetter!==1)throw 'boxed array hole';var boxedIndexedGetter=0;var boxedShadow=[false];Object.defineProperty(boxedShadow,'0',{get:function(){boxedIndexedGetter++;return null;},configurable:true});if(boxedArrayRaw(boxedShadow,0,boxedArrayNoop)!==null||boxedIndexedGetter!==1)throw 'boxed indexed accessor';if(boxedArrayRaw([undefined],0,boxedArrayNoop)!==undefined||boxedArrayRaw(['string'],0,boxedArrayNoop)!=='string')throw 'boxed array VM values';");
        } else {
            @check(body.ssa_helpers != null);
            $if $feat(SLJIT_STATS): @check(body.ssa_helper_calls > 0 && body.ssa_helper_continued > 0); $endif
            if (mode == 2) eval(&context, "function boxedEraseElement(){boxedObjectTable[0]=null;var garbage=[];for(var i=0;i<80;i++)garbage.push({x:i});}if(boxedArrayRaw(boxedObjectTable,0,boxedEraseElement)!==23||boxedObjectTable[0]!==null)throw 'boxed object root';");
        }
        h.jit_stress = false;
        $if $feat(SLJIT_STATS):
            io::printfn("native SSA boxed arrays: PASS mode=%d reads=%d completed=%d helpers=%d continued=%d", mode,
                body.ssa_data.array_reads, body.ssa_completed, body.ssa_helper_calls, body.ssa_helper_continued);
        $endif
    }
}

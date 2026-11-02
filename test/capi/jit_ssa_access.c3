module jit_test;

import boomkat;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import boomkat::vm;
import std::io;
import std::core::string;

// The real function gateway lowers high-register loads/stores without a single
// legacy LoopMemory descriptor or generic property helper. Receiver rebinding,
// callback mutation, and uncommon slots are checked separately in JS fixtures.
fn void check_scalable_ssa_access() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    eval(&context, "function scalableAccessRaw(a,n){return n;}");
    CompiledFunction* cf = named_function(&runtime, "scalableAccessRaw");
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
    uint count;
    scalable_int(&code[0], &count, 300, 0);
    scalable_int(&code[0], &count, 301, 0);
    uint header = count;
    scalable_abc(&code[0], &count, Opcode.GETPROP, 302, 0, 301);
    uint read_pc = count - 1;
    scalable_abc(&code[0], &count, Opcode.ADDI, 302, 302, 1);
    scalable_abc(&code[0], &count, Opcode.PUTPROP, 0, 301, 302);
    uint write_pc = count - 1;
    scalable_abc(&code[0], &count, Opcode.ADD, 300, 300, 302);
    scalable_abc(&code[0], &count, Opcode.ADDI, 301, 301, 1);
    scalable_abc(&code[0], &count, Opcode.LT, 303, 301, 1);
    code[count++] = bytecode::make_wide(1, 0, 0);
    code[count] = bytecode::make_a_sbx(Opcode.IF_TRUE, 303 & 255, (int)header - (int)count - 1);
    count++;
    scalable_abc(&code[0], &count, Opcode.RET, 300, 0, 0);
    cf.code = &code[0]; cf.code_count = count; cf.num_regs = 304;
    cf.ic_entries = &caches[0]; cf.ic_count = count;
    cf.var_ic_entries = &bindings[0]; cf.var_ic_count = count;
    @check(runtime.set_jit());
    String[9] initializers = { "[1,2,3,4]", "new Int8Array([1,2,3,4])", "new Uint8Array([1,2,3,4])",
        "new Int16Array([1,2,3,4])", "new Uint16Array([1,2,3,4])", "new Int32Array([1,2,3,4])",
        "new Uint32Array([1,2,3,4])", "new Float32Array([1,2,3,4])", "new Float64Array([1,2,3,4])" };
    foreach (kind, initializer : initializers) {
        if (cf.sljit_function != null) vm::sljit_function_free(h, cf);
        cf.sljit_function_calls = 0;
        char observed = kind == 0 ? 255 : (char)(vm::FUNCTION_TYPED_CLASSES[kind - 1].ordinal + 1);
        caches[read_pc].typed_kind = observed;
        caches[write_pc].typed_kind = observed;
        h.jit_stress = true;
        @pool() {
            eval(&context, string::tformat("for(var q=0;q<96;q++){var a=%s;if(scalableAccessRaw(a,4)!==14||a[0]!==2||a[3]!==5)throw 'native access';}", initializer));
        };
        FunctionPlan* plan = cf.sljit_function;
        @check(plan != null && plan.native == null && plan.ssa_region != null);
        @check(plan.ssa_region.hits > 0 && plan.ssa_region.memory_count == 0);
        @check(plan.ssa_region.ssa_data.native_accesses == 2);
        @check(plan.ssa_region.ssa_helpers == null);
        ulong before = plan.ssa_region.hits;
        h.jit_stress = false;
        @pool() {
            eval(&context, string::tformat("for(var q=0;q<24;q++){var a=%s;if(scalableAccessRaw(a,4)!==14||a[0]!==2||a[3]!==5)throw 'native access stress';}", initializer));
        };
        @check(plan.ssa_region.hits > before);
    }
    io::printn("scalable SSA access: PASS dense + 8 typed classes, WIDE, normal/stress");
}

fn void check_scalable_ssa_fields() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    @check(runtime.set_jit());
    eval(&context, "var console={log:function(){}};");
    eval(&context, $embed("../jit_ssa_scalable_fields.js"));
    CompiledFunction* cf = named_function(&runtime, "scalableFields");
    @check(cf != null && cf.code_count > vm::SSA_SPAN);
    FunctionPlan* plan = cf.sljit_function;
    @check(plan != null && plan.native == null && plan.ssa_region != null);
    @check(plan.ssa_region.hits != 0 && plan.ssa_region.memory_count == 0);
    @check(plan.ssa_region.ssa_data.native_accesses == 3);
    @check(plan.ssa_region.ssa_helpers == null);
    io::printn("scalable SSA fields: PASS live shapes, native loads/stores, exact fallback");
}

fn void check_scalable_ssa_memory_callbacks() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    @check(runtime.set_jit());
    // The fixture is helper-dominated, so the tier policy would move it to the
    // baseline tier and replace the specialization under test.
    runtime.rt.heap.jit_hold_tier = true;
    eval(&context, "var console={log:function(){}};");
    eval(&context, $embed("../jit_ssa_memory_callbacks.js"));
    CompiledFunction* cf = named_function(&runtime, "scalableMemoryCallback");
    @check(cf != null && cf.code_count > vm::SSA_SPAN);
    FunctionPlan* plan = cf.sljit_function;
    @check(plan != null && plan.native == null && plan.ssa_region != null);
    @check(plan.ssa_region.hits != 0 && plan.ssa_region.ssa_data.native_accesses == 4);
    @check(plan.ssa_region.ssa_helpers != null);
    $if $feat(SLJIT_STATS): @check(plan.ssa_region.ssa_helper_continued > 0); $endif
    io::printn("scalable SSA memory callbacks: PASS native continuation after storage mutation");
}

fn void check_effectful_ssa_inline() {
    JsRuntime runtime;
    runtime.create()!!;
    defer runtime.destroy();
    JsContext context;
    context.create(&runtime)!!;
    defer context.destroy();
    @check(runtime.set_jit());
    // The padded fixture is above the whole-body attempt bound production
    // tiers use; the plan must still inline and recover at that size.
    runtime.rt.heap.jit_ssa_body_ops = 1 << 16;
    eval(&context, $embed("../jit_ssa_effect_inline.js"));
    String[2] names = { "effectInlineCaller", "effectCallbackCaller" };
    foreach (name : names) {
        CompiledFunction* cf = named_function(&runtime, name);
        @check(cf != null && cf.sljit_function != null);
        LoopPlan* body = ((FunctionPlan*)cf.sljit_function).ssa_region;
        @check(body != null && body.hits > 0 && body.ssa_inline_sites == 1);
        @check(body.ssa_deopt_chain != null);
        @check(body.ssa_data.native_accesses >= 2);
        for (SsaHelperSite* helper = body.ssa_helpers; helper != null; helper = helper.next) {
            // Binding resolution and reservation are internal preflight;
            // the callee call itself must not be a generic runtime helper.
            @check(helper.kind != SsaHelperKind.OPERATION);
        }
        $if $feat(SLJIT_STATS):
            @check(body.ssa_inline_entries > 0 && body.ssa_inline_recoveries > 0);
            io::printfn("effectful SSA inline: PASS %s entries=%d recoveries=%d", name,
                body.ssa_inline_entries, body.ssa_inline_recoveries);
        $endif
    }
    runtime.rt.heap.jit_stress = true;
    eval(&context, "for(var q=0;q<24;q++){var a={x:1};if(effectInlineCaller(a,2,2)!==4||a.x!==2)throw 'inline stress';}"
        "var a={x:1},stressCalls=0;if(effectCallbackCaller(a,function(v){stressCalls++;return v+3;},2)!==5||a.x!==2||stressCalls!==1)throw 'inline callback stress';");
    runtime.rt.heap.jit_stress = false;
    // The callee has its own WIDE register space. Its local 300 must never
    // index the caller's eight-register emitter live map.
    CompiledFunction* child = named_function(&runtime, "effectInlineChild");
    CompiledFunction* caller = named_function(&runtime, "effectInlineCaller");
    Instruction* saved_code = child.code;
    uint saved_count = child.code_count;
    ushort saved_regs = child.num_regs;
    void* saved_ic = child.ic_entries;
    void* saved_var_ic = child.var_ic_entries;
    uint saved_ic_count = child.ic_count;
    uint saved_var_ic_count = child.var_ic_count;
    uint key;
    for (uint pc = 0; pc < child.code_count; pc++) {
        if (child.code[pc].op == Opcode.GETPROPC || child.code[pc].op == Opcode.GETPROPC_CACHED) {
            key = child.code[pc].c;
            break;
        }
    }
    vm::sljit_function_free(runtime.rt.heap, child);
    vm::sljit_function_free(runtime.rt.heap, caller);
    child.sljit_function_calls = 0;
    caller.sljit_function_calls = 0;
    Instruction[32] code;
    ICEntry[32] caches;
    VarICEntry[32] bindings;
    uint count;
    scalable_abc(&code[0], &count, Opcode.LDREG, 300, 0, 0);
    scalable_abc(&code[0], &count, Opcode.GETPROPC, 301, 300, key);
    scalable_abc(&code[0], &count, Opcode.ADDI, 302, 301, 1);
    scalable_abc(&code[0], &count, Opcode.PUTPROPC, 300, 302, key);
    scalable_abc(&code[0], &count, Opcode.ADD, 303, 302, 1);
    scalable_abc(&code[0], &count, Opcode.RET, 303, 0, 0);
    child.code = &code[0]; child.code_count = count; child.num_regs = 304;
    child.ic_entries = &caches[0]; child.ic_count = count;
    child.var_ic_entries = &bindings[0]; child.var_ic_count = count;
    defer {
        if (caller.sljit_function != null) vm::sljit_function_free(runtime.rt.heap, caller);
        if (child.sljit_function != null) vm::sljit_function_free(runtime.rt.heap, child);
        child.code = saved_code; child.code_count = saved_count; child.num_regs = saved_regs;
        child.ic_entries = saved_ic; child.ic_count = saved_ic_count;
        child.var_ic_entries = saved_var_ic; child.var_ic_count = saved_var_ic_count;
    }
    eval(&context, "for(var q=0;q<160;q++){var a={x:1};if(effectInlineCaller(a,2,2)!==4||a.x!==2)throw 'wide inline';}"
        "var wideCalls=0,a={x:1};if(effectInlineCaller(a,{valueOf:function(){wideCalls++;return 2;}},2)!==4||a.x!==2||wideCalls!==1)throw 'wide inline recovery';");
    LoopPlan* wide_body = ((FunctionPlan*)caller.sljit_function).ssa_region;
    @check(wide_body != null && wide_body.ssa_inline_sites == 1 && wide_body.hits > 0);
    $if $feat(SLJIT_STATS): @check(wide_body.ssa_inline_entries > 0 && wide_body.ssa_inline_recoveries > 0); $endif
    io::printn("effectful SSA inline: PASS WIDE child registers + exact late recovery");
}

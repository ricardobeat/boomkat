module jit_test;

import boomkat;
import boomkat::bytecode;
import boomkat::vm;
import std::io;
import libc;

const String FUNCTION_SOURCE = $embed("../sljit_function.js");
const String LOOP_SOURCE = $embed("../sljit_loop.js");
const String TEMPLATE_SOURCE = $embed("jit_render.js");
const String RUN = "for(var i=0;i<64;i++){if(render(rows)!=='<li>1:one</li><li>2:two</li>')throw new Error('render');}";

macro void @check(#condition) {
    if (!(#condition)) {
        io::eprintfn("embedding JIT check failed: %s", $stringify(#condition));
        libc::exit(1);
    }
}

fn void eval(JsContext* ctx, String source) {
    JsValue value = ctx.eval(source)!!;
    ctx.release(value);
}

fn uint plans(JsRuntime* rt) {
    uint result;
    $if $feat(SLJIT):
        for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
            CompiledFunction* cf = (CompiledFunction*)rt.rt.heap.compiled_funcs[i];
            if (cf != null && cf.sljit_template != null) result++;
        }
    $endif
    return result;
}

fn ulong native_hits(JsRuntime* rt) {
    ulong result;
    $if $feat(SLJIT) && $feat(SLJIT_STATS):
        for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
            CompiledFunction* cf = (CompiledFunction*)rt.rt.heap.compiled_funcs[i];
            if (cf == null) continue;
            if (cf.sljit_template != null) result += ((TemplatePlan*)cf.sljit_template).hits;
            if (cf.sljit_function != null) result += ((FunctionPlan*)cf.sljit_function).hits;
            for (LoopPlan* plan = cf.sljit_loops; plan != null; plan = plan.next) result += plan.hits;
        }
    $endif
    return result;
}

fn ulong function_hits(JsRuntime* rt, String name) {
    $if $feat(SLJIT) && $feat(SLJIT_STATS):
        for (uint i = 0; i < rt.rt.heap.compiled_func_count; i++) {
            CompiledFunction* cf = (CompiledFunction*)rt.rt.heap.compiled_funcs[i];
            if (cf != null && (String)cf.get_name() == name && cf.sljit_function != null) {
                return ((FunctionPlan*)cf.sljit_function).hits;
            }
        }
    $endif
    return 0;
}

fn int stop_after_polls(void* runtime, void* opaque) {
    uint* polls = (uint*)opaque;
    (*polls)++;
    return *polls >= 3 ? 1 : 0;
}

fn void main() {
    JsRuntime first, second;
    @check(!first.set_jit());
    first.create()!!;
    defer first.destroy();
    second.create()!!;
    defer second.destroy();
    JsContext a, b, isolated;
    a.create(&first)!!;
    defer a.destroy();
    b.create(&first)!!;
    defer b.destroy();
    isolated.create(&second)!!;
    defer isolated.destroy();
    JsContext*[3] contexts = {&a, &b, &isolated};
    foreach (ctx : contexts) {
        eval(ctx, TEMPLATE_SOURCE);
        eval(ctx, RUN);
    }
    @check(plans(&first) == 0 && plans(&second) == 0);
    @check(first.set_jit(false));
    $if $feat(SLJIT):
        @check(first.set_jit());
        eval(&a, RUN);
        eval(&b, RUN);
        @check(plans(&first) == 2);
        @check(plans(&second) == 0);
        ulong before = native_hits(&first);
        @check(first.set_jit(false));
        @check(!first.rt.heap.jit_enabled && !second.rt.heap.jit_enabled);
        eval(&a, "rows[0].id=7;if(render(rows)!=='<li>7:one</li><li>2:two</li>')throw 'disabled';rows[0].id=1;");
        @check(plans(&first) == 2 && native_hits(&first) == before);
        @check(first.set_jit());
        eval(&a, RUN);
        @check(native_hits(&first) > before);
        eval(&isolated, RUN);
        @check(plans(&second) == 0);
        eval(&isolated, "var console={log:function(){}};");
        eval(&isolated, LOOP_SOURCE);
        @check(second.rt.heap.jit_code_bytes == 0);
        eval(&a, "var console={log:function(){}};");
        eval(&a, LOOP_SOURCE);
        @check(first.rt.heap.jit_code_bytes > 0);
        before = native_hits(&first);
        @check(first.set_jit(false));
        eval(&a, "for(var j=0;j<64;j++)if(hash(bytes)!==expectedHash)throw 'disabled loop';");
        @check(native_hits(&first) == before);
        @check(first.set_jit());
        eval(&a, "for(var j=0;j<64;j++)if(hash(bytes)!==expectedHash)throw 'cached loop';");
        @check(native_hits(&first) > before);
        eval(&a, FUNCTION_SOURCE);
        first.rt.heap.mark_and_sweep(true, true);
        for (uint i = 0; i < 128; i++) eval(&a, "if(jitFunctionWork(jitFunctionRecord)!==18)throw 'function';");
        @check(function_hits(&first, "functionFields") > 0);
        for (uint i = 0; i < 128; i++) eval(&a, "if(jitFunctionPump(jitFunctionSource,jitFunctionSink)!==4)throw 'continuation';");
        @check(function_hits(&first, "serverPump") > 0);
        first.rt.heap.mark_and_sweep(true, true);
        for (uint i = 0; i < 128; i++) eval(&a, "if(jitFunctionWork(jitFunctionRecord)!==18)throw 'function after GC';");
        @check(function_hits(&first, "functionFields") > 0);
        before = native_hits(&first);
        @check(first.set_jit(false));
        eval(&a, "jitFunctionRecord.left=6;if(jitFunctionWork(jitFunctionRecord)!==22)throw 'disabled function';");
        @check(native_hits(&first) == before);
        @check(first.set_jit());
        eval(&a, "if(jitFunctionWork(jitFunctionRecord)!==22)throw 'cached function';");
        @check(native_hits(&first) > before);
        uint polls;
        before = native_hits(&first);
        first.set_interrupt(&stop_after_polls, &polls);
        bool interrupted;
        if (catch err = a.eval("function spin(a){var x=0;for(var i=0;i<1000000;i++)x+=a[i&511];return x;}spin(bytes);")) {
            interrupted = true;
        }
        @check(interrupted && polls == 3 && native_hits(&first) > before);
        first.set_interrupt(null);
        JsValue exception = a.get_exception()!!;
        a.release(exception);
        eval(&a, "1");
    $else
        @check(!first.set_jit());
    $endif
    io::printn("embedding JIT: PASS");
}

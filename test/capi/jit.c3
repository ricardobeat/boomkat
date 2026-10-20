module jit_test;

import boomkat;
import boomkat::bytecode;
import boomkat::vm;
import std::io;
import libc;

const String TEMPLATE_SOURCE = $embed("jit_render.js");
const String RUN = "for(var i=0;i<64;i++){if(render(rows)!=='<li>1:one</li><li>2:two</li>')throw new Error('render');}";

fn void check(bool condition) {
    if (!condition) { io::eprintn("embedding JIT check failed"); libc::exit(1); }
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
            if (cf != null && cf.sljit_template != null) result += ((TemplatePlan*)cf.sljit_template).hits;
        }
    $endif
    return result;
}

fn void main() {
    JsRuntime first, second;
    check(!first.set_jit());
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
    check(plans(&first) == 0 && plans(&second) == 0);
    check(first.set_jit(false));
    $if $feat(SLJIT):
        check(first.set_jit());
        eval(&a, RUN);
        eval(&b, RUN);
        check(plans(&first) == 2);
        check(plans(&second) == 0);
        ulong before = native_hits(&first);
        check(first.set_jit(false));
        check(!first.rt.heap.jit_enabled && !second.rt.heap.jit_enabled);
        eval(&a, "rows[0].id=7;if(render(rows)!=='<li>7:one</li><li>2:two</li>')throw 'disabled';rows[0].id=1;");
        check(plans(&first) == 2 && native_hits(&first) == before);
        check(first.set_jit());
        eval(&a, RUN);
        check(native_hits(&first) > before);
        eval(&isolated, RUN);
        check(plans(&second) == 0);
    $else
        check(!first.set_jit());
    $endif
    io::printn("embedding JIT: PASS");
}

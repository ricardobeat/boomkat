/// Phase 1 host-function tests: dispatch through the reserved index range.
///
/// Registers host functions directly against the Heap (no C ABI yet, that is
/// Phase 3) and evaluates JS that calls them through every dispatch shape the
/// plan enumerates: plain call, method with `this`, .call/.apply/.bind, getter,
/// setter, new, super(), a builtin callback, and .name/.length metadata.
module host_fn_phase1;

import duktape::builtins;
import duktape::compiler;
import duktape::vm;
import duktape::heap;
import duktape::env;
import duktape::hobject;
import duktape::hstring;
import duktape::lexer;
import duktape::types;
import duktape::bytecode;
import std::io;

int g_calls;
int g_fails;

// --- host functions under test -------------------------------------------

/// Returns 42, ignoring arguments. The minimal proof that dispatch lands.
fn void host_answer(builtins::BuiltinContext* ctx, void* udata) {
    g_calls++;
    ctx.result.set_fastint(42);
}

/// Sums its first two arguments, exercising argument access from the register
/// window the VM already staged.
fn void host_add(builtins::BuiltinContext* ctx, void* udata) {
    g_calls++;
    double sum = 0;
    for (ushort i = 0; i < ctx.argc && i < 2; i++) {
        TVal a = ctx.regs[ctx.base_reg + i];
        if (a.is_numeric()) sum += a.get_number_or_fastint();
    }
    ctx.result.set_number(sum);
}

/// Returns the `this` receiver's .x, proving this_val is delivered.
fn void host_get_x(builtins::BuiltinContext* ctx, void* udata) {
    g_calls++;
    ctx.result.set_undefined();
    if (!ctx.this_val.is_object()) return;
    HObject* o = (HObject*)ctx.this_val.get_heapptr();
    HString* key = ctx.heap.str_intern("x");
    if (key == null) return;
    TVal? v = o.get_prop(key);
    if (catch v) return;
    *ctx.result = v;
}

/// Reads the udata pointer through as an int, proving passthrough.
fn void host_udata(builtins::BuiltinContext* ctx, void* udata) {
    g_calls++;
    ctx.result.set_fastint(udata == null ? -1 : (long)*(int*)udata);
}

/// A constructor: sets this.tag = 7.
fn void host_ctor(builtins::BuiltinContext* ctx, void* udata) {
    g_calls++;
    if (ctx.this_val.is_object()) {
        HObject* o = (HObject*)ctx.this_val.get_heapptr();
        HString* key = ctx.heap.str_intern("tag");
        if (key != null) {
            TVal v; v.set_fastint(7);
            o.put_prop(key, v, hobject::PROP_FLAGS_WEC);
        }
    }
    ctx.result.set_undefined();
}

/// Comparator for Array.prototype.sort: descending. Exercises a builtin
/// calling a host function (the path most designs forget).
fn void host_cmp(builtins::BuiltinContext* ctx, void* udata) {
    g_calls++;
    double a = 0;
    double b = 0;
    if (ctx.argc > 0) { TVal t = ctx.regs[ctx.base_reg]; if (t.is_numeric()) a = t.get_number_or_fastint(); }
    if (ctx.argc > 1) { TVal t = ctx.regs[ctx.base_reg + 1]; if (t.is_numeric()) b = t.get_number_or_fastint(); }
    ctx.result.set_number(b - a);
}

// --- harness --------------------------------------------------------------

fn bool install(Heap* hp, Vm* v, String name, void* handler, void* udata, int arity, bool ctor) {
    HString* nm = hp.str_intern((char[])name);
    if (nm == null) return false;
    long slot = hp.register_host_fn(handler, udata, (void*)nm, arity, ctor);
    if (slot < 0) return false;
    HObject*? fo = builtins::make_host_function(hp, (uint)slot);
    if (catch fo) return false;
    TVal fv; fv.set_object(fo);
    return env::env_declare(v.global_env, (void*)nm, fv);
}

/// Evaluate `src` and compare its completion value's number to `want`.
fn void check_num(Heap* hp, Vm* v, String label, String src, double want) {
    Lexer lex = lexer::lexer_init((char[])src, hp);
    defer lex.free_arena();
    CompiledFunction*? f = compiler::compile_eval(&lex, hp);
    if (catch f) {
        io::printfn("FAIL %s: compile error: %s", label, (ZString)&lex.err_msg[0]);
        g_fails++;
        return;
    }
    TVal? r = v.execute(f);
    hp.drain_microtasks((void*)v);
    if (catch r) {
        if (hp.has_error && hp.error_value.is_object()) {
            HObject* eo = (HObject*)hp.error_value.get_heapptr();
            HString* mk = hp.str_intern("message");
            TVal? mv = eo.get_prop(mk);
            if (try m = mv) {
                if (m.is_string()) {
                    HString* ms = (HString*)m.get_heapptr();
                    io::printfn("FAIL %s: threw: %s", label, (ZString)ms.get_data().ptr);
                    g_fails++;
                    return;
                }
            }
        }
        io::printfn("FAIL %s: threw (no message)", label);
        g_fails++;
        return;
    }
    TVal got = r;
    if (!got.is_numeric()) {
        io::printfn("FAIL %s: not numeric", label);
        g_fails++;
        return;
    }
    double d = got.get_number_or_fastint();
    if (d != want) {
        io::printfn("FAIL %s: got %f want %f", label, d, want);
        g_fails++;
        return;
    }
    io::printfn("ok   %s = %f", label, d);
}

/// Evaluate `src` and require it to be truthy (used for string/boolean asserts).
fn void check_true(Heap* hp, Vm* v, String label, String src) {
    check_num(hp, v, label, src, 1.0);
}

fn int main(String[] args) {
    Heap*? hpr = heap::create(null, null, null, null, null);
    if (catch hpr) { io::eprintfn("heap failed"); return 1; }
    Heap* hp = hpr;
    defer hp.destroy();

    Vm*? vr = vm::vm_create(hp);
    if (catch vr) { io::eprintfn("vm failed"); return 1; }
    Vm* v = vr;
    defer vm::vm_destroy(v);

    int udata_val = 99;

    if (!install(hp, v, "hostAnswer", (void*)&host_answer, null, 0, false)) { io::eprintfn("install hostAnswer failed"); return 1; }
    if (!install(hp, v, "hostAdd",    (void*)&host_add,    null, 2, false)) { io::eprintfn("install hostAdd failed"); return 1; }
    if (!install(hp, v, "hostGetX",   (void*)&host_get_x,  null, 0, false)) { io::eprintfn("install hostGetX failed"); return 1; }
    if (!install(hp, v, "hostUdata",  (void*)&host_udata,  (void*)&udata_val, 0, false)) { io::eprintfn("install hostUdata failed"); return 1; }
    if (!install(hp, v, "HostCtor",   (void*)&host_ctor,   null, 0, true))  { io::eprintfn("install HostCtor failed"); return 1; }
    if (!install(hp, v, "hostCmp",    (void*)&host_cmp,    null, 2, false)) { io::eprintfn("install hostCmp failed"); return 1; }

    // 1. plain call
    check_num(hp, v, "plain call", "hostAnswer()", 42);
    // typeof
    check_true(hp, v, "typeof is function", "typeof hostAnswer === 'function' ? 1 : 0");
    // 2. arguments
    check_num(hp, v, "arguments", "hostAdd(40, 2)", 42);
    // 3. method call, `this`
    check_num(hp, v, "method this", "var o = {x: 42, m: hostGetX}; o.m()", 42);
    // 4. .call
    check_num(hp, v, ".call", "hostGetX.call({x: 42})", 42);
    // 5. .apply
    check_num(hp, v, ".apply", "hostAdd.apply(null, [40, 2])", 42);
    // 6. .bind
    check_num(hp, v, ".bind", "hostAdd.bind(null, 40)(2)", 42);
    // 7. getter
    check_num(hp, v, "getter", "var g = {x: 42}; Object.defineProperty(g, 'p', {get: hostGetX}); g.p", 42);
    // 8. new
    check_num(hp, v, "new", "var i = new HostCtor(); i.tag * 6", 42);
    // 9. new on a non-constructor throws
    check_true(hp, v, "new non-ctor throws",
        "var threw = 0; try { new hostAdd(); } catch (e) { threw = (e instanceof TypeError) ? 1 : 0; } threw");
    // 10. super()
    check_true(hp, v, "super()",
        "class D extends HostCtor { constructor() { super(); } } (new D()).tag === 7 ? 1 : 0");
    // 11. new on a bound host ctor
    check_true(hp, v, "new bound ctor", "(new (HostCtor.bind(null))()).tag === 7 ? 1 : 0");
    // 12. builtin calling a host fn (sort comparator)
    check_true(hp, v, "sort comparator", "var sorted = [1,3,2].sort(hostCmp); sorted.join(',') === '3,2,1' ? 1 : 0");
    // 13. metadata
    check_true(hp, v, ".name", "hostAdd.name === 'hostAdd' ? 1 : 0");
    check_num(hp, v, ".length", "hostAdd.length", 2);
    // 14. udata passthrough
    check_num(hp, v, "udata", "hostUdata()", 99);

    io::printfn("");
    io::printfn("host calls dispatched: %d", g_calls);
    if (g_fails != 0) {
        io::printfn("FAILURES: %d", g_fails);
        return 1;
    }
    io::printfn("all phase-1 host function tests passed");
    return 0;
}

// Phase 2 host-function tests: the call scope, the accessor API, throwing,
// and value round-tripping.
//
// Everything here goes through builtins::host_* rather than reading
// ctx.regs directly, which is what the C ABI will layer handles over. The
// point of the phase is that the GC design holds: every test must also pass
// under the GC_STRESS + ASan target, where a collection happens at every
// allocation.
module host_fn_phase2;

import boomkat::builtins;
import boomkat::compiler;
import boomkat::vm;
import boomkat::heap;
import boomkat::env;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::lexer;
import boomkat::types;
import boomkat::bytecode;
import std::io;

int g_fails;

// --- host functions under test -------------------------------------------

// Sums every argument through host_arg, so the count and the scope reads are
// both exercised.
fn void host_sum(builtins::BuiltinContext* ctx, void* udata) {
    double sum = 0;
    uint n = builtins::host_argc(ctx);
    for (uint i = 0; i < n; i++) {
        TVal a = builtins::host_arg(ctx, i);
        if (a.is_numeric()) sum += a.get_number_or_fastint();
    }
    TVal r;
    r.set_number(sum);
    builtins::host_return(ctx, r);
}

// Returns argument 0 unchanged: the round-trip identity test.
fn void host_echo(builtins::BuiltinContext* ctx, void* udata) {
    builtins::host_return(ctx, builtins::host_arg(ctx, 0));
}

// Reads past the end of the argument list; must be undefined, not garbage.
fn void host_missing(builtins::BuiltinContext* ctx, void* udata) {
    TVal v = builtins::host_arg(ctx, 5);
    TVal r;
    r.set_boolean(v.is_undefined());
    builtins::host_return(ctx, r);
}

// Throws a TypeError with a fixed message.
fn void host_throws(builtins::BuiltinContext* ctx, void* udata) {
    builtins::host_throw_error(ctx, builtins::HOST_ERR_TYPE, "host said no");
}

// Throws its first argument as-is, so a non-Error thrown value round-trips.
fn void host_throws_value(builtins::BuiltinContext* ctx, void* udata) {
    builtins::host_throw(ctx, builtins::host_arg(ctx, 0));
}

// Both throws and returns; the throw must win.
fn void host_throw_and_return(builtins::BuiltinContext* ctx, void* udata) {
    TVal r;
    r.set_fastint(1);
    builtins::host_return(ctx, r);
    builtins::host_throw_error(ctx, builtins::HOST_ERR_RANGE, "throw wins");
}

// Builds a fresh JS string from host bytes, including an astral character.
fn void host_greet(builtins::BuiltinContext* ctx, void* udata) {
    builtins::host_return(ctx, builtins::host_new_string(ctx, "host says hi"));
}

// Reports whether it was called as a constructor.
fn void host_is_new(builtins::BuiltinContext* ctx, void* udata) {
    TVal r;
    r.set_boolean(builtins::host_is_construct(ctx));
    // As a constructor the created object is returned instead of this value,
    // so stash it on `this` where the test can read it.
    if (builtins::host_is_construct(ctx)) {
        TVal t = builtins::host_this(ctx);
        if (t.is_object()) {
            HObject* o = (HObject*)t.get_heapptr();
            HString* k = ctx.heap.str_intern("wasNew");
            if (k != null) o.put_prop(k, r, hobject::PROP_FLAGS_WEC);
        }
        return;
    }
    builtins::host_return(ctx, r);
}

// Allocates repeatedly, then re-reads argument 0. Under GC_STRESS every one
// of those allocations collects, so this fails loudly if the scope is not
// keeping the argument alive.
fn void host_alloc_churn(builtins::BuiltinContext* ctx, void* udata) {
    for (int i = 0; i < 64; i++) {
        builtins::host_new_string(ctx, "churn allocation");
    }
    builtins::host_return(ctx, builtins::host_arg(ctx, 0));
}

// --- harness --------------------------------------------------------------

fn bool install(Heap* hp, Vm* v, String name, void* handler, int arity, bool ctor) {
    HString* nm = hp.str_intern((char[])name);
    if (nm == null) return false;
    long slot = hp.register_host_fn(handler, null, (void*)nm, arity, ctor);
    if (slot < 0) return false;
    HObject*? fo = builtins::make_host_function(hp, (uint)slot);
    if (catch fo) return false;
    TVal fv;
    fv.set_object(fo);
    return env::env_declare(v.global_env, (void*)nm, fv);
}

// Evaluate `src`; require the completion value to equal `want` numerically.
fn void check(Heap* hp, Vm* v, String label, String src, double want) {
    Lexer lex = lexer::lexer_init((char[])src, hp);
    defer lex.free_arena();
    CompiledFunction*? f = compiler::compile_eval(&lex, hp);
    if (catch f) {
        io::printfn("FAIL %s: compile: %s", label, (ZString)&lex.err_msg[0]);
        g_fails++;
        return;
    }
    TVal? r = v.execute(f);
    hp.drain_microtasks((void*)v);
    if (catch r) {
        io::printfn("FAIL %s: threw", label);
        g_fails++;
        return;
    }
    TVal got = r;
    if (!got.is_numeric() || got.get_number_or_fastint() != want) {
        io::printfn("FAIL %s: wrong value", label);
        g_fails++;
        return;
    }
    io::printfn("ok   %s", label);
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

    if (!install(hp, v, "hostSum",     (void*)&host_sum,     0, false)) return 1;
    if (!install(hp, v, "hostEcho",    (void*)&host_echo,    1, false)) return 1;
    if (!install(hp, v, "hostMissing", (void*)&host_missing, 0, false)) return 1;
    if (!install(hp, v, "hostThrows",  (void*)&host_throws,  0, false)) return 1;
    if (!install(hp, v, "hostThrowsValue", (void*)&host_throws_value, 1, false)) return 1;
    if (!install(hp, v, "hostThrowAndReturn", (void*)&host_throw_and_return, 0, false)) return 1;
    if (!install(hp, v, "hostGreet",   (void*)&host_greet,   0, false)) return 1;
    if (!install(hp, v, "HostIsNew",   (void*)&host_is_new,  0, true))  return 1;
    if (!install(hp, v, "hostChurn",   (void*)&host_alloc_churn, 1, false)) return 1;

    // --- scope-backed argument access ---
    check(hp, v, "argc 0",        "hostSum()", 0);
    check(hp, v, "argc 1",        "hostSum(42)", 42);
    check(hp, v, "argc many",     "hostSum(1,2,3,4,5,6,7,8)", 36);
    check(hp, v, "missing arg is undefined", "hostMissing(1) ? 1 : 0", 1);

    // --- value round-tripping: identity through the scope ---
    check(hp, v, "echo undefined", "hostEcho(undefined) === undefined ? 1 : 0", 1);
    check(hp, v, "echo null",      "hostEcho(null) === null ? 1 : 0", 1);
    check(hp, v, "echo true",      "hostEcho(true) === true ? 1 : 0", 1);
    check(hp, v, "echo false",     "hostEcho(false) === false ? 1 : 0", 1);
    check(hp, v, "echo zero",      "hostEcho(0) === 0 ? 1 : 0", 1);
    check(hp, v, "echo negzero",   "Object.is(hostEcho(-0), -0) ? 1 : 0", 1);
    check(hp, v, "echo NaN",       "Number.isNaN(hostEcho(NaN)) ? 1 : 0", 1);
    check(hp, v, "echo Infinity",  "hostEcho(Infinity) === Infinity ? 1 : 0", 1);
    check(hp, v, "echo 2^53",      "hostEcho(9007199254740992) === 9007199254740992 ? 1 : 0", 1);
    check(hp, v, "echo string",    "hostEcho('hello') === 'hello' ? 1 : 0", 1);
    check(hp, v, "echo empty str", "hostEcho('') === '' ? 1 : 0", 1);
    // The astral character is written as a JS escape inside the JS source, so
    // the C3 string itself stays plain ASCII.
    check(hp, v, "echo astral",
        "hostEcho('a\\u{1F600}b') === 'a\\u{1F600}b' ? 1 : 0", 1);
    check(hp, v, "echo astral length",
        "hostEcho('\\u{1F600}').length", 2);
    check(hp, v, "echo object",    "var o = {}; hostEcho(o) === o ? 1 : 0", 1);
    check(hp, v, "echo array",     "var a = [1,2]; hostEcho(a) === a ? 1 : 0", 1);
    check(hp, v, "echo function",  "hostEcho(hostSum) === hostSum ? 1 : 0", 1);

    // --- host-built strings ---
    check(hp, v, "host string",    "hostGreet() === 'host says hi' ? 1 : 0", 1);

    // --- throwing ---
    check(hp, v, "throw error kind",
        "var k = 0; try { hostThrows(); } catch (e) { k = (e instanceof TypeError) ? 1 : 0; } k", 1);
    check(hp, v, "throw message",
        "var m = ''; try { hostThrows(); } catch (e) { m = e.message; } m === 'host said no' ? 1 : 0", 1);
    check(hp, v, "throw value identity",
        "var s = {}; var c = null; try { hostThrowsValue(s); } catch (e) { c = e; } c === s ? 1 : 0", 1);
    check(hp, v, "throw primitive",
        "var c = null; try { hostThrowsValue(42); } catch (e) { c = e; } c === 42 ? 1 : 0", 1);
    check(hp, v, "throw beats return",
        "var k = 0; try { hostThrowAndReturn(); } catch (e) { k = (e instanceof RangeError) ? 1 : 0; } k", 1);
    check(hp, v, "engine survives a throw", "hostSum(20, 22)", 42);

    // --- construct detection ---
    check(hp, v, "not construct on call", "HostIsNew() === false ? 1 : 0", 1);
    check(hp, v, "construct on new",      "(new HostIsNew()).wasNew === true ? 1 : 0", 1);

    // --- GC: the argument must survive allocation inside the callback ---
    check(hp, v, "arg survives churn",    "hostChurn(42)", 42);
    check(hp, v, "string arg survives churn",
        "hostChurn('still here') === 'still here' ? 1 : 0", 1);
    check(hp, v, "object arg survives churn",
        "var o = {v: 42}; hostChurn(o).v", 42);

    // --- nesting: host -> JS -> host keeps scopes independent ---
    check(hp, v, "nested host calls",
        "[1,2,3].map(function (x) { return hostSum(x, 10); }).join(',') === '11,12,13' ? 1 : 0", 1);

    io::printfn("");
    if (g_fails != 0) {
        io::printfn("FAILURES: %d", g_fails);
        return 1;
    }
    io::printfn("all phase-2 host function tests passed");
    return 0;
}

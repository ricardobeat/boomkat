/// Phase 4 host-function tests: calling JS from host code.
///
/// Covers the host -> JS -> host round trip, argument and `this` passing,
/// exception propagation out of a callee, and the run-depth guard that bounds
/// unbounded mutual recursion. Also re-checks that a host argument survives a
/// nested call that reallocates the valstack, which is the specific hazard the
/// call scope exists to prevent.
module host_fn_phase4;

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

int g_fails;

// --- host functions under test -------------------------------------------

/// hostApply(f, x) -> f(x). The minimal host -> JS call.
fn void host_apply(builtins::BuiltinContext* ctx, void* udata) {
    TVal f = builtins::host_arg(ctx, 0);
    TVal a = builtins::host_arg(ctx, 1);
    TVal undef;
    undef.set_undefined();
    bool ok = false;
    TVal r = builtins::host_call(ctx, f, &a, 1, undef, &ok);
    if (!ok) return;   // the throw is already staged on ctx
    builtins::host_return(ctx, r);
}

/// hostApplyThis(f, recv) -> f.call(recv), proving `this` is delivered.
fn void host_apply_this(builtins::BuiltinContext* ctx, void* udata) {
    TVal f = builtins::host_arg(ctx, 0);
    TVal recv = builtins::host_arg(ctx, 1);
    bool ok = false;
    TVal r = builtins::host_call(ctx, f, null, 0, recv, &ok);
    if (!ok) return;
    builtins::host_return(ctx, r);
}

/// Calls f(x) and then re-reads its own argument 0, asserting the call scope
/// survived a nested execution that may have reallocated the valstack.
fn void host_call_then_read(builtins::BuiltinContext* ctx, void* udata) {
    TVal f = builtins::host_arg(ctx, 0);
    TVal a = builtins::host_arg(ctx, 1);
    TVal undef;
    undef.set_undefined();
    bool ok = false;
    builtins::host_call(ctx, f, &a, 1, undef, &ok);
    if (!ok) return;
    // Argument 1 must still be readable and unchanged after the nested run.
    builtins::host_return(ctx, builtins::host_arg(ctx, 1));
}

/// Calls a JS function that throws, without checking ok: the throw must still
/// propagate rather than being swallowed into an undefined result.
fn void host_call_throwing(builtins::BuiltinContext* ctx, void* udata) {
    TVal f = builtins::host_arg(ctx, 0);
    TVal undef;
    undef.set_undefined();
    bool ok = false;
    TVal r = builtins::host_call(ctx, f, null, 0, undef, &ok);
    if (!ok) return;
    builtins::host_return(ctx, r);
}

/// Calls a non-callable value, which must produce a TypeError.
fn void host_call_bad(builtins::BuiltinContext* ctx, void* udata) {
    TVal notfn = builtins::host_arg(ctx, 0);
    TVal undef;
    undef.set_undefined();
    bool ok = false;
    builtins::host_call(ctx, notfn, null, 0, undef, &ok);
}

/// Unbounded host -> JS -> host recursion. Must terminate by throwing rather
/// than exhausting the native stack.
fn void host_recurse(builtins::BuiltinContext* ctx, void* udata) {
    TVal f = builtins::host_arg(ctx, 0);
    TVal undef;
    undef.set_undefined();
    bool ok = false;
    TVal r = builtins::host_call(ctx, f, &f, 1, undef, &ok);
    if (!ok) return;
    builtins::host_return(ctx, r);
}

// --- harness --------------------------------------------------------------

fn bool install(Heap* hp, Vm* v, String name, void* handler, int arity) {
    HString* nm = hp.str_intern((char[])name);
    if (nm == null) return false;
    long slot = hp.register_host_fn(handler, null, (void*)nm, arity, false);
    if (slot < 0) return false;
    HObject*? fo = builtins::make_host_function(hp, (uint)slot);
    if (catch fo) return false;
    TVal fv;
    fv.set_object(fo);
    return env::env_declare(v.global_env, (void*)nm, fv);
}

fn void check(Heap* hp, Vm* v, String label, String src, double want) {
    Lexer lex = lexer::lexer_init((char[])src, hp);
    defer lex.free_arena();
    CompiledFunction*? f = compiler::compile_eval(&lex, hp);
    if (catch f) {
        io::printfn("FAIL %s: compile: %s", label, (ZString)compiler::last_error_msg());
        g_fails++;
        return;
    }
    TVal? r = v.execute(f);
    hp.drain_microtasks((void*)v);
    if (catch r) {
        io::printfn("FAIL %s: threw out of execute", label);
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

    if (!install(hp, v, "hostApply",        (void*)&host_apply, 2)) return 1;
    if (!install(hp, v, "hostApplyThis",    (void*)&host_apply_this, 2)) return 1;
    if (!install(hp, v, "hostCallThenRead", (void*)&host_call_then_read, 2)) return 1;
    if (!install(hp, v, "hostCallThrowing", (void*)&host_call_throwing, 1)) return 1;
    if (!install(hp, v, "hostCallBad",      (void*)&host_call_bad, 1)) return 1;
    if (!install(hp, v, "hostRecurse",      (void*)&host_recurse, 1)) return 1;

    // --- the basic round trip ---
    check(hp, v, "host calls JS",
        "hostApply(function (x) { return x * 2; }, 21)", 42);
    check(hp, v, "host calls JS with closure",
        "var base = 40; hostApply(function (x) { return base + x; }, 2)", 42);
    // A host function calling a host function: the inner hostApply gets one
    // argument, so its own arg 1 is undefined and calling it must be rejected
    // as a non-function. This is the nesting case that proves each handler
    // addresses its own scope rather than the innermost one.
    check(hp, v, "host calls a host function",
        "var k = 0; try { hostApply(hostApply, 1); } catch (e) { k = (e instanceof TypeError) ? 1 : 0; } k", 1);
    check(hp, v, "nested host sees its own args",
        "hostApply(function (n) { return hostApply(function (x) { return x * 2; }, n); }, 21)", 42);
    check(hp, v, "host calls an arrow",
        "hostApply(x => x + 40, 2)", 42);
    check(hp, v, "host calls a builtin",
        "hostApply(Math.abs, -42)", 42);

    // --- `this` delivery ---
    check(hp, v, "this through host_call",
        "hostApplyThis(function () { return this.v; }, {v: 42})", 42);

    // --- the scope survives a nested execution ---
    check(hp, v, "arg survives nested call",
        "hostCallThenRead(function () { var s = 0; for (var i = 0; i < 500; i++) { s += i; } return s; }, 42)", 42);
    check(hp, v, "object arg survives nested call",
        "var o = {v: 42}; hostCallThenRead(function () { return new Array(200).join('x'); }, o).v", 42);

    // --- exceptions out of the callee ---
    check(hp, v, "callee throw propagates",
        "var k = 0; try { hostCallThrowing(function () { throw new RangeError('inner'); }); } catch (e) { k = (e instanceof RangeError) ? 1 : 0; } k", 1);
    check(hp, v, "callee throw keeps message",
        "var m = ''; try { hostCallThrowing(function () { throw new Error('inner'); }); } catch (e) { m = e.message; } m === 'inner' ? 1 : 0", 1);
    check(hp, v, "callee throw is catchable in JS",
        "var k = 0; try { hostApply(function () { throw 7; }, 1); } catch (e) { k = (e === 7) ? 1 : 0; } k", 1);
    check(hp, v, "engine survives callee throw", "hostApply(x => x, 42)", 42);

    // --- calling a non-function ---
    check(hp, v, "call non-function throws TypeError",
        "var k = 0; try { hostCallBad(42); } catch (e) { k = (e instanceof TypeError) ? 1 : 0; } k", 1);
    check(hp, v, "call null throws TypeError",
        "var k = 0; try { hostCallBad(null); } catch (e) { k = (e instanceof TypeError) ? 1 : 0; } k", 1);

    // --- recursion terminates by throwing, not by crashing ---
    // Bounded nesting stays under MAX_HOST_DEPTH in every build profile, so
    // this exercises real host <-> JS nesting rather than the guard.
    check(hp, v, "bounded host recursion",
        "var d = 0; hostApply(function rec(n) { d++; return d < 4 ? hostApply(rec, n) : 42; }, 1)", 42);
    check(hp, v, "runaway recursion throws",
        "var threw = 0; try { hostRecurse(function f(g) { return hostRecurse(f); }); } catch (e) { threw = 1; } threw", 1);
    check(hp, v, "engine usable after recursion guard", "hostApply(x => x + 1, 41)", 42);

    io::printfn("");
    if (g_fails != 0) {
        io::printfn("FAILURES: %d", g_fails);
        return 1;
    }
    io::printfn("all phase-4 host function tests passed");
    return 0;
}

/// Host functions in the native C3 binding: JS calling into C3, and C3 calling
/// back into JS.
///
///     c3c build boomkat_example_host_c3 && ./out/boomkat_example_host_c3
module boomkat_example_host;

import boomkat;
import std::io;
import std::math;

// ----------------------------------------------------------------------------
// The host functions
//
// Each is a plain `fn void(JsCtx, void*)`. Arguments come in through
// `ctx.arg(i)`, results go out through `ctx.ret*`, and failures through
// `ctx.throw_error` -- which records the exception and returns, so the callback
// always finishes under its own control.
// ----------------------------------------------------------------------------

/// `hypot(a, b)` -- arguments in, a number out. Argument types are the host's
/// responsibility: JS may pass anything, so check and throw rather than assume.
fn void host_hypot(JsCtx ctx, void* udata) {
    double? a = ctx.arg(0).as_number();
    double? b = ctx.arg(1).as_number();
    if (catch a) { ctx.throw_error(TYPE, "hypot: first argument must be a number"); return; }
    if (catch b) { ctx.throw_error(TYPE, "hypot: second argument must be a number"); return; }
    ctx.ret_number(math::sqrt(a * a + b * b));
}

/// `greet(name)` -- a string in, a freshly built string out.
fn void host_greet(JsCtx ctx, void* udata) {
    String? name = ctx.arg(0).as_string();
    if (catch name) { ctx.throw_error(TYPE, "greet: expected a string"); return; }
    ctx.ret_string(string::tformat("hello, %s", name));
}

/// `counter()` -- reads mutable host state through the udata pointer that was
/// handed to `register_fn`. This is how a callback reaches anything other than
/// globals: C3 function pointers cannot capture.
fn void host_counter(JsCtx ctx, void* udata) {
    int* n = (int*)udata;
    (*n)++;
    ctx.ret_number((double)*n);
}

/// `withdraw(amount)` -- throws a RangeError JS can catch.
///
/// Note the `return` right after `throw_error`: the throw does not unwind, so
/// without it the rest of the body would still run.
fn void host_withdraw(JsCtx ctx, void* udata) {
    double? amount = ctx.arg(0).as_number();
    if (catch amount) { ctx.throw_error(TYPE, "withdraw: expected a number"); return; }
    if (amount > 100.0) {
        ctx.throw_error(RANGE, "insufficient funds");
        return;
    }
    ctx.ret_number(100.0 - amount);
}

/// `applyTwice(fn, x)` -- calls a JS function from host code, twice, feeding
/// each result into the next.
///
/// If the callback throws, `call` reports JS_EXCEPTION and the exception is
/// already recorded on this call, so returning propagates it to JS unchanged.
fn void host_apply_twice(JsCtx ctx, void* udata) {
    JsArg callback = ctx.arg(0);
    JsArg value = ctx.arg(1);

    for (int i = 0; i < 2; i++) {
        JsArg? next = ctx.call(callback, { value });
        if (catch e = next) {
            // NOT_CALLABLE is ours to report; JS_EXCEPTION is already pending.
            if (e == boomkat::NOT_CALLABLE) ctx.throw_error(TYPE, "applyTwice: first argument must be a function");
            return;
        }
        value = next;
    }
    ctx.ret(value);
}

/// `Point(x, y)` -- a constructor. Registered with `constructable = true`, so
/// `new Point(3, 4)` works and a plain `Point(3, 4)` is rejected here.
///
/// The engine has already allocated `this` with the prototype taken from
/// new.target, so the callback populates it and returns; there is nothing to
/// `ret`, and a returned number would be discarded anyway.
fn void host_point(JsCtx ctx, void* udata) {
    if (!ctx.is_construct()) {
        ctx.throw_error(TYPE, "Point requires 'new'");
        return;
    }
    double x = ctx.arg(0).as_number() ?? 0.0;
    double y = ctx.arg(1).as_number() ?? 0.0;

    JsArg self = ctx.this_value();
    ctx.set_prop(self, "x", ctx.number(x))!!;
    ctx.set_prop(self, "y", ctx.number(y))!!;
    ctx.set_prop(self, "r", ctx.number(math::sqrt(x * x + y * y)))!!;
}

// ----------------------------------------------------------------------------

fn int main() {
    JsRuntime rt;
    if (catch e = rt.open()) {
        io::eprintfn("could not start the engine: %s", e);
        return 1;
    }
    defer rt.close();

    // Host state a callback mutates. It must outlive the runtime, so it is a
    // local in main rather than anything scoped tighter.
    int hits = 0;

    rt.register_fn("hypot", &host_hypot, arity: 2)!!;
    rt.register_fn("greet", &host_greet, arity: 1)!!;
    rt.register_fn("counter", &host_counter, udata: &hits)!!;
    rt.register_fn("withdraw", &host_withdraw, arity: 1)!!;
    rt.register_fn("applyTwice", &host_apply_twice, arity: 2)!!;
    rt.register_fn("Point", &host_point, arity: 2, constructable: true)!!;

    io::printn("-- arguments and return values --");
    show(&rt, "hypot(3, 4)", "hypot(3, 4)");
    show(&rt, "greet('world')", "greet('world')");
    show(&rt, "hypot.length", "hypot.length");
    show(&rt, "hypot.name", "hypot.name");

    io::printn("\n-- host state via udata --");
    show(&rt, "counter() x3", "counter(); counter(); counter()");
    io::printfn("C3 side saw   = %d hits", hits);

    io::printn("\n-- throwing, caught by JS --");
    show(&rt, "caught RangeError",
        "try { withdraw(500) } catch (e) { e.constructor.name + ': ' + e.message }");
    show(&rt, "no throw", "withdraw(30)");
    show(&rt, "wrong arg type",
        "try { hypot('x', 4) } catch (e) { e.message }");

    io::printn("\n-- calling a JS callback from C3 --");
    show(&rt, "applyTwice(double, 5)", "applyTwice(function (n) { return n * 2 }, 5)");
    show(&rt, "callback throws",
        "try { applyTwice(function () { throw new Error('from JS') }, 1) } catch (e) { e.message }");
    show(&rt, "not a function",
        "try { applyTwice(42, 1) } catch (e) { e.message }");

    io::printn("\n-- new --");
    show(&rt, "new Point(3, 4).r", "new Point(3, 4).r");
    show(&rt, "instance shape",
        "JSON.stringify(new Point(1, 2)) + ' ' + (new Point(0,0) instanceof Point)");
    show(&rt, "Point without new",
        "try { Point(3, 4) } catch (e) { e.message }");

    io::printn("\n-- bounded recursion --");
    // js -> host -> js -> host nesting is capped, so a runaway chain surfaces
    // as a catchable RangeError instead of faulting the native stack.
    show(&rt, "1000 deep",
        "function f(n) { return n <= 0 ? 0 : applyTwice(function () { return f(n - 1) }, 0) } try { f(1000) } catch (e) { e.constructor.name + ': ' + e.message }");

    return 0;
}

/// Evaluate `src` and print its result, or the message of whatever it failed
/// with. Everything above goes through this so the output reads as a transcript.
fn void show(JsRuntime* rt, String label, String src) {
    JsValue? v = rt.eval(src);
    if (catch e = v) {
        io::printfn("%-20s = %s: %s", label, e, rt.last_error());
        return;
    }
    io::printfn("%-20s = %s", label, rt.to_display_string(v)!!);
    rt.release(v);
}

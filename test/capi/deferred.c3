module deferred_api;
import boomkat;
import boomkat::capi;
import std::io;

fn void expect(JsContext* cx, String source) {
    JsValue result = cx.eval(source)!!;
    assert(cx.as_bool(result)!!);
    cx.release(result);
}

fn void main() {
    JsContext cx;
    cx.create()!!;
    defer cx.destroy();
    JsValue global = cx.global()!!;
    defer cx.release(global);
    JsDeferred d;
    cx.@scope() { d = cx.deferred()!!; };
    defer cx.release_deferred(d);
    cx.set(global, "p", d.promise)!!;
    JsValue setup = cx.eval("globalThis.observed = 0; p.then(v => { observed = v; }); Promise.withResolvers = () => { throw 1; }; true")!!;
    cx.release(setup);
    JsValue thenable = cx.eval("({ then(resolve) { resolve(42); resolve(99); } })")!!;
    defer cx.release(thenable);
    cx.settle_deferred(d, true, thenable)!!;
    JsValue late = cx.number(99)!!;
    defer cx.release(late);
    cx.settle_deferred(d, false, late)!!;
    expect(&cx, "observed === 0");
    cx.release_deferred(d); // the queued adoption job must retain everything it needs
    capi::bk_gc(cx.rt, 1);
    cx.owner.drain_microtasks()!!;
    expect(&cx, "observed === 42");

    JsDeferred cycle = cx.deferred()!!;
    defer cx.release_deferred(cycle);
    cx.set(global, "cycle", cycle.promise)!!;
    cx.settle_deferred(cycle, true, cycle.promise)!!;
    expect(&cx, "globalThis.cycleError = false; cycle.catch(e => { cycleError = e instanceof TypeError; }); true");
    cx.owner.drain_microtasks()!!;
    expect(&cx, "cycleError");

    JsDeferred failed = cx.deferred()!!;
    defer cx.release_deferred(failed);
    cx.set(global, "failed", failed.promise)!!;
    JsValue getter = cx.eval("({ get then() { throw 'getter'; } })")!!;
    defer cx.release(getter);
    cx.settle_deferred(failed, true, getter)!!;
    expect(&cx, "globalThis.getterError = false; failed.catch(e => { getterError = e === 'getter'; }); true");
    cx.owner.drain_microtasks()!!;
    expect(&cx, "getterError");
    io::printn("deferred API: PASS");
}

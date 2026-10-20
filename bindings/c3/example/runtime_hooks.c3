module runtime_hooks_test;
import boomkat;
import boomkat::types;
import std::io;

uint rejected;
uint handled;
ulong rejected_id;
JsValue saved_promise;

fn void rejection(JsRuntime* rt, ulong id, JsValue promise, JsValue reason, bool is_handled, void* udata) {
    assert(udata == &rejected);
    assert(rt.type_of(reason) == JsType.STRING);
    if (is_handled) {
        assert(id == rejected_id);
        rt.release(saved_promise);
        handled++;
    } else {
        saved_promise = rt.persist(promise)!!;
        rejected_id = id;
        rejected++;
    }
}

fn int poll(void* runtime, void* opaque) {
    uint* polls = (uint*)opaque;
    (*polls)++;
    return *polls >= 2 ? 1 : 0;
}

fn void request(JsCtx ctx, void* udata) {
    JsRuntime* rt = (JsRuntime*)udata;
    rt.request_interrupt();
}

fn void check_interrupt(JsContext* rt, JsRuntime* owner, String source) {
    JsValue? result = rt.eval(source);
    if (catch err = result) {
        assert(err == boomkat::INTERRUPTED);
    } else {
        unreachable("expected INTERRUPTED");
    }
    owner.clear_interrupt();
    JsValue v = rt.eval("1+1")!!;
    assert(rt.as_number(v)!! == 2);
    rt.release(v);
}

fn void main() {
    JsRuntime rt_runtime;
    rt_runtime.create()!!;
    defer rt_runtime.destroy();
    JsContext rt;
    rt.create(&rt_runtime)!!;
    defer rt.destroy();
    rt_runtime.set_promise_rejection_tracker(&rejection, &rejected);
    rt.release(rt.eval("var p = Promise.reject('late');")!!);
    assert(rejected == 1 && handled == 0);
    rt.release(rt.eval("p.catch(function() {}); p.catch(function() {});")!!);
    rt_runtime.drain_microtasks()!!;
    assert(handled == 1);
    rt.release(rt.eval("p = Promise.reject('same turn'); Promise.resolve().then(function() { p.catch(function() {}); });")!!);
    rt_runtime.drain_microtasks()!!;
    assert(rejected == 2 && handled == 2);
    rt_runtime.set_promise_rejection_tracker(null);
    uint polls;
    rt_runtime.set_interrupt(&poll, &polls);
    check_interrupt(&rt, &rt_runtime, "while (true) {}");
    assert(polls >= 2);
    rt_runtime.set_interrupt(null);
    rt.register_fn("request", &request, udata: &rt_runtime)!!;
    check_interrupt(&rt, &rt_runtime, "request(); while (true) {}");
    check_interrupt(&rt, &rt_runtime, "request(); try { while (true) {} } catch(e) {}");
    check_interrupt(&rt, &rt_runtime, "request(); /^(a+)+$/.test('a'.repeat(40) + '!');");
    JsValue func = rt.eval("(function() { request(); while (true) {} })")!!;
    JsValue? result = rt.call(func);
    if (catch err = result) { assert(err == boomkat::INTERRUPTED); }
    else { unreachable("call must interrupt"); }
    rt_runtime.clear_interrupt();
    rt.release(func);
    func = rt.eval("(function() { request(); try { while (true) {} } finally { return 1; } })")!!;
    result = rt.call(func);
    if (catch err = result) { assert(err == boomkat::INTERRUPTED); }
    else { unreachable("finally return must interrupt"); }
    rt_runtime.clear_interrupt();
    rt.release(func);
    func = rt.eval("(function() { request(); while (true) {} })")!!;
    TVal handler;
    assert(rt.load(func, &handler));
    TVal undef; undef.set_undefined();
    rt.rt.heap.enqueue_microtask(handler, undef, undef);
    rt.release(func);
    if (catch err = rt_runtime.drain_microtasks()) { assert(err == boomkat::INTERRUPTED); }
    else { unreachable("drain must interrupt"); }
    rt_runtime.clear_interrupt();
    rt.release(rt.eval("1+1")!!);
    io::printn("native runtime hooks: PASS");
}

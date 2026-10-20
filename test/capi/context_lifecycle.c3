module context_lifecycle;

import boomkat;
import std::io;

fn double number(JsContext* context, String source) {
    JsValue value = context.eval(source)!!;
    defer context.release(value);
    return context.as_number(value)!!;
}

fn void owned_contexts() {
    JsContext first, second;
    first.destroy();
    assert(!first.is_created() && first.get_runtime() == null);
    first.create()!!;
    defer first.destroy();
    second.create()!!;
    defer second.destroy();
    assert(first.get_runtime() != second.get_runtime());
    assert(first.get_runtime().is_created());
    assert(number(&first, "var count = 41; count + 1") == 42);
    assert(number(&second, "typeof count === 'undefined' ? 1 : 0") == 1);

    JsRuntime* owner = first.get_runtime();
    if (catch err = first.create()) { assert(err == boomkat::ALREADY_CREATED); }
    else { unreachable("creating a live context must fail"); }
    if (catch err = first.create(second.get_runtime())) { assert(err == boomkat::ALREADY_CREATED); }
    else { unreachable("replacing a live context's runtime must fail"); }
    assert(first.get_runtime() == owner);
    assert(number(&first, "count") == 41);
    if (catch err = owner.create()) { assert(err == boomkat::ALREADY_CREATED); }
    else { unreachable("creating a live runtime must fail"); }

    JsValue value = first.eval("({ answer: 42 })")!!;
    if (catch err = second.persist(value)) { assert(err == boomkat::STALE_VALUE); }
    else { unreachable("separate runtimes must reject each other's values"); }
    first.release(value);

    // A sibling borrows the private runtime, so it must end before its owner.
    JsContext sibling;
    sibling.create(first.get_runtime())!!;
    assert(number(&sibling, "typeof count === 'undefined' ? 1 : 0") == 1);
    sibling.destroy();
    assert(number(&first, "count") == 41);

    first.destroy();
    first.destroy();
    assert(!first.is_created() && first.get_runtime() == null);
    first.create()!!;
    assert(first.get_runtime() == owner);
    assert(number(&first, "typeof count === 'undefined' ? 1 : 0") == 1);
    assert(number(&second, "6 * 7") == 42);
}

fn void shared_contexts() {
    JsRuntime runtime;
    runtime.destroy();
    JsContext first, second;
    if (catch err = first.create(&runtime)) { assert(err == boomkat::NOT_CREATED); }
    else { unreachable("borrowing an uninitialized runtime must fail"); }
    assert(!first.is_created() && first.get_runtime() == null);

    runtime.create()!!;
    defer runtime.destroy();
    first.create(&runtime)!!;
    defer first.destroy();
    second.create(&runtime)!!;
    defer second.destroy();
    assert(first.get_runtime() == &runtime && second.get_runtime() == &runtime);
    assert(number(&first, "var count = 7; count") == 7);
    assert(number(&second, "typeof count === 'undefined' ? 1 : 0") == 1);

    JsValue object = first.eval("({ answer: 42 })")!!;
    JsValue answer = second.get(object, "answer")!!;
    assert(second.as_number(answer)!! == 42);
    second.release(answer);
    JsValue array_ctor = first.eval("Array")!!;
    JsValue global = second.global()!!;
    second.set(global, "OtherArray", array_ctor)!!;
    second.release(global);
    first.release(array_ctor);
    assert(number(&second, "Array !== OtherArray ? 1 : 0") == 1);

    first.destroy();
    assert(runtime.is_created());
    // Runtime roots survive the originating context's destruction and GC.
    second.exec("for (var i = 0; i < 100; i++) ({ x: i });")!!;
    answer = second.get(object, "answer")!!;
    assert(second.as_number(answer)!! == 42);
    second.release(answer);
    runtime.release(object);
    first.create(&runtime)!!;
    assert(number(&first, "6 * 7") == 42);
}

struct Rejections {
    JsRuntime* owner;
    uint count;
}

fn void rejected(JsRuntime* runtime, ulong id, JsValue promise, JsValue reason,
                 bool handled, void* udata) {
    Rejections* state = (Rejections*)udata;
    assert(runtime == state.owner);
    assert(runtime.type_of(reason) == JsType.STRING);
    JsValue retained = runtime.persist(promise)!!;
    runtime.release(retained);
    state.count++;
}

fn void owned_hooks() {
    JsContext context;
    context.create()!!;
    defer context.destroy();
    Rejections state = { .owner = context.get_runtime() };
    state.owner.set_promise_rejection_tracker(&rejected, &state);
    context.exec("Promise.reject('owned runtime');")!!;
    assert(state.count == 1);
    context.exec("var done = 0; Promise.resolve().then(function() { done = 1; });")!!;
    assert(number(&context, "done") == 0);
    state.owner.drain_microtasks()!!;
    assert(number(&context, "done") == 1);
}

fn void main() {
    owned_contexts();
    shared_contexts();
    owned_hooks();
    io::printn("C3 context lifecycle: PASS");
}

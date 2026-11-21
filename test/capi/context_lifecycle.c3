module context_lifecycle;

import boomkat;
import boomkat::ast::vec;
import boomkat::bytecode;
import boomkat::capi;
import boomkat::embed;
import boomkat::image;
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

fn void module_lifecycle() {
    JsContext context;
    context.create()!!;
    defer context.destroy();
    context.define_module("pkg/math.js", "export const x = 20; export function add(a) { return a + x; }")!!;
    context.define_module("pkg/double.js", "import { add } from './math.js'; export const y = add(22);")!!;
    // Repeated imports exercise both cache hits and relative path resolution.
    JsValue ns = context.eval_module(
        "import { add } from 'pkg/math.js'; import { y } from 'pkg/double.js'; export const total = add(y);",
        "entry.js"
    )!!;
    defer context.release(ns);
    JsValue total = context.get(ns, "total")!!;
    defer context.release(total);
    assert(context.as_number(total)!! == 62);
}

struct AsyncLoaderState {
    embed::ModuleRequest* slow_req;
    uint loads;
}

fn int async_resolve_cb(void* ctx, char* referrer, char* specifier, void* request, void* opaque) {
    char[] spec = ((ZString)specifier).str_view();
    return capi::bk_module_set_name((embed::ModuleRequest*)request, spec.ptr, spec.len);
}

fn int async_load_cb(void* ctx, char* name, void* request, void* opaque) {
    AsyncLoaderState* st = (AsyncLoaderState*)opaque;
    st.loads++;
    // Hold only app:slow so we can fulfill it later; leave app:pending
    // unanswered so runtime teardown exercises pending-request cleanup.
    if (((ZString)name).str_view() == "app:slow") {
        st.slow_req = (embed::ModuleRequest*)request;
    }
    return capi::BK_OK;
}

fn void async_loader_lifecycle() {
    void* ctx = capi::bk_create();
    assert(ctx != null);
    defer capi::bk_destroy(ctx);
    void* rt = capi::bk_get_runtime(ctx);
    AsyncLoaderState state;
    embed::ModuleLoader loader = {
        .resolve = &async_resolve_cb,
        .load = &async_load_cb,
        .opaque = &state,
        .flags = capi::BK_LOADER_ASYNC | capi::BK_LOADER_NO_FILESYSTEM_FALLBACK,
    };
    int rc = capi::bk_set_module_loader(rt, &loader);
    assert(rc == capi::BK_OK);

    // Deferred async import that resolves once the host provides source.
    String slow = "app:slow";
    ulong p_slow = capi::bk_import(ctx, slow.ptr, slow.len);
    assert(p_slow != 0);
    defer capi::bk_free_value(ctx, p_slow);
    rc = capi::bk_run_jobs(rt);
    assert(rc == capi::BK_OK);
    int pstate = -1;
    rc = capi::bk_promise_state_get(ctx, p_slow, &pstate);
    if (rc != capi::BK_OK || pstate != capi::BK_PROMISE_PENDING || state.slow_req == null || state.loads != 1) {
        unreachable("async loader did not suspend app:slow");
    }
    String src = "export const v = 99;";
    rc = capi::bk_module_provide(state.slow_req, src.ptr, src.len);
    assert(rc == capi::BK_OK);
    rc = capi::bk_run_jobs(rt);
    assert(rc == capi::BK_OK);
    rc = capi::bk_promise_state_get(ctx, p_slow, &pstate);
    if (rc != capi::BK_OK || pstate != capi::BK_PROMISE_FULFILLED) {
        unreachable("async loader did not fulfill app:slow");
    }
    ulong ns = capi::bk_promise_result(ctx, p_slow);
    assert(ns != 0);
    defer capi::bk_free_value(ctx, ns);
    String key_v = "v";
    ulong v = capi::bk_get_property(ctx, ns, key_v.ptr, key_v.len);
    assert(v != 0);
    defer capi::bk_free_value(ctx, v);
    if (capi::bk_to_number(ctx, v) != 99.0) {
        unreachable("async module export v != 99");
    }

    // Unanswered async import torn down while still pending on Runtime.module_requests.
    String pending = "app:pending";
    ulong p_pend = capi::bk_import(ctx, pending.ptr, pending.len);
    assert(p_pend != 0);
    defer capi::bk_free_value(ctx, p_pend);
    rc = capi::bk_run_jobs(rt);
    assert(rc == capi::BK_OK);
    rc = capi::bk_promise_state_get(ctx, p_pend, &pstate);
    if (rc != capi::BK_OK || pstate != capi::BK_PROMISE_PENDING || state.loads != 2) {
        unreachable("async loader did not leave app:pending pending");
    }
}

fn void sort_lifecycle() {
    JsContext context;
    context.create()!!;
    defer context.destroy();
    // Arrays > SORT_INLINE_ELEMS (64) exercise heap fallback in @stack_mem:
    // sort, toSorted, empty toSorted, re-entrant nested sort, and throw unwind.
    double ok = number(&context,
        "(() => {"
        "  const a = []; for (let i = 200; i > 0; i--) a.push(i);"
        "  a.sort((x, y) => x - y);"
        "  if (a[0] !== 1 || a[199] !== 200) return 0;"
        "  const b = a.toSorted((x, y) => y - x);"
        "  if (b[0] !== 200 || b[199] !== 1 || [].toSorted().length !== 0) return 0;"
        "  let threw = false;"
        "  try { b.sort((x, y) => { if (x === 50) throw new Error('stop'); return x - y; }); } catch (e) { threw = true; }"
        "  if (!threw) return 0;"
        "  let nested = 0;"
        "  const c = []; for (let i = 80; i > 0; i--) c.push(i);"
        "  c.sort((x, y) => { if (nested === 0) { nested = 1; a.toSorted((p, q) => q - p); } return x - y; });"
        "  if (c[0] !== 1 || c[79] !== 80) return 0;"
        "  const sparse = { length: 5000, 0: 3, 4999: 1 };"
        "  Array.prototype.sort.call(sparse, (x, y) => x - y);"
        "  return sparse[0] === 1 && sparse[1] === 3 && !(4999 in sparse) ? 1 : 0;"
        "})()"
    );
    assert(ok == 1);
}

fn void call_and_deferred_lifecycle() {
    JsContext context;
    context.create()!!;
    defer context.destroy();

    // Exceed the inline argument buffer so JsContext.call exercises heap fallback.
    JsValue sum = context.eval("(function(...xs) { let s = 0; for (let x of xs) s += x; return s; })")!!;
    defer context.release(sum);
    JsValue[12] args;
    for (usz i = 0; i < args.len; i++) args[i] = context.number((double)(i + 1))!!;
    defer foreach (a : args) context.release(a);
    JsValue total = context.call(sum, args[..])!!;
    defer context.release(total);
    if (context.as_number(total)!! != 78.0) unreachable("12-arg JsContext.call failed");

    // Exercise 0-arg JsContext.call and JsContext.deferred() normal lifecycle.
    JsValue zero = context.call(sum)!!;
    defer context.release(zero);
    if (context.as_number(zero)!! != 0.0) unreachable("0-arg JsContext.call failed");
    JsDeferred d = context.deferred()!!;
    defer context.release_deferred(d);
    JsValue forty_two = context.number(42.0)!!;
    defer context.release(forty_two);
    context.settle_deferred(d, true, forty_two)!!;
    context.get_runtime().drain_microtasks()!!;
}

fn void bytecode_image_lifecycle() {
    JsContext context;
    context.create()!!;
    defer context.destroy();

    embed::Runtime* rt = context.rt;
    // A deferred (lazy) inner function makes image::encode fault with
    // UNSUPPORTED_CONSTANT, exercising `defer catch w.bytes.free()`.
    bytecode::CompiledFunction* lazy_compiled = null;
    int rc = embed::compile_script(rt, "function lazy_fn(x) { return x + 1; }", "lazy.js", true, &lazy_compiled);
    if (rc != embed::BK_OK || lazy_compiled == null) unreachable("compile_script lazy failed");
    if (catch err = image::encode(rt.heap, lazy_compiled, {})) {
        if (err != image::UNSUPPORTED_CONSTANT) unreachable("expected UNSUPPORTED_CONSTANT on lazy function");
    } else {
        unreachable("lazy function encode must fail");
    }

    // Default parameter disables lazy deferral so the inner function is eagerly
    // compiled. Exercises zero-copy encode, UTF-16 hstring decode, and rollback
    // of multiple tracked functions when decoding a truncated image.
    bytecode::CompiledFunction* compiled = null;
    rc = embed::compile_script(rt, "const s = 'héllo 🚀'; function f(x = 0) { return x + s.length; } f(3);", "img.js", true, &compiled);
    if (rc != embed::BK_OK || compiled == null) unreachable("compile_script failed");

    char[] encoded = image::encode(rt.heap, compiled, {})!!;
    defer mem::free(encoded.ptr);

    Vec{image::ModuleDecl} decls;
    defer decls.free();
    uint before_ok = rt.heap.compiled_func_count;
    bytecode::CompiledFunction* decoded = image::decode(rt.heap, encoded, &decls)!!;
    if (decoded == null || rt.heap.compiled_func_count <= before_ok) unreachable("decode failed");

    // Truncated image must fault and roll back every tracked function and decl.
    uint before_bad = rt.heap.compiled_func_count;
    sz before_decls = decls.len;
    if (catch err = image::decode(rt.heap, encoded[:encoded.len - 8], &decls)) {
        if (err != image::INVALID_IMAGE) unreachable("expected INVALID_IMAGE on truncated bytecode");
    } else {
        unreachable("truncated bytecode must fail");
    }
    if (rt.heap.compiled_func_count != before_bad || decls.len != before_decls) {
        unreachable("failed decode did not roll back heap tracking");
    }
}

fn void ext_buf_release(void* data, void* opaque) {
    uint* released = (uint*)opaque;
    (*released)++;
    if (data != null) mem::free(data);
}

fn void heap_teardown_lifecycle() {
    uint ext_released = 0;
    {
        JsContext context;
        context.create()!!;
        defer context.destroy();

        // Keep ordinary, resizable, detached, transferred, shared, and external
        // ArrayBuffers plus Symbol.for entries and WeakRefs rooted across
        // teardown so Heap.destroy() must release every backing store and
        // registry table cleanly without double-freeing.
        double ok = number(&context,
            "globalThis._ab = new ArrayBuffer(4096);"
            "globalThis._ta = new Uint8Array(1024);"
            "globalThis._rz = new ArrayBuffer(128, { maxByteLength: 512 });"
            "globalThis._rz.resize(256);"
            "globalThis._detached = new ArrayBuffer(64);"
            "globalThis._moved = globalThis._detached.transfer();"
            "globalThis._sab = typeof SharedArrayBuffer === 'function' ? new SharedArrayBuffer(128) : null;"
            "globalThis._ta[0] = 42;"
            "globalThis._s1 = Symbol.for('teardown.a');"
            "globalThis._s2 = Symbol.for('teardown.b');"
            "globalThis._wr = new WeakRef({ ok: 1 });"
            "globalThis._ab.byteLength === 4096 && globalThis._ta[0] === 42"
            "  && globalThis._rz.byteLength === 256"
            "  && globalThis._detached.detached === true && globalThis._moved.byteLength === 64"
            "  && Symbol.keyFor(globalThis._s1) === 'teardown.a'"
            "  && globalThis._wr.deref().ok === 1 ? 1 : 0"
        );
        assert(ok == 1);

        void* c = capi::bk_create();
        if (c == null) unreachable("bk_create failed");
        defer capi::bk_destroy(c);
        char* ext_mem = (char*)mem::malloc(64);
        ulong ext_ab = capi::bk_new_external_array_buffer(c, ext_mem, 64, &ext_buf_release, &ext_released);
        if (ext_ab == 0) unreachable("bk_new_external_array_buffer failed");
        // Keep the external buffer rooted in the global object until destroy().
        String key = "_ext";
        int rc = capi::bk_set_global_property(c, key.ptr, key.len, ext_ab);
        if (rc != capi::BK_OK) unreachable("set _ext failed");
        capi::bk_free_value(c, ext_ab);
    }
    if (ext_released != 1) unreachable("external ArrayBuffer release callback did not run exactly once on destroy");
}

fn void main() {
    // Prime one-time engine globals outside the leak scope, then assert that
    // full runtime/context/module lifecycles release every `mem` allocation.
    {
        JsContext warm;
        warm.create()!!;
        warm.destroy();
    }
    mem::@assert_leak() {
        owned_contexts();
        shared_contexts();
        owned_hooks();
        module_lifecycle();
        async_loader_lifecycle();
        sort_lifecycle();
        call_and_deferred_lifecycle();
        bytecode_image_lifecycle();
        heap_teardown_lifecycle();
    };
    io::printn("C3 context lifecycle: PASS");
}

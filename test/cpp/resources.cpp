/* Binary data, weak handles, GC control, heap limits and context options
 * through bk::. Mirrors test/capi/binary.c, weak.c, gc_control.c and
 * context_options.c. */
#include <cmath>
#include <cstring>
#include <optional>
#include <thread>
#include <utility>
#include "harness.hpp"

static int g_raw_released = 0;
static void* g_raw_data = nullptr;
static void raw_release(void* data, void* opaque) {
    g_raw_data = data;
    ++*static_cast<int*>(opaque);
}

/* A JS expression as a number; NaN when it fails. */
static double num(bk::Context cx, const char* src) {
    auto r = cx.eval(src);
    if (!r) return std::nan("");
    auto d = r.value().to<double>();
    return d ? *d : std::nan("");
}

/* A JS expression's truthiness; false when it fails. */
static bool truthy(bk::Context cx, const char* src) {
    auto r = cx.eval(src);
    return r && r.value().to_bool();
}

TEST(array_buffer_create_copy_and_js_view) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);

    REQUIRE_OK(bk::ArrayBuffer buf, bk::ArrayBuffer::create(cx, 8));
    REQUIRE_OK(bk::Span<uint8_t> bytes, buf.bytes());
    CHECK_EQ(bytes.size, 8u);
    bool zeroed = true;
    for (uint8_t b : bytes) zeroed = zeroed && b == 0;
    CHECK(zeroed);
    bytes[3] = 7;
    CHECK_OK(cx.global().set("ab", buf));
    CHECK_EQ(num(cx, "new Uint8Array(ab)[3]"), 7.0);
    CHECK_EQ(num(cx, "ab.byteLength"), 8.0);
    /* A write from JS is visible in the host bytes. */
    CHECK_EQ(num(cx, "new Uint8Array(ab)[5] = 9"), 9.0);
    REQUIRE_OK(bk::Span<uint8_t> again, buf.bytes());
    CHECK_EQ(again[5], 9);

    const char text[] = "hey";
    REQUIRE_OK(bk::ArrayBuffer copied, bk::ArrayBuffer::copy(cx, text, 3));
    REQUIRE_OK(bk::Span<uint8_t> cb, copied.bytes());
    CHECK_EQ(cb.size, 3u);
    CHECK(std::memcmp(cb.data, text, 3) == 0);
    CHECK_OK(cx.global().set("cp", copied));
    CHECK_EQ(num(cx, "new Uint8Array(cp)[2]"), 121.0);
}

TEST(external_buffers_release) {
    static int lambda_released = 0;
    static int teardown_released = 0;
    lambda_released = 0;
    teardown_released = 0;
    g_raw_released = 0;
    g_raw_data = nullptr;

    static double mesh[4] = {1, 2, 3, 4};
    {
        REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
        REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
        bk::Scope s(cx);

        auto release = [] { lambda_released++; };
        REQUIRE_OK(bk::ArrayBuffer ext, bk::ArrayBuffer::external(cx, mesh, sizeof mesh, release));
        CHECK_OK(cx.global().set("mesh", ext));
        CHECK_EQ(num(cx, "new Float64Array(mesh).reduce((a, b) => a + b)"), 10.0);
        CHECK_EQ(num(cx, "new Float64Array(mesh)[0] = 100"), 100.0);
        CHECK_EQ(mesh[0], 100.0);
        CHECK_EQ(lambda_released, 0);
        CHECK_OK(ext.detach());
        CHECK_EQ(lambda_released, 1);
        CHECK_OK(ext.detach());
        CHECK_EQ(lambda_released, 1);

        /* The raw bk_finalizer overload. */
        REQUIRE_OK(bk::ArrayBuffer raw_ext,
                   bk::ArrayBuffer::external(cx, mesh, sizeof mesh, static_cast<bk_finalizer>(&raw_release),
                                             &g_raw_released));
        CHECK_EQ(g_raw_released, 0);
        CHECK_OK(raw_ext.detach());
        CHECK_EQ(g_raw_released, 1);
        CHECK(g_raw_data == static_cast<void*>(mesh));
    }
    CHECK_EQ(lambda_released, 1);
    CHECK_EQ(g_raw_released, 1);

    /* A buffer still reachable at teardown is released by the runtime. */
    {
        REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
        REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
        bk::Scope s(cx);
        auto release = [] { teardown_released++; };
        REQUIRE_OK(bk::ArrayBuffer kept, bk::ArrayBuffer::external(cx, mesh, sizeof mesh, release));
        CHECK_OK(cx.global().set("kept", kept));
        CHECK_EQ(teardown_released, 0);
    }
    CHECK_EQ(teardown_released, 1);
}

TEST(detach) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);

    REQUIRE_OK(bk::ArrayBuffer buf, bk::ArrayBuffer::create(cx, 16));
    CHECK_OK(cx.global().set("ab", buf));
    CHECK_OK(buf.detach());
    REQUIRE_OK(bk::Span<uint8_t> bytes, buf.bytes());
    CHECK(bytes.data == nullptr);
    CHECK_EQ(bytes.size, 0u);
    CHECK(truthy(cx, "ab.detached === true"));

    REQUIRE_OK(bk::SharedArrayBuffer sab, bk::SharedArrayBuffer::create(cx, 16));
    auto d = sab.detach();
    CHECK(!d);
    CHECK(d.error().code() == bk::Errc::type);
}

TEST(typed_arrays) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);

    /* A fresh Float32Array the host writes and JS reads. */
    REQUIRE_OK(bk::TypedArray<float> f, bk::TypedArray<float>::create(cx, 4));
    REQUIRE_OK(bk::Span<float> fe, f.elements());
    CHECK_EQ(fe.size, 4u);
    fe[0] = 1.5f;
    fe[3] = 2.25f;
    CHECK_OK(cx.global().set("f", f));
    CHECK_EQ(num(cx, "f[0] + f[3] + f.length * 100"), 403.75);

    /* An Int32Array over part of an existing buffer. */
    REQUIRE_OK(bk::ArrayBuffer buf, bk::ArrayBuffer::create(cx, 16));
    REQUIRE_OK(bk::Span<uint8_t> raw, buf.bytes());
    const int32_t vals[2] = {-7, 1234};
    std::memcpy(raw.data + 4, vals, sizeof vals);
    REQUIRE_OK(bk::TypedArray<int32_t> ints, bk::TypedArray<int32_t>::create(cx, buf, 4, 2));
    REQUIRE_OK(bk::Span<int32_t> ie, ints.elements());
    CHECK_EQ(ie.size, 2u);
    CHECK(ie.data == reinterpret_cast<int32_t*>(raw.data + 4));
    CHECK_EQ(ie[0], -7);
    CHECK_EQ(ie[1], 1234);
    CHECK_OK(cx.global().set("ints", ints));
    CHECK(truthy(cx, "ints[1] === 1234 && ints.byteOffset === 4 && ints.buffer.byteLength === 16"));

    /* buffer() returns the backing store. */
    REQUIRE_OK(bk::ArrayBuffer back, ints.buffer());
    REQUIRE_OK(bk::Value js_buf, cx.eval("ints.buffer"));
    CHECK(back.strict_equals(js_buf));
    CHECK(back.strict_equals(buf));

    /* Views are recognized by element type. */
    REQUIRE_OK(bk::Value i32, cx.eval("new Int32Array(4)"));
    CHECK(!i32.as<bk::TypedArray<float>>().has_value());
    CHECK(i32.as<bk::TypedArray<int32_t>>().has_value());
    REQUIRE_OK(bk::Value f32, cx.eval("new Float32Array(2)"));
    CHECK(f32.as<bk::TypedArray<float>>().has_value());
    CHECK(!f32.as<bk::TypedArray<int32_t>>().has_value());

    /* as<ArrayBuffer>() is checked against the object's kind. */
    REQUIRE_OK(bk::Value js_ab, cx.eval("new ArrayBuffer(4)"));
    CHECK(js_ab.as<bk::ArrayBuffer>().has_value());
    REQUIRE_OK(bk::Value plain, cx.eval("({})"));
    CHECK(!plain.as<bk::ArrayBuffer>().has_value());
}

TEST(shared_array_buffers) {
    bk::SharedBlock block;
    {
        REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
        REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
        bk::Scope s(cx);

        REQUIRE_OK(bk::SharedArrayBuffer sab, bk::SharedArrayBuffer::create(cx, 16));
        REQUIRE_OK(bk::Span<uint8_t> bytes, sab.bytes());
        CHECK_EQ(bytes.size, 16u);
        bytes[5] = 9;

        REQUIRE_OK(bk::SharedBlock b, sab.block());
        CHECK_EQ(b.size(), 16u);
        CHECK(b.data() == static_cast<void*>(bytes.data));
        bk::SharedBlock copy = b;
        CHECK(copy.data() == b.data());
        bk::SharedBlock moved = std::move(copy);
        CHECK(!copy);
        CHECK(moved.data() == b.data());
        CHECK_EQ(moved.size(), 16u);
        block = moved;
    }
    /* The block outlives the runtime that made it. */
    CHECK(static_cast<bool>(block));

    REQUIRE_OK(bk::Runtime rt2, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx2, rt2.new_context());
    bk::Scope s2(cx2);
    REQUIRE_OK(bk::SharedArrayBuffer adopted, bk::SharedArrayBuffer::adopt(cx2, block));
    CHECK_OK(cx2.global().set("sab", adopted));
    CHECK_EQ(num(cx2, "new Uint8Array(sab)[5]"), 9.0);

    /* Two workers write different bytes through the raw block pointer while
     * the runtime is idle. */
    uint8_t* p = static_cast<uint8_t*>(block.data());
    std::thread t0([p] {
        for (int i = 0; i < 200; i++) p[0] = static_cast<uint8_t>(p[0] + 1);
    });
    std::thread t1([p] {
        for (int i = 0; i < 200; i++) p[1] = static_cast<uint8_t>(p[1] + 1);
    });
    t0.join();
    t1.join();
    CHECK_EQ(num(cx2, "new Uint8Array(sab)[0]"), 200.0);
    CHECK_EQ(num(cx2, "new Uint8Array(sab)[1]"), 200.0);
    CHECK_EQ(num(cx2, "new Uint8Array(sab)[5]"), 9.0);
}

TEST(weak_handles) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Weak<bk::Object> weak;
    bk::Global<bk::Object> keep;
    {
        bk::Scope s(cx);
        REQUIRE_OK(bk::Object o, bk::Object::create(cx));
        CHECK_OK(o.set("x", 42));
        REQUIRE_OK(bk::Weak<bk::Object> w, bk::Weak<bk::Object>::create(o));
        weak = std::move(w);
        keep = o.persist<bk::Object>();
    }
    {
        bk::Scope s(cx);
        auto live = weak.get(cx);
        CHECK(live.has_value());
        if (live) CHECK_EQ(live->get_as<int>("x").value(), 42);
    }
    keep.reset();
    rt.gc();
    {
        bk::Scope s(cx);
        CHECK(!weak.get(cx).has_value());
    }
    {
        bk::Scope s(cx);
        REQUIRE_OK(bk::Value one, cx.eval("1"));
        auto bad = bk::Weak<bk::Value>::create(one);
        CHECK(!bad);
        CHECK(bad.error().code() == bk::Errc::type);
    }
}

TEST(gc_control) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);

    uint32_t cycles = rt.heap_stats().gc_cycles;
    rt.gc();
    CHECK(rt.heap_stats().gc_cycles > cycles);

    /* Stepping finishes a cycle in bounded slices. */
    CHECK_OK(cx.eval("globalThis.junk = []; for (let i = 0; i < 50000; i++) junk.push({ i }); junk = null"));
    cycles = rt.heap_stats().gc_cycles;
    int steps = 0;
    bool busy = true;
    while (busy && steps < 10000) {
        busy = rt.gc_step(200000);
        steps++;
    }
    CHECK(!busy);
    CHECK(steps < 10000);
    CHECK(rt.heap_stats().gc_cycles > cycles);

    /* Inhibition nests: inner scopes do not lift the outer one. */
    {
        bk::GcInhibit outer(rt);
        {
            bk::GcInhibit inner(rt);
        }
        cycles = rt.heap_stats().gc_cycles;
        CHECK_OK(cx.eval("{ for (let i = 0; i < 100000; i++) ({ i }) }"));
        CHECK_EQ(rt.heap_stats().gc_cycles, cycles);
        /* An explicit collection still runs while inhibited. */
        rt.gc();
        CHECK(rt.heap_stats().gc_cycles > cycles);
    }

    /* External memory is counted up and back down. */
    uint64_t base = rt.heap_stats().external_bytes;
    rt.add_external_memory(1 << 20);
    CHECK_EQ(rt.heap_stats().external_bytes, base + (1u << 20));
    rt.add_external_memory(-(1 << 20));
    CHECK_EQ(rt.heap_stats().external_bytes, base);
}

TEST(heap_limit) {
    bk::RuntimeOptions options;
    options.heap_limit = 32ull * 1024 * 1024;
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create(options));
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    CHECK_EQ(rt.heap_stats().heap_limit, options.heap_limit);

    /* Bounded by the 32 MiB limit. The script sees a RangeError first, which
     * the catch swallows; the termination that follows is uncatchable. */
    auto r = cx.eval("let a = []; try { for (;;) a.push({ x: new Array(100) }) } catch (e) { 'caught' }");
    CHECK(!r);
    CHECK(r.error().code() == bk::Errc::nomem);
    CHECK_EQ(num(cx, "1 + 1"), 2.0);

    /* A runtime without a byte count has no limit to set. */
    REQUIRE_OK(bk::Runtime plain, bk::Runtime::create());
    auto set = plain.set_heap_limit(1 << 20);
    CHECK(!set);
    CHECK(set.error().code() == bk::Errc::invalid);
}

TEST(context_options) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());

    bk::ContextOptions locked_options;
    locked_options.flags = BK_CONTEXT_NO_EVAL;
    REQUIRE_OK(bk::OwnedContext locked, rt.new_context(locked_options));
    bk::Scope s(locked);

    auto r = locked.eval("eval('1')");
    CHECK(!r);
    CHECK(r.error().code() == bk::Errc::thrown);
    char buf[256];
    r.error().describe(buf, sizeof buf);
    CHECK(std::strstr(buf, "EvalError") != nullptr);
    CHECK_EQ(num(locked, "1"), 1.0);

    /* Unknown flag bits are refused. */
    bk::ContextOptions bad;
    bad.flags = 0x80;
    auto unknown = rt.new_context(bad);
    CHECK(!unknown);
    CHECK(unknown.error().code() == bk::Errc::invalid);
}

int main() {
    RUN(array_buffer_create_copy_and_js_view);
    RUN(external_buffers_release);
    RUN(detach);
    RUN(typed_arrays);
    RUN(shared_array_buffers);
    RUN(weak_handles);
    RUN(gc_control);
    RUN(heap_limit);
    RUN(context_options);
    TEST_MAIN_END();
}

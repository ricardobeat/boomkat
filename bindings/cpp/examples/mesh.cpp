// Host memory shared with JS without copying, a Watchdog, and a heap limit.
#include <chrono>
#include <cstdio>
#include <vector>
#include "boomkat.hpp"
#include "boomkat_std.hpp"

static int fail(const bk::Error& e) {
    char buf[256];
    e.describe(buf, sizeof buf);
    std::fprintf(stderr, "error: %s\n", buf);
    return 1;
}

/* JS doubles the host's vertices in place. The runtime is destroyed on return,
 * which runs the buffer's release callback. */
static int scale_in_place(std::vector<float>& verts, int& released) {
    auto rt = bk::Runtime::create();
    if (!rt) return fail(rt.error());
    auto cx = rt->new_context();
    if (!cx) return fail(cx.error());
    bk::Scope s(*cx);
    auto buf = bk::ArrayBuffer::external(*cx, verts.data(), verts.size() * sizeof(float),
                                         [&released] { released++; });
    if (!buf) return fail(buf.error());
    auto view = bk::TypedArray<float>::create(*cx, *buf, 0, verts.size());
    if (!view) return fail(view.error());
    if (auto r = cx->global().set("verts", *view); !r) return fail(r.error());
    if (auto r = cx->eval("for (let i = 0; i < verts.length; i++) verts[i] *= 2"); !r) return fail(r.error());
    return 0;
}

static int interrupt_runaway() {
    auto rt = bk::Runtime::create();
    if (!rt) return fail(rt.error());
    auto cx = rt->new_context();
    if (!cx) return fail(cx.error());
    bk::Scope s(*cx);
    bk::Watchdog dog(*rt, std::chrono::milliseconds(50));
    auto r = cx->eval("for (;;) {}");
    if (r) { std::fprintf(stderr, "expected an interrupt\n"); return 1; }
    if (r.error().code() != bk::Errc::interrupted) return fail(r.error());
    std::printf("watchdog interrupted the loop: fired=%d\n", dog.fired() ? 1 : 0);
    rt->clear_interrupt();
    return 0;
}

static int heap_limited() {
    bk::RuntimeOptions options;
    options.heap_limit = 16ull * 1024 * 1024;
    auto rt = bk::Runtime::create(options);
    if (!rt) return fail(rt.error());
    auto cx = rt->new_context();
    if (!cx) return fail(cx.error());
    bk::Scope s(*cx);
    auto r = cx->eval("let a = []; try { for (;;) a.push(new Array(1000)) } catch (e) {}");
    if (r) { std::fprintf(stderr, "expected the heap limit to fail\n"); return 1; }
    if (r.error().code() != bk::Errc::nomem) return fail(r.error());
    std::printf("heap limit hit: nomem\n");
    auto sum = cx->eval("1 + 1").and_then([](bk::Value v) { return v.to<double>(); });
    if (!sum) return fail(sum.error());
    std::printf("runtime still works: 1 + 1 = %g\n", *sum);
    return 0;
}

int main() {
    std::vector<float> verts = {-1, -1, 1, -1, 0, 1};
    int released = 0;
    if (int rc = scale_in_place(verts, released)) return rc;
    std::printf("host vertices:");
    for (float v : verts) std::printf(" %g", v);
    std::printf("\nrelease ran %d time(s) after the runtime was destroyed\n", released);
    if (released != 1) return 1;
    if (int rc = interrupt_runaway()) return rc;
    return heap_limited();
}

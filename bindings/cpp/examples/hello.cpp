#include <cstdio>
#include "boomkat.hpp"
static double add(double a, double b) { return a + b; }
static int fail(const bk::Error& e) { char b[256]; e.describe(b, sizeof b); std::fprintf(stderr, "error: %s\n", b); return 1; }
int main() {
    auto rt = bk::Runtime::create(); if (!rt) return fail(rt.error());
    auto cx = rt->new_context(); if (!cx) return fail(cx.error());
    bk::Scope s(*cx);
    if (auto r = cx->global().set("add", bk::function<&add>(*cx, "add")); !r) return fail(r.error());
    auto n = cx->eval("add(1, 2)").and_then([](bk::Value v) { return v.to<double>(); });
    if (!n) return fail(n.error());
    std::printf("add(1, 2) = %g\n", *n);
    return 0;
}

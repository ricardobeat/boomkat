// A bound C++ class, a JS subclass of it, and a bound print() function.
#include <cmath>
#include <cstdio>
#include <string>
#include "boomkat.hpp"
#include "boomkat_std.hpp"

struct Vec3 {
    double x, y, z;
    Vec3(double a, double b, double c) : x(a), y(b), z(c) {}
    double length() const { return std::sqrt(x * x + y * y + z * z); }
    /* Returns by value: the binding wraps the result in a new instance. */
    Vec3 scaled(double k) const { return Vec3(x * k, y * k, z * k); }
};

static int fail(const bk::Error& e) {
    char buf[256];
    e.describe(buf, sizeof buf);
    std::fprintf(stderr, "error: %s\n", buf);
    return 1;
}

static const char* kScript = R"JS(
class V4 extends Vec3 {
    constructor(x, y, z, w) { super(x, y, z); this.w = w; }
    show() { return `V4(${this.x}, ${this.y}, ${this.z}, w=${this.w})`; }
}
const a = new Vec3(1, 2, 2);
print(`length ${a.length()}`);
const b = a.scaled(3);
print(`scaled (${b.x}, ${b.y}, ${b.z}) instanceof Vec3: ${b instanceof Vec3}`);
const v4 = new V4(3, 0, 4, 9);
print(`${v4.show()} length ${v4.length()} instanceof Vec3: ${v4 instanceof Vec3}`);
)JS";

int main() {
    auto rt = bk::Runtime::create();
    if (!rt) return fail(rt.error());
    auto cx = rt->new_context();
    if (!cx) return fail(cx.error());
    bk::Scope s(*cx);

    auto vec3 = bk::Class<Vec3>(*cx, "Vec3")
                    .constructor<double, double, double>()
                    .field<&Vec3::x>("x")
                    .field<&Vec3::y>("y")
                    .field<&Vec3::z>("z")
                    .method<&Vec3::length>("length")
                    .method<&Vec3::scaled>("scaled")
                    .build();
    if (!vec3) return fail(vec3.error());
    if (auto r = cx->global().set("Vec3", vec3->constructor()); !r) return fail(r.error());

    auto printer = bk::closure(*cx, "print", [](std::string line) { std::printf("%s\n", line.c_str()); });
    if (!printer) return fail(printer.error());
    if (auto r = cx->global().set("print", *printer); !r) return fail(r.error());

    if (auto r = cx->eval(kScript); !r) return fail(r.error());
    return 0;
}

/* bk::Class: constructors, fields, methods, policies, inheritance, detach,
 * deferred finalizers, tracing and the wrapper cache. */
#include <memory>
#include "harness.hpp"

static int vec_alive = 0;

struct Vec3 {
    double x = 0, y = 0, z = 0;
    Vec3() { vec_alive++; }
    Vec3(double a, double b, double c) : x(a), y(b), z(c) { vec_alive++; }
    Vec3(const Vec3& o) : x(o.x), y(o.y), z(o.z) { vec_alive++; }
    ~Vec3() { vec_alive--; }
    double length() const { return x * x + y * y + z * z; }
    Vec3 scaled(double k) const { return Vec3(x * k, y * k, z * k); }
    void add(const Vec3& o) { x += o.x; y += o.y; z += o.z; }
};
static double sum_of(const Vec3& v) { return v.x + v.y + v.z; }

static bool eval_true(bk::Context cx, const char* src) {
    auto r = cx.eval(src);
    if (!r) {
        char buf[256];
        r.error().describe(buf, sizeof buf);
        std::fprintf(stderr, "  eval failed: %s\n    %s\n", buf, src);
        return false;
    }
    return r->to_bool();
}

static bk::Result<bk::ClassHandle<Vec3>> bind_vec3(bk::Context cx) {
    return bk::Class<Vec3>(cx, "Vec3")
        .constructor<double, double, double>()
        .field<&Vec3::x>("x")
        .field<&Vec3::y>("y")
        .field<&Vec3::z>("z")
        .method<&Vec3::length>("length")
        .method<&Vec3::scaled>("scaled")
        .method<&Vec3::add>("add")
        .method<&sum_of>("sum")
        .static_method("zero", [] { return 0.0; })
        .to_string_tag("Vec3")
        .build();
}

TEST(vec3_basics) {
    vec_alive = 0;
    {
        REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
        REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
        bk::Scope s(cx);
        REQUIRE_OK(auto vec3, bind_vec3(cx));
        CHECK_OK(cx.global().set("Vec3", vec3.constructor()));
        CHECK(eval_true(cx, "const v = new Vec3(1, 2, 3); v.x === 1 && v.length() === 14"));
        CHECK(eval_true(cx, "v.y = 5; v.y === 5 && v.sum() === 9"));
        CHECK(eval_true(cx, "const w = v.scaled(2); w instanceof Vec3 && w.z === 6 && w !== v"));
        CHECK(eval_true(cx, "v.add(w); v.x === 3"));
        CHECK(eval_true(cx, "Object.prototype.toString.call(v) === '[object Vec3]'"));
        CHECK(eval_true(cx, "Vec3.zero() === 0 && Vec3.length === 3"));
        CHECK(eval_true(cx, "try { Vec3.prototype.length.call({}); false } catch (e) { e instanceof TypeError }"));
        CHECK(eval_true(cx, "try { v.add(1); false } catch (e) { e instanceof TypeError }"));
        CHECK(eval_true(cx, "try { new Vec3('a', 1, 2); true } catch (e) { false }"));
        /* A JS subclass. */
        CHECK(eval_true(cx, "class V4 extends Vec3 { constructor() { super(1, 1, 1); this.w = 1; } "
                            "total() { return this.sum() + this.w; } }"
                            "const v4 = new V4(); v4.total() === 4 && v4 instanceof Vec3"));
        /* Unwrap from C++. */
        REQUIRE_OK(bk::Value vv, cx.eval("v"));
        REQUIRE_OK(Vec3* p, bk::unwrap<Vec3>(vv));
        CHECK_EQ(p->x, 3.0);
        REQUIRE_OK(bk::Object made, bk::make_instance<Vec3>(cx, 7.0, 8.0, 9.0));
        CHECK_EQ(made.get_as<double>("y").value(), 8.0);
        CHECK(vec_alive > 0);
    }
    /* Every owned instance was destroyed at teardown. */
    CHECK_EQ(vec_alive, 0);
}

TEST(collected_instances_are_destroyed) {
    vec_alive = 0;
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    {
        bk::Scope s(cx);
        REQUIRE_OK(auto vec3, bind_vec3(cx));
        CHECK_OK(cx.global().set("Vec3", vec3.constructor()));
        CHECK_OK(cx.eval("for (let i = 0; i < 100; i++) new Vec3(i, i, i)"));
    }
    rt.gc();
    CHECK_EQ(vec_alive, 0);
}

struct Shape {
    virtual ~Shape() = default;
    virtual double area() const = 0;
    int id = 7;
};
struct Square : Shape {
    double side;
    explicit Square(double s) : side(s) {}
    double area() const override { return side * side; }
};
static double area_of(Shape* s) { return s->area(); }
static int id_of(const Shape& s) { return s.id; }

TEST(inheritance_and_brand_checks) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    REQUIRE_OK(auto shape, bk::Class<Shape>(cx, "Shape").method<&Shape::area>("area").build());
    REQUIRE_OK(auto square, bk::Class<Square>(cx, "Square").inherits<Shape>().constructor<double>().build());
    CHECK_OK(cx.global().set("Shape", shape.constructor()));
    CHECK_OK(cx.global().set("Square", square.constructor()));
    CHECK_OK(cx.global().set("areaOf", bk::function<&area_of>(cx, "areaOf")));
    CHECK_OK(cx.global().set("idOf", bk::function<&id_of>(cx, "idOf")));
    CHECK(eval_true(cx, "const q = new Square(3); q.area() === 9 && q instanceof Shape"));
    CHECK(eval_true(cx, "areaOf(q) === 9 && idOf(q) === 7"));
    CHECK(eval_true(cx, "try { new Shape(); false } catch (e) { e instanceof TypeError }"));
    REQUIRE_OK(bk::Value msg, cx.eval("try { areaOf({}) } catch (e) { e.message }"));
    char buf[128];
    msg.describe(buf, sizeof buf);
    CHECK(std::strstr(buf, "areaOf: argument 1") != nullptr);
}

struct Node {
    int value = 0;
    Node() = default;
    explicit Node(int v) : value(v) {}
};

TEST(borrowed_and_detach) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    REQUIRE_OK(auto node, (bk::Class<Node, bk::borrowed>(cx, "Node").field<&Node::value>("value").build()));
    (void)node;
    Node host(5);
    bk::WrapperCache<Node> cache;
    REQUIRE_OK(bk::Object w1, cache.get(cx, &host));
    REQUIRE_OK(bk::Object w2, cache.get(cx, &host));
    CHECK(w1.strict_equals(w2));
    CHECK_EQ(cache.size(), 1u);
    CHECK_OK(cx.global().set("n", w1));
    CHECK(eval_true(cx, "n.value === 5"));
    host.value = 6;
    CHECK(eval_true(cx, "n.value === 6"));
    cache.forget(&host);
    CHECK_EQ(cache.size(), 0u);
    REQUIRE_OK(bk::Value msg, cx.eval("try { n.value } catch (e) { e.message }"));
    char buf[128];
    msg.describe(buf, sizeof buf);
    CHECK(std::strstr(buf, "Node object has been destroyed") != nullptr);
    /* Many objects through the cache, to exercise growth. */
    static Node many[100];
    for (auto& n : many) CHECK_OK(cache.get(cx, &n));
    CHECK_EQ(cache.size(), 100u);
    for (int i = 0; i < 50; i++) cache.forget(&many[i]);
    CHECK_EQ(cache.size(), 50u);
    CHECK(cache.contains(&many[60]));
    CHECK(!cache.contains(&many[10]));
    cache.clear();
}

static int shared_alive = 0;
struct Texture {
    int w;
    explicit Texture(int width) : w(width) { shared_alive++; }
    ~Texture() { shared_alive--; }
};

TEST(shared_policy) {
    shared_alive = 0;
    auto host_ref = std::make_shared<Texture>(64);
    {
        REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
        REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
        bk::Scope s(cx);
        using Policy = bk::shared<std::shared_ptr<Texture>>;
        REQUIRE_OK(auto tex, (bk::Class<Texture, Policy>(cx, "Texture")
                                  .constructor<int>()
                                  .field<&Texture::w>("width")
                                  .build()));
        CHECK_OK(cx.global().set("Texture", tex.constructor()));
        REQUIRE_OK(bk::Object wrapped, (bk::wrap_shared<Texture>(cx, host_ref)));
        CHECK_OK(cx.global().set("t", wrapped));
        CHECK(eval_true(cx, "t.width === 64 && new Texture(8).width === 8"));
        CHECK_EQ(host_ref.use_count(), 2);
    }
    CHECK_EQ(host_ref.use_count(), 1);
    host_ref.reset();
    CHECK_EQ(shared_alive, 0);
}

static int deferred_alive = 0;
struct Handle {
    Handle() { deferred_alive++; }
    ~Handle() { deferred_alive--; }
};

TEST(deferred_finalizers) {
    deferred_alive = 0;
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    {
        bk::Scope s(cx);
        REQUIRE_OK(auto h, bk::Class<Handle>(cx, "Handle").defer_finalization().constructor<>().build());
        CHECK_OK(cx.global().set("Handle", h.constructor()));
        CHECK_OK(cx.eval("for (let i = 0; i < 10; i++) new Handle(); 0"));
    }
    rt.gc();
    CHECK_EQ(deferred_alive, 10);
    CHECK_EQ(rt.run_finalizers(), 10u);
    CHECK_EQ(deferred_alive, 0);
}

/* A payload that points back at its own wrapper through a Traced slot: the
 * cycle must still be collected. */
static int traced_alive = 0;
struct Holder {
    bk::Traced<bk::Value> ref;
    Holder() { traced_alive++; }
    ~Holder() { traced_alive--; }
    void trace(bk::Tracer& t) const { t(ref); }
};
static bk::Result<void> hold(bk::This<Holder*> self, bk::Value v) { return self.get()->ref.set(v); }
static bk::Value held(bk::Context cx, bk::This<Holder*> self) { return self.get()->ref.get(cx); }

TEST(traced_cycle_is_collected) {
    traced_alive = 0;
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    {
        bk::Scope s(cx);
        REQUIRE_OK(auto h, bk::Class<Holder>(cx, "Holder")
                               .constructor<>()
                               .method<&hold>("hold")
                               .method<&held>("held")
                               .build());
        CHECK_OK(cx.global().set("Holder", h.constructor()));
        CHECK(eval_true(cx, "const keep = new Holder(); keep.hold({tag: 'kept'}); true"));
        CHECK_OK(cx.eval("for (let i = 0; i < 20; i++) { const x = new Holder(); x.hold(x); }"));
    }
    rt.gc();
    rt.gc();
    CHECK_EQ(traced_alive, 1);
    bk::Scope s(cx);
    /* The traced value of the live holder survived collection. */
    CHECK(eval_true(cx, "keep.held().tag === 'kept'"));
}

static bk::Value dyn_get(bk::CallInfo& info) {
    return bk::Value::boolean(info.context(), info.this_value().is_object());
}

TEST(dynamic_class) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    bk::DynamicClass dc(cx, "Dyn");
    REQUIRE_OK(bk_class id, dc.build());
    CHECK(id != 0);
    CHECK_OK(dc.method("isObj", [](bk::CallInfo& info) { return dyn_get(info); }));
    REQUIRE_OK(bk::Value inst, bk::detail::wrap<bk::Value>(cx, bk_new_instance(cx, id, &traced_alive, 0)));
    CHECK_EQ(dc.payload(inst), static_cast<void*>(&traced_alive));
    CHECK_OK(cx.global().set("d", inst));
    CHECK(eval_true(cx, "d.isObj() === true"));
}

int main() {
    RUN(vec3_basics);
    RUN(collected_instances_are_destroyed);
    RUN(inheritance_and_brand_checks);
    RUN(borrowed_and_detach);
    RUN(shared_policy);
    RUN(deferred_finalizers);
    RUN(traced_cycle_is_collected);
    RUN(dynamic_class);
    TEST_MAIN_END();
}

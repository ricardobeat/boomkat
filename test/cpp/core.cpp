/* Core bk:: API: runtime, contexts, scopes, locals, globals, errors,
 * conversions and bound functions. */
#include <stdexcept>
#include <string>
#include "harness.hpp"

static double add3(double a, double b, double c) { return a + b + c; }
static int32_t to_i32(int32_t v) { return v; }
static uint32_t to_u32(uint32_t v) { return v; }
static int64_t to_i64(int64_t v) { return v; }
static uint64_t to_u64(uint64_t v) { return v; }
static bool negate(bool b) { return !b; }
static int opt_or(std::optional<int> v) { return v ? *v : -1; }
static double strict_num(bk::Strict<double> v) { return v.value; }
static unsigned count_rest(bk::Rest<int> rest) {
    unsigned n = 0;
    for (unsigned i = 0; i < rest.size(); i++) n += static_cast<unsigned>(rest.at(i).value());
    return n;
}
static bk::Value echo_this(bk::CallInfo& info) { return info.this_value(); }
static bk::Result<int> may_fail(bk::Context cx, int v) {
    if (v < 0) return cx.range_error("negative");
    return v * 2;
}
static void nothing() {}
enum class Color : int { red = 1, green = 2 };
static Color next_color(Color c) { return c == Color::red ? Color::green : Color::red; }

static uint32_t live(bk::Context cx) { return cx.runtime().heap_stats().live_handles; }

TEST(runtime_and_eval) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    REQUIRE_OK(bk::Value v, cx.eval("1 + 2"));
    CHECK(v.is_number());
    CHECK_EQ(v.to<int>().value(), 3);
    auto bad = cx.eval("throw new TypeError('boom')");
    CHECK(!bad);
    CHECK(bad.error().code() == bk::Errc::thrown);
    char buf[128];
    bad.error().describe(buf, sizeof buf);
    CHECK(std::strstr(buf, "boom") != nullptr);
    auto syn = cx.eval("let = = 1");
    CHECK(!syn);
    CHECK(syn.error().code() == bk::Errc::syntax);
    REQUIRE_OK(bk::Value strict, cx.eval("(function(){ return this === undefined; })()", "s.js", true));
    CHECK(strict.to_bool());
}

TEST(scopes) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    uint32_t before = live(cx);
    {
        bk::Scope s(cx);
        for (int i = 0; i < 1000; i++) (void)bk::Object::create(cx);
    }
    CHECK_EQ(live(cx), before);
    bk::Scope outer(cx);
    bk::Object kept = [&] {
        bk::Scope inner(cx);
        bk::Object o = bk::Object::create(cx).value();
        (void)o.set("x", 7);
        return inner.escape(o);
    }();
    CHECK_EQ(kept.get_as<int>("x").value(), 7);
}

TEST(objects) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    REQUIRE_OK(bk::Object o, bk::Object::create(cx));
    CHECK_OK(o.set("a", 1));
    CHECK_OK(o.set("b", "two"));
    CHECK_OK(o.set(0u, true));
    CHECK_EQ(o.has("a").value(), true);
    CHECK_EQ(o.get_as<std::optional<int>>("missing").value().has_value(), false);
    CHECK_EQ(o.define("frozen", 5, bk::Prop::enumerable).value(), true);
    CHECK_OK(cx.global().set("o", o));
    REQUIRE_OK(bk::Value w, cx.eval("'use strict'; try { o.frozen = 1; 'no' } catch (e) { e.name }"));
    char buf[64];
    w.describe(buf, sizeof buf);
    CHECK(std::strstr(buf, "TypeError") != nullptr);
    REQUIRE_OK(bk::Array keys, o.keys());
    CHECK_EQ(keys.length().value(), 4u);
    CHECK_EQ(o.remove("a").value(), true);
    bk::Atom key(cx, "b");
    REQUIRE_OK(bk::Value b, o.get(key));
    CHECK(b.is_string());
    REQUIRE_OK(bk::Array arr, bk::Array::create(cx));
    CHECK_OK(arr.push(1));
    CHECK_OK(arr.push(2.5));
    CHECK_EQ(arr.length().value(), 2u);
    CHECK(arr.as<bk::Array>().has_value());
    CHECK(!bk::Value(o).as<bk::Function>().has_value());
}

TEST(functions_and_conversions) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    bk::Object g = cx.global();
    CHECK_OK(g.set("add3", bk::function<&add3>(cx, "add3")));
    CHECK_OK(g.set("i32", bk::function<&to_i32>(cx, "i32")));
    CHECK_OK(g.set("u32", bk::function<&to_u32>(cx, "u32")));
    CHECK_OK(g.set("i64", bk::function<&to_i64>(cx, "i64")));
    CHECK_OK(g.set("u64", bk::function<&to_u64>(cx, "u64")));
    CHECK_OK(g.set("negate", bk::function<&negate>(cx, "negate")));
    CHECK_OK(g.set("optOr", bk::function<&opt_or>(cx, "optOr")));
    CHECK_OK(g.set("strictNum", bk::function<&strict_num>(cx, "strictNum")));
    CHECK_OK(g.set("countRest", bk::function<&count_rest>(cx, "countRest")));
    CHECK_OK(g.set("echoThis", bk::function<&echo_this>(cx, "echoThis")));
    CHECK_OK(g.set("mayFail", bk::function<&may_fail>(cx, "mayFail")));
    CHECK_OK(g.set("nothing", bk::function<&nothing>(cx, "nothing")));
    CHECK_OK(g.set("nextColor", bk::function<&next_color>(cx, "nextColor")));

    auto num = [&](const char* src) { return cx.eval(src).value().to<double>().value(); };
    CHECK_EQ(num("add3(1, 2, 3)"), 6.0);
    CHECK_EQ(num("add3.length"), 3.0);
    CHECK_EQ(num("i32(4294967295)"), -1.0);
    CHECK_EQ(num("u32(-1)"), 4294967295.0);
    CHECK_EQ(num("i32(NaN)"), 0.0);
    CHECK_EQ(num("i64(-5)"), -5.0);
    CHECK(cx.eval("typeof i64(2n ** 62n) === 'bigint'").value().to_bool());
    CHECK(cx.eval("u64(2n ** 64n - 1n) === 2n ** 64n - 1n").value().to_bool());
    CHECK(cx.eval("try { i64(2 ** 60) ; false } catch (e) { e instanceof RangeError }").value().to_bool());
    CHECK(cx.eval("negate(0) === true").value().to_bool());
    CHECK_EQ(num("optOr()"), -1.0);
    CHECK_EQ(num("optOr(4)"), 4.0);
    CHECK_EQ(num("strictNum(1.5)"), 1.5);
    CHECK_EQ(num("countRest(1, 2, 3)"), 6.0);
    CHECK_EQ(num("countRest.length"), 0.0);
    CHECK_EQ(num("nextColor(1)"), 2.0);
    CHECK(cx.eval("const t = {}; echoThis.call(t) === t").value().to_bool());
    CHECK(cx.eval("nothing() === undefined").value().to_bool());
    CHECK_EQ(num("mayFail(4)"), 8.0);
    REQUIRE_OK(bk::Value msg, cx.eval("try { mayFail(-1) } catch (e) { e.constructor.name + ': ' + e.message }"));
    char buf[128];
    msg.describe(buf, sizeof buf);
    CHECK(std::strstr(buf, "RangeError: negative") != nullptr);
    REQUIRE_OK(bk::Value msg2, cx.eval("try { strictNum('1') } catch (e) { e.message }"));
    msg2.describe(buf, sizeof buf);
    CHECK(std::strstr(buf, "strictNum: argument 1: expected number") != nullptr);

    /* Calling JS from C++. */
    REQUIRE_OK(bk::Value fv, cx.eval("(function (a, b) { return this.k + a + b; })"));
    bk::Function f = fv.as<bk::Function>().value();
    REQUIRE_OK(bk::Object self, bk::Object::create(cx));
    CHECK_OK(self.set("k", 100));
    CHECK_EQ(f.call_with(self, 1, 2).value().to<int>().value(), 103);
    REQUIRE_OK(bk::Value ctor, cx.eval("(class P { constructor(x) { this.x = x; } })"));
    REQUIRE_OK(bk::Object inst, ctor.as<bk::Function>()->construct(9));
    CHECK_EQ(inst.get_as<int>("x").value(), 9);
}

TEST(no_registry_growth_per_call) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    {
        bk::Scope s(cx);
        CHECK_OK(cx.global().set("add3", bk::function<&add3>(cx, "add3")));
    }
    uint32_t before = live(cx);
    {
        bk::Scope s(cx);
        REQUIRE_OK(bk::Value v, cx.eval("let t = 0; for (let i = 0; i < 1000; i++) t += add3(i, 1, 2); t"));
        CHECK_EQ(v.to<double>().value(), 502500.0);
    }
    CHECK_EQ(live(cx), before);
}

TEST(closures) {
    static int destroyed = 0;
    struct Counter {
        int* hits;
        int operator()(int add) const { return *hits += add; }
        Counter(int* h) : hits(h) {}
        Counter(const Counter& o) : hits(o.hits) {}
        ~Counter() { destroyed++; }
    };
    int hits = 0;
    destroyed = 0;
    {
        REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
        REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
        bk::Scope s(cx);
        CHECK_OK(cx.global().set("bump", bk::closure(cx, "bump", Counter(&hits))));
        int before = destroyed;
        CHECK_OK(cx.eval("bump(2); bump(3)"));
        CHECK_EQ(hits, 5);
        CHECK_EQ(destroyed, before);
        std::string prefix = "hi ";
        auto greet = bk::closure(cx, "greet", [prefix](bk::String name) -> bk::Result<bk::String> {
            char buf[64];
            BK_TRY_ASSIGN(size_t n, name.utf8(buf, sizeof buf));
            std::string out = prefix + std::string(buf, n);
            return bk::String::from_utf8(name.context(), out);
        });
        CHECK_OK(cx.global().set("greet", greet));
        REQUIRE_OK(bk::Value r, cx.eval("greet('bob')"));
        char buf[32];
        CHECK_EQ(r.as<bk::String>()->utf8(buf, sizeof buf).value(), 6u);
        CHECK_STR(buf, "hi bob");
        destroyed = 0;
    }
    /* Counter's finalizer ran exactly once at teardown. */
    CHECK_EQ(destroyed, 1);
}

TEST(globals_and_errors) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Global<bk::Object> kept;
    bk::Error saved;
    {
        bk::Scope s(cx);
        REQUIRE_OK(bk::Object o, bk::Object::create(cx));
        CHECK_OK(o.set("v", 42));
        kept = o.persist<bk::Object>();
        auto r = cx.eval("null.x");
        CHECK(!r);
        saved = std::move(r).error();
    }
    rt.gc();
    {
        bk::Scope s(cx);
        CHECK_EQ(kept.get(cx).get_as<int>("v").value(), 42);
        bk::Global<bk::Object> copy = kept;
        CHECK(copy.get().strict_equals(kept.get()));
        bk::Global<bk::Value> exc = saved.exception();
        CHECK(exc.get().is_object());
        char buf[128];
        saved.describe(buf, sizeof buf);
        CHECK(std::strstr(buf, "TypeError") != nullptr);
    }
    kept.reset();
    saved = bk::Error();
}

static bk::Result<int> chain(bk::Context cx, const char* src) {
    BK_TRY_ASSIGN(bk::Value v, cx.eval(src));
    BK_TRY_ASSIGN(int n, v.to<int>());
    BK_TRY(cx.eval("1"));
    return n + 1;
}

TEST(result_macros) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    CHECK_EQ(chain(cx, "41").value(), 42);
    auto bad = chain(cx, "throw 1");
    CHECK(!bad);
    CHECK_EQ(std::move(bad).value_or(-1), -1);
    int fallback = 0;
    BK_TRY_OR(cx.eval("throw 2"), fallback = 7);
    CHECK_EQ(fallback, 7);
    auto mapped = cx.eval("20").map([](bk::Value v) { return v.to<int>().value() + 1; });
    CHECK_EQ(mapped.value(), 21);
}

#if BOOMKAT_CPP_EXCEPTIONS
TEST(exceptions_mode) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    bool caught = false;
    try {
        (void)cx.eval("throw new Error('x')").value();
    } catch (const bk::JsError& e) {
        caught = std::strstr(e.what(), "x") != nullptr;
    }
    CHECK(caught);
    CHECK_OK(cx.global().set("thrower", bk::closure(cx, "thrower", [](int k) -> int {
        if (k == 1) throw std::runtime_error("std failure");
        if (k == 2) throw 5;
        return k;
    })));
    REQUIRE_OK(bk::Value m, cx.eval("try { thrower(1) } catch (e) { e.message }"));
    char buf[64];
    m.describe(buf, sizeof buf);
    CHECK(std::strstr(buf, "std failure") != nullptr);
    CHECK(cx.eval("try { thrower(2); false } catch (e) { e instanceof Error }").value().to_bool());
}
#endif

TEST(interrupt_is_uncatchable) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    int polls = 0;
    CHECK_OK(rt.on_interrupt([&polls](bk::RuntimeRef) { return ++polls > 3; }));
    CHECK_OK(cx.global().set("nested", bk::closure(cx, "nested", [](bk::Context c) -> bk::Result<bk::Value> {
        return c.eval("for (;;) {}");
    })));
    auto r = cx.eval("try { nested() } catch (e) { 'caught' }");
    CHECK(!r);
    CHECK(r.error().code() == bk::Errc::interrupted);
    rt.clear_interrupt_handler();
    rt.clear_interrupt();
    CHECK_OK(cx.eval("1"));
}

int main() {
    RUN(runtime_and_eval);
    RUN(scopes);
    RUN(objects);
    RUN(functions_and_conversions);
    RUN(no_registry_growth_per_call);
    RUN(closures);
    RUN(globals_and_errors);
    RUN(result_macros);
#if BOOMKAT_CPP_EXCEPTIONS
    RUN(exceptions_mode);
#endif
    RUN(interrupt_is_uncatchable);
    TEST_MAIN_END();
}

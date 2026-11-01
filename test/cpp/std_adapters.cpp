/* STL adapters: boomkat_std.hpp conversions, the reference event loop and the
 * watchdog. */
#include "boomkat_std.hpp"
#include "harness.hpp"
#include <chrono>
#include <cstring>
#include <map>
#include <string>
#include <thread>
#include <tuple>
#include <utility>
#include <vector>

/* ---- bound functions ----------------------------------------------------------- */

static std::string echo_string(std::string s) { return s; }
static std::u16string echo_u16(std::u16string s) { return s; }
static std::u16string make_u16_pair() { return std::u16string(u"\U0001F600"); }
static std::u16string make_u16_lone() { return std::u16string(1, char16_t(0xD800)); }

static std::vector<int> double_ints(std::vector<int> v) {
    for (int& x : v) x *= 2;
    return v;
}
static std::vector<std::string> join_words(std::vector<std::string> v) {
    for (std::string& w : v) w += "!";
    return v;
}
static std::vector<std::vector<double>> scale_grid(std::vector<std::vector<double>> g, double k) {
    for (auto& row : g)
        for (double& x : row) x *= k;
    return g;
}
static int sum_ints(std::vector<int> v) {
    int s = 0;
    for (int x : v) s += x;
    return s;
}
static int strict_sum(std::vector<bk::Strict<int>> v) {
    int s = 0;
    for (const auto& x : v) s += x.value;
    return s;
}

static std::map<std::string, int> make_map() { return {{"a", 1}, {"b", 2}}; }
static int map_total(std::map<std::string, int> m) {
    int t = 0;
    for (const auto& kv : m) t += kv.second;
    return t;
}

static std::pair<int, std::string> make_pair_val(int n) { return {n, "pair"}; }
static int pair_len(std::pair<int, std::string> p) { return p.first + static_cast<int>(p.second.size()); }
static std::tuple<int, bool, std::string> make_tuple_val() { return {7, true, "tup"}; }
static std::string tuple_desc(std::tuple<int, bool, std::string> t) {
    return std::to_string(std::get<0>(t)) + (std::get<1>(t) ? "T" : "F") + std::get<2>(t);
}

static std::function<bk::Result<int>(int)> make_doubler() {
    return [](int x) -> bk::Result<int> { return x * 2; };
}

#if BOOMKAT_CPP20
static float span_sum(std::span<float> xs) {
    float s = 0;
    for (float x : xs) s += x;
    return s;
}
static std::span<const int32_t> span_ints() {
    static const int32_t kValues[] = {5, -2, 9};
    return std::span<const int32_t>(kValues);
}
#endif

/* ---- helpers --------------------------------------------------------------------- */

/* Evaluates `src`; true when it yields true. A failed eval is reported and counts as false. */
static bool js_true(bk::Context cx, const char* src) {
    auto r = cx.eval(src);
    if (!r) {
        char buf[256];
        r.error().describe(buf, sizeof buf);
        std::fprintf(stderr, "eval failed: %s: %s\n", src, buf);
        return false;
    }
    return r.value().to_bool();
}

/* Evaluates `src` and returns its string value as UTF-8, or a failure note. */
static std::string js_str(bk::Context cx, const char* src) {
    auto r = cx.eval(src);
    if (!r) {
        char buf[256];
        r.error().describe(buf, sizeof buf);
        return std::string("eval failed: ") + buf;
    }
    auto s = r.value().to<std::string>();
    if (!s) {
        char buf[256];
        s.error().describe(buf, sizeof buf);
        return std::string("to<std::string> failed: ") + buf;
    }
    return s.value();
}

/* ---- tests ----------------------------------------------------------------------- */

TEST(strings) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    CHECK_OK(cx.global().set("echoString", bk::function<&echo_string>(cx, "echoString")));

    REQUIRE_OK(bk::Value v, cx.eval("echoString('h\\u00e9llo \\u20ac')"));
    REQUIRE_OK(std::string got, v.to<std::string>());
    CHECK(got == "h\xc3\xa9llo \xe2\x82\xac");

    CHECK(js_str(cx, "echoString('\\uD83D\\uDE00')") == "\xf0\x9f\x98\x80");
    CHECK(js_str(cx, "echoString(42)") == "42");
    CHECK(js_str(cx, "echoString('\\uD800')") == "\xef\xbf\xbd");
    CHECK(js_true(cx, "typeof echoString('x') === 'string'"));
}

TEST(u16_strings) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    CHECK_OK(cx.global().set("echoU16", bk::function<&echo_u16>(cx, "echoU16")));
    CHECK_OK(cx.global().set("makePair", bk::function<&make_u16_pair>(cx, "makePair")));
    CHECK_OK(cx.global().set("makeLone", bk::function<&make_u16_lone>(cx, "makeLone")));

    /* JS to C++: a lone surrogate and an astral pair survive the trip. */
    CHECK(js_true(cx, "echoU16('\\uD800').length === 1 && echoU16('\\uD800').charCodeAt(0) === 0xD800"));
    REQUIRE_OK(bk::Value pair, cx.eval("echoU16('\\uD83D\\uDE00')"));
    REQUIRE_OK(std::u16string got, pair.to<std::u16string>());
    CHECK(got == u"\xD83D\xDE00");

    /* C++ to JS: an astral pair is two code units, a lone surrogate stays one. */
    CHECK(js_true(cx, "makePair().length === 2 && makePair().codePointAt(0) === 0x1F600"));
    CHECK(js_true(cx, "makeLone().length === 1 && makeLone().charCodeAt(0) === 0xD800"));

    /* A Latin-1 string (U+00E9 is stored as one byte) must keep its code unit. */
    REQUIRE_OK(bk::Value latin, cx.eval("echoU16('\\u00e9')"));
    REQUIRE_OK(std::u16string latin_got, latin.to<std::u16string>());
    CHECK(latin_got == u"é");
}

TEST(string_view_to_js) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    std::string_view plain = "from a view";
    std::string_view utf8 = "h\xc3\xa9";
    CHECK_OK(cx.global().set("viewText", plain));
    CHECK_OK(cx.global().set("viewUtf8", utf8));
    CHECK(js_true(cx, "viewText === 'from a view' && typeof viewText === 'string'"));
    CHECK(js_true(cx, "viewUtf8.length === 2 && viewUtf8.charCodeAt(1) === 0xE9"));
}

TEST(vectors) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    bk::Object g = cx.global();
    CHECK_OK(g.set("doubleInts", bk::function<&double_ints>(cx, "doubleInts")));
    CHECK_OK(g.set("joinWords", bk::function<&join_words>(cx, "joinWords")));
    CHECK_OK(g.set("scaleGrid", bk::function<&scale_grid>(cx, "scaleGrid")));
    CHECK_OK(g.set("sumInts", bk::function<&sum_ints>(cx, "sumInts")));
    CHECK_OK(g.set("strictSum", bk::function<&strict_sum>(cx, "strictSum")));

    /* vector<int>, both directions. */
    CHECK(js_str(cx, "doubleInts([1, 2, 3]).join(',')") == "2,4,6");
    /* vector<string>, both directions, non-ASCII and astral. */
    CHECK(js_str(cx, "joinWords(['h\\u00e9llo', '\\uD83D\\uDE00']).join('|')") ==
          "h\xc3\xa9llo!|\xf0\x9f\x98\x80!");
    /* Nested vector<vector<double>>, both directions. */
    CHECK(js_str(cx, "JSON.stringify(scaleGrid([[1, 2], [3]], 2))") == "[[2,4],[6]]");
    /* An array-like object converts through its length. */
    CHECK(js_str(cx, "String(sumInts({length: 2, 0: 1, 1: 2}))") == "3");

    /* A wrong element type names its index in the TypeError. */
    CHECK(js_true(cx, "strictSum([1, 2, 3]) === 6"));
    REQUIRE_OK(bk::Value msg, cx.eval("try { strictSum([1, 'x', 3]); 'no' } catch (e) { e.message }"));
    char buf[256];
    msg.describe(buf, sizeof buf);
    CHECK(std::strstr(buf, "element 1") != nullptr);
    CHECK(js_true(cx, "try { strictSum([1, 'x']); false } catch (e) { e instanceof TypeError }"));
}

TEST(maps) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    bk::Object g = cx.global();
    CHECK_OK(g.set("makeMap", bk::function<&make_map>(cx, "makeMap")));
    CHECK_OK(g.set("mapTotal", bk::function<&map_total>(cx, "mapTotal")));

    /* map<string, int> to JS: an object with the same own keys. */
    CHECK(js_true(cx, "makeMap().a === 1 && makeMap().b === 2 && Object.keys(makeMap()).length === 2"));
    /* JS to map<string, int>: key order does not matter. */
    CHECK(js_true(cx, "mapTotal({ x: 10, y: 5, z: -3 }) === 12"));
    CHECK(js_true(cx, "mapTotal({}) === 0"));
}

TEST(pairs_and_tuples) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    bk::Object g = cx.global();
    CHECK_OK(g.set("makePair", bk::function<&make_pair_val>(cx, "makePair")));
    CHECK_OK(g.set("pairLen", bk::function<&pair_len>(cx, "pairLen")));
    CHECK_OK(g.set("makeTuple", bk::function<&make_tuple_val>(cx, "makeTuple")));
    CHECK_OK(g.set("tupleDesc", bk::function<&tuple_desc>(cx, "tupleDesc")));

    CHECK(js_true(cx, "JSON.stringify(makePair(4)) === '[4,\"pair\"]'"));
    CHECK(js_true(cx, "pairLen([2, 'abc']) === 5"));
    CHECK(js_true(cx, "JSON.stringify(makeTuple()) === '[7,true,\"tup\"]'"));
    CHECK(js_true(cx, "tupleDesc([1, false, 'z']) === '1Fz'"));
}

TEST(std_function_from_js) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    std::function<bk::Result<int>(int)> held;
    CHECK_OK(cx.global().set("keep", bk::closure(cx, "keep", [&held](std::function<bk::Result<int>(int)> f) {
        held = std::move(f);
    })));
    CHECK_OK(cx.eval("keep(function (x) { if (x < 0) throw new RangeError('neg ' + x); return x * 2; })"));
    CHECK(static_cast<bool>(held));
    {
        bk::Scope call(cx);
        auto r = held(21);
        CHECK(static_cast<bool>(r));
        if (r) CHECK_EQ(r.value(), 42);
        auto bad = held(-1);
        CHECK(!bad);
        if (!bad) {
            char buf[256];
            bad.error().describe(buf, sizeof buf);
            CHECK(std::strstr(buf, "neg -1") != nullptr);
        }
    }
    /* Drop the held function before the context goes away. */
    held = nullptr;
    CHECK(!held);
}

TEST(std_function_to_js) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    CHECK_OK(cx.global().set("makeDoubler", bk::function<&make_doubler>(cx, "makeDoubler")));
    CHECK(js_true(cx, "typeof makeDoubler() === 'function'"));
    CHECK(js_true(cx, "makeDoubler()(21) === 42"));
}

TEST(event_loop_timers_and_jobs) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    bk::EventLoop loop(rt);
    CHECK_OK(loop.install(cx));
    static const char* kTimerScript = R"JS(
var order = [];
var dead = setTimeout(function () { order.push('dead'); }, 1);
clearTimeout(dead);
setTimeout(function () {
    order.push('t1');
    setTimeout(function () {
        order.push('t2');
        setTimeout(function () { order.push('t3'); }, 5);
    }, 2);
}, 1);
Promise.resolve().then(function () { order.push('micro'); });
order.push('sync');
)JS";
    CHECK_OK(cx.eval(kTimerScript));
    CHECK_OK(loop.run(cx));
    CHECK(js_str(cx, "JSON.stringify(order)") == "[\"sync\",\"micro\",\"t1\",\"t2\",\"t3\"]");
}

TEST(event_loop_post_from_thread) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    bk::EventLoop loop(rt);
    CHECK_OK(loop.install(cx));
    /* run() keeps waiting until the producer releases its hold. */
    loop.hold();
    bk::Context c = cx;
    std::thread producer([c, &loop] {
        loop.post([c] {
            bk::Scope ts(c);
            CHECK_OK(c.global().set("fromThread", 7));
        });
        loop.release();
    });
    CHECK_OK(loop.run(cx));
    producer.join();
    CHECK(js_true(cx, "fromThread === 7"));
}

TEST(watchdog_interrupts_runaway_script) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    bk::Watchdog wd(rt, std::chrono::milliseconds(50));
    auto r = cx.eval("for (;;) {}");
    CHECK(!r && r.error().code() == bk::Errc::interrupted);
    CHECK(wd.fired());
    rt.clear_interrupt();
    CHECK(js_true(cx, "1 + 1 === 2"));
}

TEST(watchdog_cancelled_before_deadline) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    bk::Watchdog wd(rt, std::chrono::seconds(30));
    wd.cancel();
    CHECK(!wd.fired());
    CHECK(js_true(cx, "(function () { let n = 0; for (let i = 0; i < 1000; i++) n += i; return n === 499500; })()"));
}

#if BOOMKAT_CPP20
TEST(typed_array_spans) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    bk::Object g = cx.global();
    CHECK_OK(g.set("spanSum", bk::function<&span_sum>(cx, "spanSum")));
    CHECK_OK(g.set("spanInts", bk::function<&span_ints>(cx, "spanInts")));

    CHECK(js_true(cx, "spanSum(new Float32Array([1.5, 2.25])) === 3.75"));
    CHECK(js_true(cx, "spanSum(new Float32Array(0)) === 0"));
    /* The returned span is copied into a new Int32Array on each call. */
    CHECK(js_true(cx, "(function () { const a = spanInts(); a[0] = 100; "
                      "return a instanceof Int32Array && a.length === 3 && a[1] === -2 && spanInts()[0] === 5; })()"));
    CHECK(js_str(cx, "try { spanSum([1]); 'no' } catch (e) { e.message }").find("expected typed array") !=
          std::string::npos);
}
#endif

int main() {
    RUN(strings);
    RUN(u16_strings);
    RUN(string_view_to_js);
    RUN(vectors);
    RUN(maps);
    RUN(pairs_and_tuples);
    RUN(std_function_from_js);
    RUN(std_function_to_js);
    RUN(event_loop_timers_and_jobs);
    RUN(event_loop_post_from_thread);
    RUN(watchdog_interrupts_runaway_script);
    RUN(watchdog_cancelled_before_deadline);
#if BOOMKAT_CPP20
    RUN(typed_array_spans);
#endif
    TEST_MAIN_END();
}

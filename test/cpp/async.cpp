/* Promises, rejection tracking, job hooks, modules and (C++20) coroutines. */
#include <memory>
#include <string>
#include "harness.hpp"
#if BOOMKAT_CPP20
#include "boomkat_coro.hpp"
#endif

TEST(host_promise) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    REQUIRE_OK(auto pair, bk::Promise::create(cx));
    auto& [promise, resolver] = pair;
    CHECK_OK(cx.global().set("p", promise));
    CHECK_OK(cx.eval("globalThis.got = 0; p.then(v => { got = v; })"));
    CHECK(promise.is_pending());
    CHECK_OK(resolver.resolve(42));
    CHECK(resolver.settled());
    CHECK_OK(resolver.resolve(7)); /* second settle is a no-op */
    CHECK_OK(cx.run_jobs());
    CHECK_EQ(cx.eval("got").value().to<int>().value(), 42);
    CHECK_EQ(promise.result().value().to<int>().value(), 42);
}

TEST(then_from_cpp) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    int ok = 0, bad = 0;
    REQUIRE_OK(bk::Value pv, cx.eval("Promise.resolve(5)"));
    CHECK_OK(pv.as<bk::Promise>()->then(cx, [&ok](int v) { ok = v; }, [&bad](bk::Value) { bad++; }));
    REQUIRE_OK(bk::Value rv, cx.eval("Promise.reject(new Error('no'))"));
    CHECK_OK(rv.as<bk::Promise>()->then(cx, [&ok](int) { ok = -1; }, [&bad](bk::Value) { bad++; }));
    CHECK_OK(cx.run_jobs());
    CHECK_EQ(ok, 5);
    CHECK_EQ(bad, 1);
}

TEST(rejection_tracker_and_job_hook) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    int hooks = 0, unhandled = 0;
    CHECK_OK(rt.on_job_enqueued([&hooks](bk::RuntimeRef) { hooks++; }));
    CHECK_OK(rt.on_rejection([&unhandled](const bk::Rejection& r) { if (!r.handled) unhandled++; }));
    bk::Scope s(cx);
    CHECK_OK(cx.eval("Promise.resolve().then(() => {}); Promise.resolve().then(() => {})"));
    CHECK_EQ(hooks, 1);
    CHECK_OK(cx.run_jobs());
    CHECK_OK(cx.eval("Promise.reject(1)"));
    CHECK_OK(cx.run_jobs());
    CHECK_EQ(unhandled, 1);
    rt.clear_job_hook();
}

struct MapLoader : bk::ModuleLoader {
    int loads = 0;
    std::string lib_source = "export const v = 1;";
    bk::Result<void> resolve(bk::Context, std::string_view, std::string_view spec, bk::ModuleName& out) override {
        return out.set(spec);
    }
    bk::Result<void> load(bk::Context cx, std::string_view name, bk::ModuleSource& out) override {
        loads++;
        if (name == "lib") return out.source(lib_source);
        if (name == "/etc/passwd") return cx.type_error("denied");
        return out.source("export default 0;");
    }
};

static double lerp(double a, double b, double t) { return a + (b - a) * t; }

TEST(modules) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    auto owned = std::make_unique<MapLoader>();
    MapLoader* loader = owned.get();
    CHECK_OK(rt.set_module_loader(std::move(owned), BK_LOADER_NO_FILESYSTEM_FALLBACK));
    bk::Scope s(cx);
    CHECK_OK(cx.define_module("engine:math", bk::exports(cx).add("lerp", bk::function<&lerp>(cx, "lerp")).add("k", 3)));
    REQUIRE_OK(bk::Object ns, cx.import("engine:math"));
    CHECK_EQ(ns.get_as<int>("k").value(), 3);
    CHECK_OK(cx.define_module("main", "import { lerp } from 'engine:math'; import { v } from 'lib';"
                                      "export const r = lerp(0, 10, 0.5) + v;"));
    REQUIRE_OK(bk::Object m, cx.import("main"));
    CHECK_EQ(m.get_as<double>("r").value(), 6.0);
    auto denied = cx.import("/etc/passwd");
    CHECK(!denied);
    /* Invalidation: the old namespace keeps working, a new import reloads. */
    REQUIRE_OK(bk::Object old_ns, cx.import("lib"));
    loader->lib_source = "export const v = 2;";
    CHECK_OK(cx.invalidate_module("lib"));
    REQUIRE_OK(bk::Object new_ns, cx.import("lib"));
    CHECK_EQ(old_ns.get_as<int>("v").value(), 1);
    CHECK_EQ(new_ns.get_as<int>("v").value(), 2);
    CHECK_OK(rt.clear_module_loader());
}

struct LaterLoader : bk::ModuleLoader {
    bk::PendingModule pending;
    bk::Result<void> resolve(bk::Context, std::string_view, std::string_view spec, bk::ModuleName& out) override {
        return out.set(spec);
    }
    bk::Result<void> load(bk::Context, std::string_view, bk::ModuleSource& out) override {
        pending = out.defer();
        return {};
    }
};

TEST(async_loader) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    LaterLoader loader;
    CHECK_OK(rt.set_module_loader(&loader, BK_LOADER_ASYNC | BK_LOADER_NO_FILESYSTEM_FALLBACK));
    bk::Scope s(cx);
    REQUIRE_OK(bk::Promise p, cx.import_async("later"));
    CHECK_OK(cx.run_jobs());
    CHECK(p.is_pending());
    CHECK(static_cast<bool>(loader.pending));
    CHECK_OK(loader.pending.source("export const x = 9;"));
    CHECK_OK(cx.run_jobs());
    CHECK(p.state() == BK_PROMISE_FULFILLED);
    CHECK_EQ(p.result().value().as<bk::Object>()->get_as<int>("x").value(), 9);
    CHECK_OK(rt.clear_module_loader());
}

#if BOOMKAT_CPP20
static bk::Task<bk::Result<int>> twice(bk::Context cx, bk::Function f) {
    bk::Result<bk::Value> r = co_await bk::await(cx, f.call());
    if (!r) co_return std::move(r).error();
    auto n = r->to<int>();
    if (!n) co_return std::move(n).error();
    co_return *n * 2;
}

TEST(coroutines) {
    REQUIRE_OK(bk::Runtime rt, bk::Runtime::create());
    REQUIRE_OK(bk::OwnedContext cx, rt.new_context());
    bk::Scope s(cx);
    REQUIRE_OK(bk::Value f, cx.eval("(async () => { await null; return 21; })"));
    auto task = twice(cx, *f.as<bk::Function>());
    CHECK(!task.done());
    CHECK_OK(cx.run_jobs());
    CHECK(task.done());
    CHECK_EQ(task.result().value(), 42);
    REQUIRE_OK(bk::Value g, cx.eval("(async () => { throw new Error('x'); })"));
    auto failing = twice(cx, *g.as<bk::Function>());
    CHECK_OK(cx.run_jobs());
    CHECK(failing.done());
    CHECK(!failing.result());
}
#endif

int main() {
    RUN(host_promise);
    RUN(then_from_cpp);
    RUN(rejection_tracker_and_job_hook);
    RUN(modules);
    RUN(async_loader);
#if BOOMKAT_CPP20
    RUN(coroutines);
#endif
    TEST_MAIN_END();
}

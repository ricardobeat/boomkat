// setTimeout chains plus a host promise settled from another thread.
#include <chrono>
#include <cstdio>
#include <string>
#include <thread>
#include "boomkat.hpp"
#include "boomkat_std.hpp"

static int fail(const bk::Error& e) {
    char buf[256];
    e.describe(buf, sizeof buf);
    std::fprintf(stderr, "error: %s\n", buf);
    return 1;
}

static const char* kScript = R"JS(
let ticks = 0;
function tick() {
    if (++ticks < 3) setTimeout(tick, 5);
    else print(`timer chain done after ${ticks} ticks`);
}
setTimeout(tick, 5);
(async function () {
    const answer = await hostAnswer;
    print(`awaited the host promise: ${answer}`);
})();
)JS";

int main() {
    auto rt = bk::Runtime::create();
    if (!rt) return fail(rt.error());
    auto cx = rt->new_context();
    if (!cx) return fail(cx.error());
    bk::Scope s(*cx);
    bk::EventLoop loop(*rt);
    if (auto r = loop.install(*cx); !r) return fail(r.error());

    auto printer = bk::closure(*cx, "print", [](std::string line) { std::printf("%s\n", line.c_str()); });
    if (!printer) return fail(printer.error());
    if (auto r = cx->global().set("print", *printer); !r) return fail(r.error());

    auto pending = bk::Promise::create(*cx);
    if (!pending) return fail(pending.error());
    if (auto r = cx->global().set("hostAnswer", pending->first); !r) return fail(r.error());
    bk::Resolver resolver = std::move(pending->second);

    if (auto r = cx->eval(kScript); !r) return fail(r.error());

    /* Resolver is move-only, so the posted task refers to it by reference; both
     * outlive the thread because the join happens before they go out of scope. */
    bk::Error task_error;
    bk::Context ctx = *cx;
    loop.hold();
    std::thread producer([&loop, &resolver, &task_error, ctx] {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        loop.post([&resolver, &task_error, ctx] {
            bk::Scope task(ctx);
            if (auto r = resolver.resolve(42); !r) task_error = std::move(r).error();
        });
        loop.release();
    });
    auto ran = loop.run(*cx);
    producer.join();
    if (!ran) return fail(ran.error());
    if (task_error.code() != bk::Errc::ok) return fail(task_error);
    return 0;
}

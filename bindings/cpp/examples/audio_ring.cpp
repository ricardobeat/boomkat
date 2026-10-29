// A producer thread fills a SharedArrayBuffer through its SharedBlock; JS sums it
// after the producer is joined.
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <thread>
#include "boomkat.hpp"

static int fail(const bk::Error& e) {
    char buf[256];
    e.describe(buf, sizeof buf);
    std::fprintf(stderr, "error: %s\n", buf);
    return 1;
}

static constexpr uint32_t kBytes = 1024;

int main() {
    auto rt = bk::Runtime::create();
    if (!rt) return fail(rt.error());
    auto cx = rt->new_context();
    if (!cx) return fail(cx.error());
    bk::Scope s(*cx);

    auto ring = bk::SharedArrayBuffer::create(*cx, kBytes);
    if (!ring) return fail(ring.error());
    if (auto r = cx->global().set("ring", *ring); !r) return fail(r.error());
    auto block = ring->block();
    if (!block) return fail(block.error());

    /* The write index lives on the host; it is only read after join(). */
    std::atomic<uint32_t> written{0};
    std::thread producer([blk = *block, &written] {
        auto* bytes = static_cast<uint8_t*>(blk.data());
        for (uint32_t i = 0; i < blk.size(); i++) {
            bytes[i] = static_cast<uint8_t>(i);
            written.store(i + 1, std::memory_order_release);
        }
    });
    producer.join();
    std::printf("producer wrote %u bytes\n", static_cast<unsigned>(written.load()));
    if (written.load() != kBytes) return 1;

    uint32_t expected = 0;
    for (uint32_t i = 0; i < kBytes; i++) expected += static_cast<uint8_t>(i);
    auto total = cx->eval("new Uint8Array(ring).reduce((a, b) => a + b, 0)")
                     .and_then([](bk::Value v) { return v.to<double>(); });
    if (!total) return fail(total.error());
    std::printf("JS sum %g, expected %u\n", *total, static_cast<unsigned>(expected));
    return *total == static_cast<double>(expected) ? 0 : 1;
}

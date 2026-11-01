/* A few macros for the C++ binding tests; works with exceptions off. */
#ifndef BK_TEST_HARNESS_HPP
#define BK_TEST_HARNESS_HPP
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "boomkat.hpp"

namespace bkt {
inline int failures = 0;
inline int checks = 0;
inline const char* current = "";
}  // namespace bkt

#define CHECK(cond)                                                                    \
    do {                                                                               \
        ::bkt::checks++;                                                               \
        if (!(cond)) {                                                                 \
            ::bkt::failures++;                                                         \
            std::fprintf(stderr, "%s:%d: [%s] CHECK(%s) failed\n", __FILE__, __LINE__, \
                         ::bkt::current, #cond);                                       \
        }                                                                              \
    } while (0)

#define CHECK_EQ(a, b) CHECK((a) == (b))
#define CHECK_STR(a, b) CHECK(std::strcmp((a), (b)) == 0)

/* Checks a Result and prints its error on failure. */
#define CHECK_OK(expr)                                                                   \
    do {                                                                                 \
        auto&& bkt_r_ = (expr);                                                          \
        ::bkt::checks++;                                                                 \
        if (!bkt_r_) {                                                                   \
            char bkt_buf_[256];                                                          \
            bkt_r_.error().describe(bkt_buf_, sizeof bkt_buf_);                          \
            ::bkt::failures++;                                                           \
            std::fprintf(stderr, "%s:%d: [%s] %s failed: %s\n", __FILE__, __LINE__,       \
                         ::bkt::current, #expr, bkt_buf_);                               \
        }                                                                                \
    } while (0)

/* Unwraps a Result into `decl`, or records a failure and returns from the test. */
#define REQUIRE_OK(decl, expr)                                                           \
    auto BK_CONCAT_(bkt_q_, __LINE__) = (expr);                                          \
    if (!BK_CONCAT_(bkt_q_, __LINE__)) {                                                 \
        char bkt_buf_[256];                                                              \
        BK_CONCAT_(bkt_q_, __LINE__).error().describe(bkt_buf_, sizeof bkt_buf_);        \
        ::bkt::failures++;                                                               \
        std::fprintf(stderr, "%s:%d: [%s] %s failed: %s\n", __FILE__, __LINE__,           \
                     ::bkt::current, #expr, bkt_buf_);                                   \
        return;                                                                          \
    }                                                                                    \
    decl = std::move(BK_CONCAT_(bkt_q_, __LINE__)).value()

/* The error message of a failed Result, described without running JS. */
template <class R> inline const char* bkt_describe(R& r, char* buf, size_t cap) {
    if (r) { std::snprintf(buf, cap, "<ok>"); return buf; }
    r.error().describe(buf, cap);
    return buf;
}

[[noreturn]] inline void bkt_panic(const char* message) {
    std::fprintf(stderr, "panic in [%s]: %s\n", ::bkt::current, message);
    std::abort();
}
struct BktInstall { BktInstall() { bk::panic_handler = &bkt_panic; } };
inline BktInstall bkt_install;

#define TEST(name) static void name()
#define RUN(name)                \
    do {                         \
        ::bkt::current = #name;  \
        name();                  \
    } while (0)

#define TEST_MAIN_END()                                                                      \
    do {                                                                                     \
        std::printf("%s: %d checks, %d failures\n", __FILE__, ::bkt::checks, ::bkt::failures); \
        return ::bkt::failures ? 1 : 0;                                                      \
    } while (0)

#endif

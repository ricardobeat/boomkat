/* boomkat_coro.hpp: C++20 coroutines over JS promises (optional).
 *
 *   bk::Task<bk::Result<int>> count(bk::Context cx, bk::Function fetch) {
 *       bk::Result<bk::Value> r = co_await bk::await(cx, fetch.call("/count"));
 *       if (!r) co_return std::move(r).error();
 *       co_return r->to<int>();
 *   }
 *
 * A Task starts eagerly and runs until its first co_await of a pending
 * promise. It resumes inside the job that settles the promise, so the host
 * drives it with job checkpoints (run_jobs or an event loop). Locals held
 * across a co_await die with the scope they were made in; keep values that
 * must survive a suspension in a bk::Global. A Task must outlive the promise
 * it waits on; destroying a suspended Task leaves the reaction dangling.
 * Coroutine frames use the global operator new.
 */
#ifndef BOOMKAT_CORO_HPP
#define BOOMKAT_CORO_HPP

#include "boomkat.hpp"

#if !BOOMKAT_CPP20
#error "boomkat_coro.hpp requires C++20"
#endif

#include <coroutine>
#include <exception>

namespace bk {

template <class T> class Task;

namespace detail {
template <class T> struct TaskPromiseBase {
    std::coroutine_handle<> continuation;
    std::suspend_never initial_suspend() noexcept { return {}; }
    struct FinalAwaiter {
        bool await_ready() noexcept { return false; }
        template <class P> std::coroutine_handle<> await_suspend(std::coroutine_handle<P> h) noexcept {
            if (auto c = h.promise().continuation) return c;
            return std::noop_coroutine();
        }
        void await_resume() noexcept {}
    };
    FinalAwaiter final_suspend() noexcept { return {}; }
    void unhandled_exception() noexcept { std::terminate(); }
};
}  // namespace detail

/* An eagerly started coroutine producing T. Move-only. */
template <class T> class Task {
public:
    struct promise_type : detail::TaskPromiseBase<T> {
        std::optional<T> value;
        Task get_return_object() { return Task(std::coroutine_handle<promise_type>::from_promise(*this)); }
        template <class U> void return_value(U&& v) { value.emplace(std::forward<U>(v)); }
    };
    Task(Task&& o) noexcept : h_(o.h_) { o.h_ = nullptr; }
    Task& operator=(Task&& o) noexcept {
        if (this != &o) { if (h_) h_.destroy(); h_ = o.h_; o.h_ = nullptr; }
        return *this;
    }
    Task(const Task&) = delete;
    Task& operator=(const Task&) = delete;
    ~Task() { if (h_) h_.destroy(); }

    bool done() const { return h_ && h_.done(); }
    /* The produced value; only once done(). */
    T& result() & { return *h_.promise().value; }
    T&& result() && { return std::move(*h_.promise().value); }

    /* Awaiting a Task from another coroutine. */
    bool await_ready() const noexcept { return done(); }
    void await_suspend(std::coroutine_handle<> c) noexcept { h_.promise().continuation = c; }
    T await_resume() { return std::move(*h_.promise().value); }

private:
    explicit Task(std::coroutine_handle<promise_type> h) : h_(h) {}
    std::coroutine_handle<promise_type> h_;
};

template <> class Task<void> {
public:
    struct promise_type : detail::TaskPromiseBase<void> {
        Task get_return_object() { return Task(std::coroutine_handle<promise_type>::from_promise(*this)); }
        void return_void() {}
    };
    Task(Task&& o) noexcept : h_(o.h_) { o.h_ = nullptr; }
    Task& operator=(Task&& o) noexcept {
        if (this != &o) { if (h_) h_.destroy(); h_ = o.h_; o.h_ = nullptr; }
        return *this;
    }
    Task(const Task&) = delete;
    Task& operator=(const Task&) = delete;
    ~Task() { if (h_) h_.destroy(); }
    bool done() const { return h_ && h_.done(); }
    bool await_ready() const noexcept { return done(); }
    void await_suspend(std::coroutine_handle<> c) noexcept { h_.promise().continuation = c; }
    void await_resume() {}
private:
    explicit Task(std::coroutine_handle<promise_type> h) : h_(h) {}
    std::coroutine_handle<promise_type> h_;
};

/* Awaits a value: a promise (or thenable) settles first; anything else, or an
 * error, is ready at once. The result is the fulfillment value, or an Error
 * holding the rejection reason. */
class PromiseAwaiter {
public:
    PromiseAwaiter(Context cx, Result<Value> v) : cx_(cx), in_(std::move(v)), out_(Error()) {}
    bool await_ready() {
        if (!in_) { out_ = std::move(in_).error(); return true; }
        auto p = in_->as<Promise>();
        if (!p) { out_ = *in_; return true; }
        if (!p->is_pending()) { settle_now(*p); return true; }
        return false;
    }
    void await_suspend(std::coroutine_handle<> h) {
        handle_ = h;
        Promise p = *in_->as<Promise>();
        PromiseAwaiter* self = this;
        auto ok = closure(cx_, "", [self](Value v) {
            self->out_ = v;
            self->handle_.resume();
        });
        auto bad = closure(cx_, "", [self](Value reason) {
            self->out_ = Error::thrown(reason.raw_context(), reason.raw());
            self->handle_.resume();
        });
        if (!ok || !bad) {
            out_ = !ok ? std::move(ok).error() : std::move(bad).error();
            h.resume();
            return;
        }
        bk_value derived = bk_promise_then(cx_, p.raw(), ok->raw(), bad->raw());
        if (derived == BK_EXCEPTION) {
            out_ = Error::from_pending(cx_);
            h.resume();
        }
    }
    Result<Value> await_resume() { return std::move(out_); }

private:
    void settle_now(Promise p) {
        auto r = p.result();
        if (!r) { out_ = std::move(r).error(); return; }
        if (p.state() == BK_PROMISE_REJECTED) {
            (void)p.mark_handled();
            out_ = Error::thrown(cx_, r->raw());
        } else {
            out_ = *r;
        }
    }
    Context cx_;
    Result<Value> in_;
    Result<Value> out_;
    std::coroutine_handle<> handle_;
};

inline PromiseAwaiter await(Context cx, Result<Value> v) { return PromiseAwaiter(cx, std::move(v)); }
inline PromiseAwaiter await(Context cx, Value v) { return PromiseAwaiter(cx, Result<Value>(v)); }

}  // namespace bk

#endif

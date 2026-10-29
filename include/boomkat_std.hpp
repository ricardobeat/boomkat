/* boomkat_std.hpp: optional STL adapters for boomkat.hpp.
 *
 * Conversions for std::string, std::string_view (to JS), std::u16string,
 * std::vector, std::map, std::pair, std::tuple, std::function and, in C++20,
 * std::span over typed arrays. Also a single-threaded reference event loop
 * (timers and posted tasks) and a Watchdog thread that interrupts a runtime
 * after a deadline. These use the standard allocator: a host including this
 * header has chosen the STL.
 */
#ifndef BOOMKAT_STD_HPP
#define BOOMKAT_STD_HPP

#include "boomkat.hpp"

#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#if BOOMKAT_CPP20
#include <span>
#endif

namespace bk {

/* ---- strings ------------------------------------------------------------------ */

/* ToString, then UTF-8 with lone surrogates replaced. */
template <> struct Convert<std::string> {
    static constexpr const char* js_name = "string";
    static Result<std::string> from_js(Value v) {
        auto s = v.is_string() ? Result<String>(String(raw_tag, v.raw_context(), v.raw())) : v.to_string();
        if (!s) return std::move(s).error();
        std::string out;
        BK_TRY(s->write_utf8([&out](std::string_view chunk) { out.append(chunk); }));
        return out;
    }
    static Result<Value> to_js(Context cx, const std::string& s) {
        auto r = String::from_utf8(cx, s);
        if (!r) return std::move(r).error();
        return Value(*r);
    }
};

template <> struct Convert<std::string_view> {
    static constexpr const char* js_name = "string";
    static Result<Value> to_js(Context cx, std::string_view s) {
        auto r = String::from_utf8(cx, s);
        if (!r) return std::move(r).error();
        return Value(*r);
    }
};

/* ToString, then the UTF-16 units as stored, lone surrogates kept. */
template <> struct Convert<std::u16string> {
    static constexpr const char* js_name = "string";
    static Result<std::u16string> from_js(Value v) {
        auto s = v.is_string() ? Result<String>(String(raw_tag, v.raw_context(), v.raw())) : v.to_string();
        if (!s) return std::move(s).error();
        return s->visit([](auto units) {
            std::u16string out(units.size(), u'\0');
            for (size_t i = 0; i < units.size(); i++)
                out[i] = sizeof(units[i]) == 1 ? static_cast<char16_t>(static_cast<unsigned char>(units[i]))
                                               : static_cast<char16_t>(units[i]);
            return out;
        });
    }
    static Result<Value> to_js(Context cx, const std::u16string& s) {
        auto r = String::from_utf16(cx, s);
        if (!r) return std::move(r).error();
        return Value(*r);
    }
};

/* ---- containers ---------------------------------------------------------------- */

namespace detail {
/* Converts element `i` of an array-like, naming the index in a mismatch. */
template <class T> inline Result<T> element_from_js(Object o, uint32_t i) {
    auto e = o.get(i);
    if (!e) return std::move(e).error();
    auto r = from_js<T>(*e);
    if (r) return r;
    char prefix[48];
    std::snprintf(prefix, sizeof prefix, "element %u", i);
    return finish_mismatch<T>(o.raw_context(), std::move(r).error(), prefix);
}
template <class Tuple, size_t... I>
inline Result<Value> tuple_to_js(Context cx, const Tuple& t, std::index_sequence<I...>) {
    auto arr = Array::create(cx);
    if (!arr) return std::move(arr).error();
    Error err;
    bool ok = true;
    auto one = [&](uint32_t i, const auto& v) {
        if (!ok) return;
        auto r = arr->set(i, v);
        if (!r) { ok = false; err = std::move(r).error(); }
    };
    (one(static_cast<uint32_t>(I), std::get<I>(t)), ...);
    (void)one;
    if (!ok) return err;
    return Value(*arr);
}
template <class Tuple, size_t... I>
inline Result<Tuple> tuple_from_js(Object o, std::index_sequence<I...>) {
    std::tuple<std::optional<std::tuple_element_t<I, Tuple>>...> parts;
    Error err;
    bool ok = true;
    auto one = [&](auto& slot, uint32_t i) {
        if (!ok) return;
        using E = typename remove_cvref_t<decltype(slot)>::value_type;
        auto r = element_from_js<E>(o, i);
        if (!r) { ok = false; err = std::move(r).error(); return; }
        slot.emplace(std::move(*r));
    };
    (one(std::get<I>(parts), static_cast<uint32_t>(I)), ...);
    (void)one;
    if (!ok) return err;
    return Tuple(std::move(*std::get<I>(parts))...);
}
}  // namespace detail

/* Any array-like object, through its length. */
template <class T, class A> struct Convert<std::vector<T, A>> {
    static constexpr const char* js_name = "array";
    static Result<std::vector<T, A>> from_js(Value v) {
        auto o = v.as<Object>();
        if (!o) return Error::mismatch(v.raw_context());
        BK_TRY_ASSIGN(uint64_t n, o->length());
        if (n > 0xFFFFFFFFu) return Error::range_error(v.raw_context(), "array too long");
        std::vector<T, A> out;
        out.reserve(static_cast<size_t>(n < 4096 ? n : 4096));
        for (uint32_t i = 0; i < n; i++) {
            BK_TRY_ASSIGN(T e, detail::element_from_js<T>(*o, i));
            out.push_back(std::move(e));
        }
        return out;
    }
    static Result<Value> to_js(Context cx, const std::vector<T, A>& v) {
        BK_TRY_ASSIGN(Array arr, Array::create(cx));
        for (size_t i = 0; i < v.size(); i++) {
            if constexpr (std::is_same_v<T, bool>) BK_TRY(arr.set(static_cast<uint32_t>(i), static_cast<bool>(v[i])));
            else BK_TRY(arr.set(static_cast<uint32_t>(i), v[i]));
        }
        return Value(arr);
    }
};

/* The object's own enumerable string keys. */
template <class T, class C, class A> struct Convert<std::map<std::string, T, C, A>> {
    static constexpr const char* js_name = "object";
    static Result<std::map<std::string, T, C, A>> from_js(Value v) {
        auto o = v.as<Object>();
        if (!o) return Error::mismatch(v.raw_context());
        BK_TRY_ASSIGN(Array keys, o->keys(BK_KEYS_STRINGS | BK_KEYS_ENUMERABLE_ONLY));
        BK_TRY_ASSIGN(uint64_t n, keys.length());
        std::map<std::string, T, C, A> out;
        for (uint32_t i = 0; i < n; i++) {
            BK_TRY_ASSIGN(Value k, keys.get(i));
            BK_TRY_ASSIGN(std::string key, Convert<std::string>::from_js(k));
            BK_TRY_ASSIGN(Value e, o->get(key));
            auto r = detail::from_js<T>(e);
            if (!r) return detail::finish_mismatch<T>(v.raw_context(), std::move(r).error(), key.c_str());
            out.emplace(std::move(key), std::move(*r));
        }
        return out;
    }
    static Result<Value> to_js(Context cx, const std::map<std::string, T, C, A>& m) {
        BK_TRY_ASSIGN(Object o, Object::create(cx));
        for (const auto& [k, e] : m) BK_TRY(o.set(k, e));
        return Value(o);
    }
};

/* Arrays of fixed length. */
template <class A, class B> struct Convert<std::pair<A, B>> {
    static constexpr const char* js_name = "array";
    static Result<std::pair<A, B>> from_js(Value v) {
        auto o = v.as<Object>();
        if (!o) return Error::mismatch(v.raw_context());
        return detail::tuple_from_js<std::pair<A, B>>(*o, std::make_index_sequence<2>());
    }
    static Result<Value> to_js(Context cx, const std::pair<A, B>& p) {
        return detail::tuple_to_js(cx, p, std::make_index_sequence<2>());
    }
};
template <class... T> struct Convert<std::tuple<T...>> {
    static constexpr const char* js_name = "array";
    static Result<std::tuple<T...>> from_js(Value v) {
        auto o = v.as<Object>();
        if (!o) return Error::mismatch(v.raw_context());
        return detail::tuple_from_js<std::tuple<T...>>(*o, std::index_sequence_for<T...>());
    }
    static Result<Value> to_js(Context cx, const std::tuple<T...>& t) {
        return detail::tuple_to_js(cx, t, std::index_sequence_for<T...>());
    }
};

/* A JS function as a std::function holding it as a Global, and a callable as
 * a JS function. Calling the std::function opens a scope, converts the
 * arguments and the result, and returns a Result. Release it before the
 * context. */
template <class R, class... A> struct Convert<std::function<Result<R>(A...)>> {
    static constexpr const char* js_name = "function";
    static Result<std::function<Result<R>(A...)>> from_js(Value v) {
        auto f = v.as<Function>();
        if (!f) return Error::mismatch(v.raw_context());
        auto g = std::make_shared<Global<Function>>(*f);
        return std::function<Result<R>(A...)>([g](A... args) -> Result<R> {
            Context cx = g->context();
            Scope s(cx);
            BK_TRY_ASSIGN(Value out, g->get(cx).call(std::forward<A>(args)...));
            if constexpr (std::is_void_v<R>) { (void)out; return {}; }
            else if constexpr (std::is_base_of_v<Value, R>) {
                BK_TRY_ASSIGN(R r, out.to<R>());
                return s.escape(r);
            } else return out.to<R>();
        });
    }
    static Result<Value> to_js(Context cx, std::function<Result<R>(A...)> f) {
        auto fn = closure(cx, "", std::move(f));
        if (!fn) return std::move(fn).error();
        return Value(*fn);
    }
};

#if BOOMKAT_CPP20
/* A typed array's elements in place, valid until the next call that can run
 * JS, resize or detach the buffer. To JS: a copy in a new typed array. */
template <class E> struct Convert<std::span<E>> {
    using T = std::remove_const_t<E>;
    static constexpr const char* js_name = "typed array";
    static Result<std::span<E>> from_js(Value v) {
        auto ta = v.as<TypedArray<T>>();
        if (!ta) return Error::mismatch(v.raw_context());
        BK_TRY_ASSIGN(Span<T> s, ta->elements());
        return std::span<E>(s.data, s.size);
    }
    static Result<Value> to_js(Context cx, std::span<E> s) {
        BK_TRY_ASSIGN(TypedArray<T> ta, TypedArray<T>::create(cx, s.size()));
        BK_TRY_ASSIGN(Span<T> dst, ta.elements());
        if (!s.empty()) std::memcpy(dst.data, s.data(), s.size_bytes());
        return Value(ta);
    }
};
#endif

/* ---- reference event loop -------------------------------------------------------- */

/* A minimal single-threaded loop: timers, tasks posted from any thread, and
 * job checkpoints. install() defines setTimeout and clearTimeout on a
 * context's global. run() returns when no timers, tasks or jobs remain, or
 * after stop(). Callbacks run on the thread that calls run(). */
class EventLoop {
public:
    using Clock = std::chrono::steady_clock;
    explicit EventLoop(RuntimeRef rt) : rt_(rt) {}
    EventLoop(const EventLoop&) = delete;
    EventLoop& operator=(const EventLoop&) = delete;

    /* setTimeout(fn, ms, ...args) and clearTimeout(id). */
    Result<void> install(Context cx) {
        Scope s(cx);
        EventLoop* self = this;
        BK_TRY(cx.global().set("setTimeout", closure(cx, "setTimeout",
            [self](Function fn, std::optional<double> ms, Rest<Value> rest) -> Result<double> {
                Timer t;
                t.id = ++self->next_id_;
                t.due = Clock::now() + std::chrono::microseconds(
                    static_cast<int64_t>((ms && *ms > 0 ? *ms : 0) * 1000));
                t.fn = Global<Function>(fn);
                for (unsigned i = 0; i < rest.size(); i++) t.args.emplace_back(rest.raw(i));
                self->timers_.push_back(std::move(t));
                return static_cast<double>(self->timers_.back().id);
            })));
        BK_TRY(cx.global().set("clearTimeout", closure(cx, "clearTimeout", [self](std::optional<double> id) {
            if (!id) return;
            for (auto it = self->timers_.begin(); it != self->timers_.end(); ++it)
                if (static_cast<double>(it->id) == *id) { self->timers_.erase(it); return; }
        })));
        return {};
    }

    /* A task for the loop thread. Safe from any thread while the loop lives. */
    void post(std::function<void()> task) {
        {
            std::lock_guard<std::mutex> lock(mu_);
            posted_.push_back(std::move(task));
        }
        rt_.waker().wake();
    }
    /* Tasks expected from other threads; run() keeps waiting while nonzero. */
    void hold() { std::lock_guard<std::mutex> lock(mu_); holds_++; }
    void release() {
        { std::lock_guard<std::mutex> lock(mu_); holds_--; }
        rt_.waker().wake();
    }
    void stop() { stopped_ = true; rt_.waker().wake(); }

    /* Runs until idle. The first failure of a job or timer callback stops the
     * loop and is returned; timers already queued stay queued. */
    Result<void> run(Context cx) {
        stopped_ = false;
        for (;;) {
            BK_TRY(cx.run_jobs());
            drain_posted();
            BK_TRY(cx.run_jobs());
            BK_TRY(fire_due(cx));
            if (stopped_) return {};
            bool waiting;
            {
                std::lock_guard<std::mutex> lock(mu_);
                waiting = holds_ > 0 || !posted_.empty();
            }
            if (timers_.empty() && !waiting && !rt_.has_pending_jobs()) return {};
            if (rt_.has_pending_jobs()) continue;
            double timeout = -1;
            if (!timers_.empty()) {
                auto next = timers_.front().due;
                for (const Timer& t : timers_) if (t.due < next) next = t.due;
                auto d = std::chrono::duration<double, std::milli>(next - Clock::now()).count();
                timeout = d > 0 ? d : 0;
            }
            if (timeout != 0) rt_.wait_events(timeout);
        }
    }

private:
    struct Timer {
        uint64_t id = 0;
        Clock::time_point due;
        Global<Function> fn;
        std::vector<Global<Value>> args;
    };
    void drain_posted() {
        std::deque<std::function<void()>> tasks;
        {
            std::lock_guard<std::mutex> lock(mu_);
            tasks.swap(posted_);
        }
        for (auto& t : tasks) t();
    }
    Result<void> fire_due(Context cx) {
        auto now = Clock::now();
        for (size_t i = 0; i < timers_.size();) {
            if (timers_[i].due > now) { i++; continue; }
            Timer t = std::move(timers_[i]);
            timers_.erase(timers_.begin() + static_cast<std::ptrdiff_t>(i));
            Scope s(cx);
            std::vector<bk_value> argv;
            for (auto& a : t.args) argv.push_back(a.get(cx).raw());
            BK_TRY(t.fn.get(cx).call_raw(cx.undefined(), static_cast<unsigned>(argv.size()), argv.data()));
            BK_TRY(cx.run_jobs());
        }
        return {};
    }
    RuntimeRef rt_;
    std::vector<Timer> timers_;
    uint64_t next_id_ = 0;
    std::mutex mu_;
    std::deque<std::function<void()>> posted_;
    int holds_ = 0;
    bool stopped_ = false;
};

/* ---- watchdog ------------------------------------------------------------------- */

/* Interrupts a runtime once a deadline passes. The destructor joins the
 * thread, so destroy the Watchdog before the runtime. */
class Watchdog {
public:
    template <class Rep, class Period>
    Watchdog(RuntimeRef rt, std::chrono::duration<Rep, Period> timeout)
        : thread_([this, rt, timeout] {
              std::unique_lock<std::mutex> lock(mu_);
              if (!cv_.wait_for(lock, timeout, [this] { return done_; })) {
                  fired_ = true;
                  rt.interrupt();
              }
          }) {}
    Watchdog(const Watchdog&) = delete;
    Watchdog& operator=(const Watchdog&) = delete;
    ~Watchdog() { cancel(); }
    /* Stops the timer and joins the thread. */
    void cancel() {
        {
            std::lock_guard<std::mutex> lock(mu_);
            done_ = true;
        }
        cv_.notify_all();
        if (thread_.joinable()) thread_.join();
    }
    bool fired() const {
        std::lock_guard<std::mutex> lock(mu_);
        return fired_;
    }
private:
    mutable std::mutex mu_;
    std::condition_variable cv_;
    bool done_ = false;
    bool fired_ = false;
    std::thread thread_;
};

}  // namespace bk

#endif

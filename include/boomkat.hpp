/* boomkat.hpp: the C++17 embedding API over boomkat.h.
 *
 * Header-only. Works with exceptions and RTTI off. Requires only boomkat.h and
 * standard headers. Optional adapters: boomkat_std.hpp (STL conversions, a
 * reference event loop, a watchdog) and boomkat_coro.hpp (C++20 coroutines).
 *
 * Ownership:
 * - Value, Object, Function, ... are locals: {bk_ctx, bk_value}, 16 bytes,
 *   trivially copyable, valid until the innermost local scope closes. A C++
 *   callback runs in a local scope; host code opens one with bk::Scope.
 * - Global<T> is a registry root and the only handle a long-lived host
 *   structure may hold, besides Traced<T> inside traced payloads. Release a
 *   Global before the context it was made with.
 * - Runtime and OwnedContext own their C objects. Destroy every OwnedContext
 *   before its Runtime.
 *
 * Threading: a runtime and everything made from it belong to one thread at a
 * time. Runtime::interrupt, Runtime::clear_interrupt and Waker::wake may run on
 * any thread while the runtime lives. A runtime stays on the thread that
 * created it: engine state that is thread-local has not moved into the heap.
 *
 * Finalizers (class payloads, closures) never call the engine; they can run in
 * any engine call that drops a reference. Classes that need engine access or a
 * host-chosen thread use defer_finalization() and Runtime::run_finalizers().
 */
#ifndef BOOMKAT_HPP
#define BOOMKAT_HPP

#include "boomkat.h"

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <optional>
#include <string_view>
#include <tuple>
#include <type_traits>
#include <utility>

#if defined(_MSVC_LANG)
#define BOOMKAT_CPP_STD _MSVC_LANG
#else
#define BOOMKAT_CPP_STD __cplusplus
#endif
#if BOOMKAT_CPP_STD < 201703L
#error "boomkat.hpp requires C++17"
#endif
#define BOOMKAT_CPP20 (BOOMKAT_CPP_STD >= 202002L)

#ifndef BOOMKAT_CPP_EXCEPTIONS
#if defined(__cpp_exceptions) || defined(_CPPUNWIND)
#define BOOMKAT_CPP_EXCEPTIONS 1
#else
#define BOOMKAT_CPP_EXCEPTIONS 0
#endif
#endif
#if BOOMKAT_CPP_EXCEPTIONS
#include <exception>
#endif

#ifndef BOOMKAT_CPP_DEBUG
#ifdef NDEBUG
#define BOOMKAT_CPP_DEBUG 0
#else
#define BOOMKAT_CPP_DEBUG 1
#endif
#endif

#if defined(__cpp_lib_expected) && __cpp_lib_expected >= 202202L
#include <expected>
#define BOOMKAT_CPP_EXPECTED 1
#else
#define BOOMKAT_CPP_EXPECTED 0
#endif

namespace bk {

class Context;
class OwnedContext;
class Runtime;
class RuntimeRef;
class Value;
class Object;
class Function;
class Array;
class String;
class Symbol;
class BigInt;
class Promise;
class Script;
class Error;
class Atom;
class CallInfo;
template <class T> class Result;
template <> class Result<void>;
template <class T = Value> class Global;
template <class T, class Enable = void> struct Convert;

/* ---- panic ---------------------------------------------------------------- */

using PanicHandler = void (*)(const char* message);
namespace detail {
[[noreturn]] inline void default_panic(const char* message) {
    std::fprintf(stderr, "boomkat: %s\n", message);
    std::abort();
}
}  // namespace detail
/* Called by Result::value() on an error when exceptions are off, and by the
 * debug checks. It must not return; if it does, the process aborts. */
inline PanicHandler panic_handler = &detail::default_panic;
[[noreturn]] inline void panic(const char* message) {
    panic_handler(message);
    std::abort();
}

#if BOOMKAT_CPP_DEBUG
#define BOOMKAT_CPP_ASSERT(cond, msg) ((cond) ? (void)0 : ::bk::panic(msg))
#else
#define BOOMKAT_CPP_ASSERT(cond, msg) ((void)0)
#endif

/* Optional thread check: define BOOMKAT_CPP_THREAD_ID() to an expression that
 * yields a comparable thread id, and debug builds check that each runtime is
 * driven by the thread that created it. */

/* ---- errors --------------------------------------------------------------- */

enum class Errc : int {
    ok = 0, nomem = -1, syntax = -2, thrown = -3, internal = -4, invalid = -5,
    type = -6, full = -7, interrupted = -8, encoding = -9, unsupported = -10
};

inline const char* errc_str(Errc code) { return bk_status_str(static_cast<bk_status>(code)); }

enum class Utf8Mode { replace = BK_UTF8_REPLACE, strict = BK_UTF8_STRICT };

/* A failure: a status code plus, when there is one, the thrown value held as a
 * registry root. Move-only. */
class Error {
public:
    Error() = default;
    Error(Errc code, bk_ctx cx = nullptr) : code_(code), cx_(cx) {}
    Error(Error&& o) noexcept { steal(o); }
    Error& operator=(Error&& o) noexcept {
        if (this != &o) { release(); steal(o); }
        return *this;
    }
    Error(const Error&) = delete;
    Error& operator=(const Error&) = delete;
    ~Error() { release(); }

    Errc code() const { return code_; }
    /* Interrupts cannot be caught by JS; a trampoline never turns them into a
     * catchable throw. */
    bool is_uncatchable() const { return code_ == Errc::interrupted; }
    inline Global<Value> exception() const;
    /* The thrown value's handle, borrowed from this Error; 0 when none. */
    bk_value raw_exception() const { return exc_; }
    bk_ctx context() const { return cx_; }
    int line() const { return line_; }
    int column() const { return col_; }
    /* Formats the exception without running JS (bk_describe). Returns the
     * full length; the buffer receives as much as fits, NUL-terminated. */
    size_t describe(char* buf, size_t cap) const {
        if (cap) buf[0] = 0;
        if (cx_ && exc_) {
            size_t len = 0;
            bk_status st = bk_describe(cx_, exc_, buf, cap, &len);
            if (st == BK_OK) return len;
            if (st == BK_ERR_FULL && cap) {
                /* Not enough room: format into a sized temporary. */
                char* tmp = static_cast<char*>(std::malloc(len + 1));
                if (tmp && bk_describe(cx_, exc_, tmp, len + 1, &len) == BK_OK) {
                    std::memcpy(buf, tmp, cap - 1);
                    buf[cap - 1] = 0;
                }
                std::free(tmp);
                return len;
            }
        }
        const char* s = errc_str(code_);
        size_t len = std::strlen(s);
        if (cap) {
            size_t n = len < cap - 1 ? len : cap - 1;
            std::memcpy(buf, s, n);
            buf[n] = 0;
        }
        return len;
    }

    /* The pending failure of the last call on `cx`: takes its exception. */
    static Error from_pending(bk_ctx cx, bk_status status = BK_OK) {
        Error e;
        e.cx_ = cx;
        bk_status code = status != BK_OK ? status : bk_get_error_code(cx);
        e.code_ = code == BK_OK ? Errc::thrown : static_cast<Errc>(code);
        bk_error_info info{};
        if (bk_get_error_info(cx, &info) == BK_OK) { e.line_ = info.line; e.col_ = info.col; }
        bk_value thrown = bk_get_exception(cx);
        if (thrown != BK_EXCEPTION) {
            e.exc_ = bk_dup_value(cx, thrown);
            bk_free_value(cx, thrown);
        }
        return e;
    }
    /* A new Error object of `kind` as the exception. */
    static Error make(bk_ctx cx, Errc code, bk_error_kind kind, const char* message) {
        Error e(code, cx);
        bk_value err = bk_new_error(cx, kind, message);
        if (err != BK_EXCEPTION) {
            e.exc_ = bk_dup_value(cx, err);
            bk_free_value(cx, err);
        }
        return e;
    }
    static Error type_error(bk_ctx cx, const char* message) {
        return make(cx, Errc::type, BK_ERROR_TYPE, message);
    }
    static Error range_error(bk_ctx cx, const char* message) {
        return make(cx, Errc::type, BK_ERROR_RANGE, message);
    }
    /* A conversion that found the wrong kind of value. The caller that knows
     * the parameter position turns it into a TypeError. */
    static Error mismatch(bk_ctx cx) {
        Error e(Errc::type, cx);
        e.mismatch_ = true;
        return e;
    }
    bool is_mismatch() const { return mismatch_; }
    /* An Error whose exception is `thrown` (borrowed). */
    static Error thrown(bk_ctx cx, bk_value value) {
        Error e(Errc::thrown, cx);
        e.exc_ = bk_dup_value(cx, value);
        return e;
    }
    /* A second Error with its own root on the same exception. */
    Error clone() const {
        Error e(code_, cx_);
        e.line_ = line_; e.col_ = col_; e.mismatch_ = mismatch_;
        if (exc_ && cx_) e.exc_ = bk_dup_value(cx_, exc_);
        return e;
    }

    /* Make the exception pending on `cx` so the current callback throws it.
     * Returns BK_EXCEPTION. */
    bk_value rethrow(bk_ctx cx) const {
        if (is_uncatchable()) return BK_EXCEPTION;
        if (exc_) return bk_throw(cx, exc_);
        char buf[160];
        describe(buf, sizeof buf);
        return bk_throw_error(cx, code_ == Errc::type ? BK_ERROR_TYPE : BK_ERROR, buf);
    }

private:
    void release() {
        if (exc_ && cx_) bk_free_value(cx_, exc_);
        exc_ = 0;
    }
    void steal(Error& o) {
        code_ = o.code_; cx_ = o.cx_; exc_ = o.exc_; line_ = o.line_; col_ = o.col_;
        mismatch_ = o.mismatch_;
        o.exc_ = 0; o.code_ = Errc::ok;
    }
    Errc code_ = Errc::ok;
    bk_ctx cx_ = nullptr;
    bk_value exc_ = 0;
    int line_ = 0, col_ = 0;
    bool mismatch_ = false;
};

#if BOOMKAT_CPP_EXCEPTIONS
/* Thrown by Result::value() on an error in exceptions mode. Trampolines turn
 * it back into the JS value. */
class JsError : public std::exception {
public:
    explicit JsError(Error e) : error_(std::move(e)) { error_.describe(what_, sizeof what_); }
    JsError(const JsError& o) : std::exception(o), error_(o.error_.clone()) { std::memcpy(what_, o.what_, sizeof what_); }
    JsError& operator=(const JsError&) = delete;
    const char* what() const noexcept override { return what_; }
    Error& error() noexcept { return error_; }
    const Error& error() const noexcept { return error_; }
private:
    Error error_;
    char what_[256];
};
#endif

namespace detail {
[[noreturn]] inline void fail_value(Error& e) {
#if BOOMKAT_CPP_EXCEPTIONS
    throw JsError(std::move(e));
#else
    char buf[200] = "Result::value() on an error: ";
    size_t used = std::strlen(buf);
    e.describe(buf + used, sizeof buf - used);
    panic(buf);
#endif
}
template <class T> struct is_result : std::false_type {};
template <class T> struct is_result<Result<T>> : std::true_type {};
template <class T> using remove_cvref_t = std::remove_cv_t<std::remove_reference_t<T>>;
}  // namespace detail

/* A value or an Error. Error converts implicitly into any Result<U>, so
 * `return err;` propagates. */
template <class T>
class [[nodiscard]] Result {
public:
    using value_type = T;
    Result(Error e) : ok_(false) { ::new (static_cast<void*>(&err_)) Error(std::move(e)); }
    template <class U, std::enable_if_t<std::is_constructible_v<T, U&&> &&
                                        !std::is_same_v<detail::remove_cvref_t<U>, Error> &&
                                        !std::is_same_v<detail::remove_cvref_t<U>, Result>, int> = 0>
    Result(U&& v) : ok_(true) { ::new (static_cast<void*>(&val_)) T(std::forward<U>(v)); }
    Result(Result&& o) noexcept(std::is_nothrow_move_constructible_v<T>) : ok_(o.ok_) {
        if (ok_) ::new (static_cast<void*>(&val_)) T(std::move(o.val_));
        else ::new (static_cast<void*>(&err_)) Error(std::move(o.err_));
    }
    Result& operator=(Result&& o) {
        if (this != &o) { destroy(); ok_ = o.ok_;
            if (ok_) ::new (static_cast<void*>(&val_)) T(std::move(o.val_)); else ::new (static_cast<void*>(&err_)) Error(std::move(o.err_)); }
        return *this;
    }
    Result(const Result&) = delete;
    Result& operator=(const Result&) = delete;
    ~Result() { destroy(); }

    bool ok() const { return ok_; }
    explicit operator bool() const { return ok_; }
    T& value() & { if (!ok_) detail::fail_value(err_); return val_; }
    const T& value() const& { if (!ok_) detail::fail_value(const_cast<Error&>(err_)); return val_; }
    const Error& error() const& { BOOMKAT_CPP_ASSERT(!ok_, "Result::error() on a value"); return err_; }
    T&& value() && { if (!ok_) detail::fail_value(err_); return std::move(val_); }
    Error& error() & { BOOMKAT_CPP_ASSERT(!ok_, "Result::error() on a value"); return err_; }
    Error&& error() && { BOOMKAT_CPP_ASSERT(!ok_, "Result::error() on a value"); return std::move(err_); }
    template <class U> T value_or(U&& fallback) && {
        return ok_ ? std::move(val_) : static_cast<T>(std::forward<U>(fallback));
    }
    template <class F> auto and_then(F&& f) && -> decltype(f(std::declval<T&&>())) {
        if (!ok_) return std::move(err_);
        return f(std::move(val_));
    }
    template <class F> auto map(F&& f) && -> Result<decltype(f(std::declval<T&&>()))> {
        using U = decltype(f(std::declval<T&&>()));
        if (!ok_) return std::move(err_);
        if constexpr (std::is_void_v<U>) { f(std::move(val_)); return Result<U>(); }
        else return Result<U>(f(std::move(val_)));
    }
    T* operator->() { return &value(); }
    T& operator*() & { return value(); }
    T&& operator*() && { return std::move(value()); }
#if BOOMKAT_CPP_EXPECTED
    std::expected<T, Error> to_expected() && {
        if (ok_) return std::move(val_);
        return std::unexpected<Error>(std::move(err_));
    }
#endif

private:
    void destroy() { if (ok_) val_.~T(); else err_.~Error(); }
    bool ok_;
    union { T val_; Error err_; };
};

template <>
class [[nodiscard]] Result<void> {
public:
    using value_type = void;
    Result() = default;
    Result(Error e) : err_(std::move(e)), ok_(false) {}
    Result(Result&&) = default;
    Result& operator=(Result&&) = default;
    bool ok() const { return ok_; }
    explicit operator bool() const { return ok_; }
    void value() const { if (!ok_) detail::fail_value(const_cast<Error&>(err_)); }
    Error& error() & { return err_; }
    const Error& error() const& { return err_; }
    Error&& error() && { return std::move(err_); }
    template <class F> auto and_then(F&& f) && -> decltype(f()) {
        if (!ok_) return std::move(err_);
        return f();
    }
#if BOOMKAT_CPP_EXPECTED
    std::expected<void, Error> to_expected() && {
        if (ok_) return {};
        return std::unexpected<Error>(std::move(err_));
    }
#endif
private:
    Error err_;
    bool ok_ = true;
};

#define BK_CONCAT_INNER_(a, b) a##b
#define BK_CONCAT_(a, b) BK_CONCAT_INNER_(a, b)
/* Declares `decl` from the value of `expr`, or returns its Error. */
#define BK_TRY_ASSIGN(decl, expr) BK_TRY_ASSIGN_IMPL_(BK_CONCAT_(bk_try_, __LINE__), decl, expr)
#define BK_TRY_ASSIGN_IMPL_(tmp, decl, expr) \
    auto tmp = (expr);                       \
    if (!tmp) return std::move(tmp).error(); \
    decl = std::move(tmp).value()
/* Returns the Error of `expr`, discarding a value. */
#define BK_TRY(expr)                                        \
    do {                                                    \
        auto bk_try_result_ = (expr);                       \
        if (!bk_try_result_) return std::move(bk_try_result_).error(); \
    } while (0)
/* Runs the fallback statement when `expr` fails. */
#define BK_TRY_OR(expr, ...)               \
    do {                                   \
        auto bk_try_result_ = (expr);      \
        if (!bk_try_result_) { __VA_ARGS__; } \
    } while (0)

/* ---- runtime bookkeeping ---------------------------------------------------- */

namespace detail {

constexpr unsigned kDataSlot = 3;  /* BK_DATA_SLOTS slot reserved for boomkat.hpp */

/* Wrapper memory (closure boxes, class records, hooks) comes from the
 * runtime's allocator. Boxes freed by finalizers keep a copy of it, because
 * finalizers may run after the runtime record is gone. */
struct Allocator {
    void* (*alloc)(void* opaque, size_t size) = nullptr;
    void (*free)(void* opaque, void* ptr) = nullptr;
    void* opaque = nullptr;
    void* allocate(size_t n) const { return alloc ? alloc(opaque, n) : std::malloc(n); }
    void deallocate(void* p) const { if (free) free(opaque, p); else std::free(p); }
};

struct ClassRecord {
    const void* tag;
    bk_class id;
    const ClassRecord* parent;
    void* (*object)(void* payload);   /* payload to T* */
    void* (*upcast)(void* object);    /* T* to the parent's object pointer */
    ClassRecord* next;
    char name[64];
};

struct Erased {
    void* object = nullptr;
    void (*destroy)(void*, const Allocator&) = nullptr;
};

struct RuntimeData {
    Allocator alloc;
    unsigned contexts = 0;
    bool owned = false;
    ClassRecord* classes = nullptr;
    Erased job_hook;
    Erased rejection_tracker;
    Erased loader;
    Erased interrupt;
#ifdef BOOMKAT_CPP_THREAD_ID
    decltype(BOOMKAT_CPP_THREAD_ID()) thread = BOOMKAT_CPP_THREAD_ID();
#endif
};

inline RuntimeData* runtime_data(bk_runtime rt) {
    return static_cast<RuntimeData*>(bk_get_runtime_data(rt, kDataSlot));
}
/* The bookkeeping of a runtime the host created through the C API is made on
 * first use and released by bk::release_runtime_data. */
inline RuntimeData* ensure_runtime_data(bk_runtime rt) {
    RuntimeData* d = runtime_data(rt);
    if (!d) {
        void* raw = std::malloc(sizeof(RuntimeData));
        if (!raw) return nullptr;
        d = new (raw) RuntimeData();
        bk_set_runtime_data(rt, kDataSlot, d);
    }
    return d;
}
inline Allocator allocator_of(bk_runtime rt) {
    RuntimeData* d = runtime_data(rt);
    return d ? d->alloc : Allocator{};
}
inline void destroy_erased(Erased& e, const Allocator& a) {
    if (e.object && e.destroy) e.destroy(e.object, a);
    e = Erased{};
}
template <class F> inline Erased make_erased(const Allocator& a, F&& f) {
    using D = remove_cvref_t<F>;
    void* raw = a.allocate(sizeof(D));
    if (!raw) return {};
    Erased e;
    e.object = new (raw) D(std::forward<F>(f));
    e.destroy = [](void* p, const Allocator& al) { static_cast<D*>(p)->~D(); al.deallocate(p); };
    return e;
}
inline void free_runtime_data(bk_runtime rt) {
    RuntimeData* d = runtime_data(rt);
    if (!d) return;
    bk_set_job_hook(rt, nullptr, nullptr);
    bk_set_promise_rejection_tracker(rt, nullptr, nullptr);
    bk_set_module_loader(rt, nullptr);
    bk_set_interrupt(rt, nullptr, nullptr);
    destroy_erased(d->interrupt, d->alloc);
    destroy_erased(d->job_hook, d->alloc);
    destroy_erased(d->rejection_tracker, d->alloc);
    destroy_erased(d->loader, d->alloc);
    for (ClassRecord* r = d->classes; r;) {
        ClassRecord* next = r->next;
        d->alloc.deallocate(r);
        r = next;
    }
    bool owned = d->owned;
    Allocator a = d->alloc;
    d->~RuntimeData();
    if (owned) a.deallocate(d); else std::free(d);
    bk_set_runtime_data(rt, kDataSlot, nullptr);
}
inline void check_thread(bk_ctx cx) {
#if defined(BOOMKAT_CPP_THREAD_ID) && BOOMKAT_CPP_DEBUG
    if (RuntimeData* d = runtime_data(bk_get_runtime(cx)))
        BOOMKAT_CPP_ASSERT(d->thread == BOOMKAT_CPP_THREAD_ID(), "runtime used from another thread");
#else
    (void)cx;
#endif
}
inline bool is_immediate(bk_value v) { return v >= BK_UNDEFINED && v <= BK_FALSE; }

}  // namespace detail

/* Releases the bookkeeping boomkat.hpp keeps for a runtime made with
 * bk_new_runtime or bk_create. Call it before bk_free_runtime. */
inline void release_runtime_data(bk_runtime rt) { detail::free_runtime_data(rt); }

/* ---- locals ------------------------------------------------------------------ */

struct RawTag { explicit RawTag() = default; };
inline constexpr RawTag raw_tag{};

/* A local handle with its context. */
class Value {
public:
    Value(RawTag, bk_ctx cx, bk_value v) : cx_(cx), v_(v) {
        BOOMKAT_CPP_ASSERT(detail::is_immediate(v) || bk_scope_current(cx) != 0,
                           "a bk:: local was created with no open bk::Scope");
        detail::check_thread(cx);
    }
    static Value from_raw(bk_ctx cx, bk_value v) { return Value(raw_tag, cx, v); }
    static Value undefined(bk_ctx cx) { return Value(raw_tag, cx, BK_UNDEFINED); }
    static Value null(bk_ctx cx) { return Value(raw_tag, cx, BK_NULL); }
    static Value boolean(bk_ctx cx, bool b) { return Value(raw_tag, cx, BK_BOOL(b)); }

    static void* operator new(size_t) = delete;
    static void* operator new[](size_t) = delete;

    bk_value raw() const { return v_; }
    inline Context context() const;
    bk_ctx raw_context() const { return cx_; }

    bk_type type() const { return bk_get_type(cx_, v_); }
    bool is_undefined() const { return v_ == BK_UNDEFINED || type() == BK_TYPE_UNDEFINED; }
    bool is_null() const { return v_ == BK_NULL || type() == BK_TYPE_NULL; }
    bool is_nullish() const { return is_undefined() || is_null(); }
    bool is_bool() const { return type() == BK_TYPE_BOOLEAN; }
    bool is_number() const { return type() == BK_TYPE_NUMBER; }
    bool is_string() const { return type() == BK_TYPE_STRING; }
    bool is_symbol() const { return type() == BK_TYPE_SYMBOL; }
    bool is_bigint() const { return type() == BK_TYPE_BIGINT; }
    bool is_object() const { bk_type t = type(); return t == BK_TYPE_OBJECT || t == BK_TYPE_FUNCTION; }
    bool is_function() const { return type() == BK_TYPE_FUNCTION; }
    bool is_array() const { return bk_is_array(cx_, v_) == 1; }

    /* A checked view: nullopt when the value is not a T. Never runs JS. */
    template <class T> std::optional<T> as() const;
    /* Conversion through Convert<T>, with a TypeError naming the expected type. */
    template <class T> Result<T> to() const;

    Result<double> to_number() const {
        double d = bk_to_number(cx_, v_);
        if (std::isnan(d) && bk_get_error_code(cx_) != BK_OK) return Error::from_pending(cx_);
        return d;
    }
    bool to_bool() const { return bk_to_bool(cx_, v_) != 0; }
    inline Result<String> to_string() const;
    bool strict_equals(Value o) const { return bk_strict_equals(cx_, v_, o.v_) != 0; }
    bool same_value(Value o) const { return bk_same_value(cx_, v_, o.v_) != 0; }
    /* Formats without running JS. Returns the full length. */
    size_t describe(char* buf, size_t cap) const {
        size_t len = 0;
        bk_status st = bk_describe(cx_, v_, buf, cap, &len);
        if (st != BK_OK && st != BK_ERR_FULL && cap) buf[0] = 0;
        return len;
    }
    inline Result<bool> instance_of(Value constructor) const;

    template <class T = Value> Global<T> persist() const;

protected:
    bk_ctx cx_;
    bk_value v_;
};

namespace detail {
template <class T> inline Result<T> wrap(bk_ctx cx, bk_value v) {
    if (v == BK_EXCEPTION) return Error::from_pending(cx);
    return T(raw_tag, cx, v);
}
inline Result<void> status(bk_ctx cx, bk_status st) {
    if (st == BK_OK) return {};
    return Error::from_pending(cx, st);
}
}  // namespace detail

class Atom;

enum class Prop : unsigned {
    none = 0, writable = BK_PROP_WRITABLE, enumerable = BK_PROP_ENUMERABLE,
    configurable = BK_PROP_CONFIGURABLE,
    all = BK_PROP_WRITABLE | BK_PROP_ENUMERABLE | BK_PROP_CONFIGURABLE
};
constexpr Prop operator|(Prop a, Prop b) { return Prop(unsigned(a) | unsigned(b)); }

struct PropertyDescriptor {
    unsigned flags = 0;
    bk_value value = BK_UNDEFINED, get = BK_UNDEFINED, set = BK_UNDEFINED;
};

class Object : public Value {
public:
    using Value::Value;
    static Result<Object> create(Context cx);
    static Result<Object> create_with_proto(Context cx, Value proto);

    Result<Value> get(std::string_view key) const {
        return detail::wrap<Value>(cx_, bk_get_property(cx_, v_, key.data(), key.size()));
    }
    Result<Value> get(uint32_t index) const {
        return detail::wrap<Value>(cx_, bk_get_property_uint32(cx_, v_, index));
    }
    inline Result<Value> get(const Atom& key) const;
    template <class T> Result<T> get_as(std::string_view key) const {
        auto v = get(key);
        if (!v) return std::move(v).error();
        return v->template to<T>();
    }

    template <class V> Result<void> set(std::string_view key, V&& value) const;
    template <class V> Result<void> set(uint32_t index, V&& value) const;
    template <class V> Result<void> set(const Atom& key, V&& value) const;

    Result<bool> has(std::string_view key) const {
        int out = 0;
        bk_status st = bk_has_property(cx_, v_, key.data(), key.size(), &out);
        if (st != BK_OK) return Error::from_pending(cx_, st);
        return out != 0;
    }
    Result<bool> remove(std::string_view key) const {
        int out = 0;
        bk_status st = bk_delete_property(cx_, v_, key.data(), key.size(), &out);
        if (st != BK_OK) return Error::from_pending(cx_, st);
        return out != 0;
    }
    /* [[DefineOwnProperty]] for a data property; false when refused. */
    template <class V> Result<bool> define(std::string_view key, V&& value, Prop attrs = Prop::all) const;
    /* An accessor pair; either may be undefined. */
    Result<bool> define_accessor(std::string_view key, Value getter, Value setter,
                                 Prop attrs = Prop::configurable) const;
    inline Result<Array> keys(unsigned flags = BK_KEYS_STRINGS | BK_KEYS_ENUMERABLE_ONLY) const;
    Result<Value> prototype() const { return detail::wrap<Value>(cx_, bk_get_prototype(cx_, v_)); }
    Result<void> set_prototype(Value proto) const {
        return detail::status(cx_, bk_set_prototype(cx_, v_, proto.raw()));
    }
    Result<uint64_t> length() const {
        uint64_t n = 0;
        bk_status st = bk_get_length(cx_, v_, &n);
        if (st != BK_OK) return Error::from_pending(cx_, st);
        return n;
    }
};

class Function : public Object {
public:
    using Object::Object;
    /* Calls with `this` undefined; each argument goes through Convert. */
    template <class... A> Result<Value> call(A&&... args) const {
        return call_with(Value::undefined(cx_), std::forward<A>(args)...);
    }
    template <class... A> Result<Value> call_with(Value self, A&&... args) const;
    Result<Value> call_raw(Value self, unsigned argc, const bk_value* argv) const {
        return detail::wrap<Value>(cx_, bk_call(cx_, v_, self.raw(), argv, argc));
    }
    template <class... A> Result<Object> construct(A&&... args) const;
    Result<Object> construct_raw(unsigned argc, const bk_value* argv, bk_value new_target = 0) const {
        return detail::wrap<Object>(cx_, bk_construct(cx_, v_, argv, argc, new_target));
    }
};

class Array : public Object {
public:
    using Object::Object;
    static Result<Array> create(Context cx);
    static Result<Array> from(Context cx, const Value* values, unsigned count);
    template <class V> Result<void> push(V&& value) const {
        auto n = length();
        if (!n) return std::move(n).error();
        return set(static_cast<uint32_t>(*n), std::forward<V>(value));
    }
};

/* The units of a string where they are stored, valid until the next engine
 * call. Neither copyable nor movable, so it stays inside the expression or
 * block that read it. */
class StringView {
public:
    StringView(const bk_string_view& v) : v_(v) {}
    StringView(const StringView&) = delete;
    StringView& operator=(const StringView&) = delete;
    size_t length() const { return v_.length; }
    bool is_latin1() const { return v_.width == 1; }
    bool is_ascii() const { return v_.ascii != 0; }
    std::string_view latin1() const {
        return is_latin1() ? std::string_view(static_cast<const char*>(v_.data), v_.length) : std::string_view();
    }
    std::u16string_view utf16() const {
        return is_latin1() ? std::u16string_view()
                           : std::u16string_view(static_cast<const char16_t*>(v_.data), v_.length);
    }
private:
    bk_string_view v_;
};

class String : public Value {
public:
    using Value::Value;
    using Release = bk_string_release;
    static Result<String> from_utf8(Context cx, std::string_view s);
#if BOOMKAT_CPP20
    static Result<String> from_utf8(Context cx, std::u8string_view s);
#endif
    static Result<String> from_latin1(Context cx, const uint8_t* chars, size_t n);
    static Result<String> from_utf16(Context cx, std::u16string_view s);
    static Result<String> external_latin1(Context cx, const uint8_t* chars, size_t n, Release release, void* opaque);
    static Result<String> external_utf16(Context cx, const char16_t* units, size_t n, Release release, void* opaque);

    size_t length() const { return bk_string_length(cx_, v_); }
    /* Bytes needed for the UTF-8 form, excluding the NUL. */
    Result<size_t> utf8_length(Utf8Mode mode = Utf8Mode::replace) const {
        size_t len = 0;
        bk_status st = bk_read_string_utf8(cx_, v_, static_cast<bk_utf8_mode>(mode), nullptr, 0, &len);
        if (st != BK_OK && st != BK_ERR_FULL) return Error::from_pending(cx_, st);
        return len;
    }
    /* Writes NUL-terminated UTF-8; needs utf8_length()+1 bytes. */
    Result<size_t> utf8(char* buf, size_t cap, Utf8Mode mode = Utf8Mode::replace) const {
        size_t len = 0;
        bk_status st = bk_read_string_utf8(cx_, v_, static_cast<bk_utf8_mode>(mode), buf, cap, &len);
        if (st != BK_OK) return Error::from_pending(cx_, st);
        return len;
    }
    Result<size_t> utf16(char16_t* buf, size_t cap) const {
        size_t len = 0;
        bk_status st = bk_read_string_utf16(cx_, v_, reinterpret_cast<uint16_t*>(buf), cap, &len);
        if (st != BK_OK) return Error::from_pending(cx_, st);
        return len;
    }
    StringView view() const {
        bk_string_view v{};
        bk_string_view_get(cx_, v_, &v);
        return StringView(v);
    }
    /* f(std::string_view latin1) or f(std::u16string_view utf16), with the
     * units in place. f must not call the engine. */
    template <class F> decltype(auto) visit(F&& f) const {
        StringView v = view();
        if (v.is_latin1()) return f(v.latin1());
        return f(v.utf16());
    }
    /* Streams the UTF-8 form to sink(std::string_view) in chunks with no full
     * copy. The sink may call the engine. */
    template <class Sink> Result<void> write_utf8(Sink&& sink, Utf8Mode mode = Utf8Mode::replace) const;
};

class Symbol : public Value {
public:
    using Value::Value;
    static Result<Symbol> create(Context cx, std::string_view description);
    static Result<Symbol> create(Context cx);
    static Result<Symbol> for_key(Context cx, std::string_view key);
    static Result<Symbol> well_known(Context cx, bk_well_known_symbol which);
    Result<Value> description() const { return detail::wrap<Value>(cx_, bk_symbol_description(cx_, v_)); }
};

class BigInt : public Value {
public:
    using Value::Value;
    static Result<BigInt> from_int64(Context cx, int64_t v);
    static Result<BigInt> from_uint64(Context cx, uint64_t v);
    static Result<BigInt> from_words(Context cx, bool negative, const uint64_t* words, size_t count);
    /* BigInt.asIntN(64); `lossless` reports whether that was exact. */
    Result<int64_t> to_int64(bool* lossless = nullptr) const {
        int64_t out = 0; int exact = 0;
        bk_status st = bk_read_bigint_int64(cx_, v_, &out, &exact);
        if (st != BK_OK) return Error::from_pending(cx_, st);
        if (lossless) *lossless = exact != 0;
        return out;
    }
    /* Magnitude words, least significant first. With words null, returns the
     * count needed. */
    Result<size_t> words(bool* negative, uint64_t* words, size_t cap) const {
        int neg = 0; size_t count = 0;
        bk_status st = bk_read_bigint_words(cx_, v_, &neg, words, cap, &count);
        if (st != BK_OK && !(st == BK_ERR_FULL && words == nullptr)) return Error::from_pending(cx_, st);
        if (negative) *negative = neg != 0;
        return count;
    }
};

class Script : public Value {
public:
    using Value::Value;
    inline Result<Value> run() const;
    inline Result<Value> run(Context cx) const;
};

/* ---- binary data ---------------------------------------------------------- */

/* Bytes of a buffer or the elements of a view. Valid until the next call that
 * can run JS, resize or detach the buffer. */
template <class E> struct Span {
    E* data = nullptr;
    size_t size = 0;
    E* begin() const { return data; }
    E* end() const { return data + size; }
    E& operator[](size_t i) const { return data[i]; }
    bool empty() const { return size == 0; }
};

/* An ArrayBuffer or, through as<ArrayBuffer>(), any buffer including a
 * SharedArrayBuffer. */
class ArrayBuffer : public Object {
public:
    using Object::Object;
    /* A zeroed buffer. */
    static inline Result<ArrayBuffer> create(Context cx, size_t length);
    static inline Result<ArrayBuffer> copy(Context cx, const void* data, size_t length);
    /* A buffer over host memory. `release(data, opaque)` runs once when the
     * buffer is detached, collected or torn down, also when creation fails. It
     * must not call the engine. */
    static inline Result<ArrayBuffer> external(Context cx, void* data, size_t length,
                                               bk_finalizer release, void* opaque);
    /* The same with a callable release(), destroyed after it runs. */
    template <class F> static Result<ArrayBuffer> external(Context cx, void* data, size_t length, F&& release);
    inline Result<Span<uint8_t>> bytes() const;
    inline Result<void> detach() const;
};

/* A SharedArrayBuffer block, reference counted across runtimes and threads.
 * Copy retains, destruction releases; both are safe on any thread. */
class SharedBlock {
public:
    SharedBlock() = default;
    /* Takes over a reference the caller holds. */
    static SharedBlock adopt(void* data, size_t length) { SharedBlock b; b.d_ = data; b.n_ = length; return b; }
    SharedBlock(const SharedBlock& o) : d_(o.d_), n_(o.n_) { if (d_) bk_shared_block_retain(d_); }
    SharedBlock(SharedBlock&& o) noexcept : d_(o.d_), n_(o.n_) { o.d_ = nullptr; o.n_ = 0; }
    SharedBlock& operator=(SharedBlock o) noexcept { std::swap(d_, o.d_); std::swap(n_, o.n_); return *this; }
    ~SharedBlock() { if (d_) bk_shared_block_release(d_); }
    explicit operator bool() const { return d_ != nullptr; }
    void* data() const { return d_; }
    size_t size() const { return n_; }
private:
    void* d_ = nullptr;
    size_t n_ = 0;
};

class SharedArrayBuffer : public ArrayBuffer {
public:
    using ArrayBuffer::ArrayBuffer;
    static inline Result<SharedArrayBuffer> create(Context cx, size_t length);
    /* A SharedArrayBuffer over the block; the buffer takes its own reference. */
    static inline Result<SharedArrayBuffer> adopt(Context cx, const SharedBlock& block);
    /* A reference to this buffer's block. */
    inline Result<SharedBlock> block() const;
};

namespace detail {
template <class E> struct element_type;
template <> struct element_type<int8_t>   { static constexpr bk_element_type value = BK_INT8; };
template <> struct element_type<uint8_t>  { static constexpr bk_element_type value = BK_UINT8; };
template <> struct element_type<int16_t>  { static constexpr bk_element_type value = BK_INT16; };
template <> struct element_type<uint16_t> { static constexpr bk_element_type value = BK_UINT16; };
template <> struct element_type<int32_t>  { static constexpr bk_element_type value = BK_INT32; };
template <> struct element_type<uint32_t> { static constexpr bk_element_type value = BK_UINT32; };
template <> struct element_type<float>    { static constexpr bk_element_type value = BK_FLOAT32; };
template <> struct element_type<double>   { static constexpr bk_element_type value = BK_FLOAT64; };
template <> struct element_type<int64_t>  { static constexpr bk_element_type value = BK_BIGINT64; };
template <> struct element_type<uint64_t> { static constexpr bk_element_type value = BK_BIGUINT64; };
template <class T> struct is_typed_array : std::false_type {};
}  // namespace detail

/* A typed array of element type E: int8_t ... uint64_t, float or double. */
template <class E> class TypedArray : public Object {
public:
    static constexpr bk_element_type kind = detail::element_type<E>::value;
    using Object::Object;
    /* A view of `length` elements of `buffer` at `byte_offset`. */
    static Result<TypedArray> create(Context cx, const ArrayBuffer& buffer, size_t byte_offset, size_t length);
    /* A view over a new zeroed buffer. */
    static Result<TypedArray> create(Context cx, size_t length);
    inline Result<Span<E>> elements() const;
    inline Result<ArrayBuffer> buffer() const;
};
namespace detail {
template <class E> struct is_typed_array<TypedArray<E>> : std::true_type {};
}  // namespace detail

/* ---- Global, Atom ---------------------------------------------------------- */

/* A registry root. Copy duplicates the root; move steals it. */
template <class T>
class Global {
    static_assert(std::is_base_of_v<Value, T>, "bk::Global holds bk:: handle types");
public:
    Global() = default;
    Global(const T& local) : cx_(local.raw_context()), h_(bk_dup_value(local.raw_context(), local.raw())) {}
    Global(const Global& o) : cx_(o.cx_), h_(o.h_ ? bk_dup_value(o.cx_, o.h_) : 0) {}
    Global(Global&& o) noexcept : cx_(o.cx_), h_(o.h_) { o.h_ = 0; }
    template <class U, std::enable_if_t<std::is_base_of_v<T, U> && !std::is_same_v<T, U>, int> = 0>
    Global(Global<U>&& o) noexcept : cx_(o.cx_), h_(o.h_) { o.h_ = 0; }
    Global& operator=(Global o) noexcept { std::swap(cx_, o.cx_); std::swap(h_, o.h_); return *this; }
    ~Global() { reset(); }

    explicit operator bool() const { return h_ != 0; }
    bool empty() const { return h_ == 0; }
    void reset() {
        if (h_) bk_free_value(cx_, h_);
        h_ = 0;
    }
    /* A local copy in the innermost scope of `cx`. */
    T get(bk_ctx cx) const {
        BOOMKAT_CPP_ASSERT(h_ != 0, "Global::get on an empty Global");
        return T(raw_tag, cx, bk_scope_local(cx, h_));
    }
    inline T get(Context cx) const;
    T get() const { return get(cx_); }
    inline Context context() const;
    bk_ctx raw_context() const { return cx_; }
    bk_value raw() const { return h_; }
    /* Adopts an owned root. */
    static Global adopt(bk_ctx cx, bk_value root) { Global g; g.cx_ = cx; g.h_ = root; return g; }

private:
    template <class U> friend class Global;
    bk_ctx cx_ = nullptr;
    bk_value h_ = 0;
};

template <class T> Global<T> Value::persist() const { return Global<T>(T(raw_tag, cx_, v_)); }

inline Global<Value> Error::exception() const {
    if (!exc_) return Global<Value>();
    return Global<Value>::adopt(cx_, bk_dup_value(cx_, exc_));
}

/* A property key held by the runtime. Copy duplicates the reference. */
class Atom {
public:
    Atom() = default;
    Atom(bk_ctx cx, std::string_view name) : cx_(cx), a_(bk_new_atom(cx, name.data(), name.size())) {}
    inline Atom(Context cx, std::string_view name);
    static Atom index(bk_ctx cx, uint32_t i) { Atom a; a.cx_ = cx; a.a_ = bk_new_atom_index(cx, i); return a; }
    static Result<Atom> from_value(Value key) {
        Atom a; a.cx_ = key.raw_context(); a.a_ = bk_value_to_atom(a.cx_, key.raw());
        if (!a.a_) return Error::from_pending(a.cx_);
        return Result<Atom>(std::move(a));
    }
    Atom(const Atom& o) : cx_(o.cx_), a_(o.a_ ? bk_dup_atom(o.cx_, o.a_) : 0) {}
    Atom(Atom&& o) noexcept : cx_(o.cx_), a_(o.a_) { o.a_ = 0; }
    Atom& operator=(Atom o) noexcept { std::swap(cx_, o.cx_); std::swap(a_, o.a_); return *this; }
    ~Atom() { if (a_) bk_free_atom(cx_, a_); }
    explicit operator bool() const { return a_ != 0; }
    bk_atom raw() const { return a_; }
    Result<Value> key() const { return detail::wrap<Value>(cx_, bk_atom_to_value(cx_, a_)); }
private:
    bk_ctx cx_ = nullptr;
    bk_atom a_ = 0;
};

inline Result<Value> Object::get(const Atom& key) const {
    return detail::wrap<Value>(cx_, bk_get_property_atom(cx_, v_, key.raw()));
}

/* ---- Context, Scope -------------------------------------------------------- */

class ExportsBuilder;
class ModuleLoader;

/* A non-owning context: trivially copyable. */
class Context {
public:
    Context() = default;
    Context(bk_ctx cx) : cx_(cx) {}
    bk_ctx raw() const { return cx_; }
    operator bk_ctx() const { return cx_; }
    explicit operator bool() const { return cx_ != nullptr; }
    inline RuntimeRef runtime() const;

    Object global() const { return Object(raw_tag, cx_, bk_get_global_object(cx_)); }
    Value undefined() const { return Value::undefined(cx_); }
    Value null() const { return Value::null(cx_); }
    Result<Value> intrinsic(bk_intrinsic which) const {
        return detail::wrap<Value>(cx_, bk_get_intrinsic(cx_, which));
    }

    /* A classic script, sloppy unless `strict`. */
    Result<Value> eval(std::string_view source, const char* filename = nullptr, bool strict = false) const {
        return detail::wrap<Value>(cx_, bk_eval_ex(cx_, source.data(), source.size(), filename,
                                                   strict ? BK_EVAL_STRICT : BK_EVAL_GLOBAL));
    }
    Result<Value> eval_module(std::string_view source, const char* filename = nullptr) const {
        return detail::wrap<Value>(cx_, bk_eval_ex(cx_, source.data(), source.size(), filename, BK_EVAL_MODULE));
    }
    Result<Script> compile(std::string_view source, const char* filename = nullptr, bool strict = false) const {
        return detail::wrap<Script>(cx_, bk_compile(cx_, source.data(), source.size(), filename,
                                                    strict ? BK_EVAL_STRICT : BK_EVAL_GLOBAL));
    }
    Result<Value> json_parse(std::string_view utf8) const {
        return detail::wrap<Value>(cx_, bk_json_parse(cx_, utf8.data(), utf8.size()));
    }
    Result<Value> json_stringify(Value v) const {
        return detail::wrap<Value>(cx_, bk_json_stringify(cx_, v.raw()));
    }
    /* Builds a new Error of `kind`; returns it, does not throw. */
    Result<Object> new_error(bk_error_kind kind, const char* message) const {
        return detail::wrap<Object>(cx_, bk_new_error(cx_, kind, message));
    }
    /* An Error for host code to return: a JS TypeError (or other kind). */
    Error error(bk_error_kind kind, const char* message) const {
        return Error::make(cx_, kind == BK_ERROR_TYPE ? Errc::type : Errc::thrown, kind, message);
    }
    Error type_error(const char* message) const { return Error::type_error(cx_, message); }
    Error range_error(const char* message) const { return Error::range_error(cx_, message); }

    /* Drains the job queue. */
    Result<void> run_jobs() const {
        bk_status st = bk_run_jobs(bk_get_runtime(cx_));
        if (st == BK_OK) return {};
        return Error::from_pending(cx_, st);
    }

    /* Modules. */
    Result<void> define_module(std::string_view name, std::string_view source) const {
        return detail::status(cx_, bk_define_module(cx_, name.data(), name.size(), source.data(), source.size()));
    }
    inline Result<void> define_module(std::string_view name, ExportsBuilder&& exports) const;
    inline Result<void> define_module(std::string_view name, Object exports) const;
    Result<void> invalidate_module(std::string_view name) const {
        return detail::status(cx_, bk_invalidate_module(cx_, name.data(), name.size()));
    }
    /* import(specifier) as a promise of the namespace. */
    inline Result<Promise> import_async(std::string_view specifier) const;
    /* Runs the job queue until the import settles. */
    inline Result<Object> import(std::string_view specifier) const;

    /* Host data slots 0-2 (slot 3 belongs to boomkat.hpp). */
    void set_data(unsigned slot, void* data) const {
        BOOMKAT_CPP_ASSERT(slot < detail::kDataSlot, "context data slot 3 is reserved");
        bk_set_context_data(cx_, slot, data);
    }
    void* data(unsigned slot) const { return bk_get_context_data(cx_, slot); }

protected:
    bk_ctx cx_ = nullptr;
};

inline Context Value::context() const { return Context(cx_); }
template <class T> inline T Global<T>::get(Context cx) const { return get(cx.raw()); }
template <class T> inline Context Global<T>::context() const { return Context(cx_); }
inline Atom::Atom(Context cx, std::string_view name) : Atom(cx.raw(), name) {}

/* RAII local scope. Stack only. */
class Scope {
public:
    explicit Scope(Context cx) : cx_(cx.raw()), s_(bk_scope_open(cx.raw())) {
        BOOMKAT_CPP_ASSERT(s_ != 0, "bk_scope_open failed");
    }
    Scope(const Scope&) = delete;
    Scope& operator=(const Scope&) = delete;
    ~Scope() { if (s_) bk_scope_close(cx_, s_); }
    static void* operator new(size_t) = delete;
    static void* operator new[](size_t) = delete;
    /* Closes the scope and returns `v` as a handle in the enclosing scope. */
    template <class T> T escape(const T& v) {
        BOOMKAT_CPP_ASSERT(s_ != 0, "Scope::escape on a closed scope");
        bk_value out = bk_scope_close_escape(cx_, s_, v.raw());
        s_ = 0;
        return T(raw_tag, cx_, out);
    }
    bk_scope raw() const { return s_; }
private:
    bk_ctx cx_;
    bk_scope s_;
};

/* ---- Runtime ------------------------------------------------------------------ */

struct RuntimeOptions {
    void* (*alloc)(void* opaque, size_t size) = nullptr;
    void* (*realloc)(void* opaque, void* ptr, size_t size) = nullptr;
    void (*free)(void* opaque, void* ptr) = nullptr;
    void* alloc_opaque = nullptr;
    void (*fatal)(void* opaque, const char* message) = nullptr;
    /* Nonzero counts heap bytes and limits them; UINT64_MAX counts only. */
    uint64_t heap_limit = 0;
};

/* A new context's options. flags: BK_CONTEXT_NO_EVAL, BK_CONTEXT_CANNOT_BLOCK.
 * With global_class, the global object is an instance of that class owning
 * global_payload. */
struct ContextOptions {
    unsigned flags = 0;
    bk_class global_class = 0;
    void* global_payload = nullptr;
};

/* Wakes bk_wait_events from any thread. */
class Waker {
public:
    explicit Waker(bk_runtime rt) : rt_(rt) {}
    void wake() const { bk_wake(rt_); }
private:
    bk_runtime rt_;
};

/* Rejection tracker event; promise and reason are borrowed. */
struct Rejection {
    Context context;
    uint64_t promise_id;
    bk_value promise;
    bk_value reason;
    bool handled;
};

class RuntimeRef {
public:
    RuntimeRef() = default;
    RuntimeRef(bk_runtime rt) : rt_(rt) {}
    bk_runtime raw() const { return rt_; }
    explicit operator bool() const { return rt_ != nullptr; }

    inline Result<OwnedContext> new_context() const;
    inline Result<OwnedContext> new_context(const struct ContextOptions& options) const;

    bool has_pending_jobs() const { return bk_is_job_pending(rt_) != 0; }
    /* Drains the queue. On failure the error is read from `cx`. */
    Result<void> run_jobs(Context cx) const { return cx.run_jobs(); }
    /* Runs one job: true when one ran. */
    Result<bool> run_one_job() const {
        bk_ctx job = nullptr;
        int r = bk_execute_pending_job(rt_, &job);
        if (r >= 0) return r == 1;
        return job ? Error::from_pending(job, static_cast<bk_status>(r)) : Error(static_cast<Errc>(r));
    }
    /* Blocks until bk_wake, an Atomics.waitAsync event, an interrupt request
     * or the timeout (negative waits indefinitely). True for an event. */
    bool wait_events(double timeout_ms) const { return bk_wait_events(rt_, timeout_ms) != 0; }
    Waker waker() const { return Waker(rt_); }
    void interrupt() const { bk_request_interrupt(rt_); }
    void clear_interrupt() const { bk_clear_interrupt(rt_); }
    unsigned run_finalizers() const { return bk_run_finalizers(rt_); }

    /* GC and resource control. */
    void gc(bool full = true) const { bk_gc(rt_, full ? BK_GC_FULL : BK_GC_MINOR); }
    /* Collector work for about `budget_ns`; true while the cycle continues. */
    bool gc_step(uint64_t budget_ns) const { return bk_gc_step(rt_, budget_ns) != 0; }
    /* Nested; see GcInhibit for the RAII form. */
    void gc_inhibit(bool inhibit) const { bk_gc_inhibit(rt_, inhibit ? 1 : 0); }
    void add_external_memory(int64_t delta_bytes) const { bk_add_external_memory(rt_, delta_bytes); }
    /* Needs a runtime made with RuntimeOptions::heap_limit; 0 removes the limit. */
    Result<void> set_heap_limit(uint64_t bytes) const {
        bk_status st = bk_set_heap_limit(rt_, bytes);
        if (st != BK_OK) return Error(static_cast<Errc>(st));
        return {};
    }
    bk_heap_stats heap_stats() const {
        bk_heap_stats s{};
        bk_get_heap_stats(rt_, &s);
        return s;
    }
    /* f(RuntimeRef) -> bool, polled while JS runs; true interrupts. It must
     * not call the engine. */
    template <class F> Result<void> on_interrupt(F&& f) const {
        detail::RuntimeData* d = detail::ensure_runtime_data(rt_);
        if (!d) return Error(Errc::nomem);
        bk_set_interrupt(rt_, nullptr, nullptr);
        detail::destroy_erased(d->interrupt, d->alloc);
        d->interrupt = detail::make_erased(d->alloc, std::forward<F>(f));
        if (!d->interrupt.object) return Error(Errc::nomem);
        using D = detail::remove_cvref_t<F>;
        bk_set_interrupt(rt_, [](bk_runtime rt, void* p) -> int { return (*static_cast<D*>(p))(RuntimeRef(rt)) ? 1 : 0; },
                         d->interrupt.object);
        return {};
    }
    void clear_interrupt_handler() const {
        bk_set_interrupt(rt_, nullptr, nullptr);
        if (detail::RuntimeData* d = detail::runtime_data(rt_)) detail::destroy_erased(d->interrupt, d->alloc);
    }

    /* f(RuntimeRef) when a job is enqueued into an empty queue. It must not
     * run JS; it schedules a checkpoint. */
    template <class F> Result<void> on_job_enqueued(F&& f) const {
        detail::RuntimeData* d = detail::ensure_runtime_data(rt_);
        if (!d) return Error(Errc::nomem);
        bk_set_job_hook(rt_, nullptr, nullptr);
        detail::destroy_erased(d->job_hook, d->alloc);
        d->job_hook = detail::make_erased(d->alloc, std::forward<F>(f));
        if (!d->job_hook.object) return Error(Errc::nomem);
        using D = detail::remove_cvref_t<F>;
        bk_set_job_hook(rt_, [](bk_runtime rt, void* p) { (*static_cast<D*>(p))(RuntimeRef(rt)); },
                        d->job_hook.object);
        return {};
    }
    void clear_job_hook() const {
        bk_set_job_hook(rt_, nullptr, nullptr);
        if (detail::RuntimeData* d = detail::runtime_data(rt_)) detail::destroy_erased(d->job_hook, d->alloc);
    }
    /* f(const Rejection&). Runs on the engine thread; must not run JS. */
    template <class F> Result<void> on_rejection(F&& f) const {
        detail::RuntimeData* d = detail::ensure_runtime_data(rt_);
        if (!d) return Error(Errc::nomem);
        bk_set_promise_rejection_tracker(rt_, nullptr, nullptr);
        detail::destroy_erased(d->rejection_tracker, d->alloc);
        d->rejection_tracker = detail::make_erased(d->alloc, std::forward<F>(f));
        if (!d->rejection_tracker.object) return Error(Errc::nomem);
        using D = detail::remove_cvref_t<F>;
        bk_set_promise_rejection_tracker(rt_,
            [](bk_ctx cx, uint64_t id, bk_value p, bk_value r, int handled, void* f) {
                (*static_cast<D*>(f))(Rejection{Context(cx), id, p, r, handled != 0});
            }, d->rejection_tracker.object);
        return {};
    }

    /* Module loader. The borrowed form leaves `loader` owned by the host. */
    inline Result<void> set_module_loader(ModuleLoader* loader, unsigned flags = 0) const;
    inline Result<void> set_module_loader(std::unique_ptr<ModuleLoader> loader, unsigned flags = 0) const;
    inline Result<void> clear_module_loader() const;

    void set_data(unsigned slot, void* data) const {
        BOOMKAT_CPP_ASSERT(slot < detail::kDataSlot, "runtime data slot 3 is reserved");
        bk_set_runtime_data(rt_, slot, data);
    }
    void* data(unsigned slot) const { return bk_get_runtime_data(rt_, slot); }

protected:
    bk_runtime rt_ = nullptr;
};

inline RuntimeRef Context::runtime() const { return RuntimeRef(bk_get_runtime(cx_)); }

/* Owns a context; destroy it before its runtime. */
class OwnedContext : public Context {
public:
    OwnedContext() = default;
    explicit OwnedContext(bk_ctx cx) : Context(cx) {
        if (detail::RuntimeData* d = detail::runtime_data(bk_get_runtime(cx))) d->contexts++;
    }
    OwnedContext(OwnedContext&& o) noexcept : Context(o.cx_) { o.cx_ = nullptr; }
    OwnedContext& operator=(OwnedContext&& o) noexcept {
        if (this != &o) { reset(); cx_ = o.cx_; o.cx_ = nullptr; }
        return *this;
    }
    OwnedContext(const OwnedContext&) = delete;
    OwnedContext& operator=(const OwnedContext&) = delete;
    ~OwnedContext() { reset(); }
    void reset() {
        if (!cx_) return;
        if (detail::RuntimeData* d = detail::runtime_data(bk_get_runtime(cx_))) d->contexts--;
        bk_free_context(cx_);
        cx_ = nullptr;
    }
    Context get() const { return Context(cx_); }
};

/* Owns a runtime. Move-only. */
class Runtime : public RuntimeRef {
public:
    Runtime() = default;
    static Result<Runtime> create(const RuntimeOptions& options = RuntimeOptions()) {
        bk_runtime_options o{options.alloc, options.realloc, options.free, options.alloc_opaque, options.fatal,
                             options.heap_limit};
        bool custom = options.alloc != nullptr;
        bk_runtime rt = bk_new_runtime(&o);
        if (!rt) return Error(custom && (!options.realloc || !options.free) ? Errc::invalid : Errc::nomem);
        detail::Allocator a;
        if (custom) { a.alloc = options.alloc; a.free = options.free; a.opaque = options.alloc_opaque; }
        void* raw = a.allocate(sizeof(detail::RuntimeData));
        if (!raw) { bk_free_runtime(rt); return Error(Errc::nomem); }
        detail::RuntimeData* d = new (raw) detail::RuntimeData();
        d->alloc = a;
        d->owned = true;
        bk_set_runtime_data(rt, detail::kDataSlot, d);
        Runtime r;
        r.rt_ = rt;
        return Result<Runtime>(std::move(r));
    }
    /* Takes ownership of a runtime made with bk_new_runtime. */
    static Runtime adopt(bk_runtime rt) {
        detail::ensure_runtime_data(rt);
        Runtime r;
        r.rt_ = rt;
        return r;
    }
    Runtime(Runtime&& o) noexcept { rt_ = o.rt_; o.rt_ = nullptr; }
    Runtime& operator=(Runtime&& o) noexcept {
        if (this != &o) { reset(); rt_ = o.rt_; o.rt_ = nullptr; }
        return *this;
    }
    Runtime(const Runtime&) = delete;
    Runtime& operator=(const Runtime&) = delete;
    ~Runtime() { reset(); }
    void reset() {
        if (!rt_) return;
        if (detail::RuntimeData* d = detail::runtime_data(rt_))
            BOOMKAT_CPP_ASSERT(d->contexts == 0, "a bk::OwnedContext outlived its bk::Runtime");
        detail::free_runtime_data(rt_);
        bk_free_runtime(rt_);
        rt_ = nullptr;
    }
    RuntimeRef ref() const { return RuntimeRef(rt_); }
};

inline Result<OwnedContext> RuntimeRef::new_context() const {
    bk_ctx cx = bk_new_context(rt_, nullptr);
    if (!cx) return Error(Errc::nomem);
    return OwnedContext(cx);
}
inline Result<OwnedContext> RuntimeRef::new_context(const ContextOptions& options) const {
    bk_context_options o{options.flags, options.global_class, options.global_payload};
    bk_ctx cx = bk_new_context(rt_, &o);
    if (!cx) return Error(Errc::invalid);
    return OwnedContext(cx);
}

/* Suspends automatic collection while alive. Nests. */
class GcInhibit {
public:
    explicit GcInhibit(RuntimeRef rt) : rt_(rt) { rt_.gc_inhibit(true); }
    GcInhibit(const GcInhibit&) = delete;
    GcInhibit& operator=(const GcInhibit&) = delete;
    ~GcInhibit() { rt_.gc_inhibit(false); }
private:
    RuntimeRef rt_;
};

/* ---- conversions ----------------------------------------------------------- */

/* Rejects a value of the wrong JS type instead of coercing it. */
template <class T> struct Strict {
    T value;
    operator const T&() const { return value; }
};
/* null and undefined become nullptr. */
template <class T> struct Nullable;
template <class T> struct Nullable<T*> {
    T* ptr = nullptr;
    explicit operator bool() const { return ptr != nullptr; }
    T* operator->() const { return ptr; }
};

namespace detail {
template <class T, class = void> struct has_convert : std::false_type {};
template <class T> struct has_convert<T, std::void_t<decltype(sizeof(Convert<T>))>> : std::true_type {};
template <class T> inline constexpr bool has_convert_v = has_convert<T>::value;

template <class T, class = void> struct has_js_name : std::false_type {};
template <class T> struct has_js_name<T, std::void_t<decltype(Convert<T>::js_name)>> : std::true_type {};
template <class T> constexpr const char* js_name() {
    if constexpr (has_js_name<T>::value) return Convert<T>::js_name;
    else return "value";
}

template <class T> inline Result<T> from_js(Value v) {
    static_assert(has_convert_v<T>,
                  "bk: no bk::Convert<T> specialization for this parameter or return type");
    return Convert<T>::from_js(v);
}
template <class T> inline Result<Value> to_js(Context cx, T&& v) {
    using D = remove_cvref_t<T>;
    static_assert(has_convert_v<D>,
                  "bk: no bk::Convert<T> specialization for this parameter or return type");
    return Convert<D>::to_js(cx, std::forward<T>(v));
}
inline Result<Value> to_js_raw(Context cx, bk_value v) {
    if (v == BK_EXCEPTION) return Error::from_pending(cx.raw());
    return Value(raw_tag, cx.raw(), v);
}
/* Turns a mismatch into "prefix: expected <name>". */
template <class T> inline Error finish_mismatch(bk_ctx cx, Error e, const char* prefix) {
    if (!e.is_mismatch()) return e;
    char buf[160];
    if (prefix && *prefix) std::snprintf(buf, sizeof buf, "%s: expected %s", prefix, js_name<T>());
    else std::snprintf(buf, sizeof buf, "expected %s", js_name<T>());
    return Error::type_error(cx, buf);
}
}  // namespace detail

template <class T> std::optional<T> Value::as() const {
    if constexpr (std::is_same_v<T, Value>) return *this;
    else if constexpr (std::is_same_v<T, Function>) { if (is_function()) return T(raw_tag, cx_, v_); }
    else if constexpr (std::is_same_v<T, Array>) { if (is_array()) return T(raw_tag, cx_, v_); }
    else if constexpr (std::is_same_v<T, Promise>) {
        bk_promise_state s;
        if (is_object() && bk_promise_state_get(cx_, v_, &s) == BK_OK) return T(raw_tag, cx_, v_);
    }
    else if constexpr (std::is_same_v<T, Object>) { if (is_object()) return T(raw_tag, cx_, v_); }
    else if constexpr (std::is_same_v<T, String>) { if (is_string()) return T(raw_tag, cx_, v_); }
    else if constexpr (std::is_same_v<T, Symbol>) { if (is_symbol()) return T(raw_tag, cx_, v_); }
    else if constexpr (std::is_same_v<T, BigInt>) { if (is_bigint()) return T(raw_tag, cx_, v_); }
    else if constexpr (std::is_same_v<T, Script>) { if (is_object()) return T(raw_tag, cx_, v_); }
    else if constexpr (std::is_same_v<T, ArrayBuffer>) {
        if (is_object() && bk_get_array_buffer(cx_, v_, nullptr, nullptr) == BK_OK) return T(raw_tag, cx_, v_);
    }
    else if constexpr (detail::is_typed_array<T>::value) {
        bk_typed_array_info info{};
        if (is_object() && bk_get_typed_array(cx_, v_, &info) == BK_OK) {
            bk_free_value(cx_, info.buffer);
            if (info.type == T::kind) return T(raw_tag, cx_, v_);
        }
    }
    else if constexpr (std::is_same_v<T, SharedArrayBuffer>)
        static_assert(!sizeof(T*), "as<SharedArrayBuffer> is not checkable; use as<ArrayBuffer>");
    else static_assert(std::is_base_of_v<Value, T>, "Value::as<T> takes a bk:: handle type");
    return std::nullopt;
}

template <class T> Result<T> Value::to() const {
    auto r = detail::from_js<T>(*this);
    if (r) return r;
    return detail::finish_mismatch<T>(cx_, std::move(r).error(), nullptr);
}

/* Handle types: a checked view, no coercion. */
template <class T>
struct Convert<T, std::enable_if_t<std::is_base_of_v<Value, T>>> {
    static constexpr const char* js_name =
        std::is_same_v<T, Function> ? "function" : std::is_same_v<T, Array> ? "array"
      : std::is_same_v<T, String> ? "string" : std::is_same_v<T, Symbol> ? "symbol"
      : std::is_same_v<T, BigInt> ? "bigint" : std::is_same_v<T, Promise> ? "promise"
      : std::is_same_v<T, Value> ? "value" : "object";
    static Result<T> from_js(Value v) {
        if (auto t = v.as<T>()) return *t;
        return Error::mismatch(v.raw_context());
    }
    static Result<Value> to_js(Context, const T& v) { return Value(v); }
};

template <> struct Convert<bool> {
    static constexpr const char* js_name = "boolean";
    static Result<bool> from_js(Value v) { return v.to_bool(); }
    static Result<Value> to_js(Context cx, bool b) { return Value::boolean(cx.raw(), b); }
};

template <class T>
struct Convert<T, std::enable_if_t<std::is_floating_point_v<T>>> {
    static constexpr const char* js_name = "number";
    static Result<T> from_js(Value v) {
        auto d = v.to_number();
        if (!d) return std::move(d).error();
        return static_cast<T>(*d);
    }
    static Result<Value> to_js(Context cx, T d) {
        return detail::to_js_raw(cx, bk_new_number(cx.raw(), static_cast<double>(d)));
    }
};

template <class T>
struct Convert<T, std::enable_if_t<std::is_integral_v<T> && !std::is_same_v<T, bool>>> {
    static constexpr const char* js_name = "number";
    static constexpr bool wide = sizeof(T) > 4;
    static Result<T> from_js(Value v) {
        bk_ctx cx = v.raw_context();
        if constexpr (wide) {
            constexpr double kSafe = 9007199254740991.0;
            if (v.is_bigint()) {
                if constexpr (std::is_signed_v<T>) {
                    int64_t out = 0; int exact = 0;
                    bk_status st = bk_read_bigint_int64(cx, v.raw(), &out, &exact);
                    if (st != BK_OK) return Error::from_pending(cx, st);
                    if (!exact) return Error::range_error(cx, "BigInt out of range for a 64-bit integer");
                    return static_cast<T>(out);
                } else {
                    int neg = 0; uint64_t w[2] = {0, 0}; size_t count = 0;
                    bk_status st = bk_read_bigint_words(cx, v.raw(), &neg, w, 2, &count);
                    if (st != BK_OK && st != BK_ERR_FULL) return Error::from_pending(cx, st);
                    if (st == BK_ERR_FULL || count > 1 || (neg && count > 0))
                        return Error::range_error(cx, "BigInt out of range for an unsigned 64-bit integer");
                    return static_cast<T>(w[0]);
                }
            }
            auto d = v.to_number();
            if (!d) return std::move(d).error();
            double t = std::trunc(*d);
            if (!std::isfinite(t) || t > kSafe || t < -kSafe ||
                (std::is_unsigned_v<T> && t < 0))
                return Error::range_error(cx, "number out of range for a 64-bit integer");
            return static_cast<T>(t);
        } else {
            auto d = v.to_number();
            if (!d) return std::move(d).error();
            double t = std::trunc(*d);
            if (!std::isfinite(t)) return static_cast<T>(0);
            /* The spec's modular conversion (ToInt32/ToUint32 and the narrower
             * WebIDL forms). */
            constexpr double kMod = 4294967296.0;
            double m = std::fmod(t, kMod);
            if (m < 0) m += kMod;
            uint32_t bits = static_cast<uint32_t>(m);
            using U = std::make_unsigned_t<T>;
            return static_cast<T>(static_cast<U>(bits));
        }
    }
    static Result<Value> to_js(Context cx, T v) {
        if constexpr (wide) {
            constexpr int64_t kSafe = 9007199254740991LL;
            bool fits = std::is_signed_v<T> ? (static_cast<int64_t>(v) <= kSafe && static_cast<int64_t>(v) >= -kSafe)
                                            : static_cast<uint64_t>(v) <= static_cast<uint64_t>(kSafe);
            if (!fits) {
                bk_value b = std::is_signed_v<T> ? bk_new_bigint_int64(cx.raw(), static_cast<int64_t>(v))
                                                 : bk_new_bigint_uint64(cx.raw(), static_cast<uint64_t>(v));
                return detail::to_js_raw(cx, b);
            }
        }
        return detail::to_js_raw(cx, bk_new_number(cx.raw(), static_cast<double>(v)));
    }
};

template <class T>
struct Convert<T, std::enable_if_t<std::is_enum_v<T>>> {
    using U = std::underlying_type_t<T>;
    static constexpr const char* js_name = "number";
    static Result<T> from_js(Value v) {
        auto u = Convert<U>::from_js(v);
        if (!u) return std::move(u).error();
        return static_cast<T>(*u);
    }
    static Result<Value> to_js(Context cx, T v) { return Convert<U>::to_js(cx, static_cast<U>(v)); }
};

template <class T> struct Convert<std::optional<T>> {
    static constexpr const char* js_name = detail::js_name<T>();
    static Result<std::optional<T>> from_js(Value v) {
        if (v.is_undefined()) return std::optional<T>();
        auto r = detail::from_js<T>(v);
        if (!r) return std::move(r).error();
        return std::optional<T>(std::move(*r));
    }
    static Result<Value> to_js(Context cx, const std::optional<T>& v) {
        if (!v) return cx.undefined();
        return detail::to_js(cx, *v);
    }
};

template <class T> struct Convert<Strict<T>> {
    static constexpr const char* js_name = detail::js_name<T>();
    static Result<Strict<T>> from_js(Value v) {
        bool ok = true;
        if constexpr (std::is_same_v<T, bool>) ok = v.is_bool();
        else if constexpr (std::is_arithmetic_v<T>) ok = v.is_number() || (sizeof(T) > 4 && v.is_bigint());
        else if constexpr (std::is_same_v<T, String>) ok = v.is_string();
        if (!ok) return Error::mismatch(v.raw_context());
        auto r = detail::from_js<T>(v);
        if (!r) return std::move(r).error();
        return Strict<T>{std::move(*r)};
    }
    static Result<Value> to_js(Context cx, const Strict<T>& v) { return detail::to_js(cx, v.value); }
};

template <> struct Convert<const char*> {
    static constexpr const char* js_name = "string";
    static Result<Value> to_js(Context cx, const char* s) {
        if (!s) return cx.null();
        return detail::to_js_raw(cx, bk_new_string(cx.raw(), s, std::strlen(s)));
    }
};
template <> struct Convert<char*> : Convert<const char*> {};
template <size_t N> struct Convert<char[N]> {
    static constexpr const char* js_name = "string";
    static Result<Value> to_js(Context cx, const char (&s)[N]) {
        return detail::to_js_raw(cx, bk_new_string(cx.raw(), s, std::strlen(s)));
    }
};

template <> struct Convert<std::nullptr_t> {
    static constexpr const char* js_name = "null";
    static Result<Value> to_js(Context cx, std::nullptr_t) { return cx.null(); }
};

template <class T> struct Convert<Global<T>> {
    static constexpr const char* js_name = detail::js_name<T>();
    static Result<Global<T>> from_js(Value v) {
        auto r = Convert<T>::from_js(v);
        if (!r) return std::move(r).error();
        return Global<T>(*r);
    }
    static Result<Value> to_js(Context cx, const Global<T>& g) {
        if (!g) return cx.undefined();
        return Value(g.get(cx));
    }
};

template <class T> struct Convert<Result<T>> {
    static Result<Value> to_js(Context cx, Result<T>&& r) {
        if (!r) return std::move(r).error();
        if constexpr (std::is_void_v<T>) return cx.undefined();
        else return detail::to_js(cx, std::move(r).value());
    }
    static Result<Value> to_js(Context cx, const Result<T>& r) {
        if (!r) return r.error().clone();
        if constexpr (std::is_void_v<T>) return cx.undefined();
        else return detail::to_js(cx, r.value());
    }
};

/* ---- definitions that needed Convert ------------------------------------------------ */

template <class V> Result<void> Object::set(std::string_view key, V&& value) const {
    auto v = detail::to_js(Context(cx_), std::forward<V>(value));
    if (!v) return std::move(v).error();
    return detail::status(cx_, bk_set_property(cx_, v_, key.data(), key.size(), v->raw()));
}
template <class V> Result<void> Object::set(uint32_t index, V&& value) const {
    auto v = detail::to_js(Context(cx_), std::forward<V>(value));
    if (!v) return std::move(v).error();
    return detail::status(cx_, bk_set_property_uint32(cx_, v_, index, v->raw()));
}
template <class V> Result<void> Object::set(const Atom& key, V&& value) const {
    auto v = detail::to_js(Context(cx_), std::forward<V>(value));
    if (!v) return std::move(v).error();
    return detail::status(cx_, bk_set_property_atom(cx_, v_, key.raw(), v->raw()));
}
template <class V> Result<bool> Object::define(std::string_view key, V&& value, Prop attrs) const {
    auto v = detail::to_js(Context(cx_), std::forward<V>(value));
    if (!v) return std::move(v).error();
    Atom a(cx_, key);
    if (!a) return Error::from_pending(cx_);
    bk_property_descriptor d{};
    d.flags = unsigned(attrs) | BK_PROP_HAS_VALUE | BK_PROP_HAS_WRITABLE | BK_PROP_HAS_ENUMERABLE |
              BK_PROP_HAS_CONFIGURABLE;
    d.value = v->raw(); d.get = BK_UNDEFINED; d.set = BK_UNDEFINED;
    int ok = 0;
    bk_status st = bk_define_property(cx_, v_, a.raw(), &d, &ok);
    if (st != BK_OK) return Error::from_pending(cx_, st);
    return ok != 0;
}
inline Result<bool> Object::define_accessor(std::string_view key, Value getter, Value setter, Prop attrs) const {
    Atom a(cx_, key);
    if (!a) return Error::from_pending(cx_);
    bk_property_descriptor d{};
    d.flags = (unsigned(attrs) & (BK_PROP_ENUMERABLE | BK_PROP_CONFIGURABLE)) | BK_PROP_HAS_GET |
              BK_PROP_HAS_SET | BK_PROP_HAS_ENUMERABLE | BK_PROP_HAS_CONFIGURABLE;
    d.value = BK_UNDEFINED; d.get = getter.raw(); d.set = setter.raw();
    int ok = 0;
    bk_status st = bk_define_property(cx_, v_, a.raw(), &d, &ok);
    if (st != BK_OK) return Error::from_pending(cx_, st);
    return ok != 0;
}
inline Result<Array> Object::keys(unsigned flags) const {
    return detail::wrap<Array>(cx_, bk_get_own_property_keys(cx_, v_, flags));
}
inline Result<Object> Object::create(Context cx) { return detail::wrap<Object>(cx, bk_new_object(cx)); }
inline Result<Object> Object::create_with_proto(Context cx, Value proto) {
    return detail::wrap<Object>(cx, bk_new_object_with_proto(cx, proto.raw()));
}
inline Result<bool> Value::instance_of(Value constructor) const {
    int out = 0;
    bk_status st = bk_instanceof(cx_, v_, constructor.raw(), &out);
    if (st != BK_OK) return Error::from_pending(cx_, st);
    return out != 0;
}
inline Result<String> Value::to_string() const { return detail::wrap<String>(cx_, bk_to_string(cx_, v_)); }

namespace detail {
template <size_t N> struct ArgBuf { bk_value v[N ? N : 1]; };
template <class... A> inline Result<void> fill_args(Context cx, bk_value* out, A&&... args) {
    Error err;
    bool ok = true;
    size_t i = 0;
    auto one = [&](auto&& a) {
        if (!ok) return;
        auto r = to_js(cx, std::forward<decltype(a)>(a));
        if (!r) { ok = false; err = std::move(r).error(); return; }
        out[i++] = r->raw();
    };
    (one(std::forward<A>(args)), ...);
    if (!ok) return err;
    return {};
}
}  // namespace detail

template <class... A> Result<Value> Function::call_with(Value self, A&&... args) const {
    detail::ArgBuf<sizeof...(A)> buf;
    BK_TRY(detail::fill_args(Context(cx_), buf.v, std::forward<A>(args)...));
    return detail::wrap<Value>(cx_, bk_call(cx_, v_, self.raw(), buf.v, sizeof...(A)));
}
template <class... A> Result<Object> Function::construct(A&&... args) const {
    detail::ArgBuf<sizeof...(A)> buf;
    BK_TRY(detail::fill_args(Context(cx_), buf.v, std::forward<A>(args)...));
    return detail::wrap<Object>(cx_, bk_construct(cx_, v_, buf.v, sizeof...(A), 0));
}

inline Result<Array> Array::create(Context cx) { return detail::wrap<Array>(cx, bk_new_array(cx)); }
inline Result<Array> Array::from(Context cx, const Value* values, unsigned count) {
    bk_value stack[16];
    bk_value* raw = count <= 16 ? stack : static_cast<bk_value*>(std::malloc(sizeof(bk_value) * count));
    if (!raw) return Error(Errc::nomem, cx.raw());
    for (unsigned i = 0; i < count; i++) raw[i] = values[i].raw();
    bk_value a = bk_new_array_from(cx, raw, count);
    if (raw != stack) std::free(raw);
    return detail::wrap<Array>(cx, a);
}

inline Result<String> String::from_utf8(Context cx, std::string_view s) {
    return detail::wrap<String>(cx, bk_new_string(cx, s.data(), s.size()));
}
#if BOOMKAT_CPP20
inline Result<String> String::from_utf8(Context cx, std::u8string_view s) {
    return detail::wrap<String>(cx, bk_new_string(cx, reinterpret_cast<const char*>(s.data()), s.size()));
}
#endif
inline Result<String> String::from_latin1(Context cx, const uint8_t* chars, size_t n) {
    return detail::wrap<String>(cx, bk_new_string_latin1(cx, chars, n));
}
inline Result<String> String::from_utf16(Context cx, std::u16string_view s) {
    return detail::wrap<String>(cx, bk_new_string_utf16(cx, reinterpret_cast<const uint16_t*>(s.data()), s.size()));
}
inline Result<String> String::external_latin1(Context cx, const uint8_t* chars, size_t n, Release release, void* opaque) {
    return detail::wrap<String>(cx, bk_new_external_string_latin1(cx, chars, n, release, opaque));
}
inline Result<String> String::external_utf16(Context cx, const char16_t* units, size_t n, Release release, void* opaque) {
    return detail::wrap<String>(cx, bk_new_external_string_utf16(cx, reinterpret_cast<const uint16_t*>(units), n,
                                                                 release, opaque));
}
template <class Sink> Result<void> String::write_utf8(Sink&& sink, Utf8Mode mode) const {
    char buf[256];
    size_t used = 0, i = 0;
    for (;;) {
        bk_string_view v{};
        bk_status st = bk_string_view_get(cx_, v_, &v);
        if (st != BK_OK) return Error::from_pending(cx_, st);
        if (i >= v.length) break;
        /* Encode until the buffer is nearly full; the view stays valid because
         * nothing here calls the engine. */
        while (i < v.length && used + 4 <= sizeof buf) {
            uint32_t cp;
            if (v.width == 1) {
                cp = static_cast<const uint8_t*>(v.data)[i++];
            } else {
                const uint16_t* u = static_cast<const uint16_t*>(v.data);
                cp = u[i++];
                if (cp >= 0xD800 && cp <= 0xDBFF && i < v.length && u[i] >= 0xDC00 && u[i] <= 0xDFFF) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (u[i++] - 0xDC00);
                } else if (cp >= 0xD800 && cp <= 0xDFFF) {
                    if (mode == Utf8Mode::strict) return Error::make(cx_, Errc::encoding, BK_ERROR_TYPE, "lone surrogate");
                    cp = 0xFFFD;
                }
            }
            if (cp < 0x80) buf[used++] = static_cast<char>(cp);
            else if (cp < 0x800) {
                buf[used++] = static_cast<char>(0xC0 | (cp >> 6));
                buf[used++] = static_cast<char>(0x80 | (cp & 0x3F));
            } else if (cp < 0x10000) {
                buf[used++] = static_cast<char>(0xE0 | (cp >> 12));
                buf[used++] = static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
                buf[used++] = static_cast<char>(0x80 | (cp & 0x3F));
            } else {
                buf[used++] = static_cast<char>(0xF0 | (cp >> 18));
                buf[used++] = static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
                buf[used++] = static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
                buf[used++] = static_cast<char>(0x80 | (cp & 0x3F));
            }
        }
        sink(std::string_view(buf, used));
        used = 0;
    }
    return {};
}

inline Result<Symbol> Symbol::create(Context cx, std::string_view d) {
    return detail::wrap<Symbol>(cx, bk_new_symbol(cx, d.data(), d.size()));
}
inline Result<Symbol> Symbol::create(Context cx) { return detail::wrap<Symbol>(cx, bk_new_symbol(cx, nullptr, 0)); }
inline Result<Symbol> Symbol::for_key(Context cx, std::string_view k) {
    return detail::wrap<Symbol>(cx, bk_symbol_for(cx, k.data(), k.size()));
}
inline Result<Symbol> Symbol::well_known(Context cx, bk_well_known_symbol w) {
    return detail::wrap<Symbol>(cx, bk_get_well_known_symbol(cx, w));
}
inline Result<BigInt> BigInt::from_int64(Context cx, int64_t v) { return detail::wrap<BigInt>(cx, bk_new_bigint_int64(cx, v)); }
inline Result<BigInt> BigInt::from_uint64(Context cx, uint64_t v) { return detail::wrap<BigInt>(cx, bk_new_bigint_uint64(cx, v)); }
inline Result<BigInt> BigInt::from_words(Context cx, bool neg, const uint64_t* w, size_t n) {
    return detail::wrap<BigInt>(cx, bk_new_bigint_words(cx, neg ? 1 : 0, w, n));
}
inline Result<Value> Script::run() const { return detail::wrap<Value>(cx_, bk_run_script(cx_, v_)); }
inline Result<Value> Script::run(Context cx) const { return detail::wrap<Value>(cx, bk_run_script(cx, v_)); }

/* ---- binding functions ---------------------------------------------------------- */

/* The call a C++ callback is running. */
class CallInfo {
public:
    CallInfo(bk_ctx cx, bk_value self, unsigned argc, const bk_value* argv, const char* name, void* data)
        : cx_(cx), self_(self), argc_(argc), argv_(argv), name_(name), data_(data) {}
    Context context() const { return Context(cx_); }
    unsigned argc() const { return argc_; }
    Value arg(unsigned i) const { return Value(raw_tag, cx_, i < argc_ ? argv_[i] : BK_UNDEFINED); }
    Value this_value() const { return Value(raw_tag, cx_, self_); }
    Value new_target() const { return Value(raw_tag, cx_, bk_get_new_target(cx_)); }
    bool is_construct() const { return bk_is_constructor_call(cx_) != 0; }
    const bk_value* raw_args() const { return argv_; }
    const char* name() const { return name_ ? name_ : "function"; }
    void* data() const { return data_; }
private:
    bk_ctx cx_;
    bk_value self_;
    unsigned argc_;
    const bk_value* argv_;
    const char* name_;
    void* data_;
};

/* `this`, converted: a bound class pointer or a handle type. */
template <class T> class This {
public:
    explicit This(T v) : v_(std::move(v)) {}
    T& get() { return v_; }
    const T& get() const { return v_; }
    auto operator->() {
        if constexpr (std::is_pointer_v<T>) return v_;
        else return &v_;
    }
private:
    T v_;
};

/* The remaining arguments, converted on access. */
template <class T> class Rest {
public:
    Rest(const CallInfo* info, unsigned first) : info_(info), first_(first) {}
    unsigned size() const { return info_->argc() > first_ ? info_->argc() - first_ : 0; }
    bool empty() const { return size() == 0; }
    Result<T> at(unsigned i) const {
        auto r = detail::from_js<T>(info_->arg(first_ + i));
        if (r) return r;
        char prefix[96];
        std::snprintf(prefix, sizeof prefix, "%s: argument %u", info_->name(), first_ + i + 1);
        return detail::finish_mismatch<T>(info_->context().raw(), std::move(r).error(), prefix);
    }
    Value raw(unsigned i) const { return info_->arg(first_ + i); }
private:
    const CallInfo* info_;
    unsigned first_;
};

namespace detail {

template <class F, class = void> struct fn_traits;
template <class R, class... A> struct fn_traits<R (*)(A...)> {
    using ret = R; using args = std::tuple<A...>; using cls = void; static constexpr bool member = false;
};
template <class R, class... A> struct fn_traits<R (*)(A...) noexcept> : fn_traits<R (*)(A...)> {};
template <class R, class C, class... A> struct fn_traits<R (C::*)(A...)> {
    using ret = R; using args = std::tuple<A...>; using cls = C; static constexpr bool member = true;
};
template <class R, class C, class... A> struct fn_traits<R (C::*)(A...) const> : fn_traits<R (C::*)(A...)> {};
template <class R, class C, class... A> struct fn_traits<R (C::*)(A...) noexcept> : fn_traits<R (C::*)(A...)> {};
template <class R, class C, class... A> struct fn_traits<R (C::*)(A...) const noexcept> : fn_traits<R (C::*)(A...)> {};
/* Lambdas and function objects: the parameters of operator(). */
template <class L> struct fn_traits<L, std::void_t<decltype(&L::operator())>> {
    using base = fn_traits<decltype(&L::operator())>;
    using ret = typename base::ret; using args = typename base::args; using cls = void;
    static constexpr bool member = false;
};

template <class P, class = void> struct Param {
    using D = remove_cvref_t<P>;
    static constexpr bool consumes = true;
    using storage = D;
    static Result<D> get(const CallInfo& ci, unsigned& i) {
        unsigned at = i++;
        auto r = from_js<D>(ci.arg(at));
        if (r) return r;
        char prefix[96];
        std::snprintf(prefix, sizeof prefix, "%s: argument %u", ci.name(), at + 1);
        return finish_mismatch<D>(ci.context().raw(), std::move(r).error(), prefix);
    }
    static P pass(D& s) {
        if constexpr (std::is_lvalue_reference_v<P>) return s;
        else return std::move(s);
    }
};
template <class P> struct Param<P, std::enable_if_t<std::is_same_v<remove_cvref_t<P>, Context>>> {
    static constexpr bool consumes = false;
    using storage = Context;
    static Result<Context> get(const CallInfo& ci, unsigned&) { return ci.context(); }
    static Context pass(Context& c) { return c; }
};
template <class P> struct Param<P, std::enable_if_t<std::is_same_v<remove_cvref_t<P>, CallInfo>>> {
    static constexpr bool consumes = false;
    using storage = CallInfo*;
    static Result<CallInfo*> get(const CallInfo& ci, unsigned&) { return const_cast<CallInfo*>(&ci); }
    static CallInfo& pass(CallInfo*& c) { return *c; }
};
template <class T> struct is_this : std::false_type {};
template <class T> struct is_this<This<T>> : std::true_type {};
template <class T> struct is_rest : std::false_type {};
template <class T> struct is_rest<Rest<T>> : std::true_type {};
template <class P> struct Param<P, std::enable_if_t<is_this<remove_cvref_t<P>>::value>> {
    using D = remove_cvref_t<P>;
    static constexpr bool consumes = false;
    using storage = D;
    template <class T> static T inner(This<T>*);
    using Inner = decltype(inner(static_cast<D*>(nullptr)));
    static Result<D> get(const CallInfo& ci, unsigned&) {
        auto r = from_js<Inner>(ci.this_value());
        if (r) return D(std::move(*r));
        char prefix[96];
        std::snprintf(prefix, sizeof prefix, "%s: this", ci.name());
        return finish_mismatch<Inner>(ci.context().raw(), std::move(r).error(), prefix);
    }
    static D pass(D& s) { return s; }
};
template <class P> struct Param<P, std::enable_if_t<is_rest<remove_cvref_t<P>>::value>> {
    using D = remove_cvref_t<P>;
    static constexpr bool consumes = true;
    using storage = D;
    static Result<D> get(const CallInfo& ci, unsigned& i) {
        D r(&ci, i);
        i = ci.argc() > i ? ci.argc() : i;
        return r;
    }
    static D pass(D& s) { return s; }
};

template <class T> struct type_tag { using type = T; };
template <class Tuple> struct arity;
template <class... A> struct arity<std::tuple<A...>> {
    static constexpr int value = (0 + ... + (Param<A>::consumes && !is_rest<remove_cvref_t<A>>::value ? 1 : 0));
};

/* Converts the arguments of `info` for a parameter list, left to right,
 * stopping at the first failure. */
template <class... A, size_t... I>
inline Result<std::tuple<std::optional<typename Param<A>::storage>...>>
convert_args(const CallInfo& ci, std::tuple<A...>*, std::index_sequence<I...>) {
    std::tuple<std::optional<typename Param<A>::storage>...> out;
    unsigned next = 0;
    Error err;
    bool ok = true;
    auto one = [&](auto& slot, auto* tag) {
        if (!ok) return;
        using PA = typename std::remove_pointer_t<decltype(tag)>::type;
        auto r = Param<PA>::get(ci, next);
        if (!r) { ok = false; err = std::move(r).error(); return; }
        slot.emplace(std::move(*r));
    };
    (one(std::get<I>(out), static_cast<type_tag<A>*>(nullptr)), ...);
    (void)one;
    if (!ok) return err;
    return Result<std::tuple<std::optional<typename Param<A>::storage>...>>(std::move(out));
}

template <class R> inline bk_value return_value(bk_ctx cx, R&& r) {
    using D = remove_cvref_t<R>;
    if constexpr (is_result<D>::value) {
        if (!r) return r.error().rethrow(cx);
        if constexpr (std::is_void_v<typename D::value_type>) return BK_UNDEFINED;
        else return return_value(cx, std::move(*r));
    } else {
        auto v = to_js(Context(cx), std::forward<R>(r));
        if (!v) return v.error().rethrow(cx);
        return v->raw();
    }
}

template <class Traits, class F, class Self, class Tuple, size_t... I>
inline bk_value invoke_with(const CallInfo& ci, F&& f, Self* self, Tuple& t, std::index_sequence<I...>) {
    using Args = typename Traits::args;
    using R = typename Traits::ret;
    (void)self; (void)t;
    if constexpr (std::is_void_v<R>) {
        if constexpr (Traits::member)
            (self->*f)(Param<std::tuple_element_t<I, Args>>::pass(*std::get<I>(t))...);
        else
            f(Param<std::tuple_element_t<I, Args>>::pass(*std::get<I>(t))...);
        return BK_UNDEFINED;
    } else {
        if constexpr (Traits::member)
            return return_value(ci.context().raw(), (self->*f)(Param<std::tuple_element_t<I, Args>>::pass(*std::get<I>(t))...));
        else
            return return_value(ci.context().raw(), f(Param<std::tuple_element_t<I, Args>>::pass(*std::get<I>(t))...));
    }
}

/* Invokes `f` with converted arguments. `self` is the object for member
 * functions. */
template <class Traits, class F, class Self>
inline bk_value invoke(const CallInfo& ci, F&& f, Self* self) {
    using Args = typename Traits::args;
    constexpr size_t N = std::tuple_size_v<Args>;
    auto conv = convert_args(ci, static_cast<Args*>(nullptr), std::make_index_sequence<N>());
    if (!conv) return conv.error().rethrow(ci.context().raw());
    return invoke_with<Traits>(ci, std::forward<F>(f), self, *conv, std::make_index_sequence<N>());
}

template <class Tuple> struct has_this_param;
template <class... A> struct has_this_param<std::tuple<A...>>
    : std::bool_constant<(is_this<remove_cvref_t<A>>::value || ...)> {};
template <class R, class Args> struct plain_traits {
    using ret = R; using args = Args; using cls = void; static constexpr bool member = false;
};
template <class First, class... Rest> std::tuple<Rest...> tuple_tail(std::tuple<First, Rest...>*);

}  // namespace detail

#if BOOMKAT_CPP_EXCEPTIONS
#define BOOMKAT_CPP_TRY try {
#define BOOMKAT_CPP_CATCH(cx)                                                         \
    }                                                                                 \
    catch (::bk::JsError & e) { return e.error().rethrow(cx); }                       \
    catch (::std::exception & e) { return bk_throw_error(cx, BK_ERROR, e.what()); }   \
    catch (...) { return bk_throw_error(cx, BK_ERROR, "C++ exception"); }
#else
#define BOOMKAT_CPP_TRY {
#define BOOMKAT_CPP_CATCH(cx) }
#endif

namespace detail {

template <auto F>
bk_value fn_trampoline(bk_ctx cx, bk_value self, unsigned argc, const bk_value* argv, void* data) {
    BOOMKAT_CPP_TRY
        CallInfo ci(cx, self, argc, argv, static_cast<const char*>(data), nullptr);
        return invoke<fn_traits<decltype(F)>>(ci, F, static_cast<void*>(nullptr));
    BOOMKAT_CPP_CATCH(cx)
}

template <class L> struct ClosureBox {
    L fn;
    Allocator alloc;
    char name[48];
};
template <class L>
bk_value closure_trampoline(bk_ctx cx, bk_value self, unsigned argc, const bk_value* argv, void* data) {
    BOOMKAT_CPP_TRY
        auto* box = static_cast<ClosureBox<L>*>(data);
        CallInfo ci(cx, self, argc, argv, box->name, nullptr);
        return invoke<fn_traits<L>>(ci, box->fn, static_cast<void*>(nullptr));
    BOOMKAT_CPP_CATCH(cx)
}
template <class L> void closure_finalize(void* data, void*) {
    auto* box = static_cast<ClosureBox<L>*>(data);
    Allocator a = box->alloc;
    box->~ClosureBox<L>();
    a.deallocate(box);
}
inline void copy_name(char* dst, size_t cap, const char* src) {
    size_t n = src ? std::strlen(src) : 0;
    if (n >= cap) n = cap - 1;
    if (n) std::memcpy(dst, src, n);
    dst[n] = 0;
}
}  // namespace detail

/* A function bound with no allocation and no closure. `name` must have static
 * storage duration: it appears in argument errors. */
template <auto F> Result<Function> function(Context cx, const char* name) {
    using T = detail::fn_traits<decltype(F)>;
    static_assert(!T::member, "bk::function binds free functions; use Class<T>::method for members");
    return detail::wrap<Function>(cx, bk_new_c_function(cx, &detail::fn_trampoline<F>, name,
                                                        detail::arity<typename T::args>::value, 0,
                                                        const_cast<char*>(name), nullptr, nullptr));
}

/* A function over a callable with captures. The callable is destroyed exactly
 * once, when the function is collected or the runtime is destroyed. */
template <class L> Result<Function> closure(Context cx, const char* name, L&& fn) {
    using D = detail::remove_cvref_t<L>;
    using T = detail::fn_traits<D>;
    detail::Allocator a = detail::allocator_of(bk_get_runtime(cx));
    void* raw = a.allocate(sizeof(detail::ClosureBox<D>));
    if (!raw) return Error(Errc::nomem, cx.raw());
    auto* box = new (raw) detail::ClosureBox<D>{std::forward<L>(fn), a, {}};
    detail::copy_name(box->name, sizeof box->name, name);
    return detail::wrap<Function>(cx, bk_new_c_function(cx, &detail::closure_trampoline<D>, box->name,
                                                        detail::arity<typename T::args>::value, 0, box,
                                                        &detail::closure_finalize<D>, nullptr));
}

/* ---- promises ----------------------------------------------------------------- */

class Resolver;

class Promise : public Object {
public:
    using Object::Object;
    /* A pending promise and the resolver that settles it. */
    static inline Result<std::pair<Promise, Resolver>> create(Context cx);
    /* Promise.resolve(value). */
    static Result<Promise> resolve(Context cx, Value v) {
        return detail::wrap<Promise>(cx, bk_promise_resolve(cx, v.raw()));
    }
    bk_promise_state state() const {
        bk_promise_state s = BK_PROMISE_PENDING;
        bk_promise_state_get(cx_, v_, &s);
        return s;
    }
    bool is_pending() const { return state() == BK_PROMISE_PENDING; }
    /* The value or reason; undefined while pending. */
    Result<Value> result() const { return detail::wrap<Value>(cx_, bk_promise_result(cx_, v_)); }
    Result<void> mark_handled() const { return detail::status(cx_, bk_promise_mark_handled(cx_, v_)); }
    /* then(on_fulfilled, on_rejected) with C++ callables taking the value. */
    template <class F, class R> Result<Promise> then(Context cx, F&& on_fulfilled, R&& on_rejected) const {
        auto f = closure(cx, "", std::forward<F>(on_fulfilled));
        if (!f) return std::move(f).error();
        auto r = closure(cx, "", std::forward<R>(on_rejected));
        if (!r) return std::move(r).error();
        return detail::wrap<Promise>(cx, bk_promise_then(cx, v_, f->raw(), r->raw()));
    }
    template <class F> Result<Promise> then(Context cx, F&& on_fulfilled) const {
        auto f = closure(cx, "", std::forward<F>(on_fulfilled));
        if (!f) return std::move(f).error();
        return detail::wrap<Promise>(cx, bk_promise_then(cx, v_, f->raw(), 0));
    }
};

/* Settles one promise. Move-only; resolving twice is a no-op, as in JS. */
class Resolver {
public:
    Resolver() = default;
    Resolver(Global<Function> resolve, Global<Function> reject)
        : resolve_(std::move(resolve)), reject_(std::move(reject)) {}
    Resolver(Resolver&&) = default;
    Resolver& operator=(Resolver&&) = default;
    Resolver(const Resolver&) = delete;
    Resolver& operator=(const Resolver&) = delete;
    Context context() const { return resolve_.context(); }
    bool settled() const { return resolve_.empty(); }
    template <class V> Result<void> resolve(V&& value) { return settle(true, std::forward<V>(value)); }
    template <class V> Result<void> reject(V&& reason) { return settle(false, std::forward<V>(reason)); }
private:
    template <class V> Result<void> settle(bool ok, V&& value) {
        if (resolve_.empty()) return {};
        Context cx = context();
        Scope s(cx);
        Function f = ok ? resolve_.get(cx) : reject_.get(cx);
        auto r = f.call(std::forward<V>(value));
        resolve_.reset();
        reject_.reset();
        if (!r) return std::move(r).error();
        return {};
    }
    Global<Function> resolve_, reject_;
};

inline Result<std::pair<Promise, Resolver>> Promise::create(Context cx) {
    bk_value res = 0, rej = 0;
    bk_value p = bk_new_promise(cx, &res, &rej);
    if (p == BK_EXCEPTION) return Error::from_pending(cx);
    Global<Function> gres = Global<Function>::adopt(cx, bk_dup_value(cx, res));
    Global<Function> grej = Global<Function>::adopt(cx, bk_dup_value(cx, rej));
    bk_free_value(cx, res);
    bk_free_value(cx, rej);
    return std::pair<Promise, Resolver>(Promise(raw_tag, cx, p), Resolver(std::move(gres), std::move(grej)));
}

/* ---- modules ---------------------------------------------------------------------- */

/* Answers a resolve question. */
class ModuleName {
public:
    explicit ModuleName(bk_module_request* r) : r_(r) {}
    Result<void> set(std::string_view name) {
        bk_status st = bk_module_set_name(r_, name.data(), name.size());
        if (st != BK_OK) return Error(static_cast<Errc>(st));
        return {};
    }
private:
    bk_module_request* r_;
};

/* A load request answered later, for a loader installed with BK_LOADER_ASYNC.
 * Answer it once, on the runtime's thread; an unanswered request is freed with
 * the runtime. Move-only. */
class PendingModule {
public:
    PendingModule() = default;
    explicit PendingModule(bk_module_request* r) : r_(r) {}
    PendingModule(PendingModule&& o) noexcept : r_(o.r_) { o.r_ = nullptr; }
    PendingModule& operator=(PendingModule&& o) noexcept { r_ = o.r_; o.r_ = nullptr; return *this; }
    PendingModule(const PendingModule&) = delete;
    PendingModule& operator=(const PendingModule&) = delete;
    explicit operator bool() const { return r_ != nullptr; }
    Result<void> source(std::string_view text) { return answer(bk_module_provide(take(), text.data(), text.size())); }
    Result<void> native(Object exports) { return answer(bk_module_provide_native(take(), exports.raw())); }
    Result<void> fail(Value error) { return answer(bk_module_fail(take(), error.raw())); }
private:
    bk_module_request* take() { bk_module_request* r = r_; r_ = nullptr; return r; }
    static Result<void> answer(bk_status st) {
        if (st != BK_OK) return Error(static_cast<Errc>(st));
        return {};
    }
    bk_module_request* r_ = nullptr;
};

/* Answers a load question with source text (copied) or a native exports object. */
class ModuleSource {
public:
    explicit ModuleSource(bk_module_request* r) : r_(r) {}
    Result<void> source(std::string_view text) {
        bk_status st = bk_module_provide(r_, text.data(), text.size());
        if (st != BK_OK) return Error(static_cast<Errc>(st));
        return {};
    }
    Result<void> native(Object exports) {
        bk_status st = bk_module_provide_native(r_, exports.raw());
        if (st != BK_OK) return Error(static_cast<Errc>(st));
        return {};
    }
    /* Keep the request to answer after load returns. Only for a loader
     * installed with BK_LOADER_ASYNC. */
    PendingModule defer() { return PendingModule(r_); }
private:
    bk_module_request* r_;
};

/* A host module loader. A callback that returns without answering falls back
 * to the filesystem unless the loader was installed with
 * BK_LOADER_NO_FILESYSTEM_FALLBACK. A failure rejects the import. */
class ModuleLoader {
public:
    virtual ~ModuleLoader() = default;
    virtual Result<void> resolve(Context cx, std::string_view referrer, std::string_view specifier,
                                 ModuleName& out) {
        (void)cx; (void)referrer; (void)specifier; (void)out;
        return {};
    }
    virtual Result<void> load(Context cx, std::string_view name, ModuleSource& out) = 0;
};

namespace detail {
inline bk_status loader_fail(bk_ctx cx, bk_module_request* req, Error& e) {
    if (e.is_uncatchable()) return static_cast<bk_status>(e.code());
    if (e.raw_exception()) return bk_module_fail(req, e.raw_exception());
    char buf[160];
    e.describe(buf, sizeof buf);
    bk_value err = bk_new_error(cx, BK_ERROR, buf);
    bk_status st = bk_module_fail(req, err);
    bk_free_value(cx, err);
    return st;
}
inline bk_status loader_resolve(bk_ctx cx, const char* referrer, const char* spec, bk_module_request* req, void* p) {
    auto* l = static_cast<ModuleLoader*>(p);
#if BOOMKAT_CPP_EXCEPTIONS
    try {
#endif
        ModuleName out(req);
        auto r = l->resolve(Context(cx), referrer ? referrer : "", spec ? spec : "", out);
        if (!r) return loader_fail(cx, req, r.error());
        return BK_OK;
#if BOOMKAT_CPP_EXCEPTIONS
    } catch (JsError& e) { return loader_fail(cx, req, e.error()); }
    catch (...) { Error e = Error::make(cx, Errc::thrown, BK_ERROR, "C++ exception in module loader");
                  return loader_fail(cx, req, e); }
#endif
}
inline bk_status loader_load(bk_ctx cx, const char* name, bk_module_request* req, void* p) {
    auto* l = static_cast<ModuleLoader*>(p);
#if BOOMKAT_CPP_EXCEPTIONS
    try {
#endif
        ModuleSource out(req);
        auto r = l->load(Context(cx), name ? name : "", out);
        if (!r) return loader_fail(cx, req, r.error());
        return BK_OK;
#if BOOMKAT_CPP_EXCEPTIONS
    } catch (JsError& e) { return loader_fail(cx, req, e.error()); }
    catch (...) { Error e = Error::make(cx, Errc::thrown, BK_ERROR, "C++ exception in module loader");
                  return loader_fail(cx, req, e); }
#endif
}
}  // namespace detail

inline Result<void> RuntimeRef::set_module_loader(ModuleLoader* loader, unsigned flags) const {
    detail::RuntimeData* d = detail::ensure_runtime_data(rt_);
    if (!d) return Error(Errc::nomem);
    if (!loader) return clear_module_loader();
    bk_module_loader l{&detail::loader_resolve, &detail::loader_load, loader, flags};
    bk_status st = bk_set_module_loader(rt_, &l);
    if (st != BK_OK) return Error(static_cast<Errc>(st));
    detail::destroy_erased(d->loader, d->alloc);
    return {};
}
inline Result<void> RuntimeRef::set_module_loader(std::unique_ptr<ModuleLoader> loader, unsigned flags) const {
    ModuleLoader* raw = loader.get();
    BK_TRY(set_module_loader(raw, flags));
    detail::RuntimeData* d = detail::runtime_data(rt_);
    detail::Erased e;
    e.object = loader.release();
    e.destroy = [](void* p, const detail::Allocator&) { delete static_cast<ModuleLoader*>(p); };
    d->loader = e;
    return {};
}
inline Result<void> RuntimeRef::clear_module_loader() const {
    bk_set_module_loader(rt_, nullptr);
    if (detail::RuntimeData* d = detail::runtime_data(rt_)) detail::destroy_erased(d->loader, d->alloc);
    return {};
}

/* Named exports for a native module. */
class ExportsBuilder {
public:
    explicit ExportsBuilder(Context cx) : cx_(cx) {
        auto o = Object::create(cx);
        if (o) obj_ = *o; else err_ = std::move(o).error();
    }
    template <class V> ExportsBuilder&& add(std::string_view name, V&& value) && {
        if (err_.code() == Errc::ok && obj_) {
            auto r = obj_->set(name, std::forward<V>(value));
            if (!r) err_ = std::move(r).error();
        }
        return std::move(*this);
    }
    template <class V> ExportsBuilder& add(std::string_view name, V&& value) & {
        if (err_.code() == Errc::ok && obj_) {
            auto r = obj_->set(name, std::forward<V>(value));
            if (!r) err_ = std::move(r).error();
        }
        return *this;
    }
    Result<Object> finish() {
        if (err_.code() != Errc::ok) return std::move(err_);
        return *obj_;
    }
private:
    Context cx_;
    std::optional<Object> obj_;
    Error err_;
};
inline ExportsBuilder exports(Context cx) { return ExportsBuilder(cx); }

inline Result<void> Context::define_module(std::string_view name, Object exports) const {
    return detail::status(cx_, bk_define_native_module(cx_, name.data(), name.size(), exports.raw()));
}
inline Result<void> Context::define_module(std::string_view name, ExportsBuilder&& b) const {
    auto o = b.finish();
    if (!o) return std::move(o).error();
    return define_module(name, *o);
}
inline Result<Promise> Context::import_async(std::string_view spec) const {
    return detail::wrap<Promise>(cx_, bk_import(cx_, spec.data(), spec.size()));
}
inline Result<Object> Context::import(std::string_view spec) const {
    auto p = import_async(spec);
    if (!p) return std::move(p).error();
    while (p->is_pending()) {
        if (!bk_is_job_pending(bk_get_runtime(cx_)))
            return Error::make(cx_, Errc::invalid, BK_ERROR, "import did not settle");
        BK_TRY(run_jobs());
    }
    auto v = p->result();
    if (!v) return std::move(v).error();
    if (p->state() == BK_PROMISE_REJECTED) return Error::thrown(cx_, v->raw());
    return Object(raw_tag, cx_, v->raw());
}

/* ---- binary data, definitions ------------------------------------------------ */

inline Result<ArrayBuffer> ArrayBuffer::create(Context cx, size_t length) {
    return detail::wrap<ArrayBuffer>(cx, bk_new_array_buffer(cx, length, nullptr));
}
inline Result<ArrayBuffer> ArrayBuffer::copy(Context cx, const void* data, size_t length) {
    void* dst = nullptr;
    bk_value b = bk_new_array_buffer(cx, length, &dst);
    if (b == BK_EXCEPTION) return Error::from_pending(cx);
    if (length) std::memcpy(dst, data, length);
    return ArrayBuffer(raw_tag, cx, b);
}
inline Result<ArrayBuffer> ArrayBuffer::external(Context cx, void* data, size_t length,
                                                 bk_finalizer release, void* opaque) {
    return detail::wrap<ArrayBuffer>(cx, bk_new_external_array_buffer(cx, data, length, release, opaque));
}
namespace detail {
template <class F> struct ReleaseBox {
    F fn;
    Allocator alloc;
    static void run(void*, void* p) {
        auto* box = static_cast<ReleaseBox*>(p);
        Allocator a = box->alloc;
        box->fn();
        box->~ReleaseBox();
        a.deallocate(box);
    }
};
}  // namespace detail
template <class F>
Result<ArrayBuffer> ArrayBuffer::external(Context cx, void* data, size_t length, F&& release) {
    using Box = detail::ReleaseBox<detail::remove_cvref_t<F>>;
    detail::Allocator a = detail::allocator_of(bk_get_runtime(cx));
    void* raw = a.allocate(sizeof(Box));
    if (!raw) { release(); return Error(Errc::nomem, cx.raw()); }
    auto* box = new (raw) Box{std::forward<F>(release), a};
    return external(cx, data, length, &Box::run, box);
}
inline Result<Span<uint8_t>> ArrayBuffer::bytes() const {
    void* d = nullptr; size_t n = 0;
    bk_status st = bk_get_array_buffer(cx_, v_, &d, &n);
    if (st != BK_OK) return Error::from_pending(cx_, st);
    return Span<uint8_t>{static_cast<uint8_t*>(d), n};
}
inline Result<void> ArrayBuffer::detach() const { return detail::status(cx_, bk_detach_array_buffer(cx_, v_)); }

inline Result<SharedArrayBuffer> SharedArrayBuffer::create(Context cx, size_t length) {
    return detail::wrap<SharedArrayBuffer>(cx, bk_new_shared_array_buffer(cx, length, nullptr));
}
inline Result<SharedArrayBuffer> SharedArrayBuffer::adopt(Context cx, const SharedBlock& block) {
    return detail::wrap<SharedArrayBuffer>(cx, bk_adopt_shared_block(cx, block.data()));
}
inline Result<SharedBlock> SharedArrayBuffer::block() const {
    auto b = bytes();
    if (!b) return std::move(b).error();
    if (!b->data) return Error::type_error(cx_, "SharedArrayBuffer has no block");
    bk_shared_block_retain(b->data);
    return SharedBlock::adopt(b->data, b->size);
}

template <class E>
Result<TypedArray<E>> TypedArray<E>::create(Context cx, const ArrayBuffer& buffer, size_t byte_offset, size_t length) {
    return detail::wrap<TypedArray>(cx, bk_new_typed_array(cx, kind, buffer.raw(), byte_offset, length));
}
template <class E> Result<TypedArray<E>> TypedArray<E>::create(Context cx, size_t length) {
    auto b = ArrayBuffer::create(cx, length * sizeof(E));
    if (!b) return std::move(b).error();
    return create(cx, *b, 0, length);
}
template <class E> Result<Span<E>> TypedArray<E>::elements() const {
    bk_typed_array_info info{};
    bk_status st = bk_get_typed_array(this->cx_, this->v_, &info);
    if (st != BK_OK) return Error::from_pending(this->cx_, st);
    bk_free_value(this->cx_, info.buffer);
    return Span<E>{static_cast<E*>(info.data), info.length};
}
template <class E> Result<ArrayBuffer> TypedArray<E>::buffer() const {
    bk_typed_array_info info{};
    bk_status st = bk_get_typed_array(this->cx_, this->v_, &info);
    if (st != BK_OK) return Error::from_pending(this->cx_, st);
    return ArrayBuffer(raw_tag, this->cx_, info.buffer);
}

/* ---- weak handles ---------------------------------------------------------------- */

/* Refers to an object or unregistered symbol without keeping it alive.
 * Move-only. Free it before the context it was made with. */
template <class T = Object> class Weak {
    static_assert(std::is_base_of_v<Value, T>, "bk::Weak holds bk:: handle types");
public:
    Weak() = default;
    static Result<Weak> create(const T& target) {
        Weak w;
        w.cx_ = target.raw_context();
        w.w_ = bk_new_weak(w.cx_, target.raw());
        if (!w.w_) return Error::from_pending(w.cx_);
        return Result<Weak>(std::move(w));
    }
    Weak(Weak&& o) noexcept : cx_(o.cx_), w_(o.w_) { o.w_ = 0; }
    Weak& operator=(Weak&& o) noexcept {
        if (this != &o) { reset(); cx_ = o.cx_; w_ = o.w_; o.w_ = 0; }
        return *this;
    }
    Weak(const Weak&) = delete;
    Weak& operator=(const Weak&) = delete;
    ~Weak() { reset(); }
    void reset() { if (w_) bk_free_weak(cx_, w_); w_ = 0; }
    explicit operator bool() const { return w_ != 0; }
    /* The target as a local of `cx`, or nullopt once collected. */
    std::optional<T> get(Context cx) const {
        if (!w_) return std::nullopt;
        bk_value v = bk_weak_get(cx.raw(), w_);
        if (v == BK_EXCEPTION || v == BK_UNDEFINED) return std::nullopt;
        return T(raw_tag, cx.raw(), v);
    }
    std::optional<T> get() const { return get(Context(cx_)); }
private:
    bk_ctx cx_ = nullptr;
    bk_weak w_ = 0;
};

/* ---- host classes ---------------------------------------------------------- */

/* Holds one JS value inside host memory without rooting it. Only valid while
 * the owning class's trace reports it. */
template <class T = Value>
class Traced {
public:
    Traced() { bk_slot_init(&slot_); }
    Traced(const Traced&) = delete;
    Traced& operator=(const Traced&) = delete;
    Result<void> set(const T& v) {
        return detail::status(v.raw_context(), bk_slot_set(v.raw_context(), &slot_, v.raw()));
    }
    T get(Context cx) const { return T(raw_tag, cx.raw(), bk_slot_get(cx.raw(), &slot_)); }
    /* Not from a finalizer. */
    void clear(Context cx) { bk_slot_clear(cx.raw(), &slot_); }
    const bk_slot* raw() const { return &slot_; }
private:
    bk_slot slot_;
};

class Tracer {
public:
    explicit Tracer(bk_tracer* t) : t_(t) {}
    template <class T> void trace(const Traced<T>& slot) { bk_trace_slot(t_, slot.raw()); }
    template <class T> Tracer& operator()(const Traced<T>& slot) { trace(slot); return *this; }
private:
    bk_tracer* t_;
};

/* Allocation of owned instances; specialize for engines with their own
 * allocators (UE NewObject, Godot memnew). */
template <class T> struct ClassTraits {
    template <class... A> static T* create(A&&... args) { return new (std::nothrow) T(std::forward<A>(args)...); }
    static void destroy(T* p) { delete p; }
};

/* Ownership policies. */
struct owned {};
struct borrowed {};
template <class P> struct shared {};
template <class X> struct policy {};

namespace detail {
template <class T> struct class_tag { static constexpr char id = 0; };
template <class T> constexpr const void* tag_of() { return &class_tag<T>::id; }

template <class T, class Policy> struct PolicyOps;
template <class T> struct PolicyOps<T, owned> {
    static constexpr bool has_finalizer = true;
    static T* object(void* payload) { return static_cast<T*>(payload); }
    static void release(void* payload) { ClassTraits<T>::destroy(static_cast<T*>(payload)); }
    template <class... A> static void* make(A&&... a) { return ClassTraits<T>::create(std::forward<A>(a)...); }
};
template <class T> struct PolicyOps<T, borrowed> {
    static constexpr bool has_finalizer = false;
    static T* object(void* payload) { return static_cast<T*>(payload); }
    static void release(void*) {}
};
template <class T, class P> struct PolicyOps<T, shared<P>> {
    static constexpr bool has_finalizer = true;
    static T* object(void* payload) { return &**static_cast<P*>(payload); }
    static void release(void* payload) { delete static_cast<P*>(payload); }
    template <class... A> static void* make(A&&... a) {
        T* obj = ClassTraits<T>::create(std::forward<A>(a)...);
        if (!obj) return nullptr;
        return new (std::nothrow) P(obj);
    }
    static void* box(P p) { return new (std::nothrow) P(std::move(p)); }
};
/* X provides: static T* get(void* payload); static void release(void* payload). */
template <class T, class X> struct PolicyOps<T, policy<X>> {
    static constexpr bool has_finalizer = true;
    static T* object(void* payload) { return X::get(payload); }
    static void release(void* payload) { X::release(payload); }
};

template <class T, class = void> struct has_trace : std::false_type {};
template <class T>
struct has_trace<T, std::void_t<decltype(std::declval<const T&>().trace(std::declval<Tracer&>()))>> : std::true_type {};

inline ClassRecord* find_record(bk_runtime rt, const void* tag) {
    RuntimeData* d = runtime_data(rt);
    for (ClassRecord* r = d ? d->classes : nullptr; r; r = r->next) if (r->tag == tag) return r;
    return nullptr;
}
inline ClassRecord* find_record_by_id(bk_runtime rt, bk_class id) {
    RuntimeData* d = runtime_data(rt);
    for (ClassRecord* r = d ? d->classes : nullptr; r; r = r->next) if (r->id == id) return r;
    return nullptr;
}

/* The object behind a host instance as a `tag` pointer, walking inheritance. */
inline Result<void*> unwrap_tag(Value v, const void* tag) {
    bk_ctx cx = v.raw_context();
    bk_class cls = v.is_object() ? bk_get_instance_class(cx, v.raw()) : 0;
    const ClassRecord* rec = cls ? find_record_by_id(bk_get_runtime(cx), cls) : nullptr;
    if (!rec) return Error::mismatch(cx);
    void* payload = bk_get_instance_payload(cx, v.raw(), cls);
    if (!payload) {
        char buf[112];
        std::snprintf(buf, sizeof buf, "%s object has been destroyed", rec->name);
        return Error::type_error(cx, buf);
    }
    void* p = rec->object(payload);
    for (const ClassRecord* r = rec; r; r = r->parent) {
        if (r->tag == tag) return p;
        if (!r->parent) break;
        p = r->upcast(p);
    }
    return Error::mismatch(cx);
}
}  // namespace detail

/* The object behind a bound-class instance, brand-checked across inheritance. */
template <class T> Result<T*> unwrap(Value v) {
    auto r = detail::unwrap_tag(v, detail::tag_of<T>());
    if (!r) return std::move(r).error();
    return static_cast<T*>(*r);
}

/* Clears an instance's payload without running its finalizer, and returns it.
 * Later calls on the instance throw "<name> object has been destroyed". */
template <class T> Result<T*> detach(Value v) {
    bk_ctx cx = v.raw_context();
    bk_class cls = bk_get_instance_class(cx, v.raw());
    detail::ClassRecord* rec = cls ? detail::find_record_by_id(bk_get_runtime(cx), cls) : nullptr;
    if (!rec) return Error::type_error(cx, "not a bound class instance");
    void* payload = bk_get_instance_payload(cx, v.raw(), cls);
    if (!payload) return static_cast<T*>(nullptr);
    BK_TRY(detail::status(cx, bk_set_instance_payload(cx, v.raw(), cls, nullptr)));
    return static_cast<T*>(rec->object(payload));
}

/* Bound class pointers and references as parameters. */
template <class T>
struct Convert<T*, std::enable_if_t<std::is_class_v<T> && !std::is_base_of_v<Value, T>>> {
    static constexpr const char* js_name = "object";
    static Result<T*> from_js(Value v) { return unwrap<std::remove_const_t<T>>(v); }
};
template <class T> struct Convert<Nullable<T*>> {
    static constexpr const char* js_name = "object or null";
    static Result<Nullable<T*>> from_js(Value v) {
        if (v.is_nullish()) return Nullable<T*>{};
        auto r = unwrap<std::remove_const_t<T>>(v);
        if (!r) return std::move(r).error();
        return Nullable<T*>{*r};
    }
};

namespace detail {
template <class P> struct Param<P, std::enable_if_t<std::is_lvalue_reference_v<P> &&
                                                    std::is_class_v<remove_cvref_t<P>> &&
                                                    !std::is_base_of_v<Value, remove_cvref_t<P>> &&
                                                    !std::is_same_v<remove_cvref_t<P>, CallInfo> &&
                                                    !std::is_same_v<remove_cvref_t<P>, Context> &&
                                                    !is_this<remove_cvref_t<P>>::value &&
                                                    !is_rest<remove_cvref_t<P>>::value &&
                                                    !has_convert_v<remove_cvref_t<P>>>> {
    using D = remove_cvref_t<P>;
    static constexpr bool consumes = true;
    using storage = D*;
    static Result<D*> get(const CallInfo& ci, unsigned& i) { return Param<D*>::get(ci, i); }
    static P pass(D*& p) { return *p; }
};
}  // namespace detail

template <class T> class ClassHandle {
public:
    ClassHandle(bk_class id, Global<Function> ctor, Global<Object> proto)
        : id_(id), ctor_(std::move(ctor)), proto_(std::move(proto)) {}
    bk_class id() const { return id_; }
    Function constructor() const { return ctor_.get(); }
    Object prototype() const { return proto_.get(); }
    const Global<Function>& constructor_global() const { return ctor_; }
private:
    bk_class id_;
    Global<Function> ctor_;
    Global<Object> proto_;
};

namespace detail {

template <class T, class Policy> void class_finalize(void* payload, void*) { PolicyOps<T, Policy>::release(payload); }
template <class T, class Policy> void class_trace(void* payload, bk_tracer* t, void*) {
    Tracer tr(t);
    PolicyOps<T, Policy>::object(payload)->trace(tr);
}

/* Wraps a new C++ object in an instance of its bound class. */
template <class T, class Policy>
inline Result<Value> new_instance(Context cx, const ClassRecord* rec, void* payload) {
    if (!payload) return Error::make(cx, Errc::nomem, BK_ERROR, "out of memory");
    bk_value v = bk_new_instance(cx, rec->id, payload, 0);
    if (v == BK_EXCEPTION) {
        PolicyOps<T, Policy>::release(payload);
        return Error::from_pending(cx);
    }
    return Value(raw_tag, cx.raw(), v);
}

template <class T, class Policy, class... A>
bk_value class_construct(bk_ctx cx, bk_value self, unsigned argc, const bk_value* argv, void* data) {
    BOOMKAT_CPP_TRY
        auto* rec = static_cast<ClassRecord*>(data);
        CallInfo ci(cx, self, argc, argv, rec->name, data);
        using Args = std::tuple<A...>;
        auto conv = convert_args(ci, static_cast<Args*>(nullptr), std::index_sequence_for<A...>());
        if (!conv) return conv.error().rethrow(cx);
        void* payload = std::apply([](auto&... o) { return PolicyOps<T, Policy>::make(std::move(*o)...); }, *conv);
        if (!payload) return bk_throw_error(cx, BK_ERROR, "out of memory");
        bk_status st = bk_set_instance_payload(cx, self, rec->id, payload);
        if (st != BK_OK) {
            PolicyOps<T, Policy>::release(payload);
            return Error::from_pending(cx, st).rethrow(cx);
        }
        return BK_UNDEFINED;
    BOOMKAT_CPP_CATCH(cx)
}

template <class T, class Policy, auto F>
bk_value method_trampoline(bk_ctx cx, bk_value self, unsigned argc, const bk_value* argv, void* data) {
    BOOMKAT_CPP_TRY
        auto* rec = static_cast<ClassRecord*>(data);
        CallInfo ci(cx, self, argc, argv, rec->name, data);
        auto obj = unwrap<T>(ci.this_value());
        if (!obj) {
            char prefix[96];
            std::snprintf(prefix, sizeof prefix, "%s method: this", rec->name);
            return finish_mismatch<T*>(cx, std::move(obj).error(), prefix).rethrow(cx);
        }
        using Tr = fn_traits<decltype(F)>;
        if constexpr (Tr::member) {
            using R = remove_cvref_t<typename Tr::ret>;
            if constexpr (std::is_same_v<R, T>) {
                /* A method returning the class by value makes a new instance. */
                using Args = typename Tr::args;
                auto conv = convert_args(ci, static_cast<Args*>(nullptr),
                                         std::make_index_sequence<std::tuple_size_v<Args>>());
                if (!conv) return conv.error().rethrow(cx);
                T* self_obj = *obj;
                T result = std::apply([&](auto&... o) { return (self_obj->*F)(std::move(*o)...); }, *conv);
                void* payload = PolicyOps<T, Policy>::make(std::move(result));
                auto v = new_instance<T, Policy>(Context(cx), rec, payload);
                if (!v) return v.error().rethrow(cx);
                return v->raw();
            } else {
                return invoke<Tr>(ci, F, *obj);
            }
        } else if constexpr (has_this_param<typename Tr::args>::value) {
            /* A free function that takes the object as bk::This<T*>. */
            return invoke<Tr>(ci, F, static_cast<void*>(nullptr));
        } else {
            /* A free function whose first parameter is the object. */
            using Args = typename Tr::args;
            using First = std::tuple_element_t<0, Args>;
            T* o = *obj;
            auto bound = [&](auto&&... rest) -> decltype(auto) {
                if constexpr (std::is_pointer_v<First>) return F(o, std::forward<decltype(rest)>(rest)...);
                else return F(*o, std::forward<decltype(rest)>(rest)...);
            };
            using Tail = decltype(tuple_tail(static_cast<Args*>(nullptr)));
            return invoke<plain_traits<typename Tr::ret, Tail>>(ci, bound, static_cast<void*>(nullptr));
        }
    BOOMKAT_CPP_CATCH(cx)
}

template <class T, auto M>
bk_value field_get(bk_ctx cx, bk_value self, unsigned argc, const bk_value* argv, void* data) {
    BOOMKAT_CPP_TRY
        auto* rec = static_cast<ClassRecord*>(data);
        CallInfo ci(cx, self, argc, argv, rec->name, data);
        auto obj = unwrap<T>(ci.this_value());
        if (!obj) return finish_mismatch<T*>(cx, std::move(obj).error(), rec->name).rethrow(cx);
        return return_value(cx, (*obj)->*M);
    BOOMKAT_CPP_CATCH(cx)
}
template <class T, auto M>
bk_value field_set(bk_ctx cx, bk_value self, unsigned argc, const bk_value* argv, void* data) {
    BOOMKAT_CPP_TRY
        auto* rec = static_cast<ClassRecord*>(data);
        CallInfo ci(cx, self, argc, argv, rec->name, data);
        auto obj = unwrap<T>(ci.this_value());
        if (!obj) return finish_mismatch<T*>(cx, std::move(obj).error(), rec->name).rethrow(cx);
        using F = remove_cvref_t<decltype((*obj)->*M)>;
        auto v = from_js<F>(ci.arg(0));
        if (!v) {
            char prefix[96];
            std::snprintf(prefix, sizeof prefix, "%s setter", rec->name);
            return finish_mismatch<F>(cx, std::move(v).error(), prefix).rethrow(cx);
        }
        (*obj)->*M = std::move(*v);
        return BK_UNDEFINED;
    BOOMKAT_CPP_CATCH(cx)
}
template <class T, class U> void* upcast_to(void* p) { return static_cast<U*>(static_cast<T*>(p)); }
}  // namespace detail


/* Builds a host class for T. Policy decides the payload (see owned, borrowed,
 * shared<P>, policy<X>). constructor(), inherits() and defer_finalization()
 * come before any member; build() reports the first failure. Needs an open
 * scope. */
template <class T, class Policy = owned>
class Class {
    using Ops = detail::PolicyOps<T, Policy>;
public:
    Class(Context cx, const char* name) : cx_(cx) { detail::copy_name(name_, sizeof name_, name); }

    template <class... A> Class& constructor() {
        static_assert(!std::is_same_v<Policy, borrowed>, "a borrowed class has no JS constructor");
        if (pre()) { construct_ = &detail::class_construct<T, Policy, A...>; arity_ = sizeof...(A); }
        return *this;
    }
    template <class Base> Class& inherits() {
        static_assert(std::is_base_of_v<Base, T>, "Class<T>::inherits<Base> needs Base to be a base of T");
        if (!pre()) return *this;
        parent_ = detail::find_record(bk_get_runtime(cx_), detail::tag_of<Base>());
        upcast_ = &detail::upcast_to<T, Base>;
        if (!parent_) fail(Error::type_error(cx_, "Class::inherits: the base class is not bound"));
        return *this;
    }
    Class& defer_finalization() { if (pre()) flags_ |= BK_CLASS_DEFER_FINALIZE; return *this; }

    template <auto F> Class& method(const char* name) {
        if (!define()) return *this;
        auto f = bk_new_c_function(cx_, &detail::method_trampoline<T, Policy, F>, name,
                                   arity_of<F>(), 0, rec_, nullptr, nullptr);
        put(proto_, name, f);
        return *this;
    }
    template <auto M> Class& field(const char* name) {
        if (!define()) return *this;
        bk_value g = bk_new_c_function(cx_, &detail::field_get<T, M>, name, 0, 0, rec_, nullptr, nullptr);
        bk_value s = bk_new_c_function(cx_, &detail::field_set<T, M>, name, 1, 0, rec_, nullptr, nullptr);
        if (g == BK_EXCEPTION || s == BK_EXCEPTION) { fail(Error::from_pending(cx_)); return *this; }
        auto r = Object(raw_tag, cx_, proto_).define_accessor(name, Value(raw_tag, cx_, g), Value(raw_tag, cx_, s));
        if (!r) fail(std::move(r).error());
        return *this;
    }
    template <auto M> Class& readonly_field(const char* name) {
        if (!define()) return *this;
        bk_value g = bk_new_c_function(cx_, &detail::field_get<T, M>, name, 0, 0, rec_, nullptr, nullptr);
        if (g == BK_EXCEPTION) { fail(Error::from_pending(cx_)); return *this; }
        auto r = Object(raw_tag, cx_, proto_).define_accessor(name, Value(raw_tag, cx_, g), cx_.undefined());
        if (!r) fail(std::move(r).error());
        return *this;
    }
    template <class L> Class& static_method(const char* name, L&& fn) {
        if (!define()) return *this;
        auto f = closure(cx_, name, std::forward<L>(fn));
        if (!f) { fail(std::move(f).error()); return *this; }
        put(ctor_, name, f->raw());
        return *this;
    }
    template <auto F> Class& static_method(const char* name) {
        if (!define()) return *this;
        auto f = function<F>(cx_, name);
        if (!f) { fail(std::move(f).error()); return *this; }
        put(ctor_, name, f->raw());
        return *this;
    }
    Class& to_string_tag(const char* tag) {
        if (!define()) return *this;
        auto sym = Symbol::well_known(cx_, BK_SYMBOL_TO_STRING_TAG);
        if (!sym) { fail(std::move(sym).error()); return *this; }
        auto key = Atom::from_value(*sym);
        if (!key) { fail(std::move(key).error()); return *this; }
        auto str = String::from_utf8(cx_, tag);
        if (!str) { fail(std::move(str).error()); return *this; }
        bk_property_descriptor d{};
        d.flags = BK_PROP_CONFIGURABLE | BK_PROP_HAS_VALUE | BK_PROP_HAS_WRITABLE | BK_PROP_HAS_ENUMERABLE |
                  BK_PROP_HAS_CONFIGURABLE;
        d.value = str->raw(); d.get = BK_UNDEFINED; d.set = BK_UNDEFINED;
        int ok = 0;
        bk_status st = bk_define_property(cx_, proto_, key->raw(), &d, &ok);
        if (st != BK_OK) fail(Error::from_pending(cx_, st));
        return *this;
    }

    Result<ClassHandle<T>> build() {
        define();
        if (err_.code() != Errc::ok) return std::move(err_);
        return ClassHandle<T>(rec_->id, Global<Function>(Function(raw_tag, cx_, ctor_)),
                              Global<Object>(Object(raw_tag, cx_, proto_)));
    }

private:
    template <auto F> static int arity_of() {
        using Tr = detail::fn_traits<decltype(F)>;
        if constexpr (Tr::member || detail::has_this_param<typename Tr::args>::value)
            return detail::arity<typename Tr::args>::value;
        else return detail::arity<typename Tr::args>::value - 1;
    }
    bool pre() {
        if (rec_) { fail(Error::type_error(cx_, "Class: constructor, inherits and defer_finalization come first")); return false; }
        return err_.code() == Errc::ok;
    }
    void fail(Error e) { if (err_.code() == Errc::ok) err_ = std::move(e); }
    void put(bk_value target, const char* name, bk_value f) {
        if (f == BK_EXCEPTION) { fail(Error::from_pending(cx_)); return; }
        bk_status st = bk_set_property(cx_, target, name, std::strlen(name), f);
        if (st != BK_OK) fail(Error::from_pending(cx_, st));
    }
    bool define() {
        if (err_.code() != Errc::ok) return false;
        if (rec_) return true;
        bk_runtime rt = bk_get_runtime(cx_);
        detail::RuntimeData* d = detail::ensure_runtime_data(rt);
        if (!d) { fail(Error(Errc::nomem, cx_)); return false; }
        void* raw = d->alloc.allocate(sizeof(detail::ClassRecord));
        if (!raw) { fail(Error(Errc::nomem, cx_)); return false; }
        auto* rec = new (raw) detail::ClassRecord{};
        rec->tag = detail::tag_of<T>();
        rec->parent = parent_;
        rec->object = [](void* payload) -> void* { return Ops::object(payload); };
        rec->upcast = upcast_;
        std::memcpy(rec->name, name_, sizeof name_);
        bk_class_def def{};
        def.name = rec->name;
        def.parent = parent_ ? parent_->id : 0;
        def.finalize = Ops::has_finalizer ? &detail::class_finalize<T, Policy> : nullptr;
        if constexpr (detail::has_trace<T>::value) def.trace = &detail::class_trace<T, Policy>;
        def.construct = construct_;
        def.arity = arity_;
        def.flags = flags_;
        def.opaque = rec;
        bk_class id = bk_define_class(cx_, &def, &ctor_, &proto_);
        if (!id) { d->alloc.deallocate(rec); fail(Error::from_pending(cx_)); return false; }
        rec->id = id;
        /* The newest binding of T is the one by-value returns use. */
        rec->next = d->classes;
        d->classes = rec;
        rec_ = rec;
        return true;
    }

    Context cx_;
    char name_[64];
    detail::ClassRecord* rec_ = nullptr;
    const detail::ClassRecord* parent_ = nullptr;
    void* (*upcast_)(void*) = nullptr;
    bk_c_function construct_ = nullptr;
    int arity_ = 0;
    unsigned flags_ = 0;
    bk_value ctor_ = 0, proto_ = 0;
    Error err_;
};

/* Opt-in by-value conversion for a bound owned class:
 *   template <> struct bk::Convert<Vec3> : bk::ClassConvert<Vec3> {};
 * from_js copies the object; to_js makes a new owned instance. */
template <class T, class Policy = owned> struct ClassConvert {
    static constexpr const char* js_name = "object";
    static Result<T> from_js(Value v) {
        auto p = unwrap<T>(v);
        if (!p) return std::move(p).error();
        return T(**p);
    }
    static Result<Value> to_js(Context cx, T v) {
        const detail::ClassRecord* rec = detail::find_record(bk_get_runtime(cx), detail::tag_of<T>());
        if (!rec) return Error::type_error(cx, "class is not bound in this runtime");
        return detail::new_instance<T, Policy>(cx, rec, detail::PolicyOps<T, Policy>::make(std::move(v)));
    }
};

/* Wraps an existing host object in an instance of its bound class. */
template <class T> Result<Object> wrap_borrowed(Context cx, T* obj) {
    const detail::ClassRecord* rec = detail::find_record(bk_get_runtime(cx), detail::tag_of<T>());
    if (!rec) return Error::type_error(cx, "class is not bound in this runtime");
    bk_value v = bk_new_instance(cx, rec->id, obj, 0);
    return detail::wrap<Object>(cx, v);
}
/* An owned instance made from constructor arguments. */
template <class T, class Policy = owned, class... A> Result<Object> make_instance(Context cx, A&&... args) {
    const detail::ClassRecord* rec = detail::find_record(bk_get_runtime(cx), detail::tag_of<T>());
    if (!rec) return Error::type_error(cx, "class is not bound in this runtime");
    auto v = detail::new_instance<T, Policy>(cx, rec, detail::PolicyOps<T, Policy>::make(std::forward<A>(args)...));
    if (!v) return std::move(v).error();
    return Object(raw_tag, cx.raw(), v->raw());
}
/* An instance of a shared<P> class over an existing smart pointer. */
template <class T, class P> Result<Object> wrap_shared(Context cx, P ptr) {
    const detail::ClassRecord* rec = detail::find_record(bk_get_runtime(cx), detail::tag_of<T>());
    if (!rec) return Error::type_error(cx, "class is not bound in this runtime");
    auto v = detail::new_instance<T, shared<P>>(cx, rec, detail::PolicyOps<T, shared<P>>::box(std::move(ptr)));
    if (!v) return std::move(v).error();
    return Object(raw_tag, cx.raw(), v->raw());
}

/* A class built at run time from names and callables (Qt meta-objects, Godot
 * ClassDB). Payloads are void*. The constructor is a bk_c_function that sets
 * the payload of `this` with bk_set_instance_payload; it and the finalizer
 * receive the class opaque. Members are added after build(). */
class DynamicClass {
public:
    DynamicClass(Context cx, const char* name) : cx_(cx) { detail::copy_name(name_, sizeof name_, name); }
    DynamicClass& parent(bk_class id) { parent_ = id; return *this; }
    DynamicClass& constructor(bk_c_function fn, int arity) { construct_ = fn; arity_ = arity; return *this; }
    DynamicClass& finalizer(bk_finalizer fn) { finalize_ = fn; return *this; }
    DynamicClass& trace(bk_trace_fn fn) { trace_ = fn; return *this; }
    DynamicClass& opaque(void* data) { opaque_ = data; return *this; }
    DynamicClass& defer_finalization() { flags_ |= BK_CLASS_DEFER_FINALIZE; return *this; }
    Result<bk_class> build() {
        bk_class_def def{};
        def.name = name_;
        def.parent = parent_;
        def.finalize = finalize_;
        def.trace = trace_;
        def.construct = construct_;
        def.arity = arity_;
        def.flags = flags_;
        def.opaque = opaque_;
        id_ = bk_define_class(cx_, &def, &ctor_, &proto_);
        if (!id_) return Error::from_pending(cx_.raw());
        return id_;
    }
    bk_class id() const { return id_; }
    Object prototype() const { return Object(raw_tag, cx_.raw(), proto_); }
    Function constructor() const { return Function(raw_tag, cx_.raw(), ctor_); }
    /* A method over any callable; CallInfo::this_value() is the instance. */
    template <class L> Result<void> method(const char* name, L&& fn) const {
        if (!id_) return Error::type_error(cx_, "DynamicClass::method before build");
        return prototype().set(name, closure(cx_, name, std::forward<L>(fn)));
    }
    /* The payload of an instance of this class or a subclass, or nullptr. */
    void* payload(Value v) const { return bk_get_instance_payload(cx_, v.raw(), id_); }
private:
    Context cx_;
    char name_[64];
    bk_class parent_ = 0, id_ = 0;
    bk_c_function construct_ = nullptr;
    bk_finalizer finalize_ = nullptr;
    bk_trace_fn trace_ = nullptr;
    void* opaque_ = nullptr;
    int arity_ = 0;
    unsigned flags_ = 0;
    bk_value ctor_ = 0, proto_ = 0;
};

/* One wrapper per native object, held strongly. The host calls forget()
 * when it destroys the native object. */
template <class T> class WrapperCache {
public:
    WrapperCache() = default;
    WrapperCache(const WrapperCache&) = delete;
    WrapperCache& operator=(const WrapperCache&) = delete;
    ~WrapperCache() { clear(); std::free(slots_); }

    /* The wrapper for `obj`, made with wrap_borrowed on first use. */
    Result<Object> get(Context cx, T* obj) {
        if (Entry* e = find(obj)) return e->wrapper.get(cx);
        auto w = wrap_borrowed<T>(cx, obj);
        if (!w) return std::move(w).error();
        if (!insert(obj, Global<Object>(*w))) return Error(Errc::nomem, cx.raw());
        return *w;
    }
    bool contains(T* obj) const { return const_cast<WrapperCache*>(this)->find(obj) != nullptr; }
    /* Drops and detaches the wrapper of `obj`. */
    void forget(T* obj) {
        Entry* e = find(obj);
        if (!e) return;
        {
            Scope s(e->wrapper.context());
            Object w = e->wrapper.get();
            bk_ctx c = w.raw_context();
            bk_class cls = bk_get_instance_class(c, w.raw());
            if (cls) (void)bk_set_instance_payload(c, w.raw(), cls, nullptr);
        }
        e->wrapper.reset();
        e->key = tombstone();
        count_--;
    }
    void clear() {
        for (size_t i = 0; i < cap_; i++) {
            if (slots_[i].key && slots_[i].key != tombstone()) slots_[i].wrapper.reset();
            slots_[i].~Entry();
            new (&slots_[i]) Entry();
        }
        count_ = 0;
    }
    size_t size() const { return count_; }
private:
    struct Entry { T* key = nullptr; Global<Object> wrapper; };
    static T* tombstone() { return reinterpret_cast<T*>(uintptr_t(1)); }
    static size_t hash(T* p) { uintptr_t x = reinterpret_cast<uintptr_t>(p); x ^= x >> 17; x *= 0xed5ad4bbu; x ^= x >> 11; return size_t(x); }
    Entry* find(T* p) {
        if (!cap_) return nullptr;
        for (size_t i = hash(p) & (cap_ - 1), n = 0; n < cap_; i = (i + 1) & (cap_ - 1), n++) {
            if (slots_[i].key == p) return &slots_[i];
            if (!slots_[i].key) return nullptr;
        }
        return nullptr;
    }
    bool insert(T* p, Global<Object> w) {
        if ((used_ + 1) * 4 >= cap_ * 3 && !grow()) return false;
        for (size_t i = hash(p) & (cap_ - 1);; i = (i + 1) & (cap_ - 1)) {
            if (!slots_[i].key || slots_[i].key == tombstone()) {
                if (!slots_[i].key) used_++;
                slots_[i].key = p;
                slots_[i].wrapper = std::move(w);
                count_++;
                return true;
            }
        }
    }
    bool grow() {
        size_t ncap = cap_ ? cap_ * 2 : 16;
        Entry* n = static_cast<Entry*>(std::malloc(sizeof(Entry) * ncap));
        if (!n) return false;
        for (size_t i = 0; i < ncap; i++) new (&n[i]) Entry();
        Entry* old = slots_;
        size_t ocap = cap_;
        slots_ = n; cap_ = ncap; used_ = 0; count_ = 0;
        for (size_t i = 0; i < ocap; i++) {
            if (old[i].key && old[i].key != tombstone()) insert(old[i].key, std::move(old[i].wrapper));
            old[i].~Entry();
        }
        std::free(old);
        return true;
    }
    Entry* slots_ = nullptr;
    size_t cap_ = 0, used_ = 0, count_ = 0;
};

}  // namespace bk

#endif

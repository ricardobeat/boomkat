# Embedding Boomkat from C++

`include/boomkat.hpp` is a header-only C++17 layer over the C API in
`include/boomkat.h` (see [embedding.md](embedding.md)). It adds nothing to
the library: no C++ symbols, no extra objects, no size change. It builds with
exceptions and RTTI off.

| Header | Needs | Contents |
|---|---|---|
| `boomkat.hpp` | C++17 | runtime, contexts, scopes, handles, `Result`, conversions, functions, classes, promises, modules, binary data, GC control |
| `boomkat_std.hpp` | C++17 | conversions for `std::string`, `vector`, `map`, `pair`, `tuple`, `function`, `span` (C++20); `EventLoop`; `Watchdog` |
| `boomkat_coro.hpp` | C++20 | `bk::Task<T>` and `co_await bk::await(cx, value)` over promises |

```cpp
#include "boomkat.hpp"
#include <cstdio>

static double add(double a, double b) { return a + b; }

int main() {
    auto rt = bk::Runtime::create().value();
    auto cx = rt.new_context().value();
    bk::Scope scope(cx);
    (void)cx.global().set("add", bk::function<&add>(cx, "add"));
    std::printf("%g\n", cx.eval("add(1, 2)").value().to<double>().value());
}
```

More complete programs live in `bindings/cpp/examples/` (`make cpp-examples`).

## Building

- Make: `make lib` builds `out/boomkat.a`. Compile with `-std=c++17 -Iinclude`
  and link `out/boomkat.a` (plus `-lm -ldl` on Linux, `-lpthread` for
  `boomkat_std.hpp`).
- `make install PREFIX=...` installs the headers, `libboomkat.a`, the shared
  library, `lib/cmake/boomkat/boomkatConfig.cmake` and
  `lib/pkgconfig/boomkat.pc`.
- CMake:

  ```cmake
  find_package(boomkat REQUIRED)        # boomkat_DIR=<prefix>/lib/cmake/boomkat or <repo>/cmake
  target_link_libraries(app PRIVATE boomkat::cpp)   # boomkat::c for C
  ```

  `boomkat::c` is the static library unless `BOOMKAT_SHARED` is on.
  `boomkat::cpp` adds `cxx_std_17`. The package works from the source tree
  after `make lib`, so a superbuild can run `make lib` through
  `ExternalProject_Add` and point `boomkat_DIR` at `<repo>/cmake`.
- Godot (SCons): add `include/` to `CPPPATH` and `out/boomkat.a` to `LIBS`.
- Unreal (`Build.cs`): `PublicIncludePaths.Add(".../include")` and
  `PublicAdditionalLibraries.Add(".../libboomkat.a")`.
- Plugins that may share a process with another copy of Boomkat should hide
  the static library's symbols: `-Wl,--exclude-libs,ALL` on ELF,
  `-exported_symbols_list` on Mach-O.

`make cpp-check` (or `just cpp-test`) builds `test/cpp/` with C++17 and C++20,
exceptions on and off, `-Wall -Wextra -Werror -pedantic`, compiles each header
alone and runs the compile-fail cases in `test/cpp/compile_fail/`.

### Configuration macros

| Macro | Default | Effect |
|---|---|---|
| `BOOMKAT_CPP_EXCEPTIONS` | `__cpp_exceptions` | `Result::value()` throws `bk::JsError`; trampolines catch C++ exceptions |
| `BOOMKAT_CPP_DEBUG` | `!NDEBUG` | checks such as "local made with no open scope" |
| `BOOMKAT_CPP_THREAD_ID()` | undefined | define to a thread-id expression to check runtime thread affinity |

## Ownership

- `bk::Runtime` owns a runtime, `bk::OwnedContext` a context. Both are
  move-only. Destroy every `OwnedContext`, `Global`, `Weak` and `Error`
  before its runtime. `bk::Context` and `bk::RuntimeRef` are non-owning and
  trivially copyable, so callbacks take them by value.
- `bk::Value`, `Object`, `Function`, `Array`, `String`, `Symbol`, `BigInt`,
  `Promise`, `ArrayBuffer`, `TypedArray<E>` and the rest are locals: a
  context plus a handle, 16 bytes, copied by value. They live until the
  innermost `bk::Scope` closes. A C++ callback runs inside a scope of its own;
  host code opens one with `bk::Scope s(cx);`. Locals cannot be heap
  allocated. `scope.escape(v)` closes a scope and hands `v` to the enclosing
  one.
- `bk::Global<T>` is a registry root: the handle to keep in long-lived host
  structures. `v.persist()` makes one, `g.get(cx)` gives a local back. Copy
  duplicates the root, move steals it.
- `bk::Weak<T>` refers to an object without keeping it alive; `get(cx)`
  returns `std::nullopt` once it was collected.
- `bk::Traced<T>` holds a value inside a host-class payload without rooting
  it. The class reports it from `void trace(bk::Tracer&) const`, so cycles
  through native objects are collected.
- `bk::Atom` is a runtime-wide property key. `bk::SharedBlock` is a
  thread-safe reference to a `SharedArrayBuffer` block.

## Errors

Every fallible call returns `bk::Result<T>`, which holds a `T` or a
`bk::Error`. An `Error` carries an `Errc` code (`thrown`, `syntax`, `type`,
`interrupted`, `nomem`, ...), the thrown value as a root, and the line and
column. `describe()` formats it without running JS.

```cpp
bk::Result<int> answer(bk::Context cx) {
    BK_TRY_ASSIGN(bk::Value v, cx.eval("6 * 7"));    // declares v or returns the Error
    BK_TRY(cx.eval("check()"));                        // discards the value
    return v.to<int>();
}
```

`BK_TRY_OR(expr, fallback)` runs a fallback statement instead. Without
exceptions, `value()` on an error calls `bk::panic_handler` (default:
print and abort). With exceptions, it throws `bk::JsError`. Under C++23,
`to_expected()` returns a `std::expected`.

Interrupts and heap-limit terminations are uncatchable: a callback never
turns them into a JS exception, and they surface as `Errc::interrupted` or
`Errc::nomem` at the outermost host call.

## Functions and conversions

```cpp
cx.global().set("add", bk::function<&add>(cx, "add"));     // no allocation, no closure
cx.global().set("greet", bk::closure(cx, "greet",
    [prefix = std::string("hi ")](std::string name) { return prefix + name; }));
```

`bk::function<&f>` binds a free function with no allocation; its name must
have static storage. `bk::closure` boxes a callable, destroyed exactly once
when the function is collected or the runtime is freed. Parameters may also
be `bk::Context`, `bk::CallInfo&` (this, new.target, raw arguments),
`bk::This<T>`, `bk::Rest<T>` (the remaining arguments) and `bk::Value`.
Return `void`, a convertible value, or `bk::Result<T>`; an error result is
thrown into JS. With exceptions on, `bk::JsError`, `std::exception` and other
C++ exceptions become JS errors at the boundary.

`bk::Convert<T>` drives conversions. Built in: `bool`, integers (32-bit and
narrower wrap like ToInt32/ToUint32; 64-bit throw RangeError outside the safe
range and accept BigInt), floating point, enums, `std::optional<T>`
(undefined is `nullopt`), `bk::Strict<T>` (no coercion), `const char*`, the
handle types, `bk::Global<T>`, and pointers or references to bound classes.
Argument errors read `add: argument 2: expected number`. A type without a
`Convert` specialization fails to compile. A user specialization:

```cpp
template <> struct bk::Convert<Vec2> {
    static constexpr const char* js_name = "Vec2";
    static bk::Result<Vec2> from_js(bk::Value v);
    static bk::Result<bk::Value> to_js(bk::Context cx, const Vec2& v);
};
```

Host string types adapt through `String::from_utf16` and `String::visit`,
which hands a Latin-1 `std::string_view` or a `std::u16string_view` of the
string in place (valid until the next engine call):

```cpp
template <> struct bk::Convert<QString> {
    static bk::Result<QString> from_js(bk::Value v) {
        BK_TRY_ASSIGN(bk::String s, v.to_string());
        return s.visit([](auto units) { return to_qstring(units); });
    }
    static bk::Result<bk::Value> to_js(bk::Context cx, const QString& q) {
        return bk::String::from_utf16(cx, {reinterpret_cast<const char16_t*>(q.utf16()),
                                           size_t(q.size())});
    }
};
```

## Host classes

```cpp
auto vec3 = bk::Class<Vec3>(cx, "Vec3")
    .constructor<double, double, double>()
    .field<&Vec3::x>("x")
    .method<&Vec3::length>("length")
    .method<&Vec3::scaled>("scaled")      // returning Vec3 makes a new instance
    .static_method("zero", [] { return 0.0; })
    .to_string_tag("Vec3")
    .build();                              // Result<bk::ClassHandle<Vec3>>
cx.global().set("Vec3", vec3->constructor());
```

`constructor`, `inherits<Base>` and `defer_finalization` come before the
members. JS can subclass the result with `extends`. `inherits<Base>()` makes
instances pass brand checks for `Base` without RTTI. A free function bound as
a method takes the object as its first parameter, or as `bk::This<T*>`.

| Policy | Payload | On collection |
|---|---|---|
| `bk::owned` (default) | `T*` from `ClassTraits<T>::create` | `ClassTraits<T>::destroy` |
| `bk::borrowed` | host `T*`, from `bk::wrap_borrowed` | nothing; call `bk::detach` or `WrapperCache::forget` before freeing |
| `bk::shared<P>` | a smart pointer `P` | drops `P` |
| `bk::policy<X>` | `X`-defined | `X::release` |

`bk::unwrap<T>(v)` returns the native object, and calls on a detached object
throw `TypeError: Vec3 object has been destroyed`. `bk::WrapperCache<T>`
keeps one wrapper per native pointer. `bk::DynamicClass` builds a class at
run time from names and callables (Qt meta-objects, Godot `ClassDB`).

Finalizers never call the engine and may run inside any engine call. Classes
whose cleanup must run on a host-chosen thread, or call the engine, use
`defer_finalization()` and `rt.run_finalizers()`.

## Promises, jobs and event loops

```cpp
BK_TRY_ASSIGN(auto pair, bk::Promise::create(cx));
auto& [promise, resolver] = pair;   // later, on the engine thread:
                                    // bk::Scope s(resolver.context()); resolver.resolve(value);
promise.then(cx, [](int v) { ... }, [](bk::Value reason) { ... });
```

The engine has no timers or I/O. The host runs job checkpoints with
`cx.run_jobs()` or `rt.run_one_job()`, learns about new jobs through
`rt.on_job_enqueued(f)`, and blocks with `rt.wait_events(ms)`, woken from any
thread by `rt.waker().wake()`. `rt.on_rejection(f)` tracks unhandled
rejections; report them after a checkpoint. `boomkat_std.hpp` has a reference
`bk::EventLoop` with `setTimeout`, `clearTimeout` and thread-safe `post`.

With `boomkat_coro.hpp`:

```cpp
bk::Task<bk::Result<int>> twice(bk::Context cx, bk::Function f) {
    bk::Result<bk::Value> r = co_await bk::await(cx, f.call());
    if (!r) co_return std::move(r).error();
    auto n = r->to<int>();
    if (!n) co_return std::move(n).error();
    co_return *n * 2;
}
```

A task resumes inside the job that settles its promise. Locals do not survive
a suspension; hold values across `co_await` in a `bk::Global`.

## Modules

```cpp
struct GameLoader : bk::ModuleLoader {
    bk::Result<void> resolve(bk::Context, std::string_view referrer, std::string_view spec,
                             bk::ModuleName& out) override { return out.set(spec); }
    bk::Result<void> load(bk::Context cx, std::string_view name, bk::ModuleSource& out) override {
        if (name.rfind("/etc/", 0) == 0) return cx.type_error("denied");
        return out.source(read_asset(name));
    }
};
rt.set_module_loader(std::make_unique<GameLoader>(), BK_LOADER_NO_FILESYSTEM_FALLBACK);
cx.define_module("engine:math", bk::exports(cx).add("lerp", bk::function<&lerp>(cx, "lerp")));
BK_TRY_ASSIGN(bk::Object ns, cx.import("game/main.js"));   // runs jobs until it settles
```

`cx.import_async` returns the promise instead. A loader installed with
`BK_LOADER_ASYNC` can keep the request with `out.defer()` and answer the
`bk::PendingModule` later on the engine thread. `cx.invalidate_module(name)`
makes the next import reload; namespaces already taken keep the old instance.
`cx.compile` returns a `bk::Script` to run many times.

## Binary data

```cpp
std::vector<float> verts = ...;
BK_TRY_ASSIGN(auto buf, bk::ArrayBuffer::external(cx, verts.data(), verts.size() * sizeof(float),
                                                 [] { /* JS released the buffer */ }));
BK_TRY_ASSIGN(auto view, bk::TypedArray<float>::create(cx, buf, 0, verts.size()));
```

`bytes()` and `elements()` return a `bk::Span` that stays valid until the next
call that can run JS or detach the buffer. `SharedArrayBuffer::block()`
returns a `bk::SharedBlock` that other threads and runtimes can hold, and
`SharedArrayBuffer::adopt` wraps one in another runtime.

## GC and resource control

| Need | API |
|---|---|
| Native memory behind small JS objects | `rt.add_external_memory(delta)` |
| Frame-paced collection | `bk::GcInhibit`, `rt.gc_step(budget_ns)` |
| Heap budget | `RuntimeOptions::heap_limit`, `rt.set_heap_limit` |
| Stop runaway scripts | `rt.interrupt()` (any thread), `rt.on_interrupt(f)`, `bk::Watchdog` |
| Sandboxed realm | `rt.new_context(ContextOptions{BK_CONTEXT_NO_EVAL})` |
| Statistics | `rt.heap_stats()` |

`RuntimeOptions` also takes a custom allocator; the binding's own boxes
(closures, class records, hooks) come from it too.

## Threading

A runtime and everything made from it belong to one thread, and stay on the
thread that created it. `Runtime::interrupt`, `clear_interrupt`,
`Waker::wake`, `SharedBlock` and `Watchdog` are safe from any thread. Separate
runtimes on separate threads share nothing but shared-memory blocks.

## Limits

- The compile-time check that a class with `bk::Traced` members declares
  `trace` is not possible without reflection; a missing `trace` shows up as a
  dangling slot under the GC stress build.

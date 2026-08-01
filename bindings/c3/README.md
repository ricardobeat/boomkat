# C3 binding

Native C3 embedding API for the JavaScript engine. It links the engine's C3
modules directly, so there is no C ABI round-trip: values are typed, failures
are C3 faults, and nothing is passed as an opaque integer handle.

| File | Purpose |
|---|---|
| `jse.c3` | the binding (`module jse`) |
| `example/hello.c3` | evaluating source and reading values back |
| `example/host_functions.c3` | JS calling into C3, and C3 calling back into JS |
| `example/project.json` | standalone build for `host_functions` (see below) |

## Prerequisites

- c3c 0.8.2, the version this was written and tested against. Newer 0.8.x
  should work. The syntax used here is version-sensitive in two places: fault
  returns are `return FAULT~` (not `?`), and `@return!` doc contracts are not
  accepted. A much older or much newer compiler may need adjusting.
- The vendored C sources the engine already depends on (`quickjs/`,
  `libregexp/`). In a git worktree these are not copied automatically; run
  `wt setup`, or symlink `quickjs/` from the main checkout.
- No prebuilt library is needed. The example target compiles the engine from
  `src/` alongside the binding, so `make lib` and `make shared` are irrelevant
  here. Those exist for the C ABI.

## Build

From the repository root:

```sh
c3c build jse_example_c3
```

## Run

```sh
./out/jse_example_c3
```

## Expected output

```
-- values --
40 + 2      = 42
joined      = hi there 😀
squares     = 1,4,9,16 (type OBJECT)

-- errors --
compile     = jse::SYNTAX_ERROR: expected '<identifier>', got '('
throw       = jse::JS_EXCEPTION: index out of bounds
parsed      = 7
undefined   = jse::JS_EXCEPTION: notDefinedAnywhere is not defined
still alive = 400
```

## Host functions

JS can call C3. Register a `fn void(JsCtx, void*)` as a global and the engine
dispatches straight into it. Plain calls, methods, `.call`/`.apply`/`.bind`,
getters and setters, `new` and `super()` all work, because a host function is
indistinguishable from a built-in at every dispatch site.

```c3
fn void host_hypot(JsCtx ctx, void* udata) {
    double? a = ctx.arg(0).as_number();
    double? b = ctx.arg(1).as_number();
    if (catch a) { ctx.throw_error(TYPE, "hypot: expected a number"); return; }
    if (catch b) { ctx.throw_error(TYPE, "hypot: expected a number"); return; }
    ctx.ret_number(math::sqrt(a * a + b * b));
}

rt.register_fn("hypot", &host_hypot, arity: 2)!!;
rt.eval("hypot(3, 4)")!!;   // 5
```

Three rules govern how callbacks behave:

`throw_error` does not unwind. It records the exception and returns, so the
callback keeps running. Put a `return` right after it unless you mean to
continue. If `ret` is also called, the throw wins. This mirrors how the engine's
own builtins report failure, which is what every dispatch site is written
against.

A `JsArg` is scoped to the call, and is a different type from `JsValue` for
exactly that reason. `JsValue` is a registry slot rooted until `release`;
`JsArg` dies when the callback returns. The compiler rejects the mix-up that
would otherwise be a use-after-free.

C3 function pointers cannot capture. Mutable host state reaches a callback
through the `udata` pointer given to `register_fn`, which the engine stores
verbatim and never frees. It must outlive the runtime.

`ctx.call(fn, args)` invokes a JS function from host code, so host functions can
call back into JS instead of being leaf-only. If the callee throws, `call`
reports `JS_EXCEPTION` and the exception is already pending on this call, so
returning propagates it to JS unchanged.

Arguments are copied into a GC-rooted call scope rather than read from VM
registers, so they stay valid across a nested `ctx.call` that reallocates the
value stack. The example produces byte-identical output under the `GC_STRESS`
plus AddressSanitizer target, where a collection happens at every allocation.

### Host API

| Call | Notes |
|---|---|
| `rt.register_fn(name, handler, udata:, arity:, constructable:)` | binds a global; lasts until `close` |
| `ctx.argc()` / `ctx.arg(i)` | out-of-range `arg` is undefined, so no arity check |
| `ctx.this_value()` / `ctx.new_target()` / `ctx.is_construct()` | strict-only: an undefined receiver stays undefined |
| `arg.type_of()` / `as_number()` / `as_bool()` / `as_string()` | strict, `WRONG_TYPE` on mismatch |
| `ctx.number/string/boolean/null_value/undefined_value(v)` | build a `JsArg` |
| `ctx.ret(v)` / `ret_number` / `ret_string` / `ret_bool` / `ret_null` | never calling one yields undefined |
| `ctx.get_prop(obj, key)` / `ctx.set_prop(obj, key, v)` | data properties only; `get_prop` does not run getters |
| `ctx.throw_error(kind, msg)` / `ctx.throw_value(v)` | does not unwind |
| `ctx.call(fn, args, this_value)` | calls JS; faults `NOT_CALLABLE`, `JS_EXCEPTION` |

`JsErrorKind` is `ERROR`, `TYPE`, `RANGE`, `REFERENCE`, `SYNTAX`.

Nesting `js -> host -> js -> host` is bounded: past the limit the engine throws
a `RangeError` rather than faulting the stack.

### Building the host-functions example

It needs its own target, and the repo's `project.json` does not have one, so
`example/project.json` is a standalone build run from the example directory:

```sh
cd bindings/c3/example
c3c build host_functions
./out/host_functions
```

Expected output:

```
-- arguments and return values --
hypot(3, 4)          = 5
greet('world')       = hello, world
hypot.length         = 2
hypot.name           = hypot

-- host state via udata --
counter() x3         = 3
C3 side saw   = 3 hits

-- throwing, caught by JS --
caught RangeError    = RangeError: insufficient funds
no throw             = 70
wrong arg type       = hypot: first argument must be a number

-- calling a JS callback from C3 --
applyTwice(double, 5) = 20
callback throws      = from JS
not a function       = applyTwice: first argument must be a function

-- new --
new Point(3, 4).r    = 5
instance shape       = {"x":1,"y":2,"r":2.23606797749979} true
Point without new    = Point requires 'new'

-- bounded recursion --
1000 deep            = RangeError: Maximum call stack size exceeded
```

`c3c build host_functions_stress && ./out/host_functions_stress` builds the same
example with `GC_STRESS` and AddressSanitizer. It must print the same thing.

To fold this into the repo's own `project.json` instead, add:

```json
"jse_example_host_c3": {
  "type": "executable",
  "sources": ["src", "bindings/c3/jse.c3", "bindings/c3/example/host_functions.c3"],
  "opt": "O2",
  "single-module": true,
  "fp-math": "relaxed",
  "debug-info": "none",
  "features": ["THREADED_DISPATCH"]
}
```

## Using it in your own target

Add `bindings/c3/jse.c3` to a target's `sources` next to `src`, then
`import jse;`:

```json
"my_app": {
  "type": "executable",
  "sources": ["src", "bindings/c3/jse.c3", "app/main.c3"],
  "opt": "O2",
  "single-module": true,
  "features": ["THREADED_DISPATCH"]
}
```

```c3
JsRuntime rt;
rt.open()!;
defer rt.close();

JsValue v = rt.eval("40 + 2")!;
io::printfn("%g", rt.as_number(v)!);
rt.release(v);
```

## API

| Call | Notes |
|---|---|
| `rt.open()` / `rt.close()` | `close` is idempotent; `defer` it |
| `rt.eval(src)` | eval semantics: a trailing expression *is* the result |
| `rt.exec(src)` | run for side effects, discard the value |
| `rt.type_of(v)` | `JsType`; never fails |
| `rt.as_number/as_bool/as_string(v)` | strict: no coercion, `WRONG_TYPE` on mismatch |
| `rt.to_display_string(v)` | coerces like `String(v)`; runs JS, so it can throw |
| `rt.release(v)` | drop one value's root |
| `rt.last_error()` | message for the most recent failure |
| `rt.drain_microtasks()` | only needed outside an eval; `eval` already drains |

Faults: `NOT_OPEN`, `ALREADY_OPEN`, `RUNTIME_EXISTS`, `OUT_OF_MEMORY`,
`SYNTAX_ERROR`, `JS_EXCEPTION`, `INTERNAL_ERROR`, `WRONG_TYPE`, `STALE_VALUE`,
`VALUE_TABLE_FULL`, `NOT_CALLABLE`, `REGISTER_FAILED`.

Allocating accessors (`as_string`, `to_display_string`) take an optional
`Allocator`, defaulting to `tmem`. Pass `mem` (and free it) to keep a string
past the current temp scope.

## Lifetime and threading

A `JsValue` is valid while its runtime is open and until `release`. Values are
GC-rooted by being stored as properties of a single registry object that is
itself a GC root, so the mark phase reaches them and refcounting is handled by
the engine's own `put_prop`/`delete_prop`.

The registry matters because no raw engine value is safe to hold across an
`eval`: the VM resets its register window on every execution and can *relocate*
the value stack, so a `TVal` captured from an earlier run is a dangling
reference. The binding is designed to make that mistake impossible.

`release` is optional for a short program, since `close` frees everything, but
required in a loop, since an unreleased value holds its slot until `close`. The
registry grows on demand and reuses released slots; only with 65535 values live
at once does `eval` report `VALUE_TABLE_FULL`.

A released handle is retired rather than blindly recycled. Each slot carries a
generation that advances on release, so reusing a handle after `release` reports
`STALE_VALUE` instead of resolving to whatever value later occupies that slot. A
slot that exhausts its generation counter is withdrawn from reuse for the life of
the runtime, so that holds for any number of cycles.

Under `GC_STRESS` with AddressSanitizer, a held string survived 50,000 object
allocations, 3,000 alloc/release cycles leaked no slots, and the runtime
enforced the cap cleanly with no use-after-free reported.

One runtime per process, and not thread safe. The engine keeps process-global
state (the compiler's error buffer, the active-heap pointer), so a second `open`
reports `RUNTIME_EXISTS` instead of corrupting the first.

## When to use the C ABI instead

Use this native binding whenever the host is C3. It avoids marshalling, keeps
values typed without handle bookkeeping, and reports errors as real strings and
faults.

For host functions specifically the gap is wider than for `eval`. The C ABI
hands a callback opaque `unsigned int` handles that must be resolved one at a
time, and its readers return status codes. Here a callback gets `JsArg` values
with typed accessors, a scope-vs-registry distinction the compiler enforces,
and errors as ordinary C3 faults. Both paths run the same engine machinery: the
C ABI's `jse_register_fn` calls exactly the `Heap.register_host_fn` and
`builtins::make_host_function` this binding calls, so there is no capability the
C ABI has and this does not.

Reach for the C ABI (`include/jse.h`, `src/capi.c3`, built via `make lib` or
`make shared`) when:

- The host is not C3, such as C, Rust, Zig, Python/ctypes, or Ruby/fiddle. That
  is what it is for; see `examples/python`, `examples/ruby`.
- You need a shared library with a stable, versioned symbol surface. The native
  binding has no ABI guarantee: it recompiles against engine internals, so
  anything built from it must be rebuilt with the engine. Only the 12 `jse_*`
  symbols are stable across engine changes.
- You are `dlopen`-ing the engine at runtime, or want the engine behind a
  process or plugin boundary rather than statically linked in.
- You want a smaller build. The C ABI dylib is ~2 MB self-contained, while
  linking the engine's C3 sources into your target pulls in the whole engine.

Do *not* use the C ABI from C3 just to "go through the supported path". It costs
a copy on every string and turns typed values back into integers, for no
benefit.

### Known limitations (shared by both paths)

- There is no top-level call API. You cannot use `rt.call(fn, args)` from
  outside a callback; wrap the call in JS source and `eval` it. Inside a host
  callback, `ctx.call` covers it.
- Registrations cannot be removed. `register_fn` lasts until `close`.
  Registering the same name twice replaces the global binding; a function
  object JS already holds keeps working.
- An engine bug unrelated to the binding: an arrow function inside *eval-mode*
  code that contains a `for (let ...)` loop mis-resolves its enclosing `let`
  bindings, which read back as `undefined`. This reproduces through the engine's
  own `eval()` builtin with no binding involved:
  `eval("(()=>{ let s=0; for(let j=0;j<3;j++) s+=j; return s; })()")` → `NaN`.
  Since `eval`/`exec` here compile in eval mode, the same snippet is affected.
  Use `function(){...}` or `for (var ...)` until it is fixed.

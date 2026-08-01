# C3 binding

Native C3 embedding API for the JavaScript engine. It links the engine's C3
modules directly, so there is no C ABI round-trip: values are typed, failures
are C3 faults, and nothing is passed as an opaque integer handle.

| File | Purpose |
|---|---|
| `jse.c3` | the binding — `module jse` |
| `example/hello.c3` | the runnable example below |

## Prerequisites

- **c3c 0.8.2** (the version this was written and tested against). Newer 0.8.x
  should work; the syntax used here is version-sensitive in two places — fault
  returns are `return FAULT~` (not `?`) and `@return!` doc contracts are not
  accepted — so a much older or much newer compiler may need adjusting.
- The vendored C sources the engine already depends on (`quickjs/`,
  `libregexp/`). In a git worktree these are not copied automatically; run
  `wt setup`, or symlink `quickjs/` from the main checkout.
- No prebuilt library is needed. The example target compiles the engine from
  `src/` alongside the binding, so `make lib` / `make shared` are irrelevant
  here — those exist for the C ABI.

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
| `rt.eval(src)` | eval semantics — a trailing expression *is* the result |
| `rt.exec(src)` | run for side effects, discard the value |
| `rt.type_of(v)` | `JsType`; never fails |
| `rt.as_number/as_bool/as_string(v)` | strict — no coercion, `WRONG_TYPE` on mismatch |
| `rt.to_display_string(v)` | coerces like `String(v)`; runs JS, so it can throw |
| `rt.release(v)` | drop one value's root |
| `rt.last_error()` | message for the most recent failure |
| `rt.drain_microtasks()` | only needed outside an eval; `eval` already drains |

Faults: `NOT_OPEN`, `ALREADY_OPEN`, `RUNTIME_EXISTS`, `OUT_OF_MEMORY`,
`SYNTAX_ERROR`, `JS_EXCEPTION`, `INTERNAL_ERROR`, `WRONG_TYPE`, `STALE_VALUE`,
`VALUE_TABLE_FULL`.

Allocating accessors (`as_string`, `to_display_string`) take an optional
`Allocator`, defaulting to `tmem`. Pass `mem` (and free it) to keep a string
past the current temp scope.

## Lifetime and threading

A `JsValue` is valid while its runtime is open and until `release`. Values are
GC-rooted by being stored as properties of a single registry object that is
itself a GC root, so the mark phase reaches them and refcounting is handled by
the engine's own `put_prop`/`delete_prop`.

This matters because **no raw engine value is safe to hold across an `eval`**:
the VM resets its register window on every execution and can *relocate* the
value stack, so a `TVal` captured from an earlier run is a dangling reference.
The binding exists largely to make that impossible to get wrong.

`release` is optional for a short program — `close` frees everything — but
required in a loop: at most **1024** values may be live at once, after which
`eval` reports `VALUE_TABLE_FULL`.

Verified under `GC_STRESS` + AddressSanitizer: a held string survived 50,000
object allocations, 3,000 alloc/release cycles leaked no slots, and the cap was
enforced cleanly, with no use-after-free reported.

**One runtime per process, and not thread-safe.** The engine keeps process-
global state (the compiler's error buffer, the active-heap pointer), so a second
`open` reports `RUNTIME_EXISTS` instead of corrupting the first.

## When to use the C ABI instead

Use this native binding whenever the host is C3. It is faster (no marshalling),
safer (typed values, no handle bookkeeping), and gives real strings and faults.

Reach for the C ABI (`include/jse.h`, `src/capi.c3`, built via `make lib` /
`make shared`) when:

- **The host is not C3** — C, Rust, Zig, Python/ctypes, Ruby/fiddle. That is
  what it is for; see `examples/python`, `examples/ruby`.
- **You need a shared library with a stable, versioned symbol surface.** The
  native binding has no ABI guarantee: it recompiles against engine internals,
  so anything built from it must be rebuilt with the engine. The 12 `jse_*`
  symbols are the contract that does not move.
- **You are `dlopen`-ing the engine at runtime**, or want the engine behind a
  process/plugin boundary rather than statically linked in.
- **You want a smaller build.** The C ABI dylib is ~2 MB self-contained;
  linking the engine's C3 sources into your target pulls in the whole engine.

Do *not* use the C ABI from C3 just to "go through the supported path" — it
costs a copy on every string and turns typed values back into integers, for no
benefit.

### Known limitations (shared by both paths)

- **Native function registration is not supported.** Built-in dispatch is
  `builtin_dispatch_table[ordinal]`, a table sized and filled at compile time,
  never a host pointer. There is no runtime table to append to. Expose host
  behaviour by computing values in C3 and injecting them as JS source, or by
  driving the engine from the host side.
- **No direct call API.** There is no `rt.call(fn, args)` yet; wrap the call in
  JS source and `eval` it.
- **Engine bug, unrelated to the binding:** an arrow function inside *eval-mode*
  code that contains a `for (let ...)` loop mis-resolves its enclosing `let`
  bindings, which read back as `undefined`. Reproduces through the engine's own
  `eval()` builtin with no binding involved:
  `eval("(()=>{ let s=0; for(let j=0;j<3;j++) s+=j; return s; })()")` → `NaN`.
  Since `eval`/`exec` here compile in eval mode, the same snippet is affected.
  Use `function(){...}` or `for (var ...)` until it is fixed.

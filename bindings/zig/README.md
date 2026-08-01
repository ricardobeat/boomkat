# Zig binding for the `jse_` embedding ABI

An idiomatic Zig wrapper over `include/jse.h`: C status codes become a Zig
error set, and `Runtime`/`Value` are `defer`-friendly.

```zig
var rt = try js.Runtime.init();
defer rt.deinit();

var v = try rt.eval("40 + 2");
defer v.deinit();

std.debug.print("{d}\n", .{try v.toNumber()});
```

Host functions are plain Zig functions; `register` builds the `callconv(.c)`
trampoline at comptime:

```zig
fn hypot(ctx: js.Ctx) !void {
    const a = try ctx.arg(0).toNumber();
    const b = try ctx.arg(1).toNumber();
    ctx.returnNumber(@sqrt(a * a + b * b));
}

try rt.register("hypot", hypot, .{ .arity = 2 });
// JS can now call hypot(3, 4).
```

## Prerequisites

- Zig 0.16.0. The build script uses the 0.16 API (`b.createModule` +
  `.root_module`) and the example uses the 0.16 `main(init: std.process.Init)`
  signature with `std.Io.File.Writer`. It will not compile on 0.15 or earlier.
- `c3c` 0.8.2, to build the engine itself.
- The engine's shared library, built from the repo root:

```sh
make shared          # produces out/libjse.dylib (macOS) or out/libjse.so (Linux)
```

## Build and run

From this directory (`bindings/zig`):

```sh
zig build run
```

`zig build test` runs the binding's unit tests, and `zig build` alone installs
the example to `zig-out/bin/jse-example`.

By default the build looks for `../../include` and `../../out/libjse.dylib`.
To point it at an installed prefix or any other location:

```sh
zig build run \
  -Djse-include=/usr/local/include \
  -Djse-lib=/usr/local/lib/libjse.dylib
```

## Expected output

```
jse 0.1.0
sum 1..100 = 5050
squares (string) = 1,4,9,16
Throw: SyntaxError: Unexpected token in JSON
Syntax: expected '<identifier>', got '('
hypot(3, 4) = 5
mapped = 5,13 (hypot.length = 2)
caught = RangeError: age must not be negative
mapTwice(x => x * 3, 5) = 45
propagated = TypeError: from JS
bump() called 3 times, counter = 3
```

Lines 4-5 show a thrown exception and a syntax error arriving as distinct Zig
errors (`error.Throw`, `error.Syntax`), with the engine's message available
from `rt.lastError()`. The remaining lines come from host functions: a Zig
function called from JS with arguments, one throwing a `RangeError` that JS
catches, one calling a JS callback back through `jse_call`, and one carrying
host state through `udata`.

## Host functions

Write a normal Zig function taking a `js.Ctx` and register it. The C ABI needs
a `callconv(.c)` function pointer; `register` generates that trampoline at
comptime, so nothing in your code is `extern` or `export`.

```zig
fn checkAge(ctx: js.Ctx) !void {
    const age = try ctx.arg(0).toNumber();
    if (age < 0) {
        ctx.throwError(.range, "age must not be negative");
        return;
    }
    ctx.returnBool(age >= 18);
}

try rt.register("checkAge", checkAge, .{ .arity = 1 });
```

`Ctx` reaches the whole call: `argc`, `arg(i)`, `this`, `newTarget`,
`isConstruct`, the `ret*` setters, `throwError`/`throwValue`, `persist`, and
`call`.

Zig errors cannot unwind through C, so an error returned by your function
becomes `throw new Error("<error name>")`. `error.WrongType` arrives in JS as
`Error: WrongType`. For a specific kind or message, call
`ctx.throwError(.type, "...")` and return.

`error.Throw` is the exception. It means a nested `ctx.call` already recorded
the callee's exception, so the trampoline leaves it alone and a JS `TypeError`
propagates as a `TypeError` instead of being flattened into a generic `Error`.

Throwing does not unwind. `throwError` records the throw and returns normally,
and your callback must return normally too. A recorded throw beats any return
value set alongside it.

Host state travels through `udata`. A Zig closure is not C-ABI-compatible, so
state goes through a pointer, exactly as in C. Use
`registerWith(name, func, ptr, .{})` with a function taking `(Ctx, *T)`. The
pointer must outlive the runtime.

Handles obtained from `Ctx` are scope handles, valid only until the callback
returns. `deinit` on one is a no-op, so `defer v.deinit()` is always safe. To
keep a value past the call, promote it with `ctx.persist(&rt, v)` and `deinit`
the result.

Calling back into JS with `ctx.call(func, args, this)` is bounded: a runaway
host to JS to host chain raises a `RangeError` instead of exhausting the native
stack. It takes up to 8 arguments and returns `error.Full` beyond that.

Registration lasts for the runtime's lifetime. `constructable: true` is what
allows `new fn()`; otherwise `new` throws a `TypeError`, as built-ins do.

## Why the shared library, not the static archive

`make lib` also produces `out/jse_static.a`, but linking it into a Zig-built
executable crashes before `main`. The C3 runtime finds its `@init` constructors
by walking the init sections of the running image at startup, and that walk
depends on resolving the image header correctly. Zig's linker emits a second,
bogus `__mh_execute_header` in `__DATA,__bss`; the walk binds to that one,
reads garbage, and faults with `EXC_BAD_ACCESS`.

The dylib is linked by `c3c` itself, so dyld runs its constructors against the
library's own header and everything resolves. Static linking of this archive
into a binary that `c3c` did not link is not currently supported. The fix
belongs in the C3 compiler's startup code, not in this binding.

## API surface

The binding wraps every ABI entry point:

| Zig | C |
|---|---|
| `js.version()` | `jse_version` |
| `Runtime.init` / `.deinit` | `jse_open` / `jse_close` |
| `Runtime.eval` / `.exec` | `jse_eval` |
| `Runtime.lastError` | `jse_last_error`, `jse_last_error_code` |
| `Runtime.drainMicrotasks` | `jse_drain_microtasks` |
| `Runtime.register` / `.registerWith` | `jse_register_fn` |
| `Value.deinit` | `jse_value_free` |
| `Value.typeOf` | `jse_type_of` |
| `Value.toNumber` / `.toBool` / `.toString` | `jse_get_number` / `_bool` / `_string` |
| `Ctx.argc` / `.arg` / `.this` / `.newTarget` | `jse_argc` / `jse_arg` / `jse_this` / `jse_new_target` |
| `Ctx.isConstruct` | `jse_is_construct` |
| `Ctx.ret` / `.returnNumber` / `.returnBool` / `.returnNull` / `.returnString` | `jse_return*` |
| `Ctx.throwError` / `.throwValue` | `jse_throw_error` / `jse_throw` |
| `Ctx.persist` | `jse_value_persist` |
| `Ctx.call` | `jse_call` |

Notes carried over from the ABI:

- The readers are strict. `toNumber`/`toBool`/`toString` never coerce; wrap the
  value in `String(x)` or `Number(x)` in JS if you want conversion.
- One runtime per process. A second `Runtime.init` returns `error.Invalid`. The
  runtime is not thread-safe.
- `toString` allocates through the allocator you pass, and you free the result.
  Everything else copies into caller memory, so there is nothing else to free.
- Handles leak if they are never freed, which is what `defer v.deinit()` is
  for. The table holds 65535 live values and then returns `error.Full`. Scope
  handles reaching a host callback are exempt: the engine reclaims them when
  the callback returns.

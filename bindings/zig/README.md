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

## Prerequisites

- **Zig 0.16.0.** The build script uses the 0.16 API (`b.createModule` +
  `.root_module`) and the example uses the 0.16 `main(init: std.process.Init)`
  signature with `std.Io.File.Writer`. It will not compile on 0.15 or earlier.
- **`c3c` 0.8.2**, to build the engine itself.
- The engine's **shared library**, built from the repo root:

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
Point it somewhere else — an installed prefix, say — with:

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
Throw: Unexpected token in JSON
Syntax: expected '<identifier>', got '('
```

The last two lines are the point of the example: a thrown exception and a
syntax error arrive as distinct Zig errors (`error.Throw`, `error.Syntax`),
with the engine's message available from `rt.lastError()`.

## Why the shared library, not the static archive

`make lib` also produces `out/jse_static.a`, but linking it into a Zig-built
executable **crashes before `main`**. The C3 runtime finds its `@init`
constructors by walking the init sections of the running image at startup, and
that walk depends on resolving the image header correctly. Zig's linker emits a
second, bogus `__mh_execute_header` in `__DATA,__bss`; the walk binds to that
one, reads garbage, and faults with `EXC_BAD_ACCESS`.

The dylib is linked by `c3c` itself, so dyld runs its constructors against the
library's own header and everything resolves. Static linking of this archive
into a binary that `c3c` did not link is not currently supported — the fix
belongs in the C3 compiler's startup code, not in this binding.

## API surface

The binding covers all 12 ABI symbols:

| Zig | C |
|---|---|
| `js.version()` | `jse_version` |
| `Runtime.init` / `.deinit` | `jse_open` / `jse_close` |
| `Runtime.eval` / `.exec` | `jse_eval` |
| `Runtime.lastError` | `jse_last_error`, `jse_last_error_code` |
| `Runtime.drainMicrotasks` | `jse_drain_microtasks` |
| `Value.deinit` | `jse_value_free` |
| `Value.typeOf` | `jse_type_of` |
| `Value.toNumber` / `.toBool` / `.toString` | `jse_get_number` / `_bool` / `_string` |

Notes carried over from the ABI:

- **Readers are strict.** `toNumber`/`toBool`/`toString` never coerce; wrap the
  value in `String(x)` or `Number(x)` in JS if you want conversion.
- **One runtime per process.** A second `Runtime.init` returns `error.Invalid`.
  Not thread-safe.
- **`toString` allocates** through the allocator you pass; free the result.
  Everything else copies into caller memory, so there is nothing else to free.
- **Handles leak if never freed** — hence `defer v.deinit()`. The table holds
  1024 live values and then returns `error.Full`.
- **No native function registration and no `jse_call`** in v1; see the comment
  at the bottom of `include/jse.h`. Wrap calls in JS source and use `eval`.

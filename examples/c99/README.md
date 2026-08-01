# Embedding the jse engine from C99

Self-contained examples of using the JavaScript engine from plain C99, in both
directions: driving JS from C, and exposing C functions to JS. They need no
build system beyond `make` and `cc`.

| File | What it is |
|---|---|
| `main.c` | Driving JS from C: evaluate for a value, read it out, surface errors, shut down. Read this first. It is meant as documentation. |
| `host_fn.c` | The other direction: registering C callbacks as JS globals, with udata, arguments, throwing, and calling back into JS. |
| `jse_util.h` / `jse_util.c` | Optional conveniences over the raw ABI (mainly the two-call string protocol). Copy them into your own project if useful. |
| `Makefile` | Static and shared link recipes. |

## Prerequisites

- A C99 compiler (`cc`, `clang`, or `gcc`) and `make`.
- The engine's header and libraries, installed from the repo root:

  ```sh
  make -C ../.. lib shared          # build out/jse_static.a and out/libjse.dylib
  make -C ../.. install PREFIX=/usr/local
  ```

  `PREFIX` defaults to `/usr/local`, which usually needs `sudo`. Any writable
  prefix works, as long as you pass the same `PREFIX` to both commands.

Verified with Apple clang 21.0.0 and GNU Make 3.81 on macOS 27 (arm64), against
libraries built with c3c 0.8.2.

## Build and run

Static link, which gives one self-contained binary with nothing to ship
alongside it:

```sh
make PREFIX=/usr/local run
```

Shared link, which resolves `libjse` at run time through an rpath:

```sh
make PREFIX=/usr/local run-shared
```

The host-function example, `host_fn.c`, is a separate static binary:

```sh
make PREFIX=/usr/local run-host-fn
```

To build straight from the engine's `out/` directory without installing at all:

```sh
make JSE_INCDIR=../../include JSE_LIBDIR=../../out \
     JSE_STATIC_LIB=../../out/jse_static.a run

make JSE_INCDIR=../../include JSE_LIBDIR=../../out \
     JSE_STATIC_LIB=../../out/jse_static.a run-host-fn
```

`make clean` removes all three binaries.

## Expected output

Both the static and shared builds print exactly this:

```
jse version 0.1.0

sum of 1..5      = 15
greeting         = jse from C99 — astral: 😀
Math is object   = true (handle type: boolean)
object as string = [object Object]

errors are values, not crashes:
  throw        THROW    index out of range
  bad syntax   SYNTAX   expected '<identifier>', got '('
  wrong type   TYPE     value is not a string

after errors     = still running
```

Exit status is 0. The engine stores text as CESU-8 internally, and
`jse_get_string` converts to real UTF-8, so the astral character in the greeting
arrives as a proper 4-byte sequence rather than a mangled surrogate pair.

`make run-host-fn` prints:

```
jse version 0.1.0

host functions called from JS:
  greet          = hello world, from c99-example
  via map        = hello ada, from c99-example / hello alan, from c99-example
  divide         = 42
  .length        = 1, 2

errors thrown by C, caught by JS:
  by zero        = RangeError: division by zero
  wrong type     = TypeError: greet() wants a string
  not a ctor     = TypeError

C calling JS back through jse_call:
  double         = 20
  arrow          = go!!
  builtin        = 3
  callee throws  = EvalError: nope

greet() reached host state 4 times
```

`greet` is called four times, not three: `['ada', 'alan'].map(greet)` accounts
for two, and the count is read from host memory through the `udata` pointer.

## What to take away

`jse_value` is a handle, not a pointer. It is an integer index into a GC-rooted
slot registry, so do not dereference it. Every handle you get from `jse_eval`
must be released with `jse_value_free`, and the registry holds 65535 live handles
before returning `JSE_ERR_FULL`.

Errors come back as return values. Nothing aborts, panics, or longjmps across
the boundary. A failed call returns a negative status and leaves a message on
the runtime, so a bad script is handled exactly like any other failed C call.
The runtime keeps working afterwards, as the output shows.

Strings are copied into your buffer. `jse_get_string` uses a two-call
measure-then-fill protocol, so the ABI never hands back memory you must free.
`jseu_string_dup` wraps that into a single `malloc`-ing call.

Readers are strict and do not coerce. `jse_get_string` on a number is a
`JSE_ERR_TYPE`, not an implicit conversion. Stringify on the JS side instead.
`jseu_eval_to_string` does this by wrapping the source in `String(...)`.

Link the archive alone. The vendored C (libregexp, cutils, dtoa) is already
inside `libjse.a` and the dylib. Compiling it separately gives duplicate
symbols.

## Host functions (`host_fn.c`)

`jse_register_fn` binds a C callback as a JS global. The callback is
`void (*)(jse_call_ctx ctx, void *udata)`. The context is opaque, and the
`udata` pointer is handed back untouched on every call, which is how a callback
reaches host state without a file-scope global.

Throws do not unwind. `jse_throw_error` records the exception and returns
normally; the callback must still return under its own power. There is no
`longjmp` across the boundary, so C++ destructors and cleanup code are never
skipped. A recorded throw beats any return value set in the same call, but
returning early keeps the intent obvious. JS then catches a real `Error` with
the right constructor, as the `RangeError` and `TypeError` lines above show.

Argument handles are scope handles. Values from `jse_arg`, `jse_this`, and
`jse_new_target` are valid only until the callback returns and must not be
stored. To keep one, promote it with `jse_value_persist`, which yields a
runtime-owned handle you must later `jse_value_free`. Handles that come back
from `jse_call` are runtime-owned already and do need freeing.

Readers work with a NULL runtime. Inside a callback, `jse_get_number` and
friends accept `NULL` for the runtime, so a binding need not thread the
`jse_runtime` through to every callback just to read an argument.

Registered functions are ordinary function objects. They have a `.name` and
`.length`, and work as methods, accessors, `.call`/`.apply`/`.bind` targets, and
callbacks to built-ins. The `['ada', 'alan'].map(greet)` above is a real
`Array.prototype.map` call. Like any `map` callback, `greet` receives
`(element, index, array)`; it simply ignores the arguments it does not want.
Constructability is opt-in: the final `jse_register_fn` argument is 0 in this
example, so `new greet()` throws a `TypeError`.

`jse_call` runs JS from C. If the callee throws, it returns `JSE_ERR_THROW`
with the exception already recorded on the context, so return promptly and let
the engine propagate it, as `mapTwice` does. Host recursion is bounded, so a
callback that re-enters JS without end raises a `RangeError` rather than
exhausting the native stack.

## Limitations in v1

- One runtime per process. A second `jse_open` returns `JSE_ERR_INVALID`.
- The engine is not thread safe. Nothing enforces this; it is only documented.
- Host functions are globals. `jse_register_fn` binds a name on the global
  object; there is no API for installing a C callback as a property of an
  arbitrary object. Do that from JS, by moving the global onto the object.
- Registration is permanent. A host function lives for the runtime's lifetime,
  and there is no unregister call.
- `jse_call` works only inside a callback. It takes a `jse_call_ctx`, so JS
  functions can be called from inside a host callback but not directly from
  `main`. To call one from the top level, wrap the call in JS source and use
  `jse_eval`.

On Linux, link with `-lm -ldl`; the Makefile adds these automatically on
non-Darwin platforms.

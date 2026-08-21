# Embedding the boomkat engine from C99

Self-contained examples of using the JavaScript engine from plain C99, in both
directions: driving JS from C, and exposing C functions to JS. They need no
build system beyond `make` and `cc`.

| File | What it is |
|---|---|
| `main.c` | Driving JS from C: evaluate for a value, read it out, surface errors, shut down. Read this first. It is meant as documentation. |
| `host_fn.c` | The other direction: registering C callbacks as JS globals, with udata, arguments, throwing, and calling back into JS. |
| `two_runtimes.c` | Several runtimes open at once: independent globals, objects and interned strings, and what a handle does and does not mean outside the runtime that issued it. |
| `bk_util.h` / `bk_util.c` | Optional conveniences over the raw ABI (mainly the two-call string protocol). Copy them into your own project if useful. |
| `Makefile` | Static and shared link recipes. |

## Prerequisites

- A C99 compiler (`cc`, `clang`, or `gcc`) and [`just`](https://github.com/casey/just).
- The engine's header and libraries, installed from the repo root:

  ```sh
  make lib shared
  make install PREFIX=/usr/local
  ```

  `PREFIX` defaults to `/usr/local`, which usually needs `sudo`. Any writable
  prefix works, as long as you pass the same `PREFIX` to both commands.

Verified with Apple clang 21.0.0 and just 1.46.0 on macOS 27 (arm64), against
libraries built with c3c 0.8.2.

## Build and run

By default the recipes read the engine's own `out/` tree, so a working build
without an install step is the default:

```sh
just example-c-static    # static-link binary
just example-c-shared    # shared-link binary (libboomkat.dylib/.so via rpath)
just example-c-multiple  # host_fn + two_runtimes, both static
just example-ruby        # Ruby fiddle example
just example-clean       # remove the built binaries
```

To link against an installed engine tree instead, set `PREFIX` (defaults to
`/usr/local`) or override `BK_INCDIR` / `BK_LIBDIR` / `BK_STATIC_LIB`
individually:

```sh
just example-c-static BK_INCDIR=/opt/boomkat/include \
                      BK_STATIC_LIB=/opt/boomkat/lib/libboomkat.a
just example-c-shared BK_INCDIR=/opt/boomkat/include \
                      BK_LIBDIR=/opt/boomkat/lib
```

## Expected output

Both the static and shared builds print exactly this:

```
boomkat version 0.1.0

sum of 1..5      = 15
greeting         = boomkat from C99 — astral: 😀
Math is object   = true (handle type: boolean)
object as string = [object Object]

errors are values, not crashes:
  throw        THROW    RangeError: index out of range
  bad syntax   SYNTAX   expected '<identifier>', got '('
  wrong type   TYPE     value is not a string

after errors     = still running
```

Exit status is 0. The engine stores text as CESU-8 internally, and
`bk_get_string` converts to real UTF-8, so the astral character in the greeting
arrives as a proper 4-byte sequence rather than a mangled surrogate pair.

`just example-c-multiple` prints (host_fn section):

```
boomkat version 0.1.0

host functions called from JS:
  greet          = hello world, from c99-example
  via map        = hello ada, from c99-example / hello alan, from c99-example
  divide         = 42
  .length        = 1, 2

errors thrown by C, caught by JS:
  by zero        = RangeError: division by zero
  wrong type     = TypeError: greet() wants a string
  not a ctor     = TypeError

C calling JS back through bk_call:
  double         = 20
  arrow          = go!!
  builtin        = 3
  callee throws  = EvalError: nope

greet() reached host state 4 times
```

`greet` is called four times, not three: `['ada', 'alan'].map(greet)` accounts
for two, and the count is read from host memory through the `udata` pointer.

`just example-c-multiple` prints (two_runtimes section):

```
boomkat version 0.1.0

independent globals:
  A.tag / A.n                  = A/111
  B.tag / B.n                  = B/222
  B.onlyB                      = number
  A.onlyB                      = undefined

independent objects and shapes:
  A.o.k199                     = 199
  B.o.k199                     = 1990
  A key count                  = 200

independent string interning:
  A.s === literal              = true
  B.s === literal              = true

handles are per-runtime, and mixing them is not diagnosed:
  C's handle vs D's handle     = 65537 vs 65537 (identical: yes)
  C's handle read by C         = 42
  D's handle read by D         = 7
  C's handle read by D         = OK, n=7  <-- D's value, not C's
  C's handle read by D again   = INVALID, n=-1  <-- caught, only by luck
  moved A->B via C             = 42

closing A leaves B alone:
  B.tag after A closed         = B/222/1990
```

Four runtimes are open over the course of that run, two of them at the same
time as the first pair.

## What to take away

`bk_value` is a handle, not a pointer. It is an integer index into one
runtime's GC-rooted slot registry, so do not dereference it, and do not use it
with any runtime but the one that issued it. Every handle you get from
`bk_eval` must be released with `bk_value_free`, passing that same runtime;
the registry holds 65535 live handles before returning `BK_ERR_FULL`.

Errors come back as return values. Nothing aborts, panics, or longjmps across
the boundary. A failed call returns a negative status and leaves a message on
the runtime, so a bad script is handled exactly like any other failed C call.
The runtime keeps working afterwards, as the output shows.

Strings are copied into your buffer. `bk_get_string` uses a two-call
measure-then-fill protocol, so the ABI never hands back memory you must free.
`bku_string_dup` wraps that into a single `malloc`-ing call.

Readers are strict and do not coerce. `bk_get_string` on a number is a
`BK_ERR_TYPE`, not an implicit conversion. Stringify on the JS side instead.
`bku_eval_to_string` does this by wrapping the source in `String(...)`.

Link the archive alone. The vendored C (libregexp, cutils, dtoa) is already
inside `libboomkat.a` and the dylib. Compiling it separately gives duplicate
symbols.

## Host functions (`host_fn.c`)

`bk_register_fn` binds a C callback as a JS global. The callback is
`void (*)(bk_call_ctx ctx, void *udata)`. The context is opaque, and the
`udata` pointer is handed back untouched on every call, which is how a callback
reaches host state without a file-scope global.

Throws do not unwind. `bk_throw_error` records the exception and returns
normally; the callback must still return under its own power. There is no
`longjmp` across the boundary, so C++ destructors and cleanup code are never
skipped. A recorded throw beats any return value set in the same call, but
returning early keeps the intent obvious. JS then catches a real `Error` with
the right constructor, as the `RangeError` and `TypeError` lines above show.

Argument handles are scope handles. Values from `bk_arg`, `bk_this`, and
`bk_new_target` are valid only until the callback returns and must not be
stored. To keep one, promote it with `bk_value_persist`, which yields a
runtime-owned handle you must later `bk_value_free`. Handles that come back
from `bk_call` are runtime-owned already and do need freeing.

Readers come in two tiers, and which one you want follows from what you hold.
Outside a callback you hold a `bk_runtime`, so you use `bk_get_number`,
`bk_get_bool`, `bk_get_string` and `bk_type_of`. Inside a callback you hold a
`bk_call_ctx`, so you use `bk_ctx_get_number` and friends — and only that tier
resolves the scope handles `bk_arg`, `bk_this` and `bk_new_target` hand out.
Neither tier accepts `NULL`.

`bk_ctx_runtime(ctx)` gets you the runtime when you genuinely need one: to
free a handle from `bk_call`, to `bk_eval`, or to hold a value past the call.
`h_map_twice` in `host_fn.c` uses it for exactly the first of those. Freeing
with a null runtime is silently ignored, so a callback that gets this wrong
leaks a registry slot per call and starts failing with `BK_ERR_FULL` once the
65535 slots run out — with no diagnostic before that point.

Registered functions are ordinary function objects. They have a `.name` and
`.length`, and work as methods, accessors, `.call`/`.apply`/`.bind` targets, and
callbacks to built-ins. The `['ada', 'alan'].map(greet)` above is a real
`Array.prototype.map` call. Like any `map` callback, `greet` receives
`(element, index, array)`; it simply ignores the arguments it does not want.
Constructability is opt-in: the final `bk_register_fn` argument is 0 in this
example, so `new greet()` throws a `TypeError`.

`bk_call` runs JS from C. If the callee throws, it returns `BK_ERR_THROW`
with the exception already recorded on the context, so return promptly and let
the engine propagate it, as `mapTwice` does. Host recursion is bounded, so a
callback that re-enters JS without end raises a `RangeError` rather than
exhausting the native stack.

## Several runtimes at once (`two_runtimes.c`)

`bk_open` may be called as many times as you like. Each runtime owns its own
globals, objects, shapes and interned strings, and they stay independent for
their whole lifetimes; closing one does not disturb another. `two_runtimes.c`
demonstrates each of those, then opens two more to make a point about handles.

A `bk_value` belongs to one runtime and means nothing in another, but the
engine will not catch you for mixing them up. A handle is a slot index plus a
generation tag, with nothing identifying which runtime issued it, so two
runtimes at the same allocation state hand out bit-identical handles. Passing
one to the wrong runtime's reader is caught only when that slot happens to be
free or differently-generationed on the other side; when the two registries are
in step, the read returns `BK_OK` and quietly gives you the other runtime's
value. `two_runtimes.c` prints both outcomes from the same pair.

Pairing a handle with its runtime is therefore the host's job. If your binding
hands `bk_value`s to its users, that is an argument for wrapping them in
something that carries the runtime along. To move a value across, read it out
on one side and write it back on the other.

## Limitations in v1

- The engine is not thread safe. A runtime must be driven from one thread at a
  time: there is no locking, and nothing enforces the rule. Two threads each
  driving their *own* runtime share nothing and are fine; two threads inside one
  runtime corrupt it.
- Host functions are globals. `bk_register_fn` binds a name on the global
  object; there is no API for installing a C callback as a property of an
  arbitrary object. Do that from JS, by moving the global onto the object.
- Registration is permanent. A host function lives for the runtime's lifetime,
  and there is no unregister call.
- `bk_call` works only inside a callback. It takes a `bk_call_ctx`, so JS
  functions can be called from inside a host callback but not directly from
  `main`. To call one from the top level, wrap the call in JS source and use
  `bk_eval`.

On Linux, link with `-lm -ldl`; the Makefile adds these automatically on
non-Darwin platforms.

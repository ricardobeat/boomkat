# Embedding the boomkat engine from C99

Self-contained examples of using the JavaScript engine from plain C99, in both
directions: driving JS from C, and exposing C functions to JS. They need no
build system beyond `make` and `cc`.

| File | What it is |
|---|---|
| `main.c` | Driving JS from C: evaluate for a value, read it out, surface errors, shut down. Read this first. It is meant as documentation. |
| `host_fn.c` | The other direction: registering C callbacks as JS globals, with udata, arguments, throwing, and calling back into JS. |
| `two_runtimes.c` | Several runtimes open at once: independent globals, objects and interned strings, and what a handle does and does not mean outside the runtime that issued it. |

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
`bk_read_string` converts to real UTF-8, so the astral character in the greeting
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

`bk_value` is a handle, not a pointer. It is a 64-bit word naming one slot in
the issuing runtime's GC-rooted registry, tagged with that runtime's id: do not
dereference it, and do not resolve it against any runtime but the one that
issued it -- the wrong-runtime case is refused with `BK_ERR_INVALID`. Every
handle you get from `bk_eval` must be released with `bk_free`; the registry
grows on demand, so it is bounded by memory rather than by a fixed count.

Errors come back as return values. Nothing aborts, panics, or longjmps across
the boundary. A failed value call returns `0` and leaves a message on the
context for `bk_error`, so a bad script is handled exactly like any other
failed C call. The runtime keeps working afterwards, as the output shows.

Strings have three paths. `bk_cstr` coerces any value to context-owned text
(valid until the fourth following call), `bk_strdup` gives you a `malloc`-ing
copy you free, and `bk_read_string` is the zero-allocation two-call protocol.

Strict readers do not coerce. `bk_read_string` on a number is a `BK_ERR_TYPE`,
not an implicit conversion; use `bk_cstr` when you want JS's own stringification.

Link the archive alone. The vendored C (libregexp, cutils, dtoa) is already
inside `libboomkat.a` and the dylib. Compiling it separately gives duplicate
symbols.

## Host functions (`host_fn.c`)

`bk_register` installs a table of C callbacks as JS globals (`target` 0 means
globalThis; pass an object handle to install onto it instead). Each entry is
`{ name, fn, arity, flags, udata }` and the table ends at `BK_FN_END`. The
callback is `void (*)(bk_ctx ctx, void *udata)`. The context is opaque, and the
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
stored. To keep one, promote it with `bk_persist`, which yields an owned handle
you must later `bk_free`. Handles that come back from `bk_call` are owned
already and need freeing too.

There is one context type. A callback's context resolves its scope handles and
every registry handle alike, so callback code and top-level code are textually
identical: the same readers work in both places, which is what retired the old
runtime/context tier split.

Registered functions are ordinary function objects. They have a `.name` and
`.length`, and work as methods, accessors, `.call`/`.apply`/`.bind` targets, and
callbacks to built-ins. The `['ada', 'alan'].map(greet)` above is a real
`Array.prototype.map` call. Like any `map` callback, `greet` receives
`(element, index, array)`; it simply ignores the arguments it does not want.
Constructability is opt-in: set the `BK_CTOR` flag on the table entry to allow
`new`; without it `new greet()` throws a `TypeError`.

`bk_call(ctx, fn, this_val, argv, argc)` runs JS from C, at top level or inside
a callback alike. It returns an owned handle, or 0 with the callee's exception
already recorded on the context, so return promptly and let the engine propagate
it, as `mapTwice` does. Host recursion is bounded, so a callback that re-enters
JS without end raises a `RangeError` rather than exhausting the native stack.

## Several runtimes at once (`two_runtimes.c`)

`bk_open` may be called as many times as you like. Each runtime owns its own
globals, objects, shapes and interned strings, and they stay independent for
their whole lifetimes; closing one does not disturb another. `two_runtimes.c`
demonstrates each of those, then opens two more to make a point about handles.

A `bk_value` belongs to the runtime that issued it and says so: the top 16 bits
of every handle carry that runtime's id. Resolving a handle against another
runtime fails with `BK_ERR_INVALID` instead of answering with whatever occupies
that slot there. Before handles were tagged, two runtimes at the same allocation
state handed out bit-identical handles, and the wrong-runtime read returned
`BK_OK` with the other runtime's value. `two_runtimes.c` asserts the refusal
for strings, numbers, persisted handles, and handles whose issuing runtime has
since closed.

To move a value across, read it out on one side and write it back on the other.

## Limitations

- The engine is not thread safe. A runtime must be driven from one thread at a
  time: there is no locking, and nothing enforces the rule. Two threads each
  driving their *own* runtime share nothing and are fine; two threads inside one
  runtime corrupt it.
- Registration is permanent. A host function lives for the runtime's lifetime,
  and there is no unregister call.

On Linux, link with `-lm -ldl`; the Makefile adds these automatically on
non-Darwin platforms.

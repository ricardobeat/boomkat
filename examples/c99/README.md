# Embedding the jse engine from C99

A complete, self-contained example of driving the JavaScript engine from plain
C99: evaluate JS for a value, read that value out, surface errors, shut down.
No build system beyond `make` and `cc`.

| File | What it is |
|---|---|
| `main.c` | The example. Read this first — it is meant as documentation. |
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
  prefix works — just pass the same `PREFIX` to both commands.

Verified with Apple clang 21.0.0 and GNU Make 3.81 on macOS 27 (arm64), against
libraries built with c3c 0.8.2.

## Build and run

Static link — one self-contained binary, nothing to ship alongside it:

```sh
make PREFIX=/usr/local run
```

Shared link — resolves `libjse` at run time through an rpath:

```sh
make PREFIX=/usr/local run-shared
```

To build straight from the engine's `out/` directory without installing at all:

```sh
make JSE_INCDIR=../../include JSE_LIBDIR=../../out \
     JSE_STATIC_LIB=../../out/jse_static.a run
```

`make clean` removes both binaries.

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

Exit status is 0. The `😀` is the interesting one: the engine stores text as
CESU-8 internally, and `jse_get_string` converts to real UTF-8, so an astral
character arrives as a proper 4-byte sequence rather than a mangled surrogate
pair.

## What to take away

**Handles, not pointers.** `jse_value` is an integer index into a GC-rooted slot
registry, never a pointer — do not dereference it. Every handle you get from
`jse_eval` must be released with `jse_value_free`, and the registry holds 1024
live handles before returning `JSE_ERR_FULL`.

**Errors are return values.** Nothing aborts, panics, or longjmps across the
boundary. A failed call returns a negative status and leaves a message on the
runtime, so a bad script is handled exactly like any other failed C call. As the
output shows, the runtime keeps working afterwards.

**Strings are copied into your buffer.** `jse_get_string` uses a two-call
measure-then-fill protocol, so the ABI never hands back memory you must free.
`jseu_string_dup` wraps that into a single `malloc`-ing call.

**Readers are strict; they do not coerce.** `jse_get_string` on a number is a
`JSE_ERR_TYPE`, not an implicit conversion. Stringify on the JS side instead —
`jseu_eval_to_string` does this by wrapping the source in `String(...)`.

**Link the archive alone.** The vendored C (libregexp, cutils, dtoa) is already
inside `libjse.a` and the dylib. Compiling it separately gives duplicate symbols.

## Limitations in v1

- **One runtime per process.** A second `jse_open` returns `JSE_ERR_INVALID`.
- **Not thread-safe**, and this is documented rather than enforced.
- **No native function registration.** Built-ins dispatch through a
  compile-time ordinal table with no host-pointer path, so registering a C
  callback needs engine changes, not a shim. See the note at the bottom of
  `jse.h`.
- **No `jse_call`.** To call a JS function from C, wrap the call in JS source
  and use `jse_eval`.

On Linux, link with `-lm -ldl`; the Makefile adds these automatically on
non-Darwin platforms.

# Embedding

How to package this engine as a library and drive it from a host program.

The engine is a strict-only ES5/ES6 interpreter meant to be embedded (see
`engine-scope.md`). This document covers the `jse_` C ABI, which is the only
supported boundary for non-C3 hosts, and the language bindings built on top of
it.

Everything stated here about the ABI was verified by building and running the
code at the commit that introduced this file. Where a claim comes from work that
is **not** on `main`, it is labelled as such — see
[Status of the bindings](#status-of-the-bindings), which you should read before
relying on any of the per-language sections.

## Contents

- [Packaging](#packaging)
- [Hello world in C99](#hello-world-in-c99)
- [ABI reference](#abi-reference)
- [Lifetime and GC rules](#lifetime-and-gc-rules)
- [Status of the bindings](#status-of-the-bindings)
- [Per-language guides](#per-language-guides)
- [Known limitations of v1](#known-limitations-of-v1)

## Packaging

Three artifacts make up the distributable engine.

| Artifact | Built by | Size | Notes |
|---|---|---|---|
| `out/jse_static.a` | `make lib` | ~2.5 MB | Static archive. Installed as `libjse.a`. |
| `out/libjse.dylib` / `.so` | `make shared` | ~2.0 MB | Shared library. `make jse` is a synonym. |
| `include/jse.h` | (source) | — | Hand-written C99 public header. |

Both libraries are self-contained: the vendored C sources (`libregexp`,
`cutils`, `dtoa`) are **already inside** them. Compiling those separately into
your program produces duplicate symbols.

The shared library exports the 12 documented `jse_` entry points:

```
jse_close  jse_drain_microtasks  jse_eval    jse_get_bool  jse_get_number
jse_get_string  jse_last_error  jse_last_error_code  jse_open  jse_type_of
jse_value_free  jse_version
```

They are **not** the only exported symbols. `c3c` has no visibility control and
emits no version script, so the entire module graph is exported alongside them
— 2460 symbols on the macOS dylib, 2272 on the Linux `.so` (measured). Treat the
12 above as the supported surface and everything else as private, but be aware
that on ELF the extra exports participate in global symbol interposition. That
is not hypothetical: a wrapper function named `re_exec` collided with glibc's
legacy `re_exec`, and every JS regexp segfaulted inside libc until it was
renamed to `re_run`. If you add a C helper to the engine, check the name against
`nm -D /lib/*/libc.so.6`.

### Installing

```sh
make lib shared
make install PREFIX=/usr/local     # PREFIX defaults to /usr/local; DESTDIR honoured
```

lays down:

```
$PREFIX/include/jse.h
$PREFIX/lib/libjse.a
$PREFIX/lib/libjse.dylib      # .so on Linux
```

The dylib keeps its `@rpath/libjse.dylib` install name rather than being
restamped with an absolute path. This is deliberate: `install_name_tool` cannot
grow a load command past the padding `c3c` emitted, so restamping fails outright
whenever `PREFIX` is longer than that padding. Consumers therefore pass
`-Wl,-rpath,$PREFIX/lib`; `ctypes`/`fiddle`-style loaders open the path directly
and are unaffected.

### Linking

```sh
# static
cc -std=c99 -I$PREFIX/include app.c $PREFIX/lib/libjse.a -o app

# shared
cc -std=c99 -I$PREFIX/include app.c -L$PREFIX/lib -ljse \
   -Wl,-rpath,$PREFIX/lib -o app
```

On Linux add `-lm -ldl`. On macOS nothing extra is needed. The Makefile applies
this automatically via `JSE_LDLIBS`.

**On Linux the static archive also needs LLVM's compiler-rt.** The BigInt path
multiplies `int128` values, which LLVM lowers to the overflow-checked builtin
`__muloti4`. Apple's libSystem carries it; GNU `libgcc` and `libgcc_s` do not —
it exists only in compiler-rt (verified: `nm` finds it in neither libgcc). A
GCC-driven static link therefore fails with:

```
/usr/bin/ld: libjse.a(duktape.esm.o): in function `duktape.hbigint.bigint_mul':
duktape::esm:(.text+0xee228): undefined reference to `__muloti4'
```

Pass the archive explicitly (Debian: `apt install libclang-rt-19-dev`):

```sh
cc -std=c99 -I$PREFIX/include app.c $PREFIX/lib/libjse.a -lm -ldl \
   /usr/lib/llvm-19/lib/clang/19/lib/linux/libclang_rt.builtins-$(uname -m).a -o app
```

The Makefile and `examples/c99/Makefile` locate it automatically and append it
to `JSE_LDLIBS`; override `C3C_RT_LIB` / `JSE_RT_LIB` to point elsewhere. The
**shared** library is unaffected — it resolved the symbol at its own link. The
same flag is needed when `c3c` links the engine itself, which the Makefile
passes via `c3c build <target> -z <archive>`.

### Build configuration

The `jse` and `jse_static` targets in `project.json` are built at `-O2`,
`single-module`, relaxed FP math, no panic messages, no debug info, with the
`THREADED_DISPATCH` feature. Two non-obvious requirements:

- **`"single-module": true` is mandatory.** Without it the dylib link fails with
  undefined symbols such as `_unicode_is_cased`.
- **Use `--no-headers`.** The `c3c`-generated header leaks C3 internals
  (`c3slice_t`, `std_core__usz`) and is not a usable public interface. That is
  why `include/jse.h` is hand-written.

Toolchain used for the macOS results in this document: `c3c` 0.8.2
(LLVM 22.1.8), Apple clang 21, macOS 27 arm64.

### Linux

Linux is **verified**, on linux/arm64 (Debian trixie, `c3c` 0.8.2 built from
source against LLVM 19.1.7, GCC 14.2). Run it with `make linux-ci`; see
[`ci/linux/README.md`](../ci/linux/README.md).

What was established by running it:

| Area | Result |
|---|---|
| `c3c build duktape_c3` | Builds, once `__muloti4` is supplied (see above) |
| `bash test/run_local.sh` | **Fully green**, identical counts to macOS: 302 scripts, 14 module fixtures, 101 + 63 syntax/export checks, 24 top-level, 12 uncaught, 5796 console lines |
| `make lib` / `make shared` | Both build; `out/libjse.so` is produced |
| `make smoke` | Prints `42` |
| `ldd` | No unresolved deps on `libjse.so` or on an executable linked against it |
| `nm -D` | All 12 `jse_` symbols exported |
| `make install PREFIX=…` | Header and both libraries install; static and `-ljse` shared builds compile and run against the prefix |
| rpath | `-Wl,-rpath,$PREFIX/lib` is load-bearing — without it the loader fails and `LD_LIBRARY_PATH` is required |

Two Linux-specific defects were found and fixed while verifying:

- **`re_exec` collided with glibc.** The vendored regexp wrapper exported a
  function named `re_exec`; glibc exports a legacy BSD `re_exec` too. Because
  the shared library exports every engine symbol, ELF interposition bound the
  engine's own call sites to *libc's* unrelated function and every JS regexp
  segfaulted inside `regexec`. Confirmed by backtrace and by the crash vanishing
  under `LD_PRELOAD=out/libjse.so`. Renamed to `re_run`. macOS's two-level
  namespace hid this completely.
- **`__muloti4` is not in libgcc**, so every link of the engine and of the
  static archive failed. See the linking section above.

The `.so` suffix selection in every loader (`bindings/python/js.py`,
`bindings/ruby/lib/js.rb`, `bindings/zig/build.zig`, `bindings/rust`'s
`build.rs`, `examples/c99/Makefile`) was already correct and needed no change.

#### The static-link init hazard does not reproduce on Linux

The Zig section below documents that on macOS, linking `out/jse_static.a` into a
Zig-built executable segfaults in `__c3_runtime_startup` before `main`, because
Zig emits a second bogus `__mh_execute_header` and the C3 runtime's constructor
walk binds to it. The natural worry is that ELF `.init_array` has the same
problem.

**It does not.** Tested directly by building the same program from both foreign
linkers against the static archive:

```
Zig  0.16.0 : rc=0, printed "zig static: 42"
rustc 1.97.1: rc=0, printed "rust static: 42"
```

For contrast, the macOS failure was re-confirmed on the same host with the same
Zig 0.16.0 and the same source: `RUN_RC=139` (SIGSEGV) with zero output. So the
hazard is specific to Mach-O image-header discovery, and **static linking from
Zig and Rust is supported on Linux**. Two caveats, both mechanical:

- `rustc` passes `-nodefaultlibs`, so the C3 runtime's `atexit` hook is
  unresolved unless you add `-C link-arg=-lc`.
- Both need the compiler-rt archive for `__muloti4`.

#### Binding status on Linux

All seven binding surfaces were run in-container and produce correct output.

| Binding | Linux | Notes |
|---|---|---|
| C99 static | pass | needs compiler-rt; `examples/c99/Makefile` adds it |
| C99 shared | pass | |
| Python (ctypes) | pass | |
| Ruby (fiddle) | pass | only after the `re_exec` → `re_run` fix; every regexp crashed before it |
| Zig (shared) | pass | needs > 2 GB of container memory or `zig build` is OOM-killed |
| Rust | pass | |
| C3 (native) | pass | |

## Hello world in C99

Compiles clean at `-std=c99 -Wall -Wextra -pedantic` and was run to produce the
output shown.

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <jse.h>

int main(void) {
    jse_runtime rt;
    if (jse_open(&rt) != JSE_OK) {
        fprintf(stderr, "cannot start the engine\n");
        return 1;
    }

    static const char SRC[] =
        "const who = 'world';"
        "`hello, ${who} — ` + [1,2,3].map(n => n * n).join(',')";

    jse_value v;
    int rc = jse_eval(rt, SRC, strlen(SRC), &v);
    if (rc != JSE_OK) {
        fprintf(stderr, "eval failed (%d): %s\n", rc, jse_last_error(rt));
        jse_close(rt);
        return 1;
    }

    /* Two-call protocol: measure, then fill a caller-owned buffer. */
    size_t len;
    if (jse_get_string(rt, v, NULL, 0, &len) == JSE_OK) {
        char *buf = malloc(len + 1);
        if (buf && jse_get_string(rt, v, buf, len + 1, &len) == JSE_OK) {
            printf("%s\n", buf);
        }
        free(buf);
    }

    jse_value_free(rt, v);
    jse_close(rt);
    return 0;
}
```

```
$ cc -std=c99 -Wall -Wextra -pedantic -I$PREFIX/include hello.c \
     $PREFIX/lib/libjse.a -o hello
$ ./hello
hello, world — 1,4,9
```

The shared-link build produces identical output, including when run from an
unrelated working directory.

## ABI reference

All declarations live in `include/jse.h`. The implementation is `src/capi.c3`.

### Types

| Type | Definition | Meaning |
|---|---|---|
| `jse_runtime` | `void *` | Opaque runtime. Never dereference. |
| `jse_value` | `unsigned int` | **Handle, not a pointer.** Index into a GC-rooted slot registry. `0` (`JSE_INVALID_VALUE`) is never valid. |

`jse_value` is an integer by design. The engine's internal `TVal` is 8 or 16
bytes depending on a compile-time feature and all its accessors are C3 macros
with no linkable symbol, so it can never cross the boundary.

### Status codes

| Code | Value | Meaning |
|---|---|---|
| `JSE_OK` | 0 | Success. |
| `JSE_ERR_NOMEM` | -1 | Allocation failed. |
| `JSE_ERR_SYNTAX` | -2 | Compile failed. |
| `JSE_ERR_THROW` | -3 | Uncaught JS exception. |
| `JSE_ERR_INTERNAL` | -4 | Engine fault with no JS error attached. |
| `JSE_ERR_INVALID` | -5 | Null/bad argument, or bad handle. |
| `JSE_ERR_TYPE` | -6 | Value is not of the requested type. |
| `JSE_ERR_FULL` | -7 | Buffer too small, **or** slot table exhausted. |

`JSE_ERR_FULL` is overloaded. Disambiguate by which call returned it:
`jse_get_string` means the buffer was too small, `jse_eval` means the value
registry is full.

### Value types

`JSE_TYPE_UNDEFINED` 0, `NULL` 1, `BOOLEAN` 2, `NUMBER` 3, `STRING` 4,
`OBJECT` 5, `FUNCTION` 6, `OTHER` 7 (symbol, bigint).

### Functions

| Function | Returns | Contract |
|---|---|---|
| `jse_open(jse_runtime *out)` | status | One runtime per process. A second call while one is open returns `JSE_ERR_INVALID` rather than corrupting the first (verified). |
| `jse_close(jse_runtime)` | void | Destroys the runtime and everything it owns; all handles become invalid. Safe with `NULL`. |
| `jse_version(void)` | `const char *` | Static string, currently `"0.1.0"`. Never `NULL`. |
| `jse_eval(rt, src, len, out_val)` | status | Compiles and runs `len` bytes of UTF-8 **for its completion value** — `"40 + 2"` yields 42. On `JSE_OK` `*out_val` is an owned handle; pass `NULL` for `out_val` to run for side effects only. Drains microtasks before returning. |
| `jse_value_free(rt, v)` | void | Releases a handle. Safe with `0` or an already-freed handle. |
| `jse_type_of(rt, v)` | `jse_type` | **Cannot fail.** An invalid or freed handle reports `JSE_TYPE_UNDEFINED`. |
| `jse_get_number(rt, v, double *out)` | status | Strict, no coercion. Handles both the double and 47-bit fastint representations. |
| `jse_get_bool(rt, v, int *out)` | status | Strict. `*out` is 0 or 1. |
| `jse_get_string(rt, v, buf, cap, out_len)` | status | Strict. Two-call protocol, see below. |
| `jse_last_error(rt)` | `const char *` | Message for the most recent failure. Never `NULL`; empty when none. Owned by the runtime — copy it. Formatted without re-entering the VM. |
| `jse_last_error_code(rt)` | status | Code matching `jse_last_error`. |
| `jse_drain_microtasks(rt)` | void | Runs pending promise jobs. Re-entrancy guarded. `jse_eval` already drains. |

`jse_eval` uses `compile_eval`, not `compile`. Plain `compile` returns a value
only on an explicit `RET`, so a top-level expression would yield `undefined` —
not what an embedder expects.

### The string protocol

The ABI never hands out memory the caller must free, which removes a whole class
of FFI leak. There is deliberately no `jse_free_string`.

```c
size_t len;
jse_get_string(rt, v, NULL, 0, &len);   /* measure: len excludes the NUL */
char *buf = malloc(len + 1);
jse_get_string(rt, v, buf, len + 1, &len);  /* fill */
```

If `cap` is too small the call returns `JSE_ERR_FULL` and writes the required
length to `*out_len`, so a failed fill tells you how big to retry (verified:
a 3-byte buffer for a 7-byte string returns `-7` with `*out_len == 7`).

Strings are converted from the engine's internal CESU-8 to standard UTF-8, so
astral characters emerge as proper 4-byte sequences rather than surrogate
halves. Verified: `'hi \u{1F600}'` measures 7 bytes and round-trips as `hi 😀`.

### Error handling

Nothing aborts, panics, or `longjmp`s across this boundary. Every call returns a
status or a handle.

```c
if (jse_eval(rt, src, len, &v) != JSE_OK) {
    fprintf(stderr, "%s\n", jse_last_error(rt));   /* copy if you keep it */
}
```

`jse_last_error` is valid only until the next `jse_*` call. The engine's compile
error buffer is process-global and is clobbered by the next failing compile, so
the shim copies the message immediately.

> **Defect on `main`: the readers do not set an error message.**
> `jse_get_number`, `jse_get_bool` and `jse_get_string` return `JSE_ERR_TYPE`,
> `JSE_ERR_INVALID` or `JSE_ERR_FULL` without recording anything. Calling
> `jse_last_error` after one of them returns either an empty string or, worse, a
> **stale message from an unrelated earlier call**. Verified on `main`:
>
> ```
> primed      = [STALE-SENTINEL]
> str<-number = rc=-6 err=[]
> ```
>
> Branch on the status code, never on the message text, after a reader call.
> A fix exists on the binding branches (see below) but is not merged.

One syntax-error input, `"var = = ="`, leaves the global compile buffer empty —
an engine gap. The shim substitutes `"SyntaxError"` so the ABI never returns an
empty message for a syntax failure.

## Host functions

A host function is a C callback that JS invokes by name. This is what makes the
engine embeddable rather than a calculator: it is how JS reaches your I/O,
timers, logging, and application logic.

```c
static void greet(jse_call_ctx ctx, void *udata) {
    char buf[128];
    size_t n = 0;
    if (jse_get_string(NULL, jse_arg(ctx, 0), buf, sizeof buf, &n) != JSE_OK) {
        jse_throw_error(ctx, JSE_ERROR_TYPE, "greet() wants a string");
        return;
    }
    printf("host sees: %s\n", buf);
    jse_return_number(ctx, (double)n);
}

jse_register_fn(rt, "greet", 5, greet, NULL, /*arity*/1, /*constructable*/0);
jse_eval(rt, "greet('world')", 14, NULL);
```

**The call protocol.** The callback receives an opaque `jse_call_ctx` and the
`udata` pointer given at registration, passed through untouched. Read arguments
with `jse_argc` and `jse_arg`; an index past the end yields a handle to
`undefined` rather than an error, matching JS. `jse_this`, `jse_new_target`, and
`jse_is_construct` cover method and constructor calls.

**Returning.** `jse_return` takes a handle; `jse_return_number`, `_bool`,
`_null`, and `_string` are the direct forms. A callback that returns nothing
yields `undefined`.

**Throwing never unwinds.** `jse_throw_error(ctx, kind, msg)` and
`jse_throw(ctx, handle)` *record* a throw and return normally — the callback
must then return normally too. There is no `longjmp` across the boundary, which
is what lets every dispatch site in the engine remain unchanged. A recorded
throw beats any return value set in the same callback.

**Constructors.** Pass `constructable` non-zero to allow `new`. The engine
creates the instance and `jse_this` sees it; return nothing to keep that object,
or return an object to replace it (ES2015 §9.2.2). A zero value makes `new fn()`
throw a `TypeError`, matching ES2015 §10.3 where built-ins construct only when
specified. Constructable host functions get an own `.prototype` with a
`.constructor` back-reference, so `class D extends HostCtor` works.

**Handle lifetime is the one rule to internalise.** Handles from `jse_arg`,
`jse_this`, and `jse_new_target` are *scope handles*: valid only until the
callback returns. To keep one, promote it with `jse_value_persist`, which
returns a runtime-owned handle the caller must `jse_value_free`. Scope handles
passed to `jse_value_free` are ignored rather than treated as an error. The
readers accept both handle kinds and tolerate a `NULL` runtime inside a
callback, so `jse_get_number(NULL, jse_arg(ctx, 0), &d)` is valid.

**Calling JS back.** `jse_call(ctx, func, argv, argc, this_val, out_val)` invokes
a JS function from inside a callback. On `JSE_OK`, `*out_val` is a runtime-owned
handle you must free. If the callee throws, the exception is recorded on your
context and `JSE_ERR_THROW` is returned — return promptly and let the engine
propagate it.

**Arguments are copied, not referenced.** The engine stages each call's
`this`, `new.target`, and arguments into a GC-rooted per-call scope rather than
pointing into VM registers. This matters because `jse_call` can grow and
reallocate the value stack; a register pointer would dangle, and a host holding
an opaque handle has no way to refresh it.

## Lifetime and GC rules

The rules an embedder must obey, and why they exist.

**Handles are owned.** A handle from `jse_eval` stays valid until you call
`jse_value_free` or `jse_close`. It **survives garbage collection** — the slot
registry is a GC root, so held values are transitively reachable by the mark
phase. Verified: a held string survived 200,000 object allocations, and the
design passes under `GC_STRESS` + AddressSanitizer with no use-after-free and no
invalid reads.

**Handles leak if you never free them.** The registry grows on demand and
reuses freed slots, so there is no small fixed cap; its ceiling is **524287**
simultaneously live handles, and exceeding that returns `JSE_ERR_FULL`
(verified: exhaustion at exactly 524287, reported cleanly rather than
misbehaving). Free eagerly in loops.

**A freed handle is retired, not blindly recycled.** Each slot carries a
generation that advances on free, so reading a stale handle fails instead of
resolving to whatever value later lands in that slot (verified: 200k alloc/free
cycles with no aliasing).

**Never dereference a `jse_value`.** It is an index, not an address.

**Do not cache `const char *` returns.** `jse_last_error` and `jse_version`
point to runtime-owned storage. Copy before the next call.

**One runtime per process, and not thread-safe.** The engine has process-global
state (the compiler error buffer, the active-heap pointer). A second `jse_open`
returns `JSE_ERR_INVALID`. That check is a **plain global with no lock**, so two
threads calling `jse_open` simultaneously still race. The ABI is documented
not-thread-safe; it does not enforce it. Confine all engine calls to one thread.

**Why handles, and not the obvious designs.** Both alternatives are broken, which
is worth knowing before anyone proposes them again:
- The valstack cannot host host-owned slots. `Vm.execute` unconditionally resets
  `valstack_top` and reinitialises registers on every eval, and
  `ensure_valstack_grow` **reallocs and relocates** the buffer. Any slot there is
  clobbered or moved.
- `gc_roots` cannot back a handle table. It is capped at 64, silently drops past
  that, and **has no unregister function** — roots are permanent.

The registry sidesteps both: one ordinary object, registered once as a GC root
(costing 1 of the 64), holding host values as normal properties under interned
integer keys. Refcounting then comes free from the existing `put_prop`/
`delete_prop` paths.

## Status of the bindings

**Read this before the per-language sections.**

Only the C ABI itself is on `main`. The six language bindings were each built and
independently verified on their own branch, and **none of those branches are
merged**. On `main` today you get:

```
include/jse.h            src/capi.c3
examples/c/{smoke,hello}.c
examples/python/jse.py   examples/ruby/jse.rb   (small pre-existing wrappers)
```

There is **no `bindings/` directory on `main`.** Every path under `bindings/`
below exists only on the branch named in the table.

| Language | Branch / commit | Verifier verdict |
|---|---|---|
| C99 | `worktree-wf_dcfbb957-d0e-6` / `794e6bb6` | Not refuted |
| Zig | `worktree-wf_dcfbb957-d0e-7` / `5743c35f` | Not refuted |
| Rust | `worktree-wf_dcfbb957-d0e-8` / `460f3a78` | Not refuted |
| C3 | `worktree-wf_dcfbb957-d0e-9` / `b5ae2df8` | Not refuted |
| Ruby | `worktree-wf_dcfbb957-d0e-10` / `7542996d` | Not refuted, **one real defect found** |
| Python | `worktree-wf_dcfbb957-d0e-11` / `dcc01402` | Not refuted |

Each binding branch also carries a fix to `src/capi.c3` found by driving the ABI
from that language. **None of these fixes are on `main`**, and each was
re-confirmed still broken on `main` while writing this document:

| Defect (still present on `main`) | Observed on `main` | Fixed on |
|---|---|---|
| Readers set no error message; `jse_last_error` returns stale text | `str<-number = rc=-6 err=[]` after priming a sentinel | C99, Rust branches |
| `Symbol` misreported as `JSE_TYPE_STRING`; `jse_get_string` then emits invalid UTF-8 | `Symbol type = 4`, bytes `ff 01 78` | Python branch |
| Thrown primitives lose their value | `throw 42` → `[uncaught exception]` | Ruby branch |
| An `Error`'s `name` is never found (own-property lookup only) | `throw new TypeError('tt')` → `[tt]`, not `TypeError: tt` | Ruby branch |

The last two mean that on `main`, error messages are less informative than the
per-language expected outputs below show. Those outputs were produced on their
own branches, with the fixes applied. **Expect different error text if you run a
binding against an unpatched `main`.**

Merging the branches requires reconciling four independent edits to
`src/capi.c3`; that work has not been done.

## Per-language guides

### C99 — `examples/c99/`

```sh
make lib shared
make install PREFIX=$PREFIX
make -C examples/c99 PREFIX=$PREFIX          # `make shared` for the shared-link variant
make -C examples/c99 PREFIX=$PREFIX run
```

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

Static and shared builds produce byte-identical output; `otool -L` confirms the
shared build genuinely links `@rpath/libjse.dylib` rather than silently
resolving to the archive. Clean under ASan.

**Caveat:** `jseu_eval_to_string()` in `jse_util.c` stringifies by concatenating
caller source into `String((...))`. That is JS source injection if the input is
ever untrusted. Safe for the literals in the example; do not copy it into a path
where the JS comes from elsewhere.

On `main` today, `make example-c` builds `examples/c/hello.c` instead and prints
`jse 0.1.0 / squares: 1,4,9,16 / caught: nope` (verified).

### Zig — `bindings/zig/`

```sh
make shared                  # from the repo root
cd bindings/zig && zig build run
```

```
jse 0.1.0
sum 1..100 = 5050
squares (string) = 1,4,9,16
Throw: Unexpected token in JSON
Syntax: expected '<identifier>', got '('
```

**Requires Zig 0.16.0 exactly.** The build script uses `b.createModule` +
`.root_module` and the example uses the 0.16 `main(init: std.process.Init)`
signature with `std.Io.File.Writer`. It will not compile on 0.15 or earlier,
which excludes most currently-deployed Zig versions.

**The static archive is unusable from Zig on macOS.** Linking `out/jse_static.a`
into a Zig-built executable segfaults in `__c3_runtime_startup` *before* `main`
(reproduced: `SIGSEGV`, zero output). Zig's linker emits a second, bogus
`__mh_execute_header` in `__DATA,__bss`; the C3 runtime's constructor walk binds
to that instead of the real header and reads garbage. **Link the dylib**, which
`build.zig` does by default. This is a C3 runtime issue, not a Zig-binding one —
any future Go binding will hit the same wall on macOS.

**This is macOS-only.** On Linux the same static archive links and runs
correctly from both Zig and `rustc`; ELF `.init_array` has no equivalent
failure. See [Linux](#linux) for the measurements.

**Footgun:** `Value` holds a raw `*Runtime` while `Runtime.init` returns by
value, so copying or moving a `Runtime` after creating `Value`s dangles. It is
documented, not enforced.

### Rust — `bindings/rust/`

```sh
make lib
cargo run --manifest-path bindings/rust/jse/Cargo.toml --example hello_js
```

```
jse 0.1.0
sum        = 10
greeting   = hello world 😀
its type   = String
wrong type = wrong type: value is not a string
counter    = 10
syntax     = syntax error: SyntaxError
throw      = uncaught exception: nope
recovered  = TypeError
before job = pending
after job  = done
Null Undefined Boolean Number String Object Function
second rt  = a runtime is already open in this process
ok
```

A workspace of two crates: `jse-sys` (raw `extern "C"`, one decl per header
symbol) and `jse` (safe wrapper). The safe layer converts several of the ABI's
disciplinary rules into compile errors: `Value` borrows `Runtime` by lifetime so
a value cannot outlive its engine, and `Runtime` is neither `Send` nor `Sync`, so
the documented thread-unsafety is enforced by the type system.

`build.rs` locates the checkout by walking up for `include/jse.h`; `JSE_LIB_DIR`
overrides for an installed copy. A missing archive panics with the exact
`make lib` command rather than a bare linker error.

**Note:** `tests/basic.rs` is deliberately a *single* test function, because
`cargo test` parallelises across threads in one process and the ABI is
one-runtime-per-process. Correct, but it means coarse failure reporting.

The `wrong type = ...: value is not a string` line is only informative with that
branch's `capi.c3` fix; on `main` it would be empty.

### C3 — `bindings/c3/`

The native binding. It links the engine's C3 modules directly and does **not**
go through the C ABI, so none of the ABI defects above apply to it.

```sh
c3c build jse_example_c3
./out/jse_example_c3
```

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

Failures surface as C3 faults (`SYNTAX_ERROR`, `JS_EXCEPTION`, `WRONG_TYPE`,
`STALE_VALUE`, `VALUE_TABLE_FULL`) rather than status codes. Use this rather than
the C ABI when the host is itself C3 — it avoids a marshalling round-trip. Use
the C ABI when the host is anything else, or when you want a stable binary
boundary.

**Pre-existing engine bug this binding exposes (not fixed, not the binding's
fault).** An arrow function inside eval-mode code containing a `for (let ...)`
loop mis-resolves its enclosing `let` bindings, which read back as `undefined`:

```js
eval("(()=>{ let s=0; for(let j=0;j<3;j++) s+=j; return s; })()")   // NaN, want 3
```

It reproduces through the engine's own `eval()` builtin with no binding
involved, so it is upstream in the compiler's eval-mode scope resolution. Both
`jse.eval` and `jse_eval` compile in eval mode (deliberately, for completion
values), so **C-ABI embedders hit this too**. Rewriting the arrow as
`function(){...}` works. The verifier checked the other suggested workaround and
found it **wrong**: `for (var ...)` inside an arrow still returns 0, not 3.

### Ruby — `bindings/ruby/`

```sh
make shared
make example-ruby        # or: ruby bindings/ruby/examples/example.rb
```

```
engine version: 0.1.0
sum of 1..5: 15
Math.hypot(3, 4): 5.0
greeting: hello from 😂
3 > 2: true, null: nil
slugify: hello-embedded-world
opaque: #<JS::Opaque object>
as JSON: {"a":1,"b":[2,3]}
caught: TypeError: Cannot read properties of null (reading 'property')
  js_class was "TypeError" -- branch on that, not the text
caught syntax error: expected '<identifier>', got '('
caught JS::Error (status -3): RangeError: out of range
recovered: SyntaxError
runtime closed
```

Pure stdlib `fiddle` — no native gem build, no `ffi` dependency. Written for
Ruby 2.6.10 (macOS system Ruby): no endless methods, no rightward assignment.
Library lookup is `$JSE_LIBRARY`, then `out/libjse.{dylib,so}` relative to the
repo root, then the bare soname.

> **Known defect, found by the verifier and not yet fixed.**
> In `bindings/ruby/lib/js.rb`, the `js_class` regex is
> `/\A([A-Z]\w*Error)(?::|\z)/`. Because `\w*` sits between a required `[A-Z]`
> and a literal `Error`, the **base class `Error` can never match**:
> `throw new Error("boom")` gives the message `"Error: boom"` but
> `js_class == nil`. All five subclasses (`TypeError`, `RangeError`, `EvalError`,
> `URIError`, `ReferenceError`) resolve correctly, so the damage is confined to
> the base class — but the README wrongly documents `js_class` as `nil` only for
> non-`Error` throws like `throw 42`. Suggested fix: `/\A([A-Z]\w*)(?::|\z)/`.

The `TypeError: ...` prefixes above depend on that branch's `capi.c3` fixes; on
`main` the same throws report the bare message.

Also unchanged: `throw {code:7}`, with neither `name` nor `message`, still
reports `uncaught exception (object)`. That is the honest floor without
re-entering the VM to stringify.

### Python — `bindings/python/`

```sh
make shared
python3 bindings/python/example.py
```

```
engine version: 0.1.0
sum of squares: 30.0
greeting: hello 😀
counter: 5.0
caught throw: [uncaught exception] Cannot read properties of null (reading 'oops')
caught syntax: [syntax error] expected '<identifier>', got '('
still alive: yes
runtime closed
```

Pure `ctypes`, stdlib only, no C extension. Verified on CPython 3.12. Library
discovery is `JSE_LIBRARY` then a path derived from `__file__`; a missing
library raises a clean `JsError(-5)`.

Type mapping: number → `float`, string → `str`, bool → `bool`, `null`/`undefined`
→ `None`, object → `<js object>`, function → `<js function>`, symbol/bigint →
`<js other>`.

This branch carries the `Symbol` fix. **On `main`, `Symbol()` raises
`UnicodeDecodeError: invalid start byte 0xff`** — reproduced while writing this
document. `jse_type_of` reports a `Symbol` as `JSE_TYPE_STRING` because a symbol
is a STRING-tagged `HString` with `is_symbol` set, and `jse_get_string` then
copies raw internal bytes.

On `main` today the smaller pre-existing wrapper `examples/python/jse.py` works
and prints `version: 0.1.0 / 40 + 2 = 42.0 / string: 'hi 😀' / array: 1,4,9 /
caught: -3 boom` (verified). `examples/ruby/jse.rb` is its Ruby counterpart.

## Known limitations of v1

**Host functions are supported** as of the `jse_register_fn` / `jse_call` work;
see [Host functions](#host-functions) above. Earlier revisions of this document
said native registration was impossible without engine changes. That was true of
the engine as it stood: dispatch went through `builtin_dispatch_table[ordinal]`,
a compile-time array, with no runtime table to append to. The engine changed. A
host function is now an ordinary function object whose dispatch index sits in a
reserved range above every compile-time ordinal, so it reaches
`dispatch_builtin`'s previously-dead out-of-range branch and routes to a
per-heap host table. Every call shape works unchanged — plain calls, methods,
`.call`/`.apply`/`.bind`, accessors, `new`, `super()`, and built-in callbacks
such as an `Array.prototype.sort` comparator.

**Registration binds globals only.** `jse_register_fn` creates a binding on the
global environment. There is no API to install a host function as a property of
an existing object from C; do it in JS (`ns.fn = hostFn`) after registering.

**Registration is permanent.** A host function lives for the runtime's
lifetime; there is no unregister. Slots are never reused, so an index captured
in a function object can never come to mean a different function.

**No property access from the host.** There is no `jse_get_prop`. Objects are
opaque handles; read them from a JS callback and return a primitive, or
serialise with `JSON.stringify`.

**`jse_call` is callback-only.** It takes a `jse_call_ctx`, so it works from
inside a host function but not from `main`. Use `jse_eval` at the top level.

**Host recursion is bounded.** A host → JS → host chain never pushes a VM
activation, so neither `MAX_CALLS` nor `MAX_RUN_DEPTH` counts it. `dispatch_host`
caps nesting and throws a `RangeError` rather than faulting the native stack.
The cap is set per build profile because the limit is native stack: an
unoptimised sanitizer build overflows an 8 MB stack around 16 levels, while an
optimised build is far cheaper.

**No coercion in the readers.** `jse_get_string` on a number returns
`JSE_ERR_TYPE`. Call `String(x)` in JS first.

**One runtime per process, not thread-safe, unenforced across threads.** See
[Lifetime and GC rules](#lifetime-and-gc-rules).

**524287 live handles.** The registry grows on demand up to that ceiling and is
not configurable at runtime.

**No modules, timers, or I/O.** The engine deliberately ships no host runtime
surface — see `engine-scope.md`. Supply your own from the host.

### Untested paths

Stated so nobody mistakes silence for coverage:

- **Linux x86-64.** Linux is verified, but only on **arm64** — see the Linux
  section above. The x86-64 path was not exercised: `container`'s amd64
  emulation breaks `c3c`'s `posix_spawn` of the C compiler, so no build could be
  produced there. Nothing found on arm64 was architecture-specific (the
  `re_exec` collision and the `__muloti4` gap are both ELF/glibc properties, not
  instruction-set ones), so x86-64 is expected to behave the same, but that is
  an inference and not a measurement.
- **musl / non-glibc Linux.** Only glibc was tested. The `re_exec` collision is
  a glibc symbol; musl may differ in either direction.
- **Cross-compilation.** Not attempted for any binding.
- **`describe_error` against exotic throws.** Throwing a bare object or a Proxy
  with a throwing getter returns `-3` cleanly rather than crashing, but the
  message formatting for those shapes is not covered by the expected outputs.
- **Windows.** The header has a `JSE_DLL`/`__declspec(dllimport)` hook but no
  Windows build was attempted.
- **A throwing user `toString`** against the C3 binding's `to_display_string`.

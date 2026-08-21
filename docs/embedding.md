# Embedding

How to package this engine as a library and drive it from a host program.

The engine is a strict-only ES5/ES6 interpreter meant to be embedded (see
`engine-scope.md`). This document covers the `bk_` C ABI, which is the only
supported boundary for non-C3 hosts, and the language bindings built on top of
it.

Everything stated here about the ABI was verified by building and running the
code. Read [Status of the bindings](#status-of-the-bindings) before relying on
any of the per-language sections.

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
| `out/boomkat.a` | `make lib` | ~2.5 MB | Static archive. Installed as `boomkat.a`. |
| `out/boomkat.dylib` / `.so` | `make shared` | ~2.0 MB | Shared library. `make shared` is a synonym. |
| `include/boomkat.h` | (source) | n/a | Hand-written C99 public header. |

Both libraries are self-contained: the vendored C sources (`libregexp`,
`cutils`, `dtoa`) are already inside them. Compiling those separately into
your program produces duplicate symbols.

The shared library exports the 12 documented `bk_` entry points:

```
bk_close  bk_drain_microtasks  bk_eval    bk_get_bool  bk_get_number
bk_get_string  bk_last_error  bk_last_error_code  bk_open  bk_type_of
bk_value_free  bk_version
```

They are not the only exported symbols. `c3c` has no visibility control and
emits no version script, so the entire module graph is exported alongside them:
2460 symbols on the macOS dylib, 2272 on the Linux `.so` (measured). Treat the
12 above as the supported surface and everything else as private, but be aware
that on ELF the extra exports participate in global symbol interposition. That
is not hypothetical. A wrapper function named `re_exec` collided with glibc's
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
$PREFIX/include/boomkat.h
$PREFIX/lib/boomkat.a
$PREFIX/lib/boomkat.dylib      # .so on Linux
```

The dylib keeps its `@rpath/boomkat.dylib` install name rather than being
restamped with an absolute path. This is deliberate: `install_name_tool` cannot
grow a load command past the padding `c3c` emitted, so restamping fails outright
whenever `PREFIX` is longer than that padding. Consumers therefore pass
`-Wl,-rpath,$PREFIX/lib`; `ctypes`/`fiddle`-style loaders open the path directly
and are unaffected.

### Linking

```sh
# static
cc -std=c99 -I$PREFIX/include app.c $PREFIX/lib/boomkat.a -o app

# shared
cc -std=c99 -I$PREFIX/include app.c -L$PREFIX/lib -lboomkat \
   -Wl,-rpath,$PREFIX/lib -o app
```

On Linux add `-lm -ldl`. On macOS nothing extra is needed. The Makefile applies
this automatically via `BK_LDLIBS`.

**On Linux the static archive also needs LLVM's compiler-rt.** The BigInt path
multiplies `int128` values, which LLVM lowers to the overflow-checked builtin
`__muloti4`. Apple's libSystem carries it; GNU `libgcc` and `libgcc_s` do not,
and it exists only in compiler-rt (verified: `nm` finds it in neither libgcc). A
GCC-driven static link therefore fails with:

```
/usr/bin/ld: boomkat.a(boomkat.esm.o): in function `boomkat.hbigint.bigint_mul':
boomkat::esm:(.text+0xee228): undefined reference to `__muloti4'
```

Pass the archive explicitly (Debian: `apt install libclang-rt-19-dev`):

```sh
cc -std=c99 -I$PREFIX/include app.c $PREFIX/lib/boomkat.a -lm -ldl \
   /usr/lib/llvm-19/lib/clang/19/lib/linux/libclang_rt.builtins-$(uname -m).a -o app
```

The root Makefile and `examples/justfile` locate it automatically and append it
to `BK_LDLIBS`; override `C3C_RT_LIB` / `BK_RT_LIB` to point elsewhere. The
shared library is unaffected, because it resolved the symbol at its own link.
The same flag is needed when `c3c` links the engine itself, which the Makefile
passes via `c3c build <target> -z <archive>`.

### Build configuration

The `boomkat_dylib` and `boomkat_static` targets in `project.json` are built at `-O2`,
`single-module`, relaxed FP math, no panic messages, no debug info, with the
`THREADED_DISPATCH` feature. Two of those settings are not obvious.
`"single-module": true` is mandatory; without it the dylib link fails with
undefined symbols such as `_unicode_is_cased`. `--no-headers` is also required,
because the `c3c`-generated header leaks C3 internals (`c3slice_t`,
`std_core__usz`) and is not a usable public interface. That is why
`include/boomkat.h` is hand-written.

Toolchain used for the macOS results in this document: `c3c` 0.8.2
(LLVM 22.1.8), Apple clang 21, macOS 27 arm64.

### Linux

Linux is verified on linux/arm64 (Debian trixie, `c3c` 0.8.2 built from source
against LLVM 19.1.7, GCC 14.2). Run it with `make linux-ci`; see
[`ci/linux/README.md`](../ci/linux/README.md).

Running it established the following:

| Area | Result |
|---|---|
| `c3c build boomkat` | Builds, once `__muloti4` is supplied (see above) |
| `bash test/run_local.sh` | Fully green, identical counts to macOS: 302 scripts, 14 module fixtures, 101 + 63 syntax/export checks, 24 top-level, 12 uncaught, 5796 console lines |
| `make lib` / `make shared` | Both build; `out/boomkat.so` is produced |
| `make smoke` | Prints `42` |
| `ldd` | No unresolved deps on `boomkat.so` or on an executable linked against it |
| `nm -D` | All 12 `bk_` symbols exported |
| `make install PREFIX=…` | Header and both libraries install; static and `-lboomkat` shared builds compile and run against the prefix |
| rpath | `-Wl,-rpath,$PREFIX/lib` is load-bearing: without it the loader fails and `LD_LIBRARY_PATH` is required |

Verifying Linux turned up two platform-specific defects, both since fixed:

- `re_exec` collided with glibc. The vendored regexp wrapper exported a function
  named `re_exec`; glibc exports a legacy BSD `re_exec` too. Because the shared
  library exports every engine symbol, ELF interposition bound the engine's own
  call sites to *libc's* unrelated function and every JS regexp segfaulted
  inside `regexec`. Confirmed by backtrace and by the crash vanishing under
  `LD_PRELOAD=out/boomkat.so`. It is now named `re_run`. macOS's two-level
  namespace hid this completely.
- `__muloti4` is not in libgcc, so every link of the engine and of the static
  archive failed. See the linking section above.

The `.so` suffix selection in every loader (`bindings/python/js.py`,
`bindings/ruby/lib/js.rb`, `bindings/zig/build.zig`, `bindings/rust`'s
`build.rs`, `examples/justfile`) was already correct and needed no change.

#### The static-link init hazard does not reproduce on Linux

The Zig section below documents that on macOS, linking `out/boomkat.a` into a
Zig-built executable segfaults in `__c3_runtime_startup` before `main`, because
Zig emits a second bogus `__mh_execute_header` and the C3 runtime's constructor
walk binds to it. ELF `.init_array` does not have the same problem, tested
directly by building the same program from both foreign linkers against the
static archive:

```
Zig  0.16.0 : rc=0, printed "zig static: 42"
rustc 1.97.1: rc=0, printed "rust static: 42"
```

For contrast, the macOS failure was re-confirmed on the same host with the same
Zig 0.16.0 and the same source: `RUN_RC=139` (SIGSEGV) with zero output. The
hazard is therefore specific to Mach-O image-header discovery, and static
linking from Zig and Rust is supported on Linux. Two caveats, both mechanical:

- `rustc` passes `-nodefaultlibs`, so the C3 runtime's `atexit` hook is
  unresolved unless you add `-C link-arg=-lc`.
- Both need the compiler-rt archive for `__muloti4`.

#### Binding status on Linux

All seven binding surfaces were run in-container and produce correct output.

| Binding | Linux | Notes |
|---|---|---|
| C99 static | pass | needs compiler-rt; `examples/justfile` adds it |
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
#include <boomkat.h>

int main(void) {
    bk_runtime rt;
    if (bk_open(&rt) != BK_OK) {
        fprintf(stderr, "cannot start the engine\n");
        return 1;
    }

    static const char SRC[] =
        "const who = 'world';"
        "`hello, ${who} — ` + [1,2,3].map(n => n * n).join(',')";

    bk_value v;
    int rc = bk_eval(rt, SRC, strlen(SRC), &v);
    if (rc != BK_OK) {
        fprintf(stderr, "eval failed (%d): %s\n", rc, bk_last_error(rt));
        bk_close(rt);
        return 1;
    }

    /* Two-call protocol: measure, then fill a caller-owned buffer. */
    size_t len;
    if (bk_get_string(rt, v, NULL, 0, &len) == BK_OK) {
        char *buf = malloc(len + 1);
        if (buf && bk_get_string(rt, v, buf, len + 1, &len) == BK_OK) {
            printf("%s\n", buf);
        }
        free(buf);
    }

    bk_value_free(rt, v);
    bk_close(rt);
    return 0;
}
```

```
$ cc -std=c99 -Wall -Wextra -pedantic -I$PREFIX/include hello.c \
     $PREFIX/lib/boomkat.a -o hello
$ ./hello
hello, world — 1,4,9
```

The shared-link build produces identical output, including when run from an
unrelated working directory.

## ABI reference

All declarations live in `include/boomkat.h`. The implementation is `src/capi.c3`.

### Types

| Type | Definition | Meaning |
|---|---|---|
| `bk_runtime` | `void *` | Opaque runtime. Never dereference. |
| `bk_value` | `unsigned int` | **Handle, not a pointer.** Index into a GC-rooted slot registry. `0` (`BK_INVALID_VALUE`) is never valid. |

`bk_value` is an integer by design. The engine's internal `TVal` is 8 or 16
bytes depending on a compile-time feature and all its accessors are C3 macros
with no linkable symbol, so it can never cross the boundary.

### Status codes

| Code | Value | Meaning |
|---|---|---|
| `BK_OK` | 0 | Success. |
| `BK_ERR_NOMEM` | -1 | Allocation failed. |
| `BK_ERR_SYNTAX` | -2 | Compile failed. |
| `BK_ERR_THROW` | -3 | Uncaught JS exception. |
| `BK_ERR_INTERNAL` | -4 | Engine fault with no JS error attached. |
| `BK_ERR_INVALID` | -5 | Null/bad argument, or bad handle. |
| `BK_ERR_TYPE` | -6 | Value is not of the requested type. |
| `BK_ERR_FULL` | -7 | Buffer too small, or slot table exhausted. |

`BK_ERR_FULL` is overloaded. Disambiguate by which call returned it:
`bk_get_string` means the buffer was too small, `bk_eval` means the value
registry is full.

### Value types

`BK_TYPE_UNDEFINED` 0, `NULL` 1, `BOOLEAN` 2, `NUMBER` 3, `STRING` 4,
`OBJECT` 5, `FUNCTION` 6, `OTHER` 7 (symbol, bigint).

### Functions

| Function | Returns | Contract |
|---|---|---|
| `bk_open(bk_runtime *out)` | status | Opens an independent runtime. Several may be open at once; they share no globals, objects or interned strings (verified). |
| `bk_close(bk_runtime)` | void | Destroys the runtime and everything it owns; all handles become invalid. Safe with `NULL`. |
| `bk_version(void)` | `const char *` | Static string, currently `"0.1.0"`. Never `NULL`. |
| `bk_eval(rt, src, len, out_val)` | status | Compiles and runs `len` bytes of UTF-8 for its completion value, so `"40 + 2"` yields 42. On `BK_OK` `*out_val` is an owned handle; pass `NULL` for `out_val` to run for side effects only. Drains microtasks before returning. |
| `bk_value_free(rt, v)` | void | Releases a handle. Safe with `0` or an already-freed handle. |
| `bk_type_of(rt, v)` | `bk_type` | **Cannot fail.** An invalid or freed handle reports `BK_TYPE_UNDEFINED`. |
| `bk_get_number(rt, v, double *out)` | status | Strict, no coercion. Handles both the double and 47-bit fastint representations. |
| `bk_get_bool(rt, v, int *out)` | status | Strict. `*out` is 0 or 1. |
| `bk_get_string(rt, v, buf, cap, out_len)` | status | Strict. Two-call protocol, see below. |
| `bk_last_error(rt)` | `const char *` | Message for the most recent failure. Never `NULL`; empty when none. Owned by the runtime, so copy it. Formatted without re-entering the VM. |
| `bk_last_error_code(rt)` | status | Code matching `bk_last_error`. |
| `bk_drain_microtasks(rt)` | void | Runs pending promise jobs. Re-entrancy guarded. `bk_eval` already drains. |

`bk_eval` uses `compile_eval`, not `compile`. Plain `compile` returns a value
only on an explicit `RET`, so a top-level expression would yield `undefined`,
which is not what an embedder expects.

### The string protocol

The ABI never hands out memory the caller must free, which removes a whole class
of FFI leak. There is deliberately no `bk_free_string`.

```c
size_t len;
bk_get_string(rt, v, NULL, 0, &len);   /* measure: len excludes the NUL */
char *buf = malloc(len + 1);
bk_get_string(rt, v, buf, len + 1, &len);  /* fill */
```

If `cap` is too small the call returns `BK_ERR_FULL` and writes the required
length to `*out_len`, so a failed fill tells you how big to retry (verified:
a 3-byte buffer for a 7-byte string returns `-7` with `*out_len == 7`).

Strings are converted from the engine's internal CESU-8 to standard UTF-8, so
astral characters emerge as proper 4-byte sequences rather than surrogate
halves. Verified: `'hi \u{1F600}'` measures 7 bytes and round-trips as `hi 😀`.

### Error handling

Nothing aborts, panics, or `longjmp`s across this boundary. Every call returns a
status or a handle.

```c
if (bk_eval(rt, src, len, &v) != BK_OK) {
    fprintf(stderr, "%s\n", bk_last_error(rt));   /* copy if you keep it */
}
```

`bk_last_error` is valid only until the next `bk_*` call. The engine's compile
error buffer is process-global and is clobbered by the next failing compile, so
the shim copies the message immediately.

Every failing reader records the reason: `bk_get_number`, `bk_get_bool`, and
`bk_get_string` return `BK_ERR_TYPE`, `BK_ERR_INVALID`, or `BK_ERR_FULL`
and leave a message that `bk_last_error` returns. Branch on the status code,
never on the message text, after a reader call.

One syntax-error input, `"var = = ="`, leaves the global compile buffer empty,
which is an engine gap. The shim substitutes `"SyntaxError"` so the ABI never
returns an empty message for a syntax failure.

## Host functions

A host function is a C callback that JS invokes by name. It is how JS reaches
the host's I/O, timers, logging, and application logic.

```c
static void greet(bk_call_ctx ctx, void *udata) {
    char buf[128];
    size_t n = 0;
    if (bk_get_string(NULL, bk_arg(ctx, 0), buf, sizeof buf, &n) != BK_OK) {
        bk_throw_error(ctx, BK_ERROR_TYPE, "greet() wants a string");
        return;
    }
    printf("host sees: %s\n", buf);
    bk_return_number(ctx, (double)n);
}

bk_register_fn(rt, "greet", 5, greet, NULL, /*arity*/1, /*constructable*/0);
bk_eval(rt, "greet('world')", 14, NULL);
```

The callback receives an opaque `bk_call_ctx` and the `udata` pointer given at
registration, passed through untouched. Read arguments with `bk_argc` and
`bk_arg`; an index past the end yields a handle to `undefined` rather than an
error, matching JS. `bk_this`, `bk_new_target`, and `bk_is_construct` cover
method and constructor calls.

To return a value, `bk_return` takes a handle, while `bk_return_number`,
`_bool`, `_null`, and `_string` are the direct forms. A callback that returns
nothing yields `undefined`.

Throwing never unwinds. `bk_throw_error(ctx, kind, msg)` and
`bk_throw(ctx, handle)` *record* a throw and return normally, and the callback
must then return normally too. There is no `longjmp` across the boundary, which
is what lets every dispatch site in the engine remain unchanged. A recorded
throw beats any return value set in the same callback.

For constructors, pass `constructable` non-zero to allow `new`. The engine
creates the instance and `bk_this` sees it; return nothing to keep that object,
or return an object to replace it (ES2015 §9.2.2). A zero value makes `new fn()`
throw a `TypeError`, matching ES2015 §10.3 where built-ins construct only when
specified. Constructable host functions get an own `.prototype` with a
`.constructor` back-reference, so `class D extends HostCtor` works.

Handle lifetime is the one rule to internalise. Handles from `bk_arg`,
`bk_this`, and `bk_new_target` are *scope handles*: valid only until the
callback returns. To keep one, promote it with `bk_value_persist`, which
returns a runtime-owned handle the caller must `bk_value_free`. Scope handles
passed to `bk_value_free` are ignored rather than treated as an error. The
readers accept both handle kinds and tolerate a `NULL` runtime inside a
callback, so `bk_get_number(NULL, bk_arg(ctx, 0), &d)` is valid.

`bk_call(ctx, func, argv, argc, this_val, out_val)` invokes a JS function from
inside a callback. On `BK_OK`, `*out_val` is a runtime-owned handle you must
free. If the callee throws, the exception is recorded on your context and
`BK_ERR_THROW` is returned; return promptly and let the engine propagate it.

Arguments are copied, not referenced. The engine stages each call's `this`,
`new.target`, and arguments into a GC-rooted per-call scope rather than pointing
into VM registers. This matters because `bk_call` can grow and reallocate the
value stack; a register pointer would dangle, and a host holding an opaque
handle has no way to refresh it.

## Lifetime and GC rules

Handles are owned. A handle from `bk_eval` stays valid until you call
`bk_value_free` or `bk_close`. It survives garbage collection, because the
slot registry is a GC root and held values are transitively reachable by the
mark phase. Verified: a held string survived 200,000 object allocations, and the
design passes under `GC_STRESS` + AddressSanitizer with no use-after-free and no
invalid reads.

Handles leak if you never free them. The registry grows on demand and reuses
freed slots, so there is no small fixed cap. Its ceiling is 65535 simultaneously
live handles, and exceeding it returns `BK_ERR_FULL` (verified: the first
failure lands at exactly 65535 and is reported cleanly, never as a zero handle
paired with success). Free eagerly in loops.

A freed handle is retired rather than blindly recycled. Each slot carries a
generation that advances on free, so reading a stale handle fails instead of
resolving to whatever value later lands in that slot. A generation counter is
finite, so a slot that exhausts its supply of distinct handles is withdrawn from
reuse for the life of the runtime instead of wrapping: were it to wrap, a stale
handle would become bit-identical to a live one and resolve silently. Verified
across 400000 alloc/free cycles holding a stale handle throughout.

Never dereference a `bk_value`. It is an index, not an address.

Do not cache `const char *` returns. `bk_last_error` and `bk_version` point to
runtime-owned storage. Copy before the next call.

Several runtimes may be open at once, each with its own globals, objects and
interned strings. Nothing is shared between them, so one is unaffected by
another allocating, collecting, or closing.

Values do not cross. A `bk_value` is an index into one runtime's registry, so
passing a handle to a different runtime's reader returns `BK_ERR_INVALID`
rather than resolving against an unrelated value. To move a value, read it out
and write it back in: the copy is a distinct object in the receiving runtime.

A runtime must be driven from one thread at a time. The engine has no locking,
so two threads inside one runtime corrupt it, and nothing enforces that. Two
threads each driving their own runtime share nothing and are safe.

The handle design was chosen because both obvious alternatives are broken, which
is worth knowing before anyone proposes them again:
- The valstack cannot host host-owned slots. `Vm.execute` unconditionally resets
  `valstack_top` and reinitialises registers on every eval, and
  `ensure_valstack_grow` reallocs and relocates the buffer. Any slot there is
  clobbered or moved.
- `gc_roots` cannot back a handle table. It is capped at 64, silently drops past
  that, and has no unregister function, so roots are permanent.

The registry sidesteps both: one ordinary object, registered once as a GC root
(costing 1 of the 64), holding host values as normal properties under interned
integer keys. Refcounting then comes free from the existing `put_prop`/
`delete_prop` paths.

## Status of the bindings

The five language bindings in `bindings/` are all on `main`, each with its own
README and example. They were written and verified against the C ABI, and
driving the ABI from those languages surfaced four defects in `src/capi.c3`,
all now fixed on `main`:

| Defect | Observed before the fix | Now |
|---|---|---|
| Readers set no error message; `bk_last_error` returned stale text | `str<-number = rc=-6 err=[]` after priming a sentinel | every failing reader leaves a message |
| `Symbol` misreported as `BK_TYPE_STRING`; `bk_get_string` emitted invalid UTF-8 | `Symbol type = 4`, bytes `ff 01 78` | symbols report `BK_TYPE_OTHER` |
| Thrown primitives lost their value | `throw 42` → `[uncaught exception]` | `throw 42` reports `42` |
| An `Error`'s `name` was never found (own-property lookup only) | `throw new TypeError('tt')` → `[tt]`, not `TypeError: tt` | `name` resolves through the prototype |

Each language section below carries its own build commands, expected output,
and any remaining limitations.

## Per-language guides

### C: `bindings/c/`

```sh
make lib shared
make install PREFIX=$PREFIX
just example-c-static    # static-link binary
just example-c-shared    # shared-link binary (boomkat.dylib/.so via rpath)
just example-c-multiple  # host_fn + two_runtimes, both static
just example-ruby        # Ruby fiddle example
just example-clean       # remove the built binaries
```

Point at the engine's own `out/` tree when an install tree is not present:

```sh
just example-c-static BK_INCDIR=$PWD/include BK_LIBDIR=$PWD/out \
                      BK_STATIC_LIB=$PWD/out/boomkat.a
```

```
boomkat version 0.1.0

sum of 1..5      = 15
greeting         = boomkat from C99 — astral: 😀
Math is object   = true (handle type: boolean)
object as string = [object Object]

errors are values, not crashes:
  throw        THROW    index out of range
  bad syntax   SYNTAX   expected '<identifier>', got '('
  wrong type   TYPE     value is not a string

after errors     = still running
```

Static and shared builds produce byte-identical output; `otool -L` confirms the
shared build genuinely links `@rpath/boomkat.dylib` rather than silently
resolving to the archive. Clean under ASan.

**Caveat:** `bku_eval_to_string()` in `bk_util.c` stringifies by concatenating
caller source into `String((...))`. That is JS source injection if the input is
ever untrusted. Safe for the literals in the example; do not copy it into a path
where the JS comes from elsewhere.

### Zig: `bindings/zig/`

```sh
make shared                  # from the repo root
cd bindings/zig && zig build run
```

```
boomkat 0.1.0
sum 1..100 = 5050
squares (string) = 1,4,9,16
Throw: Unexpected token in JSON
Syntax: expected '<identifier>', got '('
```

**Requires Zig 0.16.0 exactly.** The build script uses `b.createModule` +
`.root_module` and the example uses the 0.16 `main(init: std.process.Init)`
signature with `std.Io.File.Writer`. It will not compile on 0.15 or earlier,
which excludes most currently-deployed Zig versions.

The static archive is unusable from Zig on macOS. Linking `out/boomkat.a`
into a Zig-built executable segfaults in `__c3_runtime_startup` *before* `main`
(reproduced: `SIGSEGV`, zero output). Zig's linker emits a second, bogus
`__mh_execute_header` in `__DATA,__bss`; the C3 runtime's constructor walk binds
to that instead of the real header and reads garbage. Link the dylib instead,
which `build.zig` does by default. This is a C3 runtime issue rather than a
Zig-binding one, so any future Go binding will hit the same wall on macOS.

The problem is macOS-only. On Linux the same static archive links and runs
correctly from both Zig and `rustc`; ELF `.init_array` has no equivalent
failure. See [Linux](#linux) for the measurements.

One footgun: `Value` holds a raw `*Runtime` while `Runtime.init` returns by
value, so copying or moving a `Runtime` after creating `Value`s dangles. It is
documented, not enforced.

### Rust: `bindings/rust/`

```sh
make lib
cargo run --manifest-path bindings/rust/boomkat/Cargo.toml --example hello_js
```

```
boomkat 0.1.0
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

A workspace of two crates: `boomkat-sys` (raw `extern "C"`, one decl per header
symbol) and `boomkat_dylib` (safe wrapper). The safe layer converts several of the ABI's
disciplinary rules into compile errors: `Value` borrows `Runtime` by lifetime so
a value cannot outlive its engine, and `Runtime` is neither `Send` nor `Sync`, so
the documented thread-unsafety is enforced by the type system.

`build.rs` locates the checkout by walking up for `include/boomkat.h`; `BK_LIB_DIR`
overrides for an installed copy. A missing archive panics with the exact
`make lib` command rather than a bare linker error.

**Note:** `tests/basic.rs` is deliberately a *single* test function, because
`cargo test` parallelises across threads in one process and the ABI is
one-runtime-per-process. Correct, but it means coarse failure reporting.

The `wrong type = ...: value is not a string` line exercises the
reader-failure message path fixed on `main`.

### C3: `bindings/c3/`

The native binding links the engine's C3 modules directly and does not go
through the C ABI, so none of the ABI defects above apply to it.

```sh
c3c build boomkat_example_c3
./out/boomkat_example_c3
```

```
-- values --
40 + 2      = 42
joined      = hi there 😀
squares     = 1,4,9,16 (type OBJECT)

-- errors --
compile     = boomkat::SYNTAX_ERROR: expected '<identifier>', got '('
throw       = boomkat::JS_EXCEPTION: index out of bounds
parsed      = 7
undefined   = boomkat::JS_EXCEPTION: notDefinedAnywhere is not defined
still alive = 400
```

Failures surface as C3 faults (`SYNTAX_ERROR`, `JS_EXCEPTION`, `WRONG_TYPE`,
`STALE_VALUE`, `VALUE_TABLE_FULL`) rather than status codes. Use this rather
than the C ABI when the host is itself C3, since it avoids a marshalling
round-trip. Use the C ABI when the host is anything else, or when you want a
stable binary boundary.

### Ruby: `bindings/ruby/`

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

Pure stdlib `fiddle`, with no native gem build and no `ffi` dependency. Written
for Ruby 2.6.10 (macOS system Ruby): no endless methods, no rightward
assignment. Library lookup is `$BK_LIBRARY`, then `out/boomkat.{dylib,so}`
relative to the repo root, then the bare soname.

`throw {code:7}`, with neither `name` nor `message`, still reports
`uncaught exception (object)`. That is the honest floor without
re-entering the VM to stringify.

### Python: `bindings/python/`

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
discovery is `BK_LIBRARY` then a path derived from `__file__`; a missing
library raises a clean `JsError(-5)`.

Type mapping: number → `float`, string → `str`, bool → `bool`, `null`/`undefined`
→ `None`, object → `<js object>`, function → `<js function>`, symbol/bigint →
`<js other>`.

The `Symbol` fix the Python binding drove is on `main`: `bk_type_of` reports a
`Symbol` as `BK_TYPE_OTHER` instead of `BK_TYPE_STRING` (a symbol is a
STRING-tagged `HString` with `is_symbol` set, and `bk_get_string` would
otherwise copy raw internal bytes). Before the fix, `Symbol()` raised
`UnicodeDecodeError: invalid start byte 0xff`.

## Known limitations of v1

Host functions are supported through `bk_register_fn` and `bk_call`; see
[Host functions](#host-functions) above. A host function is an ordinary function
object whose dispatch index sits in a reserved range above every compile-time
ordinal, so it reaches `dispatch_builtin`'s out-of-range branch and routes to a
per-heap host table. Every call shape works: plain calls, methods,
`.call`/`.apply`/`.bind`, accessors, `new`, `super()`, and built-in callbacks
such as an `Array.prototype.sort` comparator.

Registration binds globals only. `bk_register_fn` creates a binding on the
global environment. There is no API to install a host function as a property of
an existing object from C; do it in JS (`ns.fn = hostFn`) after registering.

Registration is permanent. A host function lives for the runtime's lifetime;
there is no unregister. Slots are never reused, so an index captured in a
function object can never come to mean a different function.

There is no property access from the host, and no `bk_get_prop`. Objects are
opaque handles; read them from a JS callback and return a primitive, or
serialise with `JSON.stringify`.

`bk_call` is callback-only. It takes a `bk_call_ctx`, so it works from inside
a host function but not from `main`. Use `bk_eval` at the top level.

Host recursion is bounded. A host to JS to host chain never pushes a VM
activation, so neither `MAX_CALLS` nor `MAX_RUN_DEPTH` counts it. `dispatch_host`
caps nesting and throws a `RangeError` rather than faulting the native stack.
The cap is set per build profile because the limit is native stack: an
unoptimised sanitizer build overflows an 8 MB stack around 16 levels, while an
optimised build is far cheaper.

The readers do no coercion. `bk_get_string` on a number returns
`BK_ERR_TYPE`. Call `String(x)` in JS first.

A runtime must be driven from one thread at a time, and that is unenforced.
Multiple runtimes in one process are supported; values do not cross between
them. See [Lifetime and GC rules](#lifetime-and-gc-rules).

The registry grows on demand up to 65535 live handles. That ceiling is not
configurable at runtime.

There are no modules, timers, or I/O. The engine deliberately ships no host
runtime surface; see `engine-scope.md`. Supply your own from the host.

### Untested paths

Stated so nobody mistakes silence for coverage:

- Linux x86-64. Linux is verified only on arm64; see the Linux section above.
  The x86-64 path was not exercised, because `container`'s amd64 emulation
  breaks `c3c`'s `posix_spawn` of the C compiler, so no build could be produced
  there. Nothing found on arm64 was architecture-specific (the `re_exec`
  collision and the `__muloti4` gap are both ELF/glibc properties, not
  instruction-set ones), so x86-64 is expected to behave the same, but that is
  an inference and not a measurement.
- musl and other non-glibc Linux. Only glibc was tested. The `re_exec` collision
  is a glibc symbol; musl may differ in either direction.
- Cross-compilation, which was not attempted for any binding.
- `describe_error` against exotic throws. Throwing a bare object or a Proxy with
  a throwing getter returns `-3` cleanly rather than crashing, but the message
  formatting for those shapes is not covered by the expected outputs.
- Windows. The header has a `BK_DLL`/`__declspec(dllimport)` hook but no
  Windows build was attempted.
- A throwing user `toString` against the C3 binding's `to_display_string`.

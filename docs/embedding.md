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
- [Known limitations](#known-limitations)

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

The shared library exports exactly the 50 `bk_` entry points, enforced at link
time by a generated export list (`out/boomkat.exports` on Mach-O,
`out/boomkat.map` on ELF, both produced by `scripts/gen_abi_header.py` from the
header's own declarations):

```
bk_arg  bk_argc  bk_array  bk_array_of  bk_bool  bk_call  bk_close  bk_cstr
bk_delete  bk_drain  bk_error  bk_error_code  bk_error_info_of  bk_eval
bk_eval_named  bk_free  bk_get  bk_get_index  bk_global  bk_has
bk_is_construct  bk_keys  bk_new_target  bk_null  bk_number  bk_object
bk_open  bk_persist  bk_read_bool  bk_read_number  bk_read_string  bk_register
bk_return  bk_set  bk_set_global  bk_set_index  bk_set_interrupt  bk_status_str
bk_strdup  bk_string  bk_this  bk_throw  bk_throw_error  bk_to_bool
bk_to_number  bk_to_string  bk_type_of  bk_type_str  bk_undefined  bk_version
```

Before the export list existed, `c3c`'s lack of visibility control exported the
entire module graph alongside them: 2460 symbols on the macOS dylib, 2272 on
the Linux `.so` (measured). On ELF those extra exports participate in global
symbol interposition, and it was not hypothetical: a wrapper function named
`re_exec` collided with glibc's legacy `re_exec`, and every JS regexp segfaulted
inside libc until it was renamed to `re_run`. The export list removes that whole
class of collision; keep it in mind anyway if you add C helpers that consumers
might also link.

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
output shown. It is also committed verbatim as `test/capi/dozen_lines.c`, built
by `make test-dozen-lines`, which is the acceptance test for the whole surface.

```c
#include <stdio.h>
#include <boomkat.h>

int main(void) {
    bk_ctx js = bk_open();
    bk_value v = bk_eval_str(js, "[1,2,3].map(n => n*n).join(',')");
    if (!v) { fprintf(stderr, "%s\n", bk_error(js)); return 1; }
    printf("%s\n", bk_cstr(js, v, NULL));
    bk_free(js, v);
    bk_close(js);
    return 0;
}
```

```
$ cc -std=c99 -Wall -Wextra -pedantic -I$PREFIX/include hello.c \
     $PREFIX/lib/boomkat.a -o hello
$ ./hello
1,4,9
```

No malloc, no out-params, no two-call dance for the common case: value calls
return handles directly, `bk_cstr` coerces any value to context-owned text, and
`bk_error` reports what went wrong. When you need owned memory or must not
allocate at all, `bk_strdup` and `bk_read_string` cover those cases; see
[the string protocol](#the-string-protocol).

The shared-link build produces identical output, including when run from an
unrelated working directory.

## ABI reference

All declarations live in `include/boomkat.h`. The implementation is `src/capi.c3`.

### Types

| Type | Definition | Meaning |
|---|---|---|
| `bk_ctx` | `struct bk_ctx_s *` | One context type. The runtime at top level; the live call inside a host function. Opaque; never dereference. A callback's context is valid only for that call. |
| `bk_value` | `uint64_t` | **Handle, not a pointer.** Names a slot in the issuing context's GC-rooted registry, tagged with the issuing runtime's id. `0` (`BK_INVALID_VALUE`) is never valid and is the failure return of every value-producing call. |

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
| `BK_ERR_INVALID` | -5 | Null/bad argument, or bad handle (including one from another runtime). |
| `BK_ERR_TYPE` | -6 | Value is not of the requested type. |
| `BK_ERR_FULL` | -7 | Buffer too small. |
| `BK_ERR_INTERRUPT` | -8 | Aborted by the interrupt handler. |

The numeric values are single-sourced in `src/embed/abi.c3`;
`scripts/gen_abi_header.py` regenerates the header's enum blocks from it and
`make check-abi` fails when they drift.

### Value types

`BK_TYPE_UNDEFINED` 0, `NULL` 1, `BOOLEAN` 2, `NUMBER` 3, `STRING` 4,
`OBJECT` 5, `FUNCTION` 6, `OTHER` 7 (symbol, bigint).

### Functions

Value-producing calls return the handle directly and report failure as `0`,
with the detail in `bk_error` / `bk_error_code`. Calls that produce no value
return a `bk_status`.

| Function | Returns | Contract |
|---|---|---|
| `bk_open(void)` | `bk_ctx` | Opens an independent runtime; `NULL` if that failed. Several may be open at once; they share no globals, objects or interned strings (verified). |
| `bk_close(ctx)` | void | Destroys the runtime and everything it owns; all handles become invalid. Safe with `NULL`. Do not call on a callback's context. |
| `bk_version(void)` | `const char *` | Static string. Never `NULL`. |
| `bk_eval(ctx, src, len)` | `bk_value` | Compiles and runs `len` bytes of UTF-8 for its completion value, so `"40 + 2"` yields 42. Owned handle, or 0 on failure. Drains microtasks before returning. |
| `bk_eval_named(ctx, src, len, name, name_len)` | `bk_value` | As `bk_eval`, with `name` recorded as the script name for error reporting. Copied; `NULL` means `"<eval>"`. |
| `bk_drain(ctx)` | status | Runs pending promise jobs. Re-entrancy guarded. `bk_eval` already drains. |
| `bk_free(ctx, v)` | void | Releases an owned handle. Safe with `0`, a scope handle, or an already-freed handle. |
| `bk_persist(ctx, v)` | `bk_value` | Copies a scope value into the registry so it outlives the current callback. Owned result. |
| `bk_error(ctx)` | `const char *` | Message for the most recent failure. Never `NULL`; empty when none. Context-owned, valid until the next `bk_*` call. Formatted without re-entering the VM. |
| `bk_error_code(ctx)` | status | Code matching `bk_error`. |
| `bk_error_info_of(ctx, &info)` | status | Fills line/col/script-name detail for the most recent failure. |
| `bk_status_str(s)` / `bk_type_str(t)` | `const char *` | Static names for logging. Never `NULL`. |
| `bk_type_of(ctx, v)` | `bk_type` | **Cannot fail.** An invalid or freed handle reports `BK_TYPE_UNDEFINED`. |
| `bk_read_number(ctx, v, double *out)` | status | Strict, no coercion. Handles both the double and 47-bit fastint representations. |
| `bk_read_bool(ctx, v, int *out)` | status | Strict. `*out` is 0 or 1. |
| `bk_read_string(ctx, v, buf, cap, out_len)` | status | Strict. Two-call protocol, see below. |
| `bk_to_number(ctx, v)` / `bk_to_bool(ctx, v)` / `bk_to_string(ctx, v)` | value | ES abstract operations. May run user code and throw; on throw they return the zero value with `bk_error_code` set. |
| `bk_cstr(ctx, v, size_t *len)` | `const char *` | Any value as text, the way `String(v)` would render it. Context-owned, valid until the fourth following `bk_cstr` call, so several can be live in one printf. `NULL` only if the conversion threw. |
| `bk_strdup(ctx, v, size_t *len)` | `char *` | As `bk_cstr`, but caller-owned; free with `free()`. |
| `bk_number` / `bk_bool` / `bk_null` / `bk_undefined` / `bk_string` / `bk_object` / `bk_array` / `bk_array_of` / `bk_global` | `bk_value` | Constructors. Owned handles, or 0 on failure. |
| `bk_get(ctx, obj, key, key_len)` / `bk_get_index(ctx, obj, idx)` | `bk_value` | Property read through the prototype chain. Missing property yields undefined. 0 if `obj` is not an object or a getter/trap threw. |
| `bk_set(ctx, obj, key, key_len, val)` / `bk_set_index(...)` | status | Full Set semantics. Value copied in. |
| `bk_has(ctx, obj, key, key_len, int *out)` / `bk_delete(...)` | status | `in` and `delete`. Deleting non-configurable throws, as strict mode requires. |
| `bk_keys(ctx, obj)` | `bk_value` | Own string property names as an array; walk with `bk_get_index`. |
| `bk_call(ctx, fn, this_val, argv, argc)` | `bk_value` | Invokes a JS function. Pass 0 for an undefined receiver, NULL/0 for no arguments. Works at top level and inside a callback. Owned handle, or 0 with the callee's exception recorded. |
| `bk_register(ctx, target, defs)` | status | Installs a whole table of host functions onto `target` (0 = globalThis), see [Host functions](#host-functions). |
| `bk_set_global(ctx, name, name_len, v)` | status | Binds `name` to `v` as a global. Value copied in. |
| `bk_argc(ctx)` / `bk_arg(ctx, i)` / `bk_this(ctx)` / `bk_new_target(ctx)` / `bk_is_construct(ctx)` / `bk_return(ctx, v)` / `bk_throw_error(ctx, kind, msg)` / `bk_throw(ctx, v)` | — | Callback-only accessors; see [Host functions](#host-functions). |
| `bk_set_interrupt(ctx, cb, opaque)` | void | Installs a poll handler that aborts the running script uncatchably as `BK_ERR_INTERRUPT`. |

The header also carries `static inline` sugar (`bk_eval_str`, `bk_getp`,
`bk_return_number`, the `bk_is_*` predicates, ...), which adds no symbols to the
ABI.

`bk_eval` uses `compile_eval`, not `compile`. Plain `compile` returns a value
only on an explicit `RET`, so a top-level expression would yield `undefined`,
which is not what an embedder expects.

### The string protocol

Three tiers, pick by ownership and allocation budget:

```c
/* 1. Coerce anything to text, zero effort. Context-owned, valid until the
      fourth following bk_cstr call, so nesting inside one printf is safe. */
printf("%s\n", bk_cstr(rt, v, NULL));

/* 2. Owned copy the caller frees with free(). */
char *owned = bk_strdup(rt, v, &len);

/* 3. Zero-allocation two-call protocol for embedded hosts: */
bk_read_string(rt, v, NULL, 0, &len);       /* measure: len excludes the NUL */
char *buf = malloc(len + 1);
bk_read_string(rt, v, buf, len + 1, &len);  /* fill */
```

`bk_read_string` returns `BK_ERR_FULL` when `cap` is too small and writes the
required length to `*out_len`, so a failed fill tells you how big to retry
(verified: a 3-byte buffer for a 7-byte string returns `-7` with
`*out_len == 7`). The first two tiers coerce via `ToString` inside the engine,
so there is no source-splicing path for injection to ride on.

Strings are converted from the engine's internal CESU-8 to standard UTF-8, so
astral characters emerge as proper 4-byte sequences rather than surrogate
halves. Verified: `'hi \u{1F600}'` measures 7 bytes and round-trips as `hi 😀`.

### Error handling

Nothing aborts, panics, or `longjmp`s across this boundary. Value-producing
calls return `0` on failure; everything else returns a status.

```c
bk_value v = bk_eval_str(rt, src);
if (!v) {
    fprintf(stderr, "%s\n", bk_error(rt));   /* copy if you keep it */
}
```

`bk_error` is valid only until the next `bk_*` call. The engine's compile error
buffer is process-global and is clobbered by the next failing compile, so the
shim copies the message immediately.

Every failing reader records the reason: `bk_read_number`, `bk_read_bool`, and
`bk_read_string` return `BK_ERR_TYPE`, `BK_ERR_INVALID`, or `BK_ERR_FULL`
and leave a message that `bk_error` returns. Branch on the status code,
never on the message text, after a reader call.

One syntax-error input, `"var = = ="`, leaves the global compile buffer empty,
which is an engine gap. The shim substitutes `"SyntaxError"` so the ABI never
returns an empty message for a syntax failure.

## Host functions

A host function is a C callback that JS invokes by name. It is how JS reaches
the host's I/O, timers, logging, and application logic.

```c
static void greet(bk_ctx ctx, void *udata) {
    char buf[128];
    size_t n = 0;
    if (bk_read_string(ctx, bk_arg(ctx, 0), buf, sizeof buf, &n) != BK_OK) {
        bk_throw_error(ctx, BK_ERROR_TYPE, "greet() wants a string");
        return;
    }
    printf("host sees: %s\n", buf);
    bk_return_number(ctx, (double)n);
}

static const bk_fn_def api[] = {
    { "greet", greet, 1, 0u, NULL },
    BK_FN_END
};
bk_register(rt, 0, api);   /* target 0 == globalThis */
bk_exec(rt, "greet('world')");
```

The callback receives an opaque `bk_ctx` naming the live call and the `udata`
pointer given at registration, passed through untouched. Read arguments with
`bk_argc` and `bk_arg`; an index past the end yields a handle to `undefined`
rather than an error, matching JS. `bk_this`, `bk_new_target`, and
`bk_is_construct` cover method and constructor calls. The callback's context is
an ordinary context: every reader, constructor, property call and `bk_call` in
the header accepts it.

To return a value, `bk_return` takes a handle, while the inline helpers
`bk_return_number`, `_bool`, `_null`, and `_string` are the direct forms. A
callback that returns nothing yields `undefined`.

Throwing never unwinds. `bk_throw_error(ctx, kind, msg)` and
`bk_throw(ctx, handle)` *record* a throw and return normally, and the callback
must then return normally too. There is no `longjmp` across the boundary, which
is what lets every dispatch site in the engine remain unchanged. A recorded
throw beats any return value set in the same callback.

For constructors, set the `BK_CTOR` flag to allow `new`. The engine creates the
instance and `bk_this` sees it; return nothing to keep that object, or return an
object to replace it (ES2015 §9.2.2). Without the flag `new fn()` throws a
`TypeError`, matching ES2015 §10.3 where built-ins construct only when
specified. Constructable host functions get an own `.prototype` with a
`.constructor` back-reference, so `class D extends HostCtor` works.

Handle lifetime is the one rule to internalise. Handles from `bk_arg`,
`bk_this`, and `bk_new_target` are *scope handles*: valid only until the
callback returns. To keep one, promote it with `bk_persist`, which returns an
owned handle the caller must `bk_free`. Scope handles passed to `bk_free` are
ignored rather than treated as an error. The readers accept both handle kinds,
and a callback's context resolves registry handles too, so one host call needs
no other tier.

`bk_call(ctx, func, this_val, argv, argc)` invokes a JS function from inside a
callback (and works at top level too). It returns an owned handle you must
free. If the callee throws, the exception is recorded on your context and `0`
is returned; return promptly and let the engine propagate it.

Arguments are copied, not referenced. The engine stages each call's `this`,
`new.target`, and arguments into a GC-rooted per-call scope rather than pointing
into VM registers. This matters because `bk_call` can grow and reallocate the
value stack; a register pointer would dangle, and a host holding an opaque
handle has no way to refresh it.

## Lifetime and GC rules

Handles are owned. A handle from `bk_eval` stays valid until you call `bk_free`
or `bk_close`. It survives garbage collection, because the slot registry is a
GC root and held values are transitively reachable by the mark phase. Verified:
a held string survived 200,000 object allocations, and the design passes under
`GC_STRESS` + AddressSanitizer with no use-after-free and no invalid reads.

Handles leak if you never free them. The registry grows on demand and reuses
freed slots; with 32 index bits it is bounded by memory rather than by a fixed
count. Free eagerly in loops anyway.

A freed handle is retired rather than blindly recycled. Each slot carries a
generation that advances on free, so reading a stale handle fails instead of
resolving to whatever value later lands in that slot. A generation counter is
finite (15 bits), so a slot that exhausts its supply of distinct handles is
withdrawn from reuse for the life of the runtime instead of wrapping: were it to
wrap, a stale handle would become bit-identical to a live one and resolve
silently.

Every handle also carries the id of the runtime that issued it, in the top 16
bits. Resolving one against another runtime returns `BK_ERR_INVALID` instead of
answering with whatever occupies that slot there -- which, before the tag
existed, was a wrong answer indistinguishable from a correct one. Verified by
`test/capi/two_runtimes.c`, which asserts the refusal for strings, numbers,
persisted handles, and handles whose issuing runtime has since closed.

Never dereference a `bk_value`. It is an index, not an address.

Do not cache `const char *` returns. `bk_error` and `bk_version` point to
context-owned or static storage; `bk_cstr` results stay valid until the fourth
following `bk_cstr` call. Copy before the next call when in doubt.

Several runtimes may be open at once, each with its own globals, objects and
interned strings. Nothing is shared between them, so one is unaffected by
another allocating, collecting, or closing.

Values do not cross runtimes. To move a value, read it out and write it back
in: the copy is a distinct object in the receiving runtime.

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
boomkat version 0.2.0

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

### Zig: `bindings/zig/`

```sh
make shared                  # from the repo root
cd bindings/zig && zig build run
```

```
boomkat 0.2.0
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
boomkat 0.2.0
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
symbol) and `boomkat` (safe wrapper). The safe layer converts several of the ABI's
disciplinary rules into compile errors: `Value` borrows `Runtime` by lifetime so
a value cannot outlive its engine, and `Runtime` is neither `Send` nor `Sync`, so
the documented thread-unsafety is enforced by the type system.

`build.rs` locates the checkout by walking up for `include/boomkat.h`; `BK_LIB_DIR`
overrides for an installed copy. A missing archive panics with the exact
`make lib` command rather than a bare linker error.

**Note:** run `cargo test` with `-- --test-threads=1` if you pin CPU or memory:
the tests open independent runtimes, which is safe in parallel but not free.

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
engine version: 0.2.0
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
engine version: 0.2.0
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

## Known limitations

Host functions are supported through `bk_register` and `bk_call`; see
[Host functions](#host-functions) above. A host function is an ordinary function
object whose dispatch index sits in a reserved range above every compile-time
ordinal, so it reaches `dispatch_builtin`'s out-of-range branch and routes to a
per-heap host table. Every call shape works: plain calls, methods,
`.call`/`.apply`/`.bind`, accessors, `new`, `super()`, and built-in callbacks
such as an `Array.prototype.sort` comparator.

Registration is permanent. A host function lives for the runtime's lifetime;
there is no unregister. Slots are never reused, so an index captured in a
function object can never come to mean a different function. `bk_register`
installs onto any object (pass its handle as `target`), not only globals.

Host recursion is bounded. A host to JS to host chain never pushes a VM
activation, so neither `MAX_CALLS` nor `MAX_RUN_DEPTH` counts it. `dispatch_host`
caps nesting and throws a `RangeError` rather than faulting the native stack.
The cap is set per build profile because the limit is native stack: an
unoptimised sanitizer build overflows an 8 MB stack around 16 levels, while an
optimised build is far cheaper.

The strict readers do no coercion; the coercion tier (`bk_to_number`,
`bk_to_bool`, `bk_to_string`, `bk_cstr`) does, and may throw. Pick per call site:
a type check at a boundary is usually what you want, and `bk_cstr` for display.

A runtime must be driven from one thread at a time, and that is unenforced.
Multiple runtimes in one process are supported; values do not cross between
them. See [Lifetime and GC rules](#lifetime-and-gc-rules).

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

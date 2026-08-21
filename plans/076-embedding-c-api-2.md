# boomkat embedding API v2

## Context

The `bk_` C ABI (`include/boomkat.h`, 483 lines; `src/capi.c3`, 1371 lines) is a
well-built *ABI* — opaque, no owned memory returned, no unwinding, generation-tagged
handles — but it is not a good *embedding API*. Hello-world in C99 is ~30 lines
(docs/embedding.md:202-250), dominated by the two-call string protocol and a malloc.
The useful conveniences live outside the shipped surface in `bindings/c/bk_util.c`,
which every embedder is told to copy. Concretely, four costs land on every embedder:

1. **Handle bookkeeping.** Every result needs a matching `bk_value_free`, with a hard
   65535 ceiling. Handles carry no runtime identity: `bindings/c/two_runtimes.c`
   demonstrates two runtimes issuing bit-identical handles, with one runtime resolving
   the other's handle and returning `BK_OK` *with the wrong value*.
2. **String marshalling.** Two calls plus a malloc in each direction, every time.
3. **No coercion.** Readers are strict, so "print this value" is implemented in
   `bku_eval_to_string` by concatenating the user's source into `String((...))` and
   re-evaluating — JS source injection if the input is ever untrusted.
4. **Dual tiers.** `bk_get_*` vs `bk_ctx_get_*` and `bk_call` vs `bk_call_rt` double the
   surface and make callback code non-portable with top-level code.

Internally the same logic exists twice: `bindings/c3/boomkat.c3` (818 lines) is not
layered on `capi.c3`, it is a parallel reimplementation against the same engine
internals. `SlotEntry` (`boomkat.c3:105` / `capi.c3:87`), slot grow/alloc/release
(`:350-444` / `:245-341`), the error-description walk (`:460` / `:458`), the UTF-8 sink
(`:486-508` / `:605-617`) and `HostReg` + `host_trampoline` (`:549-577` / `:768-783`)
are duplicated and hand-synced, as are the status/type constants between `capi.c3:18-35`
and the header.

**Intended outcome:** embedding boomkat in C or C3 is a dozen lines with no
redeclaration of anything, one implementation of the registry behind two thin faces,
and cross-runtime handle misuse that fails loudly instead of lying.

### Where this lands vs other engines

- **JerryScript** is the closest architectural sibling (refcounted `jerry_value_t`,
  CESU-8 strings). Its hello world is ~8 lines because values are *self-describing* and
  `jerry_string_to_buffer` is one call.
- **QuickJS** passes `JSContext *` to everything — one tier, no runtime/context reader
  split — and returns `JSValue` directly with an exception tag, so there are no
  out-params. v2 adopts both of these.
- **Duktape** is value-stack based (`duk_push_*`/`duk_get_*`), which avoids handle
  lifetime entirely at the cost of a stack discipline. Not adopted: boomkat's registry
  already works and a stack rewrite touches the whole engine.
- Boomkat is currently the only one of the four whose *documented* hello world requires
  a manual malloc.

## Decisions taken

- Break the ABI. v2 is a clean slate; no compatibility shims.
- Single-source the constants for **C and C3 only**. Rust/Zig/Python/Ruby bindings are
  updated mechanically to the new names but keep their hand-written declarations.
- Shared internal C3 core with two thin faces. C3 keeps passing `TVal` directly — no ABI
  round-trip, no perf regression, and non-escaping values skip the registry entirely.
- Full ergonomic tier: coercion in the ABI, runtime-owned C strings, inline sugar.
- Fix both structural warts: one `bk_ctx` type, and runtime-tagged handles.

## Target: the dozen lines

C:

```c
#include <boomkat.h>

int main(void) {
    bk_ctx js = bk_open();
    bk_value v = bk_eval_str(js, "[1,2,3].map(n => n*n).join()");
    if (!v) { fprintf(stderr, "%s\n", bk_error(js)); return 1; }
    printf("%s\n", bk_cstr(js, v, NULL));
    bk_free(js, v);
    bk_close(js);
}
```

C3:

```c3
JsCtx js = boomkat::open()!;
defer js.close();
io::printn(js.eval("[1,2,3].map(n => n*n).join()")!.str(js));
```

## Design

### 1. One context type

`typedef struct bk_ctx_s *bk_ctx;` replaces both `bk_runtime` and `bk_call_ctx`.
`bk_open(void)` returns a `bk_ctx` (NULL on failure); a host callback receives a *call*
context, which is an ordinary `bk_ctx` for every reader, constructor and property
operation. Call-shaped accessors (`bk_argc`, `bk_arg`, `bk_this`, `bk_new_target`,
`bk_is_construct`) return 0/undefined on a non-call context rather than failing.

This deletes `bk_ctx_type_of`, `bk_ctx_get_number`, `bk_ctx_get_bool`,
`bk_ctx_get_string`, `bk_ctx_runtime` and `bk_call_rt` — six of the 52 exports — and
makes callback code and top-level code textually identical.

### 2. Handles carry a runtime tag; widen to 64-bit

`typedef uint64_t bk_value;` laid out `[16 rt id][1 scope][15 gen][32 index]`. Benefits:
resolving a handle against the wrong context returns `BK_ERR_INVALID` instead of an
unrelated value, and the 65535-live-handle ceiling disappears. Cost is 8 bytes per
handle, which is irrelevant at these call rates. The rt id is a monotonic counter
assigned in `bk_open`, wrapping at 16 bits (documented; collision requires 65536 opens
*and* a stale handle surviving across them).

### 3. Errors are values, not out-params

Every value-producing call returns `bk_value` directly, `0` meaning failure:

```c
bk_value bk_eval(bk_ctx, const char *src, size_t len);
bk_value bk_eval_named(bk_ctx, const char *src, size_t len, const char *name);
bk_value bk_call(bk_ctx, bk_value fn, bk_value this_val, const bk_value *argv, unsigned argc);
bk_value bk_new_string(bk_ctx, const char *utf8, size_t len);
bk_value bk_get(bk_ctx, bk_value obj, const char *key);
```

Detail comes from `bk_error_code(ctx)` / `bk_error(ctx)` / `bk_error_info(ctx, &info)`,
which already exist. Non-value calls (`bk_set`, `bk_has`, `bk_delete`) keep returning
`bk_status`. This halves the line count of ordinary host code.

### 4. Strings that do not require a malloc

```c
/* Coerces via ToString. Runtime-owned, valid until the Nth subsequent bk_cstr
   call on this context (ring of 4, so nesting inside one printf is safe).
   NULL only if ToString threw; *len optional. */
const char *bk_cstr(bk_ctx, bk_value v, size_t *len);

/* malloc'd copy the caller frees. */
char *bk_strdup(bk_ctx, bk_value v, size_t *len);

/* Zero-allocation path, the current two-call protocol, kept for embedded hosts. */
bk_status bk_read_string(bk_ctx, bk_value v, char *buf, size_t cap, size_t *out_len);
```

`bk_cstr` is what makes hello-world short and retires `bku_string_dup` and
`bku_eval_to_string` — including its source-injection bug, because coercion happens in
the engine rather than by splicing JS source.

### 5. Coercion tier alongside the strict tier

Strict (predicate + reader, no surprises):
`bk_is_number/_string/_bool/_object/_function/_null/_undefined`, `bk_type(ctx, v)`,
`bk_read_number`, `bk_read_bool`, `bk_read_string`.

Coercing (ES abstract ops, may throw → 0/NaN with `bk_error_code` set):
`bk_to_number`, `bk_to_bool`, `bk_to_string` (returns a `bk_value`), `bk_cstr`.

### 6. Header-only sugar (no new exported symbols)

`static inline` in `boomkat.h`, so it costs nothing at the ABI and cannot drift:

```c
static inline bk_value bk_eval_str(bk_ctx c, const char *s) { return bk_eval(c, s, strlen(s)); }
static inline double   bk_num(bk_ctx c, bk_value v) { double d; return bk_read_number(c, v, &d) ? 0.0/0.0 : d; }
static inline bk_value bk_geti(bk_ctx c, bk_value o, unsigned i);
```

Plus `bk_status_str()` / `bk_type_str()` as real exports, absorbing the rest of
`bk_util.c`. **`bindings/c/bk_util.{c,h}` is deleted** — its whole reason to exist was
that the ABI lacked these.

### 7. Table-driven registration, and registration onto objects

```c
typedef struct { const char *name; bk_host_fn fn; int arity; unsigned flags; void *udata; } bk_fn_def;
#define BK_FN_END {0,0,0,0,0}
#define BK_CTOR 1u  /* constructable */

bk_status bk_register(bk_ctx, bk_value target, const bk_fn_def *defs); /* target 0 == globalThis */
bk_status bk_set_global(bk_ctx, const char *name, bk_value v);
```

One call installs a whole module surface, and `target` lifts today's globals-only
restriction.

### 8. Symbol visibility

The dylib currently exports 2731 symbols for a 52-symbol ABI, and ELF interposition
already caused a real bug (`re_exec` vs glibc, docs/embedding.md). Add an explicit export
list to the `boomkat_dylib` link: `-Wl,-exported_symbols_list,` on Mach-O,
`-Wl,--version-script,` on ELF, both generated from the same ABI manifest as the header
(§9).

### 9. Constants declared once

`src/embed/abi.c3` holds the `BK_*` status/type/error-kind enums as C3 constants — the
single source. `scripts/gen_abi_header.py` regenerates the enum blocks of
`include/boomkat.h`, plus the linker export lists, from it. `make check-abi` diffs the
committed header against a fresh generation and fails on drift; CI runs it. The prose
and function declarations in the header stay hand-written (the generated blocks are
delimited by `/* BEGIN GENERATED */` markers) — the header remains the readable
document it is today.

## Implementation phases

Each phase ends green on `bash test/run_local.sh` + `make smoke`.

**Phase 1 — extract the shared core (pure refactor, no API change).**
New `src/embed/` module holding, once: the slot registry (from `capi.c3:245-341`), the
GC root callback and `mark_slots` (`:194-214`), `describe_error` (`:458`), the UTF-8
`StringSink` (`:605-617`), and `HostReg`/`host_trampoline` (`:768-783`). `capi.c3` and
`bindings/c3/boomkat.c3` both call into it; both keep their current public surfaces.
This is the phase that deletes ~350 duplicated lines and it is independently verifiable.

**Phase 2 — handle widening and runtime tagging.** `bk_value` → `uint64_t` with the rt
id field, inside the extracted core. Bindings updated for the width change. Add a test
asserting cross-runtime resolution now returns `BK_ERR_INVALID` (extend
`bindings/c/two_runtimes.c`, which currently *documents the bug*).

**Phase 3 — the v2 C surface.** Rewrite `include/boomkat.h` and rebuild `src/capi.c3` as
a thin shim over `src/embed/`: unified `bk_ctx`, handle-returning calls, coercion tier,
`bk_cstr` ring, inline sugar, `bk_register` tables, `bk_status_str`/`bk_type_str`.
Delete `bindings/c/bk_util.{c,h}`.

**Phase 4 — the v2 C3 surface.** Rewrite `bindings/c3/boomkat.c3` as a thin idiomatic
layer over `src/embed/` — faults, optionals, `defer`, allocator-parameterised string
reads, `JsArg` still holding `TVal` directly. No registry of its own; non-escaping values
never touch it.

**Phase 5 — single-sourced constants + visibility.** `src/embed/abi.c3`,
`scripts/gen_abi_header.py`, `make check-abi`, and the linker export lists (§8, §9).

**Phase 6 — bindings, examples, docs.** Mechanically update `bindings/{zig,rust,python,
ruby}` to the v2 names and the 64-bit handle; rewrite `bindings/c/main.c`,
`host_fn.c`, `bindings/c3/example/*`; rewrite the hello-world and ABI-reference sections
of `docs/embedding.md` and the six binding READMEs. Fix the two known doc staleness bugs
found during exploration: the Rust README's `out/bk_static.a` (build.rs wants
`boomkat.a`) and the `libboomkat.dylib` vs `boomkat.dylib` inconsistency across READMEs.

## Files

- `src/capi.c3` — becomes a thin shim (target: well under 500 lines).
- `src/embed/` (new) — `abi.c3` (constants), `registry.c3`, `marshal.c3`, `hostfn.c3`.
- `include/boomkat.h` — rewritten; generated enum blocks.
- `bindings/c3/boomkat.c3` — rewritten as a thin layer.
- `bindings/c/bk_util.{c,h}` — deleted.
- `scripts/gen_abi_header.py` (new); `Makefile` (`check-abi`, export lists);
  `project.json` (export-list link flags on `boomkat_dylib`).
- `docs/embedding.md`, `bindings/*/README.md`, `bindings/c/*.c`, `bindings/c3/example/*`.

## Verification

- `bash test/run_local.sh` and `just rosetta` after every phase (the extracted core is on
  the host-callback and GC-mark paths).
- Existing C ABI test binaries, ported to v2: `make embed-api`, `make host-fn-abi`,
  `make two-runtimes`, `make compile-threads` (`Makefile:134-191`).
- `just build-nonanbox` / `test-nonanbox` — the marshalling touches `TVal` internals.
- `boomkat_stress` target (GC_STRESS + ASan) over the construction, property and
  registry paths.
- One `just test262-phase` run before Phase 6.
- **New `test/capi/dozen_lines.c`**: the §Target program verbatim, compiled at
  `-std=c99 -Wall -Wextra -pedantic` with zero warnings, asserted to print `1,4,9`.
  This is the acceptance test for the whole plan.
- New cross-runtime test: a handle from runtime A resolved against runtime B returns
  `BK_ERR_INVALID` (not a wrong value).
- `bk_cstr` ring test: four nested `bk_cstr` results live simultaneously in one `printf`.
- `nm -D out/boomkat.so | grep -c ' T '` equals the ABI symbol count after Phase 5.
- `make check-abi` clean; `make linux-ci` before declaring done (both platform bugs found
  so far were Linux-only).

## Deferred

Not in this plan, but the v2 shape leaves room for each: memory limits
(`bk_set_memory_limit`), module-resolver hooks for `bk_eval_module`, bytecode
serialisation, Symbol/BigInt values, and `error.stack` (all already tracked in
`plans/074-embedding-c-api.md` §10).

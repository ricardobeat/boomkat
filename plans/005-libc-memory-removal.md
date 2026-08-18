# Plan: Remove direct libc memory calls, route through the Heap allocator

## Goal & honest framing

The request: "get rid of the libc memory methods, use entirely C3 stdlib collections,
native memory handling."

**Important calibration — "remove libc" is not literally achievable by switching to
the C3 stdlib.** C3's `std::core::mem` (`mem::new`, `mem::malloc`, `mem::free`) and the
collections (`List`, `HashMap`) bottom out in libc `malloc` through the default
allocator. Spelling `libc::malloc` as `mem::new` does not drop the `malloc` symbol from
the binary; it only changes the call site. So the meaningful, achievable goal is:

> **Stop calling `libc::` directly. Route every allocation through the `Heap` allocator
> abstraction that *already exists* in `src/heap.c3` (`alloc_func` / `realloc_func` /
> `free_func`), and adopt idiomatic C3 (`@pool` temp allocator, `List`, `DString`) only
> where the GC and the perf-critical paths don't object.**

This is the right reading of "native memory handling": make it idiomatic and consistent,
not freestanding. A genuine *zero-libc / freestanding* build (custom allocator at the
very bottom, no `malloc` symbol at all) is a much larger, separate effort — sketched at
the end as an optional Track B, not assumed here.

This also preserves the **whole point** of those `Heap` callbacks: this is a Duktape
port, and pluggable allocators (arena/pool/custom) are a core embeddability feature. The
plan *strengthens* that feature; it must not quietly hardcode a global allocator.

## Current state (from exploration)

The `Heap` struct (`heap.c3:99-105`) already defines the right abstraction:
`alloc_func`, `realloc_func`, `free_func`, `heap_udata`, `fatal_func`, with libc-backed
defaults (`default_alloc/realloc/free/fatal`, `heap.c3:234-254`). `Heap.alloc`,
`Heap.realloc`, `Heap.free` (lines 441/493/508) correctly go through the callbacks **and**
integrate with the GC trigger.

But most allocations **bypass** this abstraction and hit libc (or `mem::`) directly. Tally
of direct calls: `snprintf` 72, `free` 55, `memset` 35, `malloc` 29, `memcpy` 24,
`realloc` 7, plus `strtod`/`strtol`/`strcmp`/`memcmp` and time functions.

### Latent bugs this surfaces
1. **`heap.c3:761`** — sweep frees string objects with `libc::free` instead of
   `self.free_func`. With a custom allocator this corrupts/leaks. Real bug.
2. **hstring** allocates via `mem::malloc` (`hstring.c3:294,362`) but is freed via
   `libc::free` in sweep (761) and `mem::free` in `hstring_free` (402) — mismatched
   alloc/free families. Real bug under custom allocators.
3. **`hobject_alloc`/`env_create`** receive a `heap`/`heap_ptr` parameter but ignore it,
   mallocing directly — the abstraction exists but is unused.

## Design principle: tier by GC-coupling, NOT by file

The main way this plan could go wrong is converting perf-critical, GC-coupled structures
to C3 `List`/`HashMap`. Those add indirection + separate backing allocations the
mark-and-sweep cannot scan without special access, and would regress the benchmarks this
branch (`feat/fair-benchmark`) exists to improve — all *without* removing libc. So:

- **Tier 1 — Transient scratch** (no GC involvement): convert to `@pool()`/temp
  allocator, `DString`, `List`. Genuine idiomatic wins.
- **Tier 2 — Internal bookkeeping arrays** (`gc_objects`, `compiled_funcs`): back with the
  Heap allocator (or a `List` over it). Safe; GC just walks the array.
- **Tier 3 — GC-managed object memory** (HObject `prop_alloc`/hash/array, HString,
  EnvRecord, `vm.valstack`, CompiledFunction payload): **route through
  `Heap.alloc/realloc/free`, keep the manual memory layout.** Do **not** swap in
  `HashMap`/`List` here. This is correctness + the user's goal in one, with zero perf risk.

## Explicit non-goals
- Do **not** replace HObject's unified `prop_alloc` block (props+hash+array in one
  allocation — recent perf work) with C3 collections.
- Do **not** replace `vm.valstack` with a `List`.
- Do **not** touch `snprintf` / `strtod` / `strtol` / date-time in this effort. They are
  not "memory methods," and `%.17g` is load-bearing for `Number.prototype.toString`
  ECMAScript parity (`builtins.c3:925` etc.); C3 stdlib float formatting will not match
  without heavy conformance testing. See "Out of scope" below.
- Do **not** remove the pluggable-allocator callbacks. They are the deliverable's spine.

---

## Work breakdown (incremental, tests green between each step)

Each step ends with the full suite green: `test_vm`, the `test/*.js` corpus, and the
test262 runner. Verify after every tier.

### Step 0 — Plumbing: make a `Heap*` reachable everywhere allocations happen
Prerequisite for Tier 3. Confirm/propagate a `Heap*` into:
- `hobject.c3`: `hobject_alloc` already takes `void* heap_ptr` (line 908) but ignores it —
  type it as `Heap*` and store it on the object (HObject likely already has a back-pointer
  via its header; verify) so `grow_props`/`grow_array`/`rebuild_hash` can reach it.
- `hstring.c3`: thread the `heap_ptr` it already receives into the alloc/free calls.
- `env.c3`: `env_create*` already take `Heap*`; just use it for the `EnvRecord` struct too.

Watch for the import cycle (`heap` imports `hobject`/`hstring` for sweep; those would now
need `Heap`). C3 modules allow mutual reference within a project, but if a true cycle
bites, pass the three function pointers (or `Heap*` as an opaque `void*` plus accessor
fns) rather than importing the full type. Decide this empirically in Step 0.

### Step 1 — Fix the allocator-consistency bugs (Tier 3 correctness, smallest diff)
- `heap.c3:761`: `libc::free(hdr)` → `self.free_func(self.heap_udata, hdr)`.
- Make hstring alloc and free use the **same** family. Once Step 0 gives hstring a
  `Heap*`, route `hstring_alloc`/`hstring_concat` through `heap.alloc` and
  `hstring_free` + sweep through `heap.free_func`. Until then, at minimum make alloc/free
  symmetric.
- Verify: a quick custom-allocator smoke test (install non-libc `alloc/realloc/free` that
  log + bump a counter; assert net-zero live bytes after `Heap.destroy`). This test is
  also the regression guard for the whole effort.

### Step 2 — Tier 2: internal bookkeeping arrays
- `gc_objects` (`heap.c3:470` realloc, 367 free) → `self.realloc_func`/`self.free_func`,
  or a `List{void*}` constructed with the heap allocator.
- `compiled_funcs` (`heap.c3:418` realloc, 375-382 free) and the `CompiledFunction`
  payload (`compiler.c3:324/336/349/363`) → route through the heap allocator. Keep the
  flat code/constants/inner_funcs arrays (bytecode layout matters); just change who
  allocates them. Consider a per-function arena so the whole function frees in one call.

### Step 3 — Tier 3: GC-managed object memory through `Heap.alloc/realloc/free`
- **HObject** (`hobject.c3:750/752/799/801/844/847/859/909/958/962`): `grow_props`,
  `grow_array`, `rebuild_hash`, `hobject_alloc`, `hobject_free`. Replace `libc::malloc/
  realloc/free` with `heap.alloc/realloc/free`. **Keep the unified `prop_alloc` layout.**
  `memset`/`memcpy` stay (they operate on already-owned memory; they are not allocation).
- **HString** (`hstring.c3`): finish what Step 1 started — alloc via `heap.alloc`.
  Note: HStrings are interned/immutable; ensure the GC-string path and the table-eviction
  path both use the heap allocator.
- **EnvRecord** (`env.c3:37/65/82/49/94/109`): allocate the struct via `heap.alloc`
  (the inner bindings HObject already goes through `heap.alloc_object`).
- **vm.valstack** (`vm.c3:305 realloc, 1000/1005 malloc, 994 memset`): route through the
  heap allocator. This is GC-critical (the stack is a root set, already scanned) — keep it
  a flat `TVal*` array, only change the allocator. Verify GC still scans it correctly.

### Step 4 — Tier 1: transient scratch → idiomatic C3 (`@pool`, `List`, `DString`)
None of these are GC-managed; they are allocated and freed within a single operation.
- `vm.c3`: ForIn keys/seen arrays (644/648/691), string-concat temp (1208), exception
  `Catcher` nodes (4097), generator state scratch.
- `builtins.c3`: `Function.prototype.apply`/`bind`/`call` arg buffers (7840/7966/8122),
  regex capture arrays (2838-3042), JSON serialize buffers (8912+).
- Pattern: wrap the operation in `@pool() { ... }` and use `tmalloc`/`temp_array`/`DString`,
  or a `List{TVal}` for the arg buffers. The `≤512B stack buffer else heap` trick at
  `vm.c3:1205` can become a stack buffer + temp-allocator fallback.
- These are independent and low-risk; can be done in any order, each verified alone.

### Step 5 — Sweep for stragglers & document
- `grep -rn "libc::\(malloc\|free\|calloc\|realloc\)" src/` should return **zero** (the
  conversion ones; `default_alloc/realloc/free` in heap.c3 are the *intended* libc
  bottom and stay). `memset`/`memcpy`/`memcmp` may remain — they are not allocation; the
  C3 idiom is `mem::copy`/`mem::clear` if you want to drop the `libc::` spelling, but it's
  cosmetic.
- Update `architecture_report.md` / `progress.md` to describe the single allocation path.

---

## Out of scope for this effort (separate, higher-risk tracks)
- **`snprintf` (72 calls)** — number/error formatting. `%.17g` parity is JS-conformance
  critical. Touch only with the test262 number suite as a gate.
- **`strtod` / `strtol` / `strcmp` (Infinity handling)** — JS number-parsing semantics.
- **Date/time (`time`/`mktime`/`localtime_r`/`gmtime_r`, 8 calls)** — no C3 stdlib
  equivalent with the needed semantics; leave as libc.
- **`abort`** (`heap.c3:253` default fatal) — fine as the libc-backed default.

## Optional Track B — true freestanding / zero-libc (only if the user wants it)
If the actual goal is no `malloc` symbol at all: provide a built-in default allocator
(arena/buddy over a fixed pool or `mmap`/`sbrk`) wired into `alloc_func` et al., compile
with `--use-stdlib=no` or a no-libc target, and replace the residual `snprintf`/`strtod`/
time calls with self-contained implementations (Ryū/Grisu for float↔string). This is a
large, conformance-sensitive project; flag it and get explicit buy-in before starting.

## Risks
- **Import cycle** between `heap` and `hobject`/`hstring` (Step 0) — mitigate with opaque
  `void*` + accessor fns if the full-type import cycles.
- **Perf regression** if any Tier-3 layout accidentally changes — benchmark
  (`boomkat` target) before/after Tier 3.
- **GC root scanning** of valstack must remain intact after the allocator swap (Step 3).
- **Custom-allocator smoke test** (Step 1) is the safety net for the whole effort; build
  it first.

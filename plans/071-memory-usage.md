# Plan 071: memory usage

Work to close the peak-RSS gap with QuickJS, driven by profiling rather than
guesswork. Each item below starts from a measured allocation, explains why the
current design pays it, and states the change that removes it.

## M1: per-object property hash tables

### What profiling found

`HASH_MIN_PROPS = 8` (src/hobject.c3) is exactly where object memory climbs.
A micro-benchmark of 50,000 same-shaped objects, once with 7 named properties
and once with 8:

| Script | boomkat | QuickJS |
|--------|-----------|---------|
| 7 props | 17,584 KB | 14,976 KB |
| 8 props | 31,056 KB | 14,976 KB |

The 7-to-8 jump is 13,472 KB over 50,000 objects, or 276 B per object. The
code predicts 272 B: `prop_hash_mask_for(8)` doubles to 16 slots, 16 slots x
16 B per `HashEntry` is 256 B, plus the 16 B `PropHashInfo` struct. QuickJS
does not move at all between the two scripts.

### Why the design pays it

The hash table is allocated per object. The shape chain already holds the
authoritative key list and is shared between same-shaped objects through the
transition table, so 50,000 identically-shaped objects build 50,000 identical
256 B tables to answer the same key-to-index question one shared table could
answer. `HObjectBase` also carries an 8 B `prop_hash` pointer on every object,
including the majority that never reach 8 properties.

### The change

Move the table from the object to the shape, which is how QuickJS avoids the
cliff (its `JSShape` holds the property hash for every object using it).

A shape's key-to-index mapping is immutable for its whole lifetime: keys are
fixed at creation, and both `delete_prop` and `set_prop_flags` operate by
giving the object a fresh private shape rather than mutating a shared one. A
table built once therefore never goes stale, needs no invalidation, and stays
valid for every object that shares the shape.

Concretely:

- Add a `HashEntry*` field to `Shape`. The table covers the whole chain from
  root to that shape, since that is the key list lookups walk.
- Build the table lazily in `find_prop_idx`, the first time a lookup sees
  `prop_count >= HASH_MIN_PROPS` on a shape with no table. Build by walking
  the shape chain, as the current `ensure_prop_hash` does. Allocation failure
  leaves the table null and falls back to the chain walk.
- Free the table in `shape_free`, the single choke point all shape teardown
  paths go through.
- Delete the eager maintenance: the in-place insert in `put_prop`, the
  rebuild in `delete_prop`, the free in `hobject_free`, the `prop_hash`
  pointer in `HObjectBase`, and the `PropHashInfo` struct.

### Expected effect

On the profiled script the 50,000 tables become one table per shape in the
chain: 13.5 MB saved, bringing the 8-prop case from 31 MB to roughly the
7-prop baseline. Every object also shrinks by 8 B, and objects that are built
but never read by key (write-only construction) never pay for a table at all.

### Measured result

Done. The 8-prop case went from 31,056 KB to 16,288 KB, within noise of the
7-prop case (16,112 KB, itself down from 17,584 KB on the removed pointer).
QuickJS holds at 14,976 KB for both. Gates: rosetta 42/42, local suite and
all sub-suites green, test262 phase 0-1 2468 pass / 0 fail.

### Accepted trade-off

The single-user case was later reconciled (session 318): an object whose shape
chain has no second user keeps a per-object incremental table, so growing one
object one key at a time is O(1) amortized again. Only a shape reached by more
than one object builds the shared table, so 50,000 identical objects still pay
one table per shape, never per object, and the 8-prop memory cliff stays
closed.

## Remaining gap, not yet profiled

M2 (below) closed the micro-bench gap as a side effect: the 7-prop and
8-prop scripts now measure 13,304 KB and 13,287 KB, both under QuickJS
14,976 KB. The surviving delta is the pool pages and engine scaffolding.

## M2: pooled small blocks for property storage and strings

### What profiling found

The normal memory bench (`benchmarks/memory_test.js`) measured 15,248 KB
against QuickJS's 6,128 KB, but a frozen heap walk showed only ~2 MB of live
data. The gap was allocator overhead: object headers were pooled, while
property blocks, string bodies, and everything the compiler touched went
through raw malloc/realloc, whose freed blocks macOS keeps resident.

Profiling also found a compile-time spike dwarfing the runtime: compiling
`memory_test.js` alone peaked at 13 MB. The move-elimination liveness pass
allocated four per-instruction register bitsets, each sized for the full
16-bit register file: `code_cap * 4 * 8 KB`. A 1188-byte script paid 16 MB
per compile, and larger functions double it.

### The change

- Size-class `FixedBlockPool`s on the Heap, shared by property blocks and
  string bodies, with classes from 48 B to 8 KB and libc fallback above.
  `grow_props`/`grow_array` copy into a fresh block and return the old one
  to its class pool, replacing realloc; `seal` shrinks its block so the
  free site can still derive the class from the current size.
- The liveness `RegSet` is now sized by the function's actual `max_reg`
  instead of `MAX_REGISTERS`: a few words per instruction instead of 2048,
  cutting the four arrays from 16 MB to tens of KB for typical functions.
  The sets live in one per-function arena wired in `CompilerContext.finish`.

### Measured result

| Benchmark | before | after | vs qjs |
|-----------|--------|-------|--------|
| memory_test.js | 15,248 KB | 6,960 KB | 1.1x (was 2.4x) |
| bench_memory_heavy.js | 40,512 KB | 30,320 KB | 0.9x (was 1.2x) |

Compile-only peak for the same script: 13 MB to 4.2 MB. Gates: rosetta
42/42, local suite and all sub-suites green, test262 phases 0-8 and 11-15,
17, 20-22 all 0 fail, golden bytecode 30/30, nonanbox build clean.

### Notes

Pooling alone did not move RSS; the liveness fix is what closed the gap.
macOS malloc keeps freed Large-zone blocks resident, so the remaining
~700 KB over QuickJS is the pool pages and engine scaffolding, not
fragmentation.

## M3: string header, array growth, follow-ups

- The HString header is now 32 bytes (was 36): the large-string registry
  slot moved out and the registry finds entries by pointer, since it holds
  only a handful of large non-interned strings. The char-offset scan cache
  stays: dropping it made non-ASCII charCodeAt loops 20x slower than the
  reference engines for a 4-byte-per-string saving.
- Dense-array growth was left as-is. The doubling schedule matches QuickJS
  and Duktape, and the realloc churn the tuning was meant to remove was
  already absorbed by the M2 pools: the matrix section dropped from +3.0 MB
  to +1.33 MB with the pool pages accounting for 1.06 MB of that.

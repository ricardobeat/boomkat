# Plan 030 — Memory Profiling & Gap Analysis

**Date**: June 12, 2026
**Status**: ✅ DONE — `memory_test.js` now ~6,656 KB (1.0× QuickJS)
**Goal**: Close the 2.6× RSS gap vs original Duktape (16 MB → ~6 MB on `memory_test.js`)

---

## Profiling Results (from `memory_test.js`)

```
malloc_total:     9,310 KB   (21,847 calls)
avg_alloc:          436 B
live_objects:     12,419
peak_objects:     12,419
strings:           9,425    (in string table)
shapes:            1,293
```

- **Total malloc'd**: 9,310 KB
- **RSS observed**: 16,384 KB
- **Gap**: 7,074 KB — unexplained. This gap is larger than every itemized cost below
  combined; profiling it (allocator retention, fragmentation, large one-off buffers,
  code, stack) should happen before assuming the items below close it.

---

## Struct Size Comparison (64-bit, nanbox)

| Struct | Duktape (C) | QuickJS (C) | Our C3 port | Delta vs best |
|---|---|---|---|---|
| Object header (plain `{}`) | 64 B | ~72 B | **64 B** | 0 |
| Object header (function) | sizeof(base)+subclass fields | ~72 B (union inline) | **96 B** | +24 B |
| Object header (array) | same as base | ~72 B | **72 B** | 0 |
| String header | ~24 B | **12 B** (packed) | 32 B | +20 B vs QJS |
| Property value slot | 16 B (union value/getset) | 16 B (union) | **16 B** (value+setter, setter wasted on data) | 0-8 B |
| Shape property | — (inline in props) | **8 B** | 16 B | +8 B |
| Shape header | — | ~57 B + hash + props | 24 B + props | n/a |
| GC links | 16 B (next+prev) | 16 B (list_head) | 16 B (next+prev) | 0 |
| Per-object hash table | 0 (inline in props) | 0 (in shape) | **2 mallocs** (PropHashInfo + HashEntry) | var |

### Key finding: object headers are NOT the problem

After Items 3 & 4 & 1, our HObjectBase is **64 bytes** — identical to original Duktape and smaller than QuickJS (~72 bytes). The remaining gap comes from:

---

## Root Causes (ranked by estimated impact)

### 1. Per-object `prop_alloc` blocks — every property-bearing object gets a separate malloc

**Current**: Each object with properties gets its own `malloc(128+)` for `prop_alloc` (initial capacity 8 slots × 16 bytes). With 10,000+ property-bearing objects, that's 10,000 separate mallocs.

**Original Duktape**: Same pattern (each object gets its own props allocation). But Duktape packs keys, values, flags, AND hash table into one contiguous block — equivalent to our `prop_alloc`, just with more inline.

**QuickJS**: Properties split between shared `Shape` (names/flags/hash — one allocation shared by all objects with same layout) and per-object `JSProperty[]` (values only). Per-object prop array is still a separate malloc.

**Fix options**:
- A. **Inline small prop tables** — embed 4 PropValue slots directly in the object tail (after prototype), avoiding the separate malloc for 0-4 property objects.
- B. **Pool allocator** — use fixed-size arenas like QuickJS to eliminate per-allocation malloc overhead for small allocations. Complex but highest impact.

Note: option A changes per-class object sizes, which redefines the size classes used by the pool allocator (Item 1). The pool size-class table must be the single source of truth (derived from `alloc_size_for_class`) so this change only edits one place.

### 2. PropValue setter waste — 8 bytes unused per data property slot

**Current**: `PropValue` is 16 bytes (TVal value + TVal setter). For data properties, the `setter` field (8 bytes) is never used. Data properties are the overwhelming majority of slots (~35,000 active slots in memory_test.js).

**Original Duktape and QuickJS** both have the same waste: 16-byte slots sized for the accessor case. No need to stay faithful to either — other engines solve this better.

**Chosen fix — boxed accessor pairs (SpiderMonkey / JavaScriptCore design)**:
Every slot becomes a single 8-byte TVal. Accessors don't live in the slot at all — a
getter/setter pair is boxed into its own small heap cell, and the slot holds a pointer
to it:

```c3
struct GetterSetter {   // GC-managed cell, traced like any heap object
    HeapHeader hdr;
    TVal getter;
    TVal setter;
}
```

The shape's per-property flags already record "this is an accessor", so reads know how
to interpret the slot. `prop_idx` semantics, IC behavior, and the `prop_values[]` layout
all stay uniform — slots just shrink 16 B → 8 B. Accessors pay one extra indirection and
a 16+ B cell, but they are rare and not hot.

Costs: one new GC-managed cell type (must be traced and refcounted); accessor get/set
takes one more pointer hop; data→accessor redefinition allocates a cell.

**Alternatives considered (rejected)**:
- **Segregated slot arrays (V8-flavored)**: separate value array and accessor side
  array, shape records which. Same memory win, but slot-index bookkeeping during
  transitions (delete, data→accessor redefine) is much more complex than option 1.
- **Heap-wide accessor table keyed by (object, key)**: uniform 8 B slots, zero cost for
  accessor-free objects, but lifetime management of the side table (deletion, GC,
  potential object moves) is awkward.
- **Two-slot accessors (Lua-spirit, keep slots uniform and special-case the rare
  thing)**: accessor properties occupy two consecutive 8 B slots. No new heap cell, but
  property indices stop matching shape indices, requiring translation in every IC and
  `prop_idx` computation — exactly the kind of indexing blast radius that produced the
  plan 029 bugs.

### 3. String header: 32 B vs QuickJS 12 B

| Field | Our HString | QuickJS JSString | Delta |
|---|---|---|---|
| flags | 4 B | — (packed in block header) | |
| refcount | 4 B | — (packed in block header) | |
| next | 8 B | — (in atom table) | |
| hash | 4 B | 4 B (packed with len) | |
| blen | 4 B | 4 B (packed with is_wide) | |
| clen | 4 B | — (computed lazily) | |
| arridx | 4 B | — (cached elsewhere) | |
| **Total** | **32 B** | **12 B** | +20 B |

With 9,425 strings in the table, the per-header delta compounds. Not the dominant cost, but notable.

**Fix**: Compute `clen` lazily instead of storing it (5,100+ strings). Remove `arridx` from HString and compute on demand (or cache in a side table for hot strings only).

### 4. Both `shape_id` AND `shape` pointer — redundant cache

**Current**: Every object carries `ushort shape_id` (2+6 pad) + `Shape* shape` (8 bytes) = 16 bytes. The `shape` pointer is always `heap->shapes[shape_id]` — a pure cache.

**Original Duktape**: No shape system — property layout is inline in the props allocation.

**QuickJS**: Only `JSShape*` pointer (8 bytes) — no separate shape_id. The shape IS refcounted, so the pointer is the canonical reference.

**Fix**: Drop the `shape` pointer (8 bytes) and dereference through `heap->shapes[shape_id]` via `_active_heap`. Adds one indirection per property access. Gated behind `-D NOSHAPECACHE` for memory-constrained builds — the default build keeps the cache, so this saves nothing by default.

### 5. QuickJS pool allocator — the big differentiator

QuickJS uses arenas of fixed-size blocks with an 8-byte inline header (`JSMallocBlockHeader`). This:
- Eliminates per-allocation `malloc` metadata (16+ bytes)
- Eliminates fragmentation from variable-size allocations
- Groups allocations of the same size into contiguous pages

Our port calls `libc::malloc` for every tiny allocation (21,847 calls for memory_test.js), each carrying libc metadata overhead and contributing to fragmentation.

**Fix**: Implement a pool allocator for object headers (the most frequent allocation), eliminating per-allocation metadata and grouping same-size objects into contiguous pages. Note: pool pages are not returned to the OS until the pool is destroyed, so RSS reflects peak object count, not live count.

---

## C3 Stdlib Options

### `std::core::mem::mempool` — `FixedBlockPool` fixed-size slab allocator

The C3 stdlib ships a fixed-block pool allocator. Perfect for allocating HObjects of
known sizes:

```c3
import std::core::mem::mempool;

// One pool per allocation size class
FixedBlockPool obj_pool_64;   // plain objects
FixedBlockPool obj_pool_96;   // FUNCTION/REGEXP/etc

obj_pool_64.init(allocator, 64);   // requires an Allocator + block size
void* p = obj_pool_64.alloc();     // zero-initialized block
obj_pool_64.dealloc(p);            // return ONE block to pool
// obj_pool_64.free() destroys the ENTIRE pool — never call per object
```

- Eliminates per-allocation `libc::malloc` metadata
- Reduces fragmentation — all objects of same size class share contiguous pages
- `alloc()` zero-initializes (pages are calloc'd; freelist reuse is `mem::clear`ed) —
  replaces our `libc::malloc` + `libc::memset` pair
- `dealloc()` carries an `@require` that validates the pointer by walking the page
  list — O(pages) per free, but only in safe-mode builds; release builds compile it
  out and dealloc is an O(1) freelist push. Combined with `--sanitize=address`, debug
  builds get wrong-pool/double-free detection for free.

**Integration design** (free-path provenance is the hard part — the GC sweeper must
route each object back to the correct pool):

1. **Compile-time class→pool table.** Generate the size-class table at compile time
   from the struct definitions themselves (`$foreach` / `.sizeof` / `$assert`), so it
   can never drift from `alloc_size_for_class`:
   ```c3
   const usz[] POOL_SIZES = { HObjectBase.sizeof, HArrayObject.sizeof, HFunctionObject.sizeof };
   $assert(HObjectBase.sizeof <= 64);  // layout regressions fail the build
   ```
   Provenance at free time is then `pool_for_class(obj.cls)` — a pure function of the
   class field the sweeper already reads. Zero runtime metadata per object. If Item 5
   (inline prop tables) changes struct sizes, the size classes reflow automatically.
2. **Fallback flag bit.** One bitstruct flag bit in the object header marks
   malloc-fallback allocations (pool exhausted, oversized class). The free path
   branches on this bit: flag set → `Heap.free()`, otherwise → owning pool's
   `dealloc()`.
3. `hobject_alloc()` replaces its `Heap.alloc()` call with the pool lookup; falls back
   to `Heap.alloc()` + flag bit when needed.

Note: pool pages are not returned to the OS until the pool is destroyed, so RSS
reflects peak object count, not live count.

**Potential follow-up — half-BIBOP page map**: `FixedBlockPool.init` accepts an
`alignment` parameter (pages go through `calloc_aligned`), so page-aligned pools come
for free. With a small side map of `masked_page_addr → pool`, provenance becomes O(1)
for *any* pointer with no class knowledge required. Not needed while only object
headers are pooled (the class enum is provenance enough), but it is the natural second
stage if pooling expands to allocations whose type isn't knowable at the free site
(prop tables, strings, shape blocks), and the stepping stone to bulk page sweeping.

### `@pool()` / `mem::@stack_mem()` — Arena/scratch allocators

```c3
// Temp arena freed at scope exit — zero overhead, no individual frees needed
@pool() {
    // All allocations here use temp allocator, freed automatically
    char[] buf = mem::temp_array(char, 4096);
}

// Stack-based arena (fixed size, no heap)
mem::@stack_mem(65536; |Allocator arena| {
    // Allocations from 'arena' live on the stack
});
```

Useful for:
- **Compilation temporaries** — parser AST nodes, compiler intermediate data
- **Regex compilation** — bytecode buffers, temporary strings
- **GC gray stack** — already using a dynamic array, but could benefit from pre-sized arena

### `collections::List{T}` — Typed dynamic array

```c3
import std::collections::list;
alias PropList = List{PropValue};

PropList props;
props.init(heap_allocator, initial_capacity = 8);
props.push(prop_val);
props[i] = val;        // zero-cost operator[]
props.free();
```

Could replace our manual `prop_alloc` management (realloc, memmove, zero-init). But adds
`List`'s own overhead (capacity, size fields) which are already in HObject. Not a direct
replacement — more of a refactoring opportunity.

### `mem::new_array(T, n)` — Typed zero-init allocation

```c3
PropValue* pv = mem::new_array(PropValue, 8);  // alloc + zero-init, 8 slots
mem::free(pv);
```

Cleaner than `libc::malloc(n * sizeof(X))` + `libc::memset(p, 0, ...)`. Already equivalent
to what we do in `grow_props`. Minor code quality improvement.

### Generics for sized pools

C3 generics could make a type-safe pool per HObject variant:

```c3
struct PoolAlloc <Type> {
    Mempool pool;
}
fn void PoolAlloc.init(Type self, sz block_size = Type::size) {
    self.pool.init(block_size);
}
fn Type* PoolAlloc.alloc(Type self) { return (Type*)self.pool.alloc(); }
fn void PoolAlloc.free(Type self, Type* p) { self.pool.free(p); }
```

This would let us allocate `PoolAlloc{HObjectBase}.alloc()` for plain objects, etc.
But the `mem_mempool` API is already type-agnostic — generics add little value here.

### `inline` Struct Subtyping — true structural inheritance

C3's `inline` keyword on a struct member flattens the member's fields into the parent:

```c3
struct HObjectBase { ObjFlags flags; ... PropHashInfo* prop_hash; }
struct HObject {
    inline HObjectBase base;   // fields accessible as self.flags, self.prop_count, etc.
    HObjectExtra extra;        // 32 bytes at offset HObjectBase::size
    uint array_length;         // 4 bytes
}
// HObject* implicitly converts to HObjectBase* and HeapHeader*
```

This means:
- No duplicate field definitions needed between HObjectBase and HObject
- `HObject*` → `HeapHeader*` cast works (same layout at offset 0)
- `HObject*` → `HObjectBase*` conversion is implicit (no cast needed)
- All existing `self.flags`, `self.prop_count` etc. keep working without any changes

Could simplify our current approach where HObjectBase duplicates HObject's first N fields
verbatim to guarantee layout compatibility. Lower maintenance burden.

### `@packed` — Eliminate struct padding

```c3
struct ShapeProperty @packed {
    void*     key;   // 8 bytes
    PropFlags flags; // 1 byte (bitstruct : char)
}
// 9 bytes instead of 16 (no padding to align key)
```

Useful for memory-critical structs: `ShapeProperty` (16→12? no, key needs 8-byte alignment),
`Shape` (24→20), `PropHashInfo` (16→12). Gains are modest (2-4 bytes each) but
compound across thousands of allocations.

Caveat: unaligned access may be slower. Not recommended for hot-path structs like
`PropValue` or `ICEntry`.

### `mem::new_with_padding` — Cleaner variable-size allocation

```c3
// Current: manual size calculation + memset
usz sz = alloc_size_for_class(cls);
void* raw = heap.alloc(sz);
libc::memset(raw, 0, sz);

// With new_with_padding:
HObjectBase* raw = mem::new_with_padding(HObjectBase, extra_bytes);
// Allocates sizeof(HObjectBase) + extra_bytes, all zero-initialized
```

Cleaner than our `alloc_size_for_class` switch. The extra bytes are zeroed automatically.
Requires the heap's allocator to implement the `Allocator` interface (or we adapt
`Heap.alloc` to match `mem::malloc` semantics).

### `$$memset` / `$$memcpy` — Compiler builtins

C3's LLVM backend provides optimized `$$memset` / `$$memcpy` builtins that map to
LLVM intrinsics. Replace `libc::memset` / `libc::memcpy` in hot paths:
- `grow_props` (memmove array part on realloc)
- `GC mark` (iterating property values)
- `hobject_alloc` (zero-init new objects)

### `--sanitize=address` — ASan for validation

```bash
c3c build --sanitize=address boomkat
```

Catches heap corruption, use-after-free, buffer overflows at runtime. Would have caught
our earlier `hobject_alloc` heap corruption (writing to offset 72 on 72-byte allocation)
immediately. Essential for validating Item 1-class changes.

---

## Correctness Bugs from Plan 029 (fix before proceeding)

These were introduced by the `uint→ushort` compression in plan 029 and must be resolved
before adding further changes that depend on `_active_heap` or shape IDs.

### Bug A — IC generation wrap (hobject.c3:1587)

`VarICEntry.generation` was narrowed to `ushort` but `Shape.generation` remains `uint`
(hobject.c3:1465). After 65536 mutations to a shape, the stored ushort wraps and aliases
a past generation value. The IC-validation compare (`shape.generation ==
vic.generation`) promotes the ushort to uint — so when the live generation is e.g. 65537
and the IC was stored at generation 1, both produce ushort 1 and the IC appears valid. A
stale `prop_idx` is then used to read/write the wrong slot in `prop_values[]`.

There are **four** compare/store site pairs, all of which must be fixed:
vm.c3:2234/2404, 5959/6037, 6095/6176, and 6255/6286.

**Fix**: Widen `VarICEntry.generation` back to `uint` and drop the `(ushort)` cast at
all four store sites. The field sits next to `ushort prop_idx` — widening costs 2 bytes
of padding per entry, a negligible regression against the plan 029 wins.

### Bug B — Shape ID 65535 aliases SHAPE_ID_NONE (heap.c3:637)

`alloc_shape_slot()` returns `uint` with no cap below 65535. When `shape_count` reaches
65535 organically, the returned id passes the `SHAPE_NONE` (0xFFFF_FFFF) guard and is cast
to `(ushort)65535 == SHAPE_ID_NONE`. The shape is stored in `shapes[65535]` but the
object's `shape_id` is set to the sentinel value. Any lookup-transition return of this ID
is treated as "no transition found", breaking shape sharing and IC for that object. At
65536+ shapes the ushort wraps to 0, 1, … aliasing live shapes and corrupting
`prop_values[]` accesses.

**Fix**: One line in `alloc_shape_slot` before returning: `if (id >= 0xFFFE) return SHAPE_NONE;`
(cap valid IDs at 65534). 65535 shapes is far beyond any real workload, so this is safe.

---

## Recommended Implementation Order

| # | Item | C3 help | Effort | Risk |
|---|---|---|---|---|
| A | **Fix IC generation wrap** (`VarICEntry.generation` → `uint`, 4 sites) | — | Trivial | None |
| B | **Cap shape IDs at 65534** in `alloc_shape_slot` | — | Trivial | None |
| 0 | **Profile the 7 MB malloc-to-RSS gap** before assuming items below close it | — | Low | None |
| 1 | **Pool allocator via `FixedBlockPool`** + compile-time class→pool table | `std::core::mem::mempool`, `$foreach`/`$assert` | Low | Low |
| 2 | Drop `shape` pointer (`-D NOSHAPECACHE` builds only) | — | Low | Low |
| 3 | Use `inline` struct subtyping for HObject/HObjectBase | `inline` keyword | Low | Very low |
| 4 | Compute `clen` lazily | — | Low | Very low |
| 5 | Inline small prop tables (size classes reflow via Item 1's table) | — | Medium | Medium |

**Items A & B** must go first — they are correctness fixes for plan 029 regressions.
Item 2 (drop `shape` pointer) relies on `_active_heap` being correct; shipping that on
top of a broken IC generation check would make failures harder to diagnose.

**Item 3** is a no-brainer refactor — eliminates duplicate field definitions, makes the
struct relationship self-documenting, and ensures HObject*/HObjectBase*/HeapHeader* casts
stay safe as we evolve the struct. Should be done before any further HObject surgery.

**Item 1** (pool allocator) becomes the priority — C3 ships the allocator for free,
we just wire it into `hobject_alloc`. Replaces 12,000+ `libc::malloc` calls with
pool allocations. Re-run profiling after to reassess the remaining gap.

## Verification

```bash
just build
just bench-memory   # compare before/after RSS
```

## See Also

- [033-memory-next-steps.md](033-memory-next-steps.md) — next priorities after the fixes in this plan landed

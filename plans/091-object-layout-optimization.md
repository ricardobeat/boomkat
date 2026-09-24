# 091: Class-specific object layouts and pools

Status: implemented and measured. Each class reports its own logical size and
allocates from one of six pools. Pool pages fill their allocator size class,
and the two header stages below are closed with measurements.

## Goal

Reduce object storage and allocation work across ordinary JavaScript workloads by
giving each object class storage appropriate to its payload. Preserve the common
object header, inline property capacity, GC behavior, and existing semantics.

## Findings

The C3 skill, language layout reference, and installed C3 0.8.3 stdlib support
typed layouts with an `inline HObjectBase` prefix. `FixedBlockPool.init_for_type`
derives block size and alignment from the complete struct.

Before implementation, an isolated compiler probe on macOS ARM64, with
NaN-boxing enabled, measured:

- `TVal`: 8 bytes.
- `HObjectBase`: 80 bytes.
- `HObjectExtra`: 104 bytes, alignment 8, determined by the Temporal payload.
- Existing inline property storage: 32 bytes.

| Class | Current pool block | Candidate typed layout | Reduction |
|---|---:|---:|---:|
| Array | 216 B | 120 B | 44% |
| Arguments | 216 B | 128 B | 41% |
| Function | 216 B | 192 B | 11% |
| Promise | 216 B | 152 B | 30% |
| RegExp | 216 B | 136 B | 37% |
| Getter/setter | 216 B | 96 B | 56% |

Candidate layouts retain existing inline property capacity where applicable.
Getter/setters have no inline properties. Plain objects already occupy 112-byte
blocks and do not carry the extra union.

These figures describe object storage, not total heap savings or throughput.
Shared size-class pools may round candidate layouts up to larger blocks.

Getter/setters request 96 bytes through `alloc_size_for_class`, but
`pool_for_class` routes them to the 216-byte function pool. Allocation size and
physical pool block size must both change to realize savings.

The installed pool clears recycled blocks; `hobject_alloc` clears them again.
Fresh bump-allocated pool blocks are uninitialized. Removing duplicate clearing
requires an explicit initialization contract covering both paths.

A `NONANBOX` probe fails the existing compile-time assertion that
`HObjectTemporal::size > HObjectFunction::size`. Layout selection must work when
the largest payload differs between configurations.

## Results

Interleaved A/B, best of five, against a binary built from the same tree before each
change. Peak RSS from `/usr/bin/time -l`.

### Getter/setter cells: 216 B -> 96 B (commit 1984917c)

Cells asked for 96 bytes but were routed to the 216-byte function pool. A workload
that allocates and retains 100k cells runs about 25% faster with about 12% lower peak
RSS; the benchmark suite is unchanged.

### Arrays and arguments: 216 B -> 120 B and 128 B

Both now share the array pool at a 128-byte block, so no pool was added.

| Workload | Before | After | Change |
|---|---:|---:|---:|
| 800k retained arrays, 2 elements and 2 named props | 0.52 s | 0.44 s | -15.4% |
| 8M array allocation churn | 1.23 s | 1.13 s | -8.1% |
| 4M calls with mapped `arguments` | 2.08 s | 2.10 s | +1.0% (noise) |
| 800k retained arrays, peak RSS | 387.0 MB | 313.2 MB | -19.1% |
| 300k retained 8-element arrays, peak RSS | 133.6 MB | 105.7 MB | -20.9% |
| 8M array churn, peak RSS | 4.8 MB | 4.7 MB | flat |
| Minimal script, peak RSS (pool baseline) | 4.2 MB | 4.3 MB | flat |

Every `benchmarks/bench_*.js` workload stayed within +-3.4% over 20-run batches.

`just gc-profile` on the retained-array workload: 800,901 allocations, 9 cycles,
14,336,534 objects marked, or 17.9 marks per allocation. The collection pass walks
each object many times, which is what the header stages below aim at.

### Every other class, sized from its own payload (commits 0dbd068b, 1be1c032, d292b3c3)

Classes now report the payload they use rather than the union's size, and share two
pools: one sized for the promise payload, one for the two payloads that exceed it.
Getter/setters, arrays, arguments, functions, proxies, promises, RegExp objects,
boxed primitives, errors, generators, array buffers, typed arrays, host objects,
wrapped iterators, the plain iterators, and the four collection classes all moved.

| Workload | Before | After | Change |
|---|---:|---:|---:|
| 200k retained promises | 0.36 s | 0.29 s | -19.4% |
| 300k retained RegExp objects | 0.20 s | 0.17 s | -15.0% |
| 500k retained closures | 0.23 s | 0.15 s | -34.8% |
| 300k retained typed arrays | 0.13 s | 0.07 s | -46.2% |
| 300k retained Maps | 0.12 s | 0.08 s | -33.3% |
| 300k retained errors | 0.18 s | 0.14 s | -22.2% |
| 200k retained promises, peak RSS | 175.3 MB | 150.8 MB | -14.0% |
| 300k retained typed arrays, peak RSS | 146.4 MB | 109.5 MB | -25.2% |
| 300k retained Maps, peak RSS | 133.7 MB | 105.8 MB | -21.0% |

The migration also fixed a latent NONANBOX crash: the string iterator kept its
string in the primitive payload and its position in the iterator payload, which do
not overlap while a TVal is 8 bytes but do at 16. A collection after iterating a
string read a corrupt value. It has a payload of its own now.

### The collection lookup index, and what a stride costs (commits 142d1316, 9dac3b71)

Every object carried a pointer for the lookup index only Map, Set, WeakMap, and
WeakSet build. Moving it into those four classes' payloads shrank the common header
from 80 to 72 bytes and every size class with it.

That change also moved the small pool's block from 152 to 144 bytes, and a workload
retaining eight million Date objects then ran 18% slower: 1.76 s against 1.48 s. The
stride, not the payload, was responsible:

| Small pool block | 8M retained Dates |
|---:|---:|
| 144 B | 1.76 s |
| 152 B | 1.45 s |
| 160 B | 4.55 s |

Pool strides interact with cache geometry, so a block that merely fits its largest
payload is not automatically the fastest. The small pool is padded back to 152 and
the padding is recorded in the code; any future payload that lands near a size
boundary needs measuring rather than assuming.

### Pool page sizing (commit 0998f17a)

A pool page is one allocator request and the allocator rounds it up to its next size
class, so a page spilling just past 64 KB costs about a quarter more than the same
bytes packed under it. Each pool now takes as many blocks as fit under 64 KB rather
than a flat 512.

| Workload | 512-block pages | Filled to 64 KB | Change |
|---|---:|---:|---:|
| 8M retained plain objects, peak RSS | 1168.2 MB | 984.4 MB | -15.7% |
| 8M retained Dates, peak RSS | 1413.6 MB | 1352.5 MB | -4.3% |
| 500k retained closures, peak RSS | 167.9 MB | 152.5 MB | -9.2% |
| 800k retained arrays, peak RSS | 313.2 MB | 307.0 MB | -1.9% |
| Minimal script, peak RSS | 4.3 MB | 4.3 MB | flat |
| 8M retained plain objects | 0.79 s | 0.74 s | -6.3% |
| 8M retained Dates | 1.49 s | 1.46 s | -2.0% |

This is what makes the per-class block sizes visible in RSS at all: before it, a
block change of eight bytes sat inside the rounding of the page it lived on.

### Experiments that shaped the design

**Pool block alignment.** A 128-byte block is two cache lines, but pool pages come
from `calloc` at 16-byte alignment, so half the blocks straddle a line. Initializing
the array pool with 64-byte alignment made every block line-aligned and changed
nothing measurable (0.0% and +1.8% over nine repetitions; an apparent -3% at five
repetitions was load noise). Not adopted.

**Inline property capacity.** Setting `INLINE_PROPS` to 0 -- the shape a 32-byte
header forces -- moves every named property out of the object. Measured against the
current layout:

| Workload | 4 inline props | No inline props | Change |
|---|---:|---:|---:|
| 800k arrays with 2 named props | 0.44 s | 0.65 s | +47.7% |
| 800k objects with 2 named props | 0.18 s | 0.26 s | +44.4% |
| 300k dense arrays, no named props | 0.10 s | 0.08 s | -20.0% |
| 8M array churn | 1.15 s | 1.14 s | -0.9% |
| 800k retained arrays, peak RSS | 313.2 MB | 286.7 MB | -8.5% |
| 800k retained objects, peak RSS | 163.8 MB | 187.0 MB | +14.4% |

Inline property storage stays. A smaller header only pays for objects that carry no
named properties, and costs about 45% of runtime for the ones that do.

**Measurement harness.** An eight-byte-per-object change is invisible in peak RSS
until pool pages fill their allocator size class, and short workloads are dominated
by machine noise: the same binary timed twice in one interleaved run must agree
before any delta is believed, and a 296-byte-per-object change must move RSS by the
predicted amount before the harness is trusted.

### Reference engines

Measured in this tree for Duktape 2.7.0 and the vendored quickjs-ng, and read from
V8 and WebKit sources for the rest.

| Engine | Base object | Array object | Prototype, shape, and names | GC state in object |
|---|---:|---:|---|---|
| V8, pointer compression | 12 B | 16 B | shared Map, 4 B per object | none |
| V8, no compression | 24 B | 32 B | shared Map | none |
| JSC (and Bun) | 8 B cell, 16 B with butterfly | 16 B | shared Structure, 4 B id | 1 B cell state |
| QuickJS | 64 B | 64 B | shared `JSShape`, 56 B | 16 B list, refcount in the malloc header |
| Duktape 2.7.0 | 56 B (`duk_hobject`) | 64 B (`duk_harray`) | per-object property table | 24 B heap header |
| boomkat | 80 B | 120 B | per-object prototype, shape id, and names | 16 B list, 8 B flags and refcount |

V8 and JSC reach 12-16 bytes by keeping no refcount in the object and packing shape
and prototype into a 4-byte compressed map or structure id. The engines this project
mirrors are QuickJS and Duktape at 56-64 bytes, so the gap is a design difference in
where prototype, counts, and property names live, not an accident of sizing.

## Design

### Typed layouts

Define complete structs containing an `inline HObjectBase`, the class payload,
and inline properties where applicable. Use compiler-derived size, alignment,
and member offsets. Keep payloads in the same allocation as their header.

Use typed payload accessors as layouts migrate. Retain unions only where their
members intentionally share storage. Packing structs does not address the
oversized union and would weaken alignment guarantees.

### Central layout information

Centralize the relationship between object class, logical allocation size,
inline property offset, and pool selection. Allocation, access, and freeing must
agree on the same layout. Pool block size may exceed logical layout size; inline
properties must remain at their typed field offset.

Preserve these contracts:

- Callable proxies share the `builtin_fn_index` offset with function payloads.
- Arrays and arguments have different payload requirements; arguments include
  their mapped-parameter bits.
- GC and reference-count traversal visit the correct class-specific fields.
- Pool fallback, pool bypass, reset, and destruction use matching sizes and
  ownership rules.
- Initialization preserves required JavaScript values: zeroed `TVal` storage is
  not an undefined value.

Add compile-time checks for common-prefix compatibility, relevant field offsets,
alignment, and the callable-proxy contract in both value representations.

### Pool organization

A pool's block size is the largest logical layout it serves. A pool page is `calloc`ed
and only touched blocks become resident, so an extra size class costs virtual address
space (64 KB at capacity 512) rather than baseline RSS: baseline RSS stayed flat when
the array pool block dropped from 216 to 128 bytes.

| Pool | Block | Classes |
|---|---:|---|
| plain | 112 B | OBJECT |
| gs | 96 B | GETTER_SETTER |
| array | 128 B | ARRAY 120 B, ARGUMENTS 128 B |
| small | 152 B | REGEXP 136 B, PROMISE 152 B, ERROR 120 B, primitives 120 B, GENERATOR 144 B, ARRAYBUFFER 144 B, typed arrays 144 B, HOST, WRAP_FOR_VALID_ITERATOR, and the plain iterators at 128 B |
| func | 192 B | FUNCTION, PROXY |
| big | 216 B | TEMPORAL_* 216 B, ITERATOR_HELPER 200 B |

Classes move into `small` one at a time as their payload access is audited. The GC
mark switch and the teardown path are already gated on the object class, so a class
whose payload fits the block can be routed there without changing its accessors.

Treat duplicate clearing as a separate follow-up experiment so its effects can
be measured independently of layout changes.

## Implementation checklist

- [x] Read C3 layout and pool references; measure representative typed layouts.
- [x] Identify pool-size mismatch and `NONANBOX` assertion failure.
- [x] Record timings, allocation counts, and memory for retained and churn workloads.
- [x] Define shared layout machinery and compile-time invariants.
- [x] Implement compact getter/setter, array, and arguments layouts with suitable pools.
- [x] Audit payload access, inline properties, GC, freeing, fallback allocation,
  heap reset, and pool bypass for the migrated classes.
- [x] Validate correctness and report measured results before expanding scope.
- [x] Extend the same machinery to functions, promises, RegExp, and the remaining
  classes whose payload fits the `small` pool.
- [x] Stage 1: move class-specific metadata out of the common header. `coll_hash`
  moved; the dense-part counts and the 16-bit packing are closed with reasons.
- [x] Stage 2: share prototype and property names across objects with the same shape.
  Property names are already shared; moving the prototype is closed with reasons.
- [x] Size pool pages to the allocator's size class, which is what makes block-size
  changes visible in peak RSS.
- [ ] Evaluate single-clear allocation separately.
- [x] Update `docs/architecture.md` for the accepted design and commit validated
  stages with results recorded here.

## Follow-on stages

Both stages below come out of the measurements in "Results". The retained-array
profile marks each object 17.9 times per allocation, so the mark pass -- not
allocation size -- is the remaining cost centre, and both stages reduce what a mark
has to touch per object. Stage 1 is safe and local; stage 2 is an object-model
change and is gated on stage 1's results.

### Stage 1: class-specific metadata out of the common header

`HObjectBase` is 80 bytes and holds four fields that only some classes read:

| Field | Bytes | Read by | Verdict |
|---|---:|---|---|
| `coll_hash` | 8 | MAP, SET, WEAKMAP, WEAKSET | done (142d1316), plus the stride fix in 9dac3b71 |
| `array_size`, `array_used` | 8 | classes with a dense part | not worth doing, see below |
| `shape_id`, `prop_capacity` | 8 | every class | not worth doing, see below |

`coll_hash` landed: no non-collection path reads it, so moving it cost nothing but
a class check on teardown. The other two are not worth their risk, for measured
reasons rather than guessed ones.

**Dense-part counts.** They would move into the payload of every class with a dense
part, and ARRAY is one. An array's payload is the 8-byte `array_length` slot today;
adding `array_size` and `array_used` makes it 12 bytes and, with padding, 16, so
every array grows by 8 bytes while classes without a dense part shrink by 8. Arrays
are the most common object in JavaScript, and the counts are read from the hottest
path in the engine (`array_part()`, element reads and writes). Trading a larger
array for a smaller function is the wrong direction, and the 8-byte delta is
invisible in RSS on the workloads measured.

**Packing `shape_id` and `prop_capacity`.** `shape_id` appears in 133 places across
the VM, including the inline-cache keys and the bytecode that encodes them, so a
16-bit shape id is a change to the IC format and to the shape table's lifetime
rules, not a header tweak. It buys 4 bytes per object, which the measurements above
cannot resolve, and it needs an overflow fallback for both fields.

### Stage 2: shared shape

The premise needs correcting before anyone implements it. Property *names* are
already shared: each object stores a `shape_id`, the shape holds the ordered
`ShapeProperty` keys, the shape chain has a shared key-to-index hash table, and the
per-object storage is values only. The V8 and JSC property-name sharing this stage
was meant to add is already here.

What remains is the 8-byte `prototype` slot. Moving it into the shape means every
prototype read becomes `shapes[shape_id].prototype`: an extra dependent load on
every property miss, every `instanceof`, and every method dispatch, in exchange for
8 bytes per object. The measurements in this plan say an 8-byte-per-object change is
worth nothing measurable on their own, while the property-miss path is the hottest
code in the engine. `Object.setPrototypeOf` would also become a shape transition,
and a shape id of zero would need a prototype fallback that costs the 8 bytes back.

V8 and JSC reach 12 to 16 byte objects by keeping the prototype in a *pointer* they
already load, not behind an index they must look up, and V8's 4-byte map pointer only
works because pointer compression makes every pointer 4 bytes. Neither trick is
available here: pointer compression caps the heap at 4 GB and does not fit the
low-powered targets this engine is built for. Stage 2 is therefore closed as
described, with the object-model rewrite it would need recorded as a separate
question rather than a follow-on to this plan.

## Validation and acceptance

Run focused fixtures for dense and sparse arrays, mapped arguments, accessors,
inline-property growth, callable proxies, and GC lifetime behavior. Use the local
suite, Rosetta, and relevant narrow test262 directories. Rebuild ASAN before
testing; exercise both production pooling and pool-bypass allocation. Build and
validate the `NONANBOX` representation after fixing the layout assertion.

Compare repeated release-build runs against an unchanged baseline. Measure
allocation-heavy and retained-object workloads alongside the existing benchmark
suites. Include peak memory and small-heap baseline memory so pool reservation
does not hide the cost of additional size classes.

Accept the change only with correctness preserved and a useful measured memory
or performance benefit without material regressions elsewhere. Report experiment
results before proceeding to another optimization. No speedup is established by
the layout probe alone.

## References

- C3 skill: `/Users/rtomasi/.agents/skills/c3-lang/SKILL.md` and its advanced and
  stdlib references.
- [C3 structs and unions](https://c3-lang.org/language-common/structs-and-unions/).
- Installed C3 0.8.3 stdlib: `std/core/mem_mempool.c3`, especially
  `FixedBlockPool.init`, `init_for_type`, and `alloc`.
- `src/hobject.c3`: object payloads, layout constants, allocation, property
  accessors, and pool selection.
- `src/heap.c3`: pool initialization, reset, and destruction.

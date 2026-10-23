# 105: Object shapes, cache storage, and allocation experiments

Status: researched and prioritized; optimization implementation has not started.

This plan applies the object-model literature linked from Max Bernstein's
[Objects, attributes, maps, oh my!](https://bernsteinbear.com/blog/object-shapes/)
to Boomkat. It records the current implementation, a metadata census, explicit
hypotheses, proposed experiments, and the limits of transferring results from
JIT-based systems to an embedded interpreter. The additional tentative
optimizations are candidates to investigate, not commitments to implement.

Research baseline: `ac02b1a8`, inspected on 2026-10-23. Recheck source and
overlapping work before implementation. The `plans/archive` branch stores this
document; its engine sources need not match the research baseline. Resolve
source references against that baseline or a fresh implementation checkout.

## 1. Objectives and ordering

Reduce persistent metadata, object allocation cost, and property-access work
while preserving supported JavaScript semantics, small-heap behavior, and
portability. A useful memory saving is an acceptable outcome even when execution
time is unchanged. A speed improvement needs its memory cost recorded.

Start with R0's bounded instrumentation and R1's cache experiments. Continue
with R2 or R3 according to measured cache traffic and object populations. R4-R6
require their own opportunity measurements. Explore T1-T10 only where their
trigger conditions hold.

| ID | Experiment | Initial priority | Principal evidence needed |
|---|---|---|---|
| R0 | Cache, shape, and allocation census | First | Costs by source site and miss cause |
| R1 | Compact cache records and allocate by consumer | Highest | 208 cache bytes per instruction position today |
| R2 | Optional two/four-entry own-property PIC | High if hot sites alternate layouts | Local misses that the shared cache answers |
| R3 | Allocation layouts for selected five-to-eight-field objects | High for retained object workloads | Overflow allocations and actual pool charges |
| R4 | Separate cache validity conditions | Medium | Collateral misses after unrelated mutations |
| R5 | Construction-graph and descriptor-layout sharing | Medium | Retained intermediate nodes and private clones |
| R6 | Guarded operation fusion and local shape propagation | Medium; coordinate with 104 | Repeated dispatches/checks in hot sequences |

No optimization is accepted solely because it improves a synthetic benchmark
or resembles a successful JIT technique. Preserve a rejected or inconclusive
experiment's measurements and explanation.

## 2. What Boomkat already implements

### 2.1 Logical shapes and property storage

`src/hobject.c3` and `src/heap.c3` already implement shared property layouts,
shape transitions keyed by parent/key/flags, inline values, property caches,
and a heap-wide megamorphic cache. Property names and descriptor flags live in
shapes; ordinary object property storage contains values.

Transition shapes contain incremental segments. Adding a property does not
copy the entire preceding property map. Shared shapes acquire lookup hashes
on demand; solitary large objects use private dictionary shapes. The inspected
thresholds are eight properties for hashing and 64 for solitary dictionary
conversion. Shape collection retains live objects' ancestors and pinned shapes'
ancestors and can recycle unused shape IDs.

Most ordinary object layouts have four inline named-property slots. Arrays
have a separate layout with zero inline named slots, and a specialized short
array-literal allocation already exists. Named and indexed storage can share a
backing block, so changing its named section can move indexed values too.

An important invariant: a shape identifies a logical property layout, not an
absolute physical field offset or a JavaScript class. Objects of different VM
classes or with different prototypes may share a shape. A cache that embeds a
physical address or byte offset needs the corresponding storage/layout guards.

### 2.2 Existing compiler and construction optimizations

`src/compiler/literals.c3` recognizes eligible constant-key literals, builds
their complete shared shape, pins the leaf, and emits `NEWOBJ_SHAPE` plus
`INIT_SLOT`. It already avoids runtime transition lookup for these literals.
Indexed keys, duplicate keys, computed/spread/accessor cases, and portable
bytecode impose additional eligibility limits. The known shape still normally
uses the ordinary object allocation and an external property block beyond four
slots.

`src/vm/vm_calls.c3` recognizes simple constructors with up to four parameter
stores and validates warmed absent-property caches before direct initialization.
Some immediate object/scalar and constructor/getter cases already avoid ordinary
allocation or activation work. JSON serialization already has shape plans.
Investigate the remaining cases instead of adding parallel versions of these
optimizations.

### 2.3 Cache behavior and validity

`ICEntry` is monomorphic and includes a four-link prototype-chain snapshot.
Own-property hits resolve the current receiver's property storage. Absent-store
entries can skip transition lookup after validating the full recorded chain
and its terminator. The 512-entry shared megamorphic cache handles own and
immediate-prototype properties; it does not cover arbitrary deeper chains.
Computed property names introduce key polymorphism as well as shape polymorphism.

`VarICEntry` caches environment resolution, may hold a raw slot pointer, and
includes up to four environment-rearming records. The heap-wide recycle epoch
protects more than ID reuse: storage/flag changes on bound objects can advance
it. `grow_props` also bumps the generation of the shared shape whose object
grew. These mechanisms are correctness protections, but their scope may exceed
the requirements of individual cache kinds.

`CompiledFunction.alloc_caches` allocates and clears both cache arrays with
`code_count` entries. The threaded dispatcher derives a cache address directly
from the instruction address, avoiding an index-table load. Consumers include
declarations, calls, and construction, not just opcodes named GET/PUT.
The collector scans property-cache arrays for cached prototype owners, while
variable caches have weak-reference pruning and separate invalidation rules.

### 2.4 Constraints affecting the literature's applicability

The default `TVal` is already eight bytes through NaN-boxing; `NONANBOX` uses
16 bytes. Storing an unboxed double does not automatically save an eight-byte
slot in the default build. Boomkat has no optimizing JIT to amortize arbitrary
type-maintenance costs through generated code. Independent runtimes own
thread-confined heaps and exchange copied data; the shared-heap synchronization
papers do not motivate adding object locks to this design.

## 3. Measured starting point

### 3.1 Method and limitations

A temporary CLI hook reports metadata before normal CLI completion. It uses
the current engine sources without changing production source. The build is
C3 0.8.5, LLVM 23.1.3, arm64 macOS, O2, size optimization, single module,
relaxed FP, and `THREADED_DISPATCH`, `PRINT`, `CONSOLE` features.

Artifacts are retained in [105-object-shapes-and-cache-economics/](105-object-shapes-and-cache-economics/):

- `metadata.json`: exact baseline, compiler output, and workload hashes.
- `results.json`: the original six diagnostic runs, including stdout/stderr.
- `recheck-metadata.json` and `recheck-results.json`: a fresh build/run using
  the archived reproduction script; all six workloads completed successfully.
- `probe.c3`: the metadata hook appended to a temporary CLI copy.
- `run_probe.py`: recreate the diagnostic build from a selected engine checkout
  or run an already-built diagnostic binary.

These are end-of-run metadata measurements, not performance comparisons or a
peak/live-heap composition profile. Requested bytes exclude allocator rounding,
pool slack, and resident-memory behavior. Shape accounting excludes the shape
pointer table, retained key strings, and per-object property hashes.

The original hook labels functions with allocated IC arrays `executed` and
their instruction positions `executed_instructions`. Interpret these as
**cache-bearing functions and static instruction positions**, not dynamic
instruction counts or proof of function invocation. Some optimization helpers
can allocate another function's caches. A populated-property record has a
non-null key; a populated-variable record has a non-null slot pointer. GC
pruning and cache replacement affect these snapshots. An empty record is not
proof that its instruction can never need a cache.

The fresh build reproduces type sizes and cache allocation totals for all six
workloads. The scene run ends with 20 populated property records instead of
19, with one additional prototype entry. TypeScript ends with four fewer
populated own-property records. Timing-dependent paths and cache population
make those snapshots variable; the reserved-byte calculation does not depend
on them. The archived raw runs retain both observations.

### 3.2 Type sizes and cache allocation

| Type | Bytes in this build |
|---|---:|
| Instruction | 4 |
| ICEntry | 88 |
| VarICEntry | 120 |
| Shape header | 56 |
| ShapeProperty | 16 |
| TransitionEntry | 24 |
| HObjectBase | 88 |
| PropValue | 8 |

The current policy reserves 208 cache bytes for each four-byte instruction
position once a function acquires caches: 52 times the instruction bytes,
before constants, debug metadata, or other function state. It allocates once
per compiled function's cache lifetime, not once per call or loop iteration.

| Workload | Cache-bearing instruction positions | Cache bytes | Populated property records | Populated variable records |
|---|---:|---:|---:|---:|
| Monomorphic IC | 50 | 10,400 | 5 | 5 |
| Prototype IC | 66 | 13,728 | 10 | 9 |
| Richards | 1,181 | 245,648 | 239 | 147 |
| DeltaBlue | 1,981 | 412,048 | 384 | 217 |
| Scene churn, 100k nodes | 498 | 103,584 | 19 | 62 |
| TypeScript | 71,356 | 14,842,048 | 13,592 | 3,513 |

For TypeScript, the associated bytecode is 278.7 KiB and the cache arrays are
14.15 MiB: 5.99 MiB property caches and 8.17 MiB variable caches. At exit about
19.0% and 4.9% of those records are populated. Of populated property records,
11,415 describe own properties, 986 prototype properties, and 1,191 absent
stores. These are static record counts, not access-frequency percentages.

The same run reports 13,980 live shape records, with 1,121,104 requested bytes
for shapes and their property capacity, 1,508,864 for shape lookup hashes, and
786,432 for the transition table: about 3.26 MiB under this partial accounting.
Cache arrays therefore deserve attention before a wholesale shape redesign.
The small-script runs also retain roughly 678 shapes; use R0's empty-runtime
census to distinguish intrinsic initialization from application layouts.

### 3.3 Comparison with other interpreters and engines

Source inspection on 2026-10-23 gives these representative base payloads. Other
engines were not built for this comparison, and total engine memory cannot be
inferred from these entries. Headers, shared metadata, generated code, and
additional cache objects are outside the tabulated payloads.

| Engine | Representative payload and allocation policy | Primary source |
|---|---|---|
| QuickJS-NG | Ordinary named `get_field` performs shape/property lookup and prototype traversal without a persistent per-site IC array; shared shapes still consume memory | [quickjs.c](https://github.com/quickjs-ng/quickjs/blob/master/quickjs.c) |
| Hermes `static_h` | Read cache: 12 B with compressed pointers, 24 B on uncompressed 64-bit; write cache: 8 B / 16 B. Indexed read/write arrays; property-add payloads stored separately | [C mirror layouts](https://github.com/facebook/hermes/blob/static_h/include/hermes/VM/sh_mirror.h), [property caches](https://github.com/facebook/hermes/blob/static_h/include/hermes/VM/PropertyCache.h), [allocation](https://github.com/facebook/hermes/blob/static_h/lib/VM/CodeBlock.cpp) |
| V8 | Common property feedback uses two tagged slots: 8 B compressed, 16 B on uncompressed 64-bit. Relevant operations request slots; polymorphic arrays and handlers add memory | [slot sizes](https://github.com/v8/v8/blob/main/src/objects/feedback-vector-inl.h), [feedback payloads](https://github.com/v8/v8/blob/main/src/objects/feedback-vector.cc), [tagged sizes](https://github.com/v8/v8/blob/main/include/v8-internal.h) |
| CPython 3.14 | LOAD_ATTR reserves 18 B, STORE_ATTR 8 B, LOAD_GLOBAL 8 B. Cache words belong to selected opcodes rather than every instruction | [cache structures](https://github.com/python/cpython/blob/3.14/Include/internal/pycore_code.h) |

Hermes's sizes follow from the declared C mirror layouts and matching C++
assertions. Its normal bytecode cache counts are bounded; lazy CodeBlocks can
reserve the maximum. V8's pair can refer to separately allocated structures;
an eight-byte pair is not the entire implementation of a prototype or PIC
case. These distinctions matter more than a single bytes-per-site ranking.

## 4. R0: bounded diagnostics and an opportunity profile

Hypothesis: a small number of sites and object populations account for most
cache misses, overflow allocations, and useful shape specialization.

Collect static cache eligibility after all bytecode transforms, separating
property, variable, combined, and no-cache consumers. Count reservation,
population, and high-water bytes separately. Distinguish function-entry
allocation from compilation and cache warmup.

In an opt-in diagnostic build, record sampled site hotness and bounded receiver
shape/key distributions, local hits, megamorphic hits, generic lookups, chain
depth, and refusal reasons. Attribute shape mismatch, ID recycling, storage
movement, descriptor changes, prototype mismatch, dictionary/exotic refusal,
and computed-key churn separately. Avoid a second unbounded per-PC metadata
system merely to profile the first one. Count allocations before timing code
paths; use sampling or bounded heavy-hitter tracking for site details.

For objects, collect class, field count, capacity, allocation site, overflow
bytes, growth/copy counts, and retained versus transient populations. For
shapes, collect direct users, ancestor-only retention, sharing, transition
out-degree, hash bytes, private/dictionary counts, and descriptor operations.
Identify built-in startup cost with an empty script and a minimally initialized
embedding runtime, not by subtracting two unrelated processes' RSS.

Use existing source maps to report file/function/line/column with the hot
operation and its failed assumption. Group sites by constructor/allocation
site when appropriate. Keep reports actionable: intentional polymorphism and
cold instability should not dominate a warning list.

Deliverable: a compact opportunity table giving estimated removable work,
metadata costs, and the workload supporting each next experiment. These
estimates select experiments; they are not speedup predictions.

## 5. R1: compact and selective cache storage

Hypothesis: cache density and worst-case record size cause substantially more
memory, initialization, and GC scanning work than common cases require.

Run a two-by-two comparison so density and record layout can be evaluated
independently:

| Variant | Addressing/allocation | Record representation |
|---|---|---|
| A | Existing full PC-indexed arrays | Existing records |
| B | Full PC-indexed arrays | Compact common records plus optional cold payload |
| C | Packed arrays for real consumers | Existing records |
| D | Packed arrays for real consumers | Compact records plus optional cold payload |

### Representation candidates

For property caches, keep the common own-property guard, slot, and necessary
key information compact; move prototype-chain and absent-store payloads to
optional blocks. A 24-32-byte common record is a design target to measure, not
a guaranteed final size. Constant-key sites may not need a retained duplicate
key, but construction, computed-key, declaration, and fused users must be
audited before removing it.

For variable caches, separate direct binding hits from the less common
environment-rearming chain. Preserve owner lifetime, flags, search-head and
resolution checks. R0 must establish which fields can leave the common record
without adding more hot loads than the smaller working set saves.

Packed arrays can use a 16-bit per-PC index with an explicit large-function
fallback, or a wider map where needed. Also evaluate opcode-encoded indices
where an encoding already has space. Preserve constant/register/jump ranges
and account for bytecode expansion. A property/variable union is only valid
after proving which instructions require both families.

A per-function "uses this cache family" decision is an inexpensive first
candidate. It needs an allocation-state indicator independent of a non-null
property-array pointer: current entry paths use that pointer to distinguish
warm functions. Functions legitimately requiring no arrays must not allocate
repeatedly or lose lean-call eligibility.

### Dependencies and correctness

Audit threaded address biasing, switch paths, simple constructors, getters,
declarations, fused calls, diagnostics, function teardown, retained keys,
prototype roots, variable-cache pruning, heap reset, and allocation failure.
Index maps must reflect the final instruction stream after fusion, NOP
compaction, wide decoding, and inline expansion. Portable images need a
heap-independent description or reconstruction rule.

Optional blocks must not become one small allocation per access site without
measuring allocator overhead. Try arena/slab allocation per function or cache
kind where appropriate. Preserve the existing fallback if cache allocation
fails; establish failure behavior for partially allocated metadata.

### Measurements and decision

Measure compiled/cold functions, first call, steady-state monomorphic loops,
prototype loops, large bundles, TypeScript, Richards, DeltaBlue, scene churn,
and short embedding invocations. Record requested bytes, RSS, allocation and
clear counts, collector cache-scan work, dispatches, and binary size.

Success means a useful measured memory reduction with acceptable time costs;
record configurations that trade throughput for a tiny-build memory budget.
Reject an addressing strategy if the extra dependent index load consistently
outweighs its working-set reduction on target workloads. The data may favor B
for speed and D for constrained targets rather than a single universal mode.

## 6. R2: small adaptive polymorphic caches

Hypothesis: some hot constant-key sites alternate between two to four stable
layouts and repeatedly take `th_get_shared`, despite the shared cache being
able to answer the access.

Start with ordinary own-data-property reads and two accepted shapes. Allocate
the extension only after observed useful instability and sufficient hotness.
Preserve the first monomorphic comparison as the common path. Measure a
four-entry option separately, cap attachment, and fall back to the existing
shared cache instead of growing indefinitely. Coordinate its payload with R1.

Sweep 1/2/4/8/32 shapes, alternating/clustered/random receiver order, same and
different field offsets, and stable versus changing value types. Distinguish
many instances sharing one shape from true layout polymorphism. Exercise
computed keys separately; a shape-only PIC is insufficient for them.

Count local misses, PIC hits, shared-cache hits/collisions, full lookups, and
attachment/eviction costs. Check Richards and DeltaBlue for end-to-end benefit.
Do not attribute every local miss to an expensive property-table search.

Semantic cases include same shape with different prototypes and object classes,
storage growth, shape reuse, descriptor changes, accessors, proxies, strict
stores, and GC between fill and hit. Extend to writes or prototype reads only
after the own-read experiment establishes a benefit. A no-benefit result on
already-cheap shared-cache traffic is a complete experimental outcome.

## 7. R3: allocation-site-appropriate object storage

Hypothesis: selected objects with five to eight properties pay avoidable
allocation and indirection costs after exceeding four inline slots.

### Known literals

Prototype one additional ordinary-object allocation layout for six or eight
inline values, selected for compiler-known literals. Compare it with a
variable-size trailing-slot allocation. Retain the current allocation for
small generic objects. The scene graph's six-field node is a motivating case;
its three-field style objects and two-field vectors must not all grow.

Record actual pool/block/page charges, including unused original inline space,
overflow size-class rounding, allocation count, GC traversal locality, and
steady retained footprint. A larger logical object does not necessarily mean
a larger total allocation; the converse also holds because of allocator and
cache geometry.

An explicit physical-layout contract must cover property access, growth,
marking, freeing, pool bypass, fallback allocation, and reset. Shared logical
shape IDs must not silently imply one physical layout. Object addresses stay
stable. Initialize every GC-visible value correctly before publication or a
safepoint; zero bits are not a general substitute for JavaScript `undefined`.

### Constructor capacity prediction

Before assigning ordinary constructors a predicted final shape, test reserving
capacity at allocation. A bounded allocation-site estimate can avoid growth
without changing which properties exist or the order of writes. Compare exact
last size, capped high-water, and conservative estimates on stable and bimodal
sites. Count wasted capacity and predictor memory alongside saved copies.

Do not move or insert source assignments. Constructors can leak `this`, invoke
prototype setters, enumerate properties, take branches, and throw partway
through initialization. Existing simple-constructor recognition provides a
separate, already guarded opportunity to extend only if profiling identifies
its current field-count limit as significant.

### Decision matrix

Test 0/1/2/4/5/6/8/9/16 properties; retained and churn populations; ordinary,
frozen, and subsequently grown objects; plus scene churn, JSON payloads, and
real-library workloads. Test both `TVal` representations and constrained-heap
startup cost. Avoid a global `INLINE_PROPS=8` decision before establishing
field-count distributions and regressions for small objects.

## 8. R4: validity tokens with specific responsibilities

Hypothesis: storage movement and unrelated shape activity cause collateral
cache invalidations that do not reflect a changed lookup result.

First inventory all consumers of shape generation, recycle epoch, binding
invalidation, raw slot pointers, and cached descriptor flags. Distinguish:

| Assumption | What can invalidate it |
|---|---|
| A shape ID still names the same layout | Shape destruction/reuse and heap reset |
| A property index/flags describe the receiver | Structural or descriptor mutation, including mutable dictionaries |
| A raw slot address remains valid | Backing-storage relocation and owner lifetime |
| A name resolves to the same binding | Eval, shadowing, scope/prototype changes, deletion/redeclaration |
| A prototype lookup has the same path/owner | Changes to any relevant chain object or link |

Index-based own-property caches already re-resolve current backing storage.
Test whether their validity can avoid shape-wide invalidation on one object's
growth after auditing all raw-pointer users. Keep lifetime/recycling protection
and mutable-shape semantics. An object's transition during growth can make
many generation bumps irrelevant in practice; count the affected live sites
before prioritizing a redesign.

Coordinate binding-resolution generations with plan 104 T3. Its eval-induced
resolution changes are distinct from storage and ID lifetime. Lazy semantic
invalidation does not replace weak-cache pruning. Specify wraparound and reset
behavior and update every reader in one consistent change.

Use a hot stable reader while unrelated objects grow, change descriptors,
enter dictionary mode, or produce/recycle many shapes. Add env-storage growth,
eval/with/TDZ, global deletion/redeclaration, reentry, and heap-reset cases.
Accept only if false misses and measured runtime fall without weakening any
semantic or lifetime check.

## 9. R5: construction graphs, hashes, and descriptor sharing

Hypothesis: some shape metadata represents cold construction prefixes or
repeated descriptor operations rather than layouts serving enough live objects
to justify its cost.

R0 must separate direct shape users from ancestor-only retention. Known literal
leaves pin their full ancestry today. Experiment with interning a complete flat
layout for eligible literals, keyed by ordered property keys and flags, and
compare the saved headers/transitions with lost prefix sharing and hashing
cost. Preserve property order, descriptor identity, key ownership, and portable
image reconstruction. A hash lookup is not required on every literal allocation
once compilation has interned the layout.

Profile creation and lookup of repeated sealed/frozen layouts. Test one shared
batch descriptor transformation for equivalent shapes before creating a
private clone per instance. Avoid repeated per-property chain replay with
quadratic construction work. Existing small-chain flag retransition already
shares some descriptor changes, so identify the remaining cases first.

For broader allocation-site final-layout prediction, preserve the distinction
between an absent property and an own property whose value is `undefined`.
The embedded-VM paper introduces an absence sentinel for precisely this reason.
Such prediction would affect get/has/ownKeys/descriptors/prototype behavior,
deletion, GC, and IC assumptions. Capacity prediction in R3 is the smaller
initial experiment. Preserve hot intermediate shapes when many objects stop
there; preallocating every rare final layout can increase memory.

Measure all shape-related components. In the TypeScript census, shape hashes
cost more than the shape records themselves, so reducing node count alone may
miss the largest component. Revisit hash thresholds or representation using
lookup frequency, sharing, build cost, and dictionary behavior, not solely
field count. Retain a general fallback for profile mismatches and dynamic code.

## 10. R6: guarded operations and local shape propagation

Hypothesis: small hot sequences spend measurable time on repeated dispatch and
redundant checks that one guarded operation can perform more cheaply.

Use profile-selected own-field load/predicate or two-field numeric sequences
first. Guard object kind, layout/descriptor assumptions, and current value
types as needed, then perform the operation. Share a validated receiver/shape
within a sequence only while no intervening action can mutate it or run user
code. Preserve existing reference-count and GC publication requirements.

This is a bounded interpreter counterpart to shape propagation; it does not
require attaching a type to every property write. A read cache must reload the
current value. A cached method owner or slot does not prove the function's
identity remains constant.

Coordinate with plan 104 T5 and the existing fusion/CSE passes. Refusal must
occur before an observable effect or have a precise continuation after the
completed portion. Accessors, coercions, calls, stores through aliases,
exceptions, jump targets, and suspended execution limit fusion boundaries.

Measure dispatch/check reductions, threaded versus switch execution, added
bytecode/cache metadata, binary size, compile time, and runtime. Plan 104's
inliner measurements demonstrate that avoiding calls can still lose badly
when interpreted bookkeeping and initialization increase. Require actual
removed work and representative release-build gains before extending scope.

## 11. Additional tentative optimizations

### T1: prototype validity cells or bounded watchpoints

Trigger: hot inherited accesses spend significant time replaying stable chains.
Hypothesis: validating a receiver/link guard and a compact dependency token is
cheaper than checking several prototype identities and shapes on every hit.

Compare existing replay with a simple prototype-mutation epoch and a bounded
dependency scheme. Register only relevant dependencies and include dictionary
mutations, shadowing, deletion, descriptor changes, and changed prototype links.
Do not advance a global token on every fresh object's prototype initialization:
that can invalidate all readers during ordinary allocation. Account for receiver
prototype changes even when its shape does not change. Measure dependency
memory, mutation fan-out, stale registrations, GC lifetime, and write-heavy
regressions. Avoid moving the prototype into the shape merely to implement this.

### T2: explicit negative read caches

Trigger: repeated optional/missing-field reads perform full chain searches.
Hypothesis: an absence result is stable enough to cache profitably.

Start with constant names and ordinary non-dictionary objects. A negative read
needs the entire relevant chain and null terminator protected, including same-
shape receivers with different prototypes. Reuse validity machinery where its
proof applies; the existing absent-store cache also proves write conditions,
so it is not an interchangeable negative-read result. Test addition at every
chain depth, setPrototypeOf, delete/re-add, dictionary changes, proxies, and
missing versus present-undefined. Count the memory and comparison cost of the
negative case against simply performing the lookup.

### T3: share actions across accepted shapes with the same slot

Trigger: PIC cases differ in shape ID but use the same physical operation.
Hypothesis: several accepted shape guards can share one load/store action,
reducing duplicated payload or dispatch work.

Retain explicit acceptance of each layout and all key/descriptor/storage-mode
conditions. A matching numeric slot by itself proves nothing about which key
or accessor lives there. Compare action sharing with a normal two-entry PIC;
drop it if extra indirection or classification exceeds the metadata saving.

### T4: adaptive dictionary and hash policies

Trigger: many single-use prefixes, per-object hash allocations, or dictionary
lookups dominate memory/time. Hypothesis: sharing likelihood and mutation
history predict a better choice than a single property-count threshold.

Sweep existing thresholds first. Then test bounded allocation-site feedback or
hysteresis that avoids oscillation and retains a cheap generic path. Include
large repeated records as well as truly unrelated request-key dictionaries:
early dictionary conversion can sacrifice useful sharing. Count key retention,
hash rebuilds, private-shape copies, deletion churn, and peak metadata. Retain
current shape-ID-reuse and negative-lookup correctness protections.

### T5: reuse enumeration metadata

Trigger: repeated Object.keys/ownKeys or similar enumeration rebuilds the same
key list for many ordinary objects sharing a layout. Hypothesis: a shared
ordered-key plan amortizes collection work.

Cache only the portion proved stable by the layout; create the required fresh
JavaScript result array on every call. Account for integer-index ordering,
symbols, enumerable flags, dictionaries, deletions, and exotic ownKeys.
for-in additionally depends on prototypes, shadowing, and mutation during
iteration and should be a separate extension. Measure retained key/plan bytes.
Inspect existing JSON plans before introducing overlapping caches.

### T6: compact or prebuilt intrinsic layout descriptions

Trigger: an empty-runtime census shows significant intrinsic shape startup cost
on a constrained target. Hypothesis: complete built-in layout descriptions can
reduce transitional nodes, initialization work, or writable metadata.

Start with runtime-created flat/interned layouts. A later deployment-specific
variant can place immutable descriptions in read-only storage or flash, with
runtime-owned keys and mutable state outside them. Portable bytecode must not
serialize heap pointers or native shape IDs. Preserve realms, conditional
features, property order, and observable modification of built-ins. Measure
flash/image size, startup RAM, relocation/lookup costs, and per-runtime copies.
This is distinct from assuming all applications have a fixed offline profile.

### T7: narrow numeric collection strategies

Trigger: homogeneous numeric buffers are common and element checks or GC
scanning are measured costs. Hypothesis: selected backing stores can avoid
unnecessary element interpretation or use narrower integer storage.

An unboxed double still occupies eight bytes in the default representation;
justify it through removed checks/mark work, not an assumed size reduction.
An int32 strategy has a potential storage saving but needs widening for the
engine's wider fast integers and general Number values. Account for holes,
explicit undefined, indexed prototype properties, length mutation, negative
zero, NaN, infinities, conversions, and generic transitions. Preserve aliases
and iterators when replacing backing storage. Count promotion frequency and
copied bytes; reject strategies that repeatedly convert small mixed arrays.

Type-segregated heterogeneous stores with an extra index map are lower
priority: Boomkat's existing one-word values weaken the main boxing argument,
while the extra map and element indirection remain. Compare with explicit
TypedArray use where the host application can choose it without changing
JavaScript Array semantics.

### T8: bounded cache lifetime and memory budgets

Trigger: long-lived compiled functions retain cold cache payloads or obsolete
prototype owners. Hypothesis: bounded cold-payload reclamation or a runtime
cache budget reduces retained memory at acceptable rewarming cost.

Measure which cache references keep owners alive. Preserve current strong
rooting and weak-reference rules unless a complete replacement lifetime proof
is implemented. Clear retained keys and owner references with their required
ownership operations. Prototype pointers and weak chain snapshots must never
be dereferenced after collection merely because an old shape ID matches.
Test phase-changing applications, GC between fill/hit, and tiny heaps. Budget
exhaustion must retain correct generic execution, not prevent program progress.

### T9: eliminate provably duplicate initialization

Trigger: allocation profiles show repeated clearing of the same storage.
Hypothesis: an explicit initialization contract can remove one clear pass for
selected fully initialized object layouts or cache blocks.

Plan 091 already identifies pool clearing plus object initialization as an
open measurement. Separate fresh bump blocks, recycled blocks, pool bypass,
and fallback allocation. Every traced field and visible JavaScript value must
be initialized before GC/reentry or publication; exceptions during literal
initialization still require a safely traversable object. Measure bytes written,
allocation time, and write-heavy/cache effects, with ASAN and both value modes.

### T10: shape-aware coaching for application authors

Trigger: source-level shape instability is both hot and avoidable by the
application author. Hypothesis: a small actionable report can recover more
performance per engine byte than adding general optimization machinery.

Report hot sites, observed layout sequences, conflicting construction orders,
late property additions, and the cache consequence. Group causes across sites
and suppress cold/intentional polymorphism. Suggest consistent construction
only as an author-reviewed change. In JavaScript, inserting an undefined-valued
property changes own-property and enumeration behavior, and reordering stores
can change effects. No source transformation follows automatically from a
coaching suggestion. A text/JSON report is sufficient for the first experiment.

## 12. Existing work and decisions to preserve

- [091-object-layout-optimization.md](091-object-layout-optimization.md):
  class-specific payloads/pools, actual allocator sizing, and pool-stride
  measurements. A global no-inline-property experiment made the two-field
  ordinary-object workload about 44% slower and increased its peak RSS about
  14%. Moving the prototype into shapes and naive 16-bit shape-ID packing are
  closed there with explicit costs; reopening either needs new evidence.
- [099-engine-architecture-investigation.md](099-engine-architecture-investigation.md)
  and the current `test/benchmarks/architecture-investigation/frames-array-layout/`
  report: compact arrays already trade named-property speed for retained array
  memory. A two-slot array variant was measured. Do not repeat a global array
  slot change as though it were untested.
- [104-optimization-plan.md](104-optimization-plan.md): T3 binding-resolution
  invalidation and T5 operation fusion overlap R4/R6. Coordinate interfaces,
  measurement, and implementation instead of duplicating work. Its guarded
  inliner measurements warn against code and bookkeeping growth.
- [102-ast-optimization-investigation.md](102-ast-optimization-investigation.md):
  local shape/value propagation and scalar replacement may share compiler
  analysis prerequisites. The cache-storage experiment need not wait for a
  complete AST optimizer.

Default deferred choices: broad typed shapes/type freezing, prototype-in-shape
object-model replacement, shared-heap synchronization, and general JIT data
structures. Reconsider only with a specific workload and a measured budget.

## 13. Measurement and correctness protocol

### Reproduction and artifacts

Reproduce the archived census from an engine checkout matching the baseline:

```sh
python3 /path/to/plans/105-object-shapes-and-cache-economics/run_probe.py \
  --repo /path/to/boomkat --out /tmp/boomkat-shape-census
```

The script builds a diagnostic-only CLI under the output directory. It never
edits the selected repository. An explicit diagnostic binary can be supplied
with `--binary`. Do not pass a normal CLI and interpret absent counters as zero.

Keep implementation measurement artifacts in a per-experiment directory under
`test/benchmarks/` in the implementation checkout, following existing practice.
Record source revision, compiler/version, target, flags, pointer/value sizes,
benchmark hashes, commands, and the exact variant. Store individual samples,
not just a reported best result. Archive plans and their research evidence on
`plans/archive`; no main-branch engine changes are part of writing this plan.

### Benchmark matrix

| Dimension | Required cases |
|---|---|
| Cache footprint | Many small functions; large cold branch; numeric-only function; variable/property-heavy functions; bundle load and first call |
| Read locality | 1/2/4/8/32 shapes; same/different offsets; clustered/random order; many instances on one shape |
| Prototype behavior | Own, missing, depth 1-4; distinct prototypes with the same receiver shape; shadowing and mutation |
| Object lifetime | Retained, short-lived churn, growing objects, empty-to-16-field populations |
| Representative workloads | Existing IC/prototype/lookup/shape benchmarks; Richards; DeltaBlue; TypeScript; scene churn; JSON payloads; real-library runtime fixtures |
| Target budgets | Default/slim/tiny as applicable, small heaps and startup, both value representations; at least one actual low-powered target before a layout default is generalized |

Run release timing sequentially with no concurrent build or benchmark batch.
Use at least seven alternating A/B samples after warmup, and confirm a proposed
win in a second batch. Include identical-binary A/A runs when establishing a
new harness. Investigate repeatable regressions above 2%; treat differences
within observed noise as inconclusive. Record process startup separately from
steady-state throughput and use a monotonic high-resolution timer for frame
latency. Diagnostic hook times are not release performance evidence.

Track requested/live/peak bytes, actual pool charges, RSS, allocation/clear/copy
counts, shape/hash/transition/cache bytes, GC work and pauses, bytecode/binary
size, compile time, dispatch counts, and warmup where relevant. An opcode-count
reduction alone does not prove a speedup. Use sampling when counters cannot
explain a time difference.

### Semantic checks

Use focused regressions during iteration, followed by local/Rosetta/module and
relevant narrow test262 checks. Preserve script sloppy behavior, strict scripts,
modules/classes, feature gates, and deliberate test262 scope exclusions.

Cover inherited accessors and setters, property absence versus undefined,
hasOwn/in/ownKeys/descriptor behavior, flags, non-extensibility, freeze/seal,
delete/re-add, symbol and integer keys, dictionary mutation, proxies/exotics,
prototype replacement, getters/coercions that mutate layouts, reentry,
exceptions, and allocation failure. Cache/lifetime changes additionally need
GC between fill/hit, recycled IDs, weak pruning, string ownership, and reset.
Storage changes need pooled and bypass/fallback allocation and both `TVal`
representations. Rebuild ASAN after relevant source changes.

Threaded/fused changes must pass opcode-profile consistency checks and preserve
fallback evaluation order, registers, reference counts, roots, and continuation
after partial execution. Serialize/load portable bytecode where metadata or
instruction mapping changes. Update architecture documentation for accepted
behavior. Do not add implementation-mirroring tests for a documentation-only
plan; test the observable assumptions of an actual optimization.

## 14. Literature notes and transfer limits

The following notes preserve the relevant contributions of every substantive
direct reference from Bernstein's article, including its two coaching footnotes.
The AOSA subsection is part of the same source. Navigation, author links, and
links recursively contained in the references are not additional readings.
Numbers are the cited systems' results, not predicted Boomkat improvements.

### L0: Bernstein, Objects, attributes, maps, oh my!

[Article](https://bernsteinbear.com/blog/object-shapes/), 2026-10-21.
Shared maps separate names/offsets from per-object values; immutable layout
identity supports access-site guards and direct slots. The article distinguishes
language classes from layout shapes and connects shapes with inline caching,
typed storage, collection strategies, versioning, and object-size tradeoffs.
Boomkat already has the central mechanism. The useful next questions are the
cost of its metadata, the exact invariant each cache guards, and whether more
specialization removes enough work to repay its maintenance and memory cost.

### L1: A Simple Object Model

[AOSA chapter](https://aosabook.org/en/500L/a-simple-object-model.html), including
its instance-optimization section. The progressive implementation separates
instance fields, class behavior, inheritance, and method lookup, then replaces
per-instance dictionaries with shared maps and indexed storage. It makes the
reasoning behind layout sharing and map-based fast paths explicit. Boomkat
already shares names/flags and stores values separately; applying the chapter
means checking the actual key-to-slot and mutation invariants rather than
replacing an imagined dictionary-per-object implementation. Its Python-oriented
class/metaclass examples are not a direct specification of JavaScript lookup.

### L2: What's up with monomorphism?

[Vyacheslav Egorov](https://mrale.ph/blog/2015-01-11-whats-up-with-monomorphism.html).
Monomorphism belongs to an operation site and the representations reaching it,
not to the number of allocated instances or the source-level class count.
Shape stability enables simple guards; apparently similar objects can still
have different layouts, while many objects can share one. Apply this to R0/R2
by measuring receiver distributions and access order per hot site. Distinguish
key, layout, prototype, and value-type variability. A shared-cache hit after
a monomorphic miss is a different cost from a generic lookup.

### L3: Explaining JavaScript VMs in JavaScript: Inline Caches

[Egorov](https://mrale.ph/blog/2012-06-03-explaining-js-vms-in-js-inline-caches.html).
The executable model shows how hidden classes, property slots, transition
sharing, and per-site caching cooperate. An IC can specialize on observed
layouts and evolve as additional cases arrive; shapes alone do not remove
lookup work. Boomkat already implements these foundations. Use the model to
design controlled shape/key workloads and interpret local versus shared-cache
behavior. Generated JavaScript/native-code examples do not establish that a
larger interpreted guard chain will improve Boomkat.

### L4: Inline cache implementation on JSC

[Caio Lima](https://caiolima.github.io/jsc/2020/03/12/jsc-inline-cache.html), 2020.
The LLInt uses operation-specific metadata with default, unset, array-length,
and prototype-load modes. Own loads require a structure and offset; inherited
loads additionally need owner/path validity, supported by property conditions
and adaptive watchpoints. JIT tiers attach richer cases and consume feedback
for optimization. This supports R1's compact common representations and
T1/T2's separate prototype/negative cases. It is a historical implementation
explanation, not a current JSC byte-size census. Watchpoints shift work and
memory to dependency registration and mutation, which must be measured.

### L5: An Inline Cache isn't Just a Cache

[Matthew Gaudet](https://www.mgaudet.ca/technical/2018/6/5/an-inline-cache-isnt-just-a-cache).
ICs are guarded operation specializations, not merely saved lookup results.
The same approach can cover arithmetic, calls, conversions, and other semantic
operations, with bounded alternative stubs and a generic fallback. CacheIR
provides a shared representation across execution tiers. Apply the principle
to R6's selected guarded/fused operations and R2's bounded attachment policy.
Boomkat need not adopt a general stub IR or JIT to benefit; dispatch and
metadata overhead can outweigh an overly general interpreter framework.

### L6: Storage Strategies for Collections in Dynamically Typed Languages

[Bolz, Diekmann, Tratt, author copy](https://tratt.net/laurie/research/pubs/papers/bolz_diekmann_tratt__storage_strategies_for_collections_in_dynamically_typed_languages.pdf),
[DOI](https://doi.org/10.1145/2544173.2509531).
Collections use homogeneous integer/float/string representations when their
contents permit it and transition to generic storage on incompatible writes.
The paper reports an 18% performance improvement and 6% lower peak memory on
its Python benchmark set. Transition frequency and the size at dehomogenization
matter because conversion can require reboxing every existing element.
Boomkat's NaN-boxed values already avoid much primitive boxing; T7 therefore
needs a narrower case based on int32 size, checks, or GC scanning. Preserve
holes, prototypes, aliases, and conversion costs rather than copying the
Python list strategy without its semantic and representation assumptions.

### L7: Type Freezing: Exploiting Attribute Type Monomorphism in Tracing JIT Compilers

[Cheng et al., author copy](https://www.csl.cornell.edu/~cbatten/pdfs/cheng-type-freezing-cgo2020.pdf),
[DOI](https://doi.org/10.1145/3368826.3377907).
Type monomorphism is maintained on writes so compiled reads can rely on
quasi-immutable attribute-type metadata. A type-changing write invalidates
dependent traces. Nested freezing extends assumptions across object-valued
attributes; terminal maps are needed to account for mutations through aliases.
The tracing compiler's invalidation/deoptimization machinery is central to
the benefit. Interpreter/write overhead and metadata must be counted before
transferring the mechanism. Prefer R6's local guarded sequence initially;
eight-byte Boomkat values do not gain an automatic storage reduction from
being called unboxed.

### L8: An Efficient Implementation of SELF

[Chambers, Ungar, Lee](https://bibliography.selflanguage.org/_static/implementation.pdf).
Maps capture common object structure and distinguish shared behavior/constants
from varying instance state. Compiler customization exploits that structure to
resolve operations and reduce dynamic checks. It explains why a shared map
can be valuable beyond saving property-name memory. For Boomkat, reusable
guarded operations and stable-layout allocation are practical transfers;
the paper's compiler customization is not a measured interpreter optimization.
Putting more facts in a shape requires updating it or invalidating assumptions
when those facts change, including mutable JavaScript method values and
prototype behavior.

### L9: Optimizing Dynamically-Typed Object-Oriented Languages With Polymorphic Inline Caches

[Hölzle, Chambers, Ungar](https://bibliography.selflanguage.org/_static/pics.pdf).
PICs attach a small number of guarded receiver cases at a site and expose
receiver distributions that an optimizing compiler can consume. They address
the instability of a single-entry cache without imposing the cost of a full
generic dispatch on every case. This is the primary conceptual basis for R2.
Bound case count, keep monomorphic traffic cheap, and compare against Boomkat's
existing shared cache. The accompanying feedback/inlining benefit in a JIT
does not automatically exist in the interpreter.

### L10: Optimizing Dynamically-Dispatched Calls with Run-Time Type Feedback

[Hölzle and Ungar, author copy](https://bibliography.selflanguage.org/_static/type-feedback.pdf),
[DOI](https://doi.org/10.1145/178243.178478).
Recorded receiver types guide customization and inlining, after which further
optimizations remove more work than dispatch alone. Feedback thus serves both
execution and profiling roles. Code growth and specialization policy remain
part of the tradeoff. Apply this to bounded, source-attributed R0 feedback and
R6's removal of actual dispatch/check work. Plan 104's measured inliner
regressions illustrate why avoiding a call or collecting accurate feedback
is insufficient when interpreted initialization and bookkeeping increase.

### L11: An Object Storage Model for the Truffle Language Implementation Framework

[Wöß et al., author copy](https://chrisseaton.com/truffleruby/pppj14-om/pppj14-om.pdf),
[DOI](https://doi.org/10.1145/2647508.2647517).
Shapes describe storage locations, including inline primitive/reference slots
and overflow storage, and change as properties or representations evolve.
Transition sharing, lazy metadata, and soft transitions can preserve efficient
common layouts. Compiler assumptions/watchpoints amortize dynamic behavior.
R1/R3 can borrow representation separation and selective metadata allocation.
Boomkat's shapes currently describe logical slots across physical classes;
making locations more physical needs an explicit layout contract. Its default
values already occupy one word, so typed primitive slots have a different
memory payoff than in a boxed host-language implementation.

### L12: Extending Basic Block Versioning with Typed Object Shapes

[Chevalier-Boisvert and Feeley](https://arxiv.org/pdf/1507.02437).
Typed shapes and shape propagation specialize generated basic blocks and
remove redundant property-type and shape checks. The Higgs study reports
48% fewer type tests, 45% fewer shape tests, and 25% lower execution time;
typed shapes also create 4.5 times as many shape nodes on average, with a 60.4x
outlier. This is nodes created, not a matching increase in total memory: with
unlimited propagation, measured process memory rises 3.7% on average, partly
offset by smaller generated code. Version limits control specialization growth.
R6 transfers the bounded propagation lesson; R0/R5 must account for shape
proliferation. Those JIT results do not justify attaching evolving type
combinations to every Boomkat shape without measuring the read benefit and
write/metadata cost.

### L13: Just-in-Time Data Structures

[De Wael et al., author copy](https://stefan-marr.de/downloads/onward15-de-wael-et-al-just-in-time-data-structures.pdf),
[DOI](https://doi.org/10.1145/2814228.2814231).
Representations can adapt to observed operations and contents rather than
remaining fixed for an object's lifetime. Specialization can target data
structures as well as executable code. Migration cost, aliases, iterators,
representation selection, and transitions are part of the mechanism. Borrow
the principle for bounded allocation/storage choices in R3/T7, preserving
object identity and generic fallback. A general representation compiler would
add substantial machinery; establish a profitable narrow transition before
building infrastructure for arbitrary adaptive data structures.

### L14: Efficient and Thread-Safe Objects for Dynamically-Typed Languages

[Daloze et al., author copy](https://stefan-marr.de/downloads/oopsla16-daloze-et-al-efficient-and-thread-safe-objects-for-dynamically-typed-languages.pdf),
[DOI](https://doi.org/10.1145/2983990.2984001).
Local and shared objects have distinct representation/shape states. Local
operations avoid synchronization; sharing is propagated through reachable
objects. Shared updates coordinate layout evolution, while suitable slot
assignment invariants support lock-free reads, including uniqueness of field
and representation locations. This is relevant if Boomkat ever permits one
heap to execute concurrently. Current independent runtimes already avoid
that problem by ownership. Adding sharing bits, locks, or concurrent layouts
to thread-confined objects would spend memory without serving this plan's
execution model.

### L15: Parallelization of Dynamic Languages: Synchronizing Built-in Collections

[Daloze et al., author copy](https://stefan-marr.de/downloads/oopsla18-daloze-et-al-parallelization-of-dynamic-languages-synchronizing-built-in-collections.pdf),
[DOI](https://doi.org/10.1145/3276478).
Collection synchronization distinguishes local access from shared access and
separates fixed-storage element work from operations changing representation
or capacity. Dynamic layout changes demand coordination beyond simply making
an element store atomic. The transferable lesson is to identify distinct
storage/lifetime invariants, as in R4. Its synchronization algorithms are
deferred for thread-confined Boomkat heaps. Any future shared-heap proposal
must include collection growth, iterators, and representation transitions,
not just ordinary object field reads and writes.

### L16: Profile Guided Offline Optimization of Hidden Class Graphs for JavaScript VMs in Embedded Systems

[Ugawa, Marr, Jones, author copy](https://stefan-marr.de/downloads/vmil22-ugawa-et-al-profile-guided-offline-optimization-of-hidden-class-graphs.pdf),
[DOI](https://doi.org/10.1145/3563838.3567678).
Allocation profiles select likely final layouts, remove cold intermediate
nodes, and reduce storage reallocations. Hot stopping points are preserved;
rare branches and profile mismatches need treatment. `JS_EMPTY` distinguishes
predicted but absent fields from present undefined fields. The eJSVM results
include 61.9% fewer hidden classes, 3-30% lower footprint, and 6.3% mean speed
improvement, with a 0.3% Richards slowdown. Prototype identity affects graph
construction. Closed-world deployment enables offline specialization; storing
graphs in flash is further work. R3/R5/T6 adapt these ideas incrementally;
Boomkat already pretransitions eligible literals and must retain dynamic code.

### L17: Optimizations for Dynamic Collections

[Nanjekye, Bremner, Micic, JOT 2025](https://www.jot.fm/issues/issue_2025_01/a1.pdf).
Type-based stores support heterogeneous collections using separate primitive
areas plus an index mapping. Allocation-context-aware presizing profiles
allocation sites and approximates calling context with stack height. The
paper reports useful aggregate results but substantial slowdowns for some
operations; accessing/applying presizing data can cost up to 25%. Stack-height
context identification is imperfect and affected by transformations. For
Boomkat, prefer bounded site-local capacity prediction in R3, then add context
only if a measured bimodal site needs it. NaN-boxing reduces the attraction
of type-segregated stores while their map, indirection, and migration costs
remain.

### L18: Controlling the Tracing of an Interpreter With Hints, Part 3: Putting it All Together

[PyPy class-versioning discussion](https://pypy.org/posts/2011/03/controlling-tracing-of-interpreter-with_21-6524148550848694588.html#versioning-of-classes).
Version tokens separate frequently read data from slowly changing lookup
metadata. A compiler can rely on a token/assumption and invalidate optimized
work when the protected class changes. This motivates the distinction among
binding resolution, storage lifetime, and layout identity in R4. Each token
must cover all mutations that affect its assumption, with explicit lifetime,
wraparound, and reset rules. Interpreter reads still execute checks, so the
choice between repeated validation and mutation-side maintenance requires
measurement rather than assuming the tracing compiler's result.

### L19: Compact C++ object-layout sketch

[Bernstein's gist](https://gist.github.com/tekknolagi/caf8462b75ac8ba7e33f6ade06b3f914).
The sketch uses a compact shape/capacity header and inline slots to illustrate
how little metadata a restricted object representation can require. It is
incomplete: overflow, removal, collector state, ownership, and the full language
object model are not all implemented. Use it as a lower-bound thought exercise
for R3, not a claim that Boomkat's complete objects should have the same
header. Compare actual pool/page charges and all runtime responsibilities
before drawing conclusions from a struct declaration alone.

### L20: Rails PR 57020

[Initialize class instance variables consistently](https://github.com/rails/rails/pull/57020).
The patch initializes three class instance variables through inherited hooks
so lazily reached layouts converge, reducing the discussed layout variation
from three shapes to one. The motivation includes ZJIT's specialization
behavior. This is evidence that application construction patterns can affect
many downstream cache sites, motivating T10's grouped cause reporting. Ruby
instance-variable initialization is not permission to insert JavaScript own
properties: presence, enumeration, getters/setters, and evaluation order must
be reviewed by the application author.

### L21: Optcarrot PR 59

[Remove an unused instance-variable write](https://github.com/mame/optcarrot/pull/59).
The patch removes assignment to `@output_bg_color` in the PPU path. Besides
removing a write, eliminating unused state avoids an unnecessary layout
transition. This supports investigating source causes instead of treating all
shape polymorphism as an engine defect. A JavaScript engine cannot generally
delete an apparently unused property store: setters, proxies, descriptors,
subsequent reflection, and aliases can observe it. T10 should explain the
opportunity; automatic elimination needs a real non-observability proof.

### L22: Optimization Coaching: Optimizers Learn to Communicate with Programmers

[St-Amour, Tobin-Hochstadt, Felleisen](https://bernsteinbear.com/assets/img/optimization-coaching.pdf).
An optimization coach turns successful/missed optimization information into
actionable explanations at source locations. It synthesizes related events
and filters reports so users do not have to reverse engineer generated code.
The Racket case studies demonstrate the workflow, not a universal gain from
printing compiler diagnostics. R0/T10 should identify the cause and likely
cost of hot shape instability, group related sites, and avoid burying useful
signals under cold refusals. A small structured report is enough to test the
benefit before building an interactive interface.

### L23: Optimization Coaching for JavaScript

[St-Amour and Guo](https://bernsteinbear.com/assets/img/optimization-coaching-js.pdf).
The SpiderMonkey coach handles optimization failures that are non-local and
change across recompilations. It relates symptoms to receiver/type behavior,
groups causes, and uses profiling to prioritize recommendations. Suggested
source edits may change semantics and require programmer judgment. Boomkat
can apply this to construction order, late fields, and conflicting layouts,
even without JIT tiers. Record hotness and causal sites, suppress intentional
polymorphism, and keep coaching separate from automatic program rewriting.

The PIC background in L9 is an additional paper linked by the JSC reference,
retained here because it directly motivates R2. The 22 distinct direct
references comprise L1-L8 and L10-L23; L0 is the original article.

## 15. Completion records

For every attempted experiment, retain:

1. Hypothesis and source evidence; exact baseline and variant.
2. Observed semantic assumptions and affected lifetime/ownership paths.
3. Focused correctness results and relevant broader checks.
4. Raw release measurements, metadata composition, and diagnostic counts.
5. A decision: retain, target-specific option, reject, or inconclusive.
6. Explanation of remaining costs and any source/documentation updates.

The immediate next work is R0 plus R1's representation/allocation matrix.
Later experiments should follow the resulting opportunity profile rather than
requiring completion of every tentative idea in this document.

# Bounded shape and allocation diagnostics

This diagnostic branch adds `OP_PROFILE` hooks. Coding was source-only; builds,
semantic checks and measurement belong to the reviewing process. Every new hook
and counter is feature-gated. No heap/object/pool layout field is added.

`SHAPE_SITE` preserves the existing report format. Its eleven event positions
are own guard, inherited guard, shape miss, generation miss, chain miss, shared
hit, generic fallback, missing, key-guard miss, computed threaded attempt, and
computed switch attempt. Counts are nonexclusive events, not an exhaustive
partition of reads or a cache hit rate. A threaded refusal and its switch retry
can both be observed. A key-guard miss can mean cold/unfilled/refused metadata;
it is not evidence of key polymorphism.

Source sampling uses 512 slots, eight probes, and a 1/64 pseudorandom sampling
probability. Each retained site records up to four shape IDs and eight early
shape changes. Names, filenames and a sample key are copied into bounded byte
buffers; no key is kept alive solely for profiling. Replacement biases retention
toward hotter contenders without an exact heavy-hitter guarantee. Shape-ID reuse
and function-address reuse across heap resets can merge sampled populations.

`SHAPE_KEYS` is a separate line, so existing consumers anchored to `SHAPE_SITE`
remain compatible with the longer counts array. It describes sampled computed
input fingerprints: string content hash plus length, symbol address, numeric
bits after conversion to double, or an input tag for other values. No
ToPropertyKey, user coercion, allocation or deferred-hash mutation is performed
for sampling. Hash collisions, symbol-address reuse, and coarse other-input
classification can merge keys; different raw numeric representations can split
keys that would coerce identically. The receiver-class mask distinguishes arrays,
typed arrays, proxies and ordinary objects. Primitive receivers are excluded.

The final in-memory instruction stream is classified by the current position's
IC/VarIC consumers: none, property, variable, both, or unclassified future opcode.
This includes transformed/warmed instructions and counts WIDE prefixes as
nonconsumers. DECLVAR uses both families; the inline read guard borrows the
following property's record. Counts cover all compiled positions and the subset
belonging to functions with reserved arrays. Populated property records at a
known nonconsumer position are reported separately to expose special-template
uses or classification mistakes. These static totals are not dynamic hotness.

The cache census separates reserved bytes from populated records. Allocation
counters track successful requested bytes, explicit full cache clears, and
current/high-water requested cache bytes across heaps on the profiling thread.
Normal compiled-function teardown decreases the current counter. The high-water
value is not peak RSS, allocator charge or live-cache hotness. Additional cache
reclamation variants need matching decrement hooks when combined with this code.

Allocation traffic includes successful object headers by class and initial
inline capacity, header requested bytes, fallback header clears, and freed
headers by class. Shape initialization requests and property reservations have
separate capacity histograms. External property/dense growth records requested
bytes and the exact byte lengths passed to its copy operations. Direct reserve
blocks and shaped external blocks are counted separately. Selected explicit
external clears and undefined-slot initialization sizes are also recorded.
These are not a complete census of every write, initialization or copy in the
engine; function-property initialization, deletion clears, shape/hash copying,
and arbitrary builtin allocations are outside those traffic counters.

PagePool traffic distinguishes freelist reuse, fresh zeroed bump blocks,
cleared bump blocks from recycled reserved pages, fresh calloc pages, and page
reuse. It covers every PagePool user, rather than attributing a page to one
object class. Calloc bytes are logical requested zeroing, not measured physical
memory writes. Requested bytes exclude allocator rounding, slack and headers.

Allocation counters and registered populations print before heap teardown.
Registered objects are not a root-reachability or peak-live census. The shape
ownership scratch map tracks at most 65,536 IDs, reporting truncation or
allocation failure. It separates direct registered-object users, ancestors of
those users, pinned-only dependencies, and remaining allocated records not
explained by those sources. Ancestor traversal can visit parents of out-of-range
shapes; direct counts and histograms remain limited to the tracked IDs.
Transition-table out-degree and direct-user histograms use buckets 0 through16
and17-or-more. None of these categories establishes that an object is live or
that an unexplained shape is collectible immediately.

A separate allocation-site sampler has 128 slots, eight probes, 1/64 sampling,
up to four initial capacities with sample counts, a class mask, and copied source
names/paths. ALLOCATION_SITE rows group successful explicit NEWOBJ and
NEWOBJ_SHAPE allocations in both dispatch paths, plus compiled base-constructor
allocations in the ordinary new/super call paths and their threaded fast path.
The hook runs before constructor stores. Initial capacity is not a final-field
count, retained size or lifetime measurement. Successful speculative allocations
that later fall back remain counted as real allocation work. Builtin/internal
allocations, arrays, closure/prototype allocations, host construction and indirect
Reflect.construct allocation paths are not source-attributed by this sampler;
they remain in the global allocation counters where applicable. Sample records
copy no object pointer and do not keep objects alive. Function-address reuse and
hash-table replacements retain the same approximation limits as property sites.

Remaining coverage gaps include complete allocation-site attribution, exact
retained-versus-transient reachability, complete mutation-cause attribution,
computed coercion-result diversity, primitive computed reads, and sampling of
all nonthreaded constant-read outcomes. The diagnostics provide an opportunity
profile; they do not close every R0 investigation.

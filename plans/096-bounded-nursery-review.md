# 096 — A simpler bounded nursery

**Status: implemented and validated.**

Measured results and validation details:
[bounded nursery report](../benchmarks/gc-nursery-vs-cooperative/README.md).

The implementation baseline is `55e0b746`: cooperative marking and sweeping
with paced safepoints. The rejected generational draft is preserved as a patch
outside the tree. This implementation preserves the cooperative core described in
[095](095-incremental-gc-design.md).

## Decision

Use generations for the existing object/buffer/BigInt allocation lists. Keep
environments and generator storage under their existing lifetime authorities.
A minor collection conservatively roots that auxiliary storage; a major
collection determines its actual reachability. Both use the existing bounded
scanners and reclamation code.

Remember every promoted object for one additional minor scan. This makes
promotion responsible for preserving its outgoing edges, and keeps the store
barrier independent of whether a young owner is about to be swept.

This is a deliberate retention tradeoff. It avoids converting every engine
allocation into a new universal GC node type. Acceptance depends on measured
memory bounds in closure and async workloads as well as scene throughput.

## Evidence and limits

The [saved pacing profile](../benchmarks/gc-call-pacing-profile.json) records:

| Workload, first recorded run | Allocations | Cycles | Value visits per allocation | Mark / sweep time |
| --- | ---: | ---: | ---: | ---: |
| 100k scene, 3,000 frames | 4,126,912 | 15 | 8.48 | 251.126 / 223.147 ms |
| Heavy VDOM | 3,928,495 | 278 | 6.66 | 99.299 / 160.199 ms |

These are instrumented runs of the committed cooperative collector, not
measurements of this proposal. Value visits include repeated visits and do not
count distinct objects. Both runs allocate one declarative and one object
environment, no function environments, and report no await suspensions.
Their environment sweep totals are 0.005 and 0.056 ms respectively.

The dominant opportunity in these workloads is avoiding repeated traversal and
sweeping of ordinary retained containers. The data does not justify a wholesale
rewrite of environment or generator ownership. It also does not establish that
conservative auxiliary roots are cheap in other programs.

The draft's latest reproducible failure is:

```sh
make out/boomkat_gc_stress
./out/boomkat_gc_stress --script test/async_gen_gc_lifetime.js
```

The full oracle finds an environment missing from the incremental result;
its bindings object is old. This establishes a reachability mismatch, not a
complete diagnosis of the missing publication. The design must preserve the
oracle's coverage rather than suppressing this comparison.

## Why the draft grows special cases

1. Object age controls traversal, but environments are independently swept on
   every minor. Skipping an old object does not prove that its environment is
   dead. `ENVREF` values make this more general than a function-class test.
2. Promotion happens during sliced sweeping. An owner can receive a freshly
   allocated target while still young, then become old after the store.
3. Generator state has multiple reference-counted holders and a separate
   retirement queue. Its registry is not a list of ordinary collectible nodes.
4. The blocking collector duplicates marking and sweeping policy, so each new
   generational rule acquires a second implementation.
5. Remembered vectors can allocate from a store barrier. That conflicts with
   the cooperative core's allocation-free marking contract.

These are lifetime and phase problems. Moving complex conditions into helpers
improves readability but does not settle them.

## Lifetime rules

| Storage | Minor collection | Major collection | Storage release |
| --- | --- | --- | --- |
| Young objects, buffers, BigInts | Trace and collect | Trace and collect | Existing bounded sweep |
| Old objects, buffers, BigInts | Retain; scan remembered owners only | Trace and collect | Existing bounded sweep |
| Allocated environment cells | Conservative roots; trace bindings and parents | Trace from actual roots | Pool sweep after major marking |
| Generator states with owners | Conservative roots; scan saved state | Reach through actual holders/roots | Reference count and bounded retirement |
| Retired generator states | No root or resurrection | No root or resurrection | Existing retirement cursor |
| Strings | Counted ownership | Counted ownership plus registry cleanup | Existing ownership rules |

During a minor, root **every allocated environment**, not just the environments
found by walking young functions. Otherwise retained cells can hold bindings
that the young sweep has freed. Merely skipping the environment sweep is unsafe.

This also preserves the one-bit environment epoch invariant from
[085](085-envrecord-reclamation.md): each cell retained through a completed
collection has the current epoch. Major reclamation removes unreachable cells;
minor tracing visits all allocated cells. There is no second environment age
system or new epoch reset pass.

Environment creation and reparenting still require publication barriers during
marking. `vm_calls.c3` and `vm_execute.c3` contain parent assignments, so parent
links must not be assumed immutable. Binding-slot mutation uses the ordinary
owner-aware object barrier.

Feed auxiliary roots into the existing environment and generator scanners,
with a pool block/index cursor and a generator registry cursor. Feed remembered
owners directly into the object scanner. These cursors stay independent of VM
root restarts and require no additional marking scheduler stages. New publications shade
their values during marking. Generator publication occurs after initialization
and acquisition of its holder reference. Unpublished error cleanup must never
free a state already borrowed by a scan queue.

An auxiliary registry is a root source **only for minors**. Rooting it during
majors would retain environment and generator cycles indefinitely. Zero-owner
generator states must be excluded even while their registry entries await
retirement; their retirement link cannot also become a marking link.

Host payloads with a mark callback remain conservative remembered owners across
minors. The host API's stored-value operations must shade publications during
marking. Repeated callbacks alone cannot protect a value written behind a scan
cursor. Majors trace only reachable hosts.

## Promotion and the barrier

At the mark-to-sweep boundary, capture the young and, for a major, old sweep
heads. No new collection starts until reclamation completes. Allocations during
sweeping enter ahead of these cursors and remain young.

For each young survivor, bounded sweeping performs one operation:

1. Unlink it from the young list.
2. Mark it old and insert it into the old list.
3. If it has outgoing edges, remember it for the next minor.

The remembered scan uses the ordinary object scanner. It costs one additional
scan per promoted container, after which ordinary stores determine whether
another scan is necessary. Buffers and BigInts are leaves and need no scan.

Consider `a.child = b` during sweeping, where `a` survives the current
collection and `b` is a new allocation. If `a` is already old, the store
remembers it. If `a` is still young, promotion remembers it. Both orders lead
to the same state before the next minor. There is no special young-owner
barrier during sweeping.

A small exhaustive transition model checked 4,480 valid interleavings of two
promotions, two allocations and four replacement stores. An old-owner-only
barrier misses owners in 1,848 schedules; adding promotion registration misses
none. This checks that limited invariant, not the engine implementation.

The marking barrier remains unconditional shading of newly published traced
values. During marking, a separate remembered insertion is unnecessary: every
shaded young target belongs to the ensuing sweep and survives it. Outside
marking, an old-to-young store remembers the owner. Scheduled collections commit
the dead set at a quiescent boundary and sweep all young nodes allocated before
that boundary. Do not detach the nursery at the beginning of marking.

### Remembered work

Use a typed intrusive owner link, separate from the gray link. A membership bit
prevents duplicates. The barrier must not allocate or retain slot addresses.
This is the same allocation-free queue pattern already used for marking.
Measure its effect on actual object layouts and pool classes before accepting
the extra link.

On the measured arm64 NaN-boxed build, DWARF reports `HeapHeader::size = 24`
and `HObjectBase::size = 88` (baseline 80). The class-size formulas give plain
pool blocks of 120 bytes (baseline 112), array/arguments blocks of 136 (128),
and function blocks of 200 (192). The extra link therefore costs 8 bytes per
object in these pools; it does not enlarge buffers or BigInts.

At minor start, consume remembered owners through a bounded cursor. Clear
membership as an owner leaves the queue; shade its children through the shared
scanner. Marking-time insertion barriers cover stores behind that scan. The
next sweep rebuilds pending work through promotion and old-owner stores.
Host callback owners are retained for the next minor after their scan.

At major start, detach remembered work without treating its owners as roots.
Reset stale membership when reachable owners are scanned. Marking-time stores
shade targets and do not insert new remembered entries. The sweep registers
promotions, host callback owners, and old survivors of a collection that keeps
native pins. Stores during sweeping remember old-to-young edges normally.

An old survivor of a quiescent major needs no unconditional follow-up scan:
its young targets from marking are all in the ensuing sweep. This avoids
repeating a full old-graph scan through the remembered set. The first measured
trial registered all major survivors and scanned 1.84 million remembered
owners on the 100k scene; its throughput improvement was only 1.2%.

## One runtime collection algorithm

Use `GcKind.MINOR` or `GcKind.MAJOR` alongside the existing phase enum. The
kind selects roots, old-node admission and sweep lists. It does not select a
second object field visitor.

Objects, leaf headers, environment references and generator states keep typed
entry points. Centralize header admission so an old BigInt or buffer cannot
accidentally keep a stale mark through a minor. Do not route arbitrary pointers
through an `HObject*` cast or build a general GC interface hierarchy.

An explicit blocking collection drains the same major state machine. Native
temporary roots are seeded through an explicit root policy; promotion remains
disabled while initialization can hold unregistered locals. The conservative
major rebuild remembers surviving old owners even when their targets stay
young. A blocking major with native pins commits synchronously under that root
policy; it must not masquerade as a quiescent scheduled collection.
Shutdown/reset retain their separate ownership teardown, not a second
reachability algorithm. Validate native allocation-failure and reentry paths
before removing the existing blocking implementation.

The independent full-mark oracle remains separate intentionally. Sharing the
runtime scanner between minor and major collection does not require making the
oracle share their admission or root-selection decisions. Verification must
not mutate the application graph or allocate traced nodes; unexpected oracle
side effects need diagnosis, not exclusion from its comparison.

Variable caches whose environment and bindings are retained by the minor root
rule can remain until major weak-cache pruning. Audit the cache contract before
skipping that pass. Major pruning must precede freeing any referenced storage.

## C3 implementation boundaries

- Keep `PropValue` distinct, and keep `@set_edge` as the narrow publication
  boundary. Use `$switch $Typeof(value)` for genuinely different store types;
  evaluate macro inputs once.
- Use enums and small named methods for collection kind, admission and queue
  operations. Avoid another compound scheduler readiness condition.
- Keep existing typed intrusive mark queues and pool cursors. Use stdlib
  `List` for growable storage outside the allocation-free barrier; its `push`
  can grow capacity and therefore does not satisfy that barrier contract.
- Preserve the heap's allocator callbacks for embedder-owned storage. Choosing
  the stdlib does not authorize allocating through one allocator and freeing
  through another.
- Use `defer` for scoped roots and cleanup; contracts/assertions for queue
  membership and retirement. C3 does not provide linear ownership or prevent
  every raw-pointer write. The type boundary, verifier and ASAN complement one
  another.
- Keep this collector on the mutator thread. These cursors and barriers do not
  authorize concurrent reads of mutable backing arrays.

## Cost and collection policy

Minor work scales with young storage, remembered slots, registered roots,
reserved environment-pool cells and registered generator states. Only allocated
environment cells are roots, but the cursor visits free cells too. Pool blocks
remain available for reuse between bounded sweeps. A minor does not walk the
unchanged ordinary old graph.
A single modified large old array still requires a resumable full-owner scan.
This bounds pauses, but does not make its total work small. Measure remembered
slots before proposing cards or dirty ranges.

Conservative auxiliary roots retain some otherwise dead objects until a major.
Request majors from old-generation growth **and auxiliary allocation pressure**,
with a finite minor-count backstop. Count environment allocations even when a
`with` environment allocates no bindings object. Charge generator backing
storage, not just state headers. A minor-count limit alone is not a byte bound.

`gc_next_kind()` selects the collection kind. Small heaps use majors; minors
become eligible once a completed major retains 65,536 nodes. The minimum
allocation allowance is 16,384 units, including allocation debt accrued during
the collection. The work-based allowance still grows for larger graphs.
Auxiliary storage shares one byte counter. Environment cells, generator states
and saved registers select a major for the next scheduled collection after
allocating `max(256 KiB, last_major_old_count * HeapHeader::size)` bytes. Scaling
with the retained graph lets large closure and Promise workloads amortize full
tracing; a fixed allowance repeatedly traces the growing graph. Large auxiliary
allocations consume the shared allocation budget in KiB units, as large strings
do. The byte threshold selects collection kind; it does not independently
request an early collection. A major resets the counter when it starts.
Old-node growth beyond
twice the last major's survivors plus 4,096 nodes, native temporary roots, or
64 minors also select a major. These are pacing thresholds, not hard memory
bounds: active collection and native execution can defer reclamation.

The minimum heap policy follows an isolation experiment. With minors enabled
on small heaps, heavy VDOM regressed 26.1% and peak RSS doubled from about
16 MiB to 34 MiB. The same implementation restricted to majors measured +2.5%
runtime, with the same median worst frame as baseline. Small short-lived heaps
cannot amortize the extra promotion scan. Conversely, the 100k retained scene
benefits from skipping its old graph. `GC_STRESS` permits minors on small heaps
and lowers the allocation allowance so tests exercise both collection kinds.

Keep the current paced entry policy and 0.5 ms soft slice budget initially.
Measure allocation assists and explicit collections separately. The target is
observed GC interruptions below 4 ms on 100k and heavy VDOM; whole-frame time
also includes application execution. No 300k scenario is needed.

## Alternatives considered

| Alternative | Benefit | Cost / decision |
| --- | --- | --- |
| Generational environments and generator states | Precise minor reclamation of auxiliary storage | More age, publication and lifetime transitions; consider only if auxiliary retention fails its gate |
| Common GC header for every traced allocation | More uniform graph representation | Rewrites environment pools and generator RC/error paths, grows metadata; too broad for the current evidence |
| Allocation cohorts and logical bulk promotion | Avoids per-survivor promotion ordering | Adds cohort classification, rollover and list-membership rules; conservative promotion scans solve the concrete hazard more directly |
| Remember all mutated objects until a major | Simple persistent set | Repeatedly scans owners whose young edges have already matured; poor fit for long-lived scene mutation |
| Tune only the existing full collector | Smallest change | Can trade memory for fewer cycles, but does not remove repeated retained-graph traversal |

## Implementation and acceptance order

1. Preserve the failed draft as a patch, then remove only its experimental
   hunks with targeted edits. Keep `55e0b746` as the performance baseline.
   Review independent fixes separately, such as freeing root-list storage.
2. Make the blocking path drive the shared collection machinery and validate
   the unchanged full collector, including reset, native pins and failure paths.
3. Add the nursery, conservative auxiliary roots and promotion registration
   together. A minor must not become runnable with only part of its root rule.
4. Verify one-unit slices across every phase: stores before/after promotion,
   allocation during sweeping, old arrays containing `ENVREF`, reparenting,
   shared generator holders, zero-owner retirement, and host publication.
   Require the independent full oracle to find no missing young nodes or
   environments. Rebuild ASAN with pool bypass before using its results.
5. Run collector stress, Rosetta/local, embedding, NONANBOX, threaded dispatch
   and focused test262 coverage for functions, generators and promises. Expand
   testing if these expose a remaining risk; do not weaken the oracle or skip
   tests to accommodate the design.
6. Compare `just bench`, `bench-es6`, the 100k scene and heavy VDOM against fresh
   baseline binaries using alternating runs with builds/tests stopped. Report
   total runtime, GC CPU, entry count, maximum slices and peak memory. Add
   closure churn, async churn, a mutated large old array and the environment
   retention probe from plan 085. Repeat bounded-live work long enough to show
   memory reaching a plateau.

## Implementation map

| Source | Responsibility |
| --- | --- |
| `src/gc_nursery.c3` | Collection-kind policy, shared node admission, intrusive remembered owners, auxiliary allocation accounting |
| `src/gc_incremental.c3` | Shared bounded state machine, young/old sweep snapshots, promotion and collection pacing |
| `src/gc_object.c3` | Shared field scanner; consumes remembered owners alongside young gray objects |
| `src/env.c3`, `src/gc_generator.c3` | Conservative minor root cursors using existing typed storage and scanners |
| `src/heap.c3` | Typed store barriers, generator acquisition/publication, shared blocking-major entry, reset and teardown |
| `src/gc_verify.c3` | Independent full traversal; checks young nodes for minors, all nodes for majors, and environments in both |

## Measured outcome and limits

The direct collector test checks that a settled old graph requires zero object
marks in a minor. On the 100k scene, full collections fall from 15 to 7,
traced-value visits fall 25.0%, and scheduled collector time falls 23.7%.
Release runtime improves 7.1%. The ES5 benchmark suite is effectively flat
(−0.5% total); ES6 improves 7.6%. Heavy VDOM is essentially flat (+0.7% runtime),
with 6.6% more instrumented collector time. The extra object link and promotion
bookkeeping remain real costs.

Across three profile runs per workload, the largest scheduled GC slice is
0.502 ms and no measured GC interruption reaches 4 ms. Whole VDOM frames still
take longer than 4 ms. Allocators and host callbacks remain indivisible, so this
is an observed scheduling result, not a hard realtime guarantee.

Closure churn with a retained graph approaches a release RSS plateau, and a
forced major returns the environment live count to two. Async probes likewise
leave zero generator states and two live environments after a major. A long
single-checkpoint async chain still grows peak RSS in both baseline and
candidate: the microtask queue retains capacity proportional to jobs appended
during a drain. These probes do not establish an async RSS plateau. The report
records the queue counters, reserved pool storage and peak-memory comparison.

The source archive and saved patch preserve the baseline and rejected draft
outside the working tree. Runtime validation includes the independent oracle,
ASAN with pool bypass, both value representations, embedding, heap reset and
focused test262 coverage. Full test262 was not rerun for this change.

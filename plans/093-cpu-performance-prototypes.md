# 093: CPU performance prototypes

Status: in progress; track A measured and validated, remaining tracks pending.
Baseline inspected: `ba8610c8` on `speed`, matching local `main` at setup.

## Objective and scope

Evaluate every performance-relevant candidate from the CPU discussion and the
collection/container review. Retain changes only when checked workloads show a
repeatable speed or memory benefit with acceptable implementation cost. The
engine must preserve JavaScript semantics, low-memory operation, and portability.

This plan covers eight tracks. Their order controls dependencies and experiment
cost; it does not exclude the later tracks. Each ends in a measured keep/reject
decision or a documented evidence gate that explains why no prototype is justified.
BigInt hashing is outside this performance task.

| Track | Remaining opportunity | Investigation verdict |
|---|---|---|
| A | Maintained Map/Set live counts | Explicit linear scans remain in size reads |
| B | Compact Promise reactions | Internal records still use ordinary objects and named properties |
| C | Fixed-shape literal construction | Complete-layout initialization can remove work beyond existing INITPROP |
| D | Call setup and frame compaction | General frame sizing remains open after scope and capture optimizations |
| E | More indexed capture coverage | Lexical and transitive fallback paths remain |
| F | Dispatch reduction | More fusion needs current execution-frequency evidence; block interpretation is exploratory |
| G | Allocation work and memory locality | Existing layout improvements are substantial; further changes need allocation/cache evidence |
| H | Collection index churn | Historical entry counts and retained deleted entries can increase index cost |

The review's proposed Map/Set hash index already exists in `coll_find`; building
another index is unnecessary. Raw-pointer VM storage does not establish optimal
call, dispatch, ownership, or allocation costs. A shared growable-array adapter is
maintenance work unless a specific growth/initialization policy changes measured
cost; such policy experiments belong to G.

## Source findings and existing work

- `src/builtins/core.c3`: `coll_find`, `coll_hash_build`, `coll_set_entry`,
  `coll_add_value`, `coll_delete`, get-or-insert helpers, and group-by insertion.
  Lookups use an incremental open-addressing index. Rebuild sizing uses the
  entry-log length. Deletion leaves Map/Set log slots in place.
- `src/builtins/map.c3` and `set.c3`: both public size getters scan the log;
  `set_live_count` performs another scan for set operations. Set operations also
  write deleted markers directly, outside `coll_delete`.
- `src/builtins/promise.c3`: reactions use `ObjClass.OBJECT`, named handler and
  downstream properties, and a hidden next property. `Heap.enqueue_microtask`
  stores handler/argument/downstream triples in `src/heap.c3`.
- `CompilerContext.object_literal` in `src/compiler/expressions.c3` emits
  `NEWOBJ` and `INITPROP`. `src/vm/vm_control.c3` handles property definition;
  `src/vm/vm_objects.c3` handles allocation. Measure against this path, including
  its current initialization shortcuts, rather than assuming generic PUTPROP.
- `src/compiler/moveelim.c3` already has whole-function liveness with distinct
  treatment of call windows. `src/compiler/context.c3` builds bounded await
  liveness. Call entry and cleanup use `num_regs` in `src/vm/`.
- [090](090-resolved-bindings.md) records indexed captures, compact cells for
  eligible var/parameter bindings, and producer register promotion. Lexical scope
  identity, transitive forwarding, and general frame compaction remain open.
- `src/bytecode.c3`, `compiler/peephole.c3`, and `compiler/fusion.c3` already
  contain fused operations. `vm_execute_threaded.c3` runs threaded handlers;
  `vm_opprofile.c3` provides opcode-pair profiling. Verify coverage of threaded
  execution before treating its counters as a complete instruction profile.
- [091](091-object-layout-optimization.md) records class-specific layouts and
  pool sizing, including rejected layout experiments. Property names already
  live in shared shapes. Smaller object strides are not automatically faster.

The C3 stdlib reference provides `Allocator`, `List`, and fixed-size pool
facilities. Reuse suitable facilities only after checking their initialization,
failure, and allocator contracts against the engine's heap callbacks and tracing.
Container availability alone does not establish a speed opportunity.

## Common experiment protocol

### Baselines and isolation

1. Build a fresh release `boomkat` from the recorded baseline. Preserve the binary,
   commit, build command, compiler version, architecture, flags, and executable
   size in a dedicated artifact directory. Never trust worktree-local old binaries.
2. Use one bounded patch per prototype. Record its parent baseline. Independent
   experiments should compare to the same base; dependent experiments also report
   their incremental gain over the required parent.
3. Run builds, benchmarks, and profilers sequentially. Avoid competing benchmark
   processes. Keep the host's power mode consistent and record it.
4. Keep optional counters out of timed release builds. Use a separate diagnostic
   build for allocation, instruction, fallback, and live-register attribution.
5. Preserve raw per-run times, exit statuses, expected outputs, peak RSS, and
   counters alongside the patch. Record rejected prototypes too.

### Workloads and measurement

- Run plain fixtures as scripts with `--script`. Use existing ES5/ES6 suites as
  regression controls, and separate new checked fixtures for candidate coverage.
- Fixtures must consume results through an asserted checksum or equivalent
  observable result. Completion without checking the computation is insufficient.
- Use a pilot to choose equal work for baseline and candidate, aiming for at least
  several hundred milliseconds per sample. Report startup/compile time separately
  when it materially affects results. Do not change work counts between binaries.
- Begin with seven alternating A/B pairs after warmup, swapping the leading
  binary across pairs. Report medians and dispersion, not the best run. Run an
  A/A control when noise is comparable to the apparent effect.
- Treat 5% as an initial materiality threshold, not proof of significance. A
  smaller result needs unusually low noise or clear, useful memory savings. A
  repeatable regression over 3% on an unaffected control needs explanation and a
  resolution before retention. Avoid open-ended reruns to obtain a favorable sign.
- Measure both allocation churn and retained objects. Peak RSS, logical payload
  bytes, reserved pool bytes, GC work, and elapsed time answer different questions.
- Check unchanged ES5 and ES6 suites before retaining a candidate. Duktape is an
  ES5 comparison; use QuickJS for ES6 workloads. Engine comparisons provide
  context, while same-build A/B establishes the effect of our change.
- Use existing `just bench`, `just bench-es6`, and benchmark scripts where their
  options fit. A paired runner must accept explicit immutable binary paths; do
  not allow baseline measurements to resolve to a rebuilt `out/boomkat`.

### Correctness and portability gates

Use focused semantic fixtures first, then `just rosetta` and narrow test262
directories for the changed feature. Run the local suite for retained compiler,
ownership, and object-layout changes. Do not run full test262 or edit its scope.
Rebuild ASAN before ownership/GC-stress validation. Compare behavior with a
reference engine, including both strict and sloppy fixtures where relevant.
Exercise NONANBOX for representation/layout changes. Check an available second
platform before claiming portability; record unavailable validation explicitly.

Existing baseline failures must be recorded separately. A newly failing test
disqualifies a candidate. Do not turn unrelated correctness work into a dependency
of this plan or count incorrect output as a performance result.

## A. Maintained collection live counts

### Hypothesis and prototype

An independent live-entry count makes size reads constant-time and removes
repeated scans in set-method branch selection. The entry log still provides
iteration order and positions. `array_used` and `CollHashInfo.used` are not live
counts: the former includes deleted slots and the latter tracks index occupancy.

Add a count to collection-specific state, initialized even when no hash table is
built. Measure the resulting logical size and physical pool stride before choosing
the final layout. Avoid adding a field to every ordinary object.

Inventory every mutation before editing: constructors, new versus existing-key
set/add, delete hit/miss, clear, getOrInsert, reentrant getOrInsertComputed,
Map.groupBy, set-operation result construction, direct deleted-marker writes,
and any clone/reset paths. Increment only after successful insertion, decrement
only for a live deletion, and keep replacement count-neutral. Allocation failure
must not commit a count without its entry. Keep Weak collection behavior explicit
if the shared payload or helpers are extended.

Route getters and `set_live_count` through the maintained count. Keep iterator
bounds based on the entry log; a live count cannot replace an iterator position
limit. Add diagnostic-only recomputation assertions to catch missed mutations.

### Experiments and validation

- Sizes 0, 1, 7, 8, 16, 1,024, and 65,536; query size repeatedly after construction.
- Build while reading size each iteration; compare scaling when size doubles.
- Fixed live population with many deletions/reinsertions; repeated size reads.
- Control insertion/get/has loops without size reads, and many tiny retained maps.
- Check duplicate insertion, overwrite, undefined keys/values, delete misses,
  clear/reuse, callbacks that mutate collections, and iterators spanning mutations.
- Validate Map/Set test262 directories, including set operations and groupBy where
  selected by the current scope. Check getOrInsertComputed mutation explicitly.

Keep if size-query scaling becomes independent of log length, the targeted
workload improves measurably, and count maintenance/pool rounding does not impose
an unacceptable insertion or small-collection memory cost.

## B. Compact Promise reaction records

### Hypothesis and staged prototype

Direct fields can remove reaction property installs, reads, and hidden-link
lookups, while a smaller representation can reduce allocation and tracing work.

First enumerate producers and consumers: then/catch/finally, await, adoption,
combinators, custom species/capabilities, settlement, job enqueue/drain, rejection
tracking, GC marking, reset, and teardown. Count reaction allocations, bytes,
property operations, and queued jobs on representative async workloads.

Prototype B1 changes the internal reaction representation while retaining the
existing job queue protocol. Use a typed traced record or dedicated internal
object payload; choose after measuring actual size and pool rounding. Direct
fields hold fulfillment/rejection handlers, downstream/capability state, and next.
Start with intrinsic promises and retain an explicit fallback for unsupported
capabilities. Mixed representations must have a defined traversal and ownership
contract. Preserve every observable handler invocation and job boundary.

Write an ownership table for pending-list, detached settlement list, queued job,
currently executing handler, and abandoned/reset states. Every live record and
TVal edge must be traced, including records temporarily held across allocation or
reentry. Define cancellation/error teardown and reference transfer explicitly.

B2 may enqueue compact jobs or reduce queue copying if B1 measurements show that
queue work remains important. Measure B2 separately; it must not double-count B1
savings or introduce synchronous execution of settled-promise handlers.

### Experiments and validation

- Long settled chains, many reactions on one pending promise, rejection chains,
  repeated await, combinators, and many simultaneously suspended operations.
- Mix native promises, custom thenables/species, throwing handlers, and handlers
  that enqueue more jobs. Include a synchronous allocation control.
- Record reaction bytes/allocations, property work, jobs executed, queue high-water
  mark, GC work, runtime, and peak RSS. A lower allocation count alone is not a win.
- Check FIFO order, asynchronous settlement, pass-through reactions, adoption,
  self-resolution, rejection tracking, finally, and capability callbacks.
- Narrow Promise and async-function test262 coverage; fresh ASAN/GC stress,
  repeated context teardown, local suite, Rosetta, and NONANBOX.

Keep B1/B2 independently only with preserved job behavior and measured time or
memory gains. Reject a representation whose extra dispatch/ownership machinery
outweighs the property work removed.

## C. Fixed-shape object literal initialization

### Hypothesis and prototype

The current NEWOBJ/INITPROP sequence performs property definition work for each
key. A literal-site descriptor can select a complete existing shape, allocate its
value storage once, and initialize known slots directly.

Start with fresh ordinary literals containing unique constant non-index string
data keys. Exclude spread, computed keys, accessors/methods, duplicate keys,
prototype-setting syntax, and suspension points. Class-instance construction is a
separate extension: constructors can expose `this`, invoke inherited setters, and
return alternate objects, so literal eligibility does not transfer automatically.

Record eligible literal sites during compilation and reuse the engine's shape
system. Define descriptor ownership, key roots, cache invalidation across heap
reset, and cleanup with the compiled function. Avoid unsafe cross-heap shape ids.

Choose the instruction form after disassembling representative literals: allocate
with a descriptor and store by slot, or combine initialization where registers
permit. Preserve initializer evaluation order, anonymous-function name inference,
and abrupt completion. Initialize every slot to a GC-safe value before allocation
or callbacks can expose it to tracing. Account for extra register pressure and
metadata; an optimization that retains all initializer values can enlarge frames.

### Experiments and validation

- Literals with 1, 2, 4, 8, and 16 keys; primitive versus heap values; retained
  objects versus allocate/read/discard churn; repeated versus many distinct sites.
- Existing `bench_object`, shape benchmarks, ES6 destructuring, and class controls.
- Count shape transitions, property-definition operations, allocations, bytecode
  dispatches, descriptor bytes, register counts, runtime, and RSS.
- Check key order/descriptors, inherited setters, initializer side effects/throws,
  nested allocation/GC, inferred names, fallback forms, and execution after reset.
- Narrow object-initializer/property-definition test262 directories; bytecode
  goldens where applicable, local suite, Rosetta, fresh ASAN, and NONANBOX.

Keep if repeated eligible construction improves beyond current INITPROP and
metadata, compilation, or frame costs do not create meaningful control regressions.
Only then evaluate a separately guarded class-construction extension.

## D. Call setup and frame compaction

### Evidence gate

Measure call counts by entry path, allocated register spans, register occupancy,
initialization/cleanup work, environment allocations, and valstack growth. Include
ordinary direct calls, native callbacks, constructors, recursion, and rest/default
parameters. Existing scope elimination and compiled-call shortcuts are baseline.

Use `compiler/moveelim.c3`, `compiler/context.c3`, `vm_calls.c3`,
`vm_execute.c3`, activation ownership code, and [090](090-resolved-bindings.md).
Determine whether time is in frame work, dispatch/classification, or environment
allocation before choosing the first implementation. Low measured overhead is a
valid reason to close a proposed shortcut.

### Bounded prototypes

D1: trim provably unused trailing registers after optimization. Model implicit
operands, entire call/argument windows, parameter/rest locations, captures,
exception edges, multiword instructions, and metadata references. Unknown forms
retain their current frame size. Never infer deadness from explicit operands only.

D2: compact temporary registers for eligible ordinary functions using binding-aware
liveness. Pin ABI-visible parameters, persistent capture owners, and required
contiguous call windows. Remap all register-bearing metadata. Initially fall back
for eval/with, suspension, exception complexity, and unsupported opcodes. Reuse the
existing liveness solver only after auditing its meaning for this transform.

D3: if classification/setup still dominates tiny hot calls, prototype a guarded
stable-callee shortcut into existing activation setup. Account for existing CALL_VAR
and ordinary compiled-function fast paths before adding a cache. Guard callable
identity/kind and maintain this conversion, strictness, arguments, new.target,
exceptions, recursion, interrupts, and reentry behavior. Avoid benchmark-body
recognizers such as the rejected rest.length shortcut in plan 089.

### Experiments and validation

- Existing function_call, recursion, valstack_copy, spread_rest, and closure tests.
- Checked functions with short/long temporary lifetimes, large argument windows,
  branches, and mixed captured/local values; deep retained call stacks.
- Report compile time, eligibility rate, registers saved, setup/cleanup work,
  stack growth, runtime, RSS, and code/metadata size for D1/D2/D3 separately.
- Check callback-triggered stack relocation, mapped arguments, closures after
  return, constructor calls, getters/coercions reentering JS, abrupt exits, and
  excluded async/generator paths. Run bytecode goldens and relevant function,
  arguments, closure, and exception test262 subsets plus local/Rosetta/ASAN checks.

Retain each stage only when frame/setup savings translate into useful measured
benefits without changing ownership or call semantics.

## E. Extend indexed capture coverage

### Evidence and prototype

Existing GETCAP/PUTCAP and compact var/parameter cells are baseline. Instrument
fallbacks by reason: lexical scope reentry, shadowing, transitive references,
dynamic scope, or unsupported consumer. Count executed fallback accesses and
environment allocations, not just static functions marked eligible.

E1: forward a statically resolved capture through intermediate closures so the
consumer reaches the same owner/cell without a name search. Preserve owner lifetime
even when an intermediate closure does not itself read the value.

E2: assign explicit lexical scope identities and extend cells to an eligible
lexical subset. Begin with scopes executed once; treat per-iteration fresh cells
as a separate extension. Keep TDZ/uninitialized state and const checks explicit.
Dynamic lookup stays on its supported environment path. Do not blanket-disable
sloppy functions; scope behavior determines eligibility.

### Experiments and validation

- Immediate versus transitive captures, same-named shadowed bindings, siblings
  sharing mutations, retained closure factories, and per-iteration closures.
- Measure fallback reduction, environment/cell allocations, retained-owner bytes,
  creation cost, read/write throughput, and peak RSS. Use unchanged closure_capture
  and let_loop plus controls that already use compact cells.
- Check eval/with shadowing, TDZ, const writes, break/continue, loop reentry,
  exceptions, GC after outer return, callbacks, and constructor entry. Use narrow
  lexical/closure/loop/eval test262 sets, local/Rosetta, and fresh ASAN/GC stress.

Prototype only branches with material executed fallback cost. Keep E1/E2
independently; reject broader coverage that raises common closure creation or
retained-memory costs beyond its demonstrated benefit.

## F. Reduce interpreter dispatch

### Evidence and prototypes

First verify opcode-pair counts across switch and threaded execution against a
known bytecode loop. Instrument both paths if necessary, avoiding double counting
at burst entry/exit. Keep counter overhead out of timing binaries.

F1: select a frequent sequence with measurable dispatch/register-transfer cost
that existing fusion does not cover. Add one fused form and compiler transform.
Specify branch-entry restrictions, observable intermediate values, reference
ownership, exception-PC mapping, and interrupt polling. Audit every bytecode
consumer: decoder, disassembler, instruction widths, liveness, optimizer, and both
execution paths. Compare dispatch count and release runtime.

F2: only if F1 leaves material dispatch overhead, prototype predecoded basic blocks
for a narrow hot numeric loop. Define hotness threshold, cache memory, bounded
execution, exits on guards/calls/throws, and original-PC maps. A micro-op loop still
dispatches: do not assume predecoding eliminates dispatch unless the implementation
actually combines operations. Charge discovery and construction time to total cost.

### Experiments and validation

- Arithmetic/loop workloads, mixed property/call code, short scripts, and large
  code working sets. Include unpredictable branches and failed guards.
- Measure dispatches, decoding work, executable/cache size, startup, steady-state
  time, and RSS. Use hardware instruction/branch counters if available; state when
  only software counters are available.
- Validate branch targets, overflow/coercion fallback, debugging PCs, exceptions,
  interrupts, and optimization-disabled equivalence. Run bytecode goldens,
  Rosetta/local, and test262 subsets for the fused operations.

Keep F1/F2 separately only when release measurements justify their code and
metadata footprint. Reject a loop-only gain accompanied by broad code-cache or
startup regressions.

## G. Allocation work, growth policies, and locality

### Evidence gate and bounded experiments

Profile allocation bytes/frequency, clearing bytes, growth copies, retained pool
capacity, and GC marking work by object category. Start from plan 091's measured
layouts. Do not repeat rejected inline-property removal, alignment, or shared-name
proposals without new workload evidence.

G1: remove demonstrably redundant clearing at a specific allocation boundary.
Document fresh versus recycled block initialization and every field readable by
GC/teardown. Keep an initialization contract; uninitialized reuse is not a speedup.

G2: change a measured growth/reservation policy for a selected scratch buffer or
queue. Compare copied/cleared bytes, capacity retention, OOM behavior, and callback
reentry. Preserve heap allocator callbacks and raw-pointer refresh requirements.
An allocator adapter may support the experiment, but adapter consolidation itself
has no assumed gain.

G3: if marking or cache misses dominate a class, test one layout/pool adjustment
with compiler-derived offsets and sizes. Measure physical allocation stride and
page rounding as well as logical struct size. Preserve inline property behavior.

### Experiments and validation

- Allocation churn, retained arrays/objects/closures, bursty queue/scratch growth,
  large-then-small reuse, and minimal-script memory. Include named-property objects.
- Use existing memory fixtures and relevant workload controls. Track runtime,
  bytes cleared/copied, reserved/live bytes, GC work, and RSS.
- Validate fresh/recycled storage, reset/teardown, allocation failures where the
  harness supports them, growth during callbacks, tracing, and NONANBOX. Use fresh
  ASAN/GC stress and the local/Rosetta suites for retained changes.

Keep only a concrete policy/layout change with repeatable benefit. A refactor with
equal timings is maintenance work and should be recorded separately.

## H. Collection hash-index behavior under churn

### Hypothesis and prototype

The ordered log and lookup index have distinct lifetime requirements. Deleted log
entries preserve iteration positions, but need not force oversized lookup tables
or long probe chains. Current rebuild sizing uses `array_used / stride`, and
lookup slots can keep referring to deleted log entries.

Instrument successful/missing probe lengths, index bytes, rebuild frequency/time,
historical entries, live entries, and deleted occupancy. Compare stable maps with
fixed-live-size delete/reinsert workloads before selecting thresholds.

H1: maintain index deletion state and periodically rebuild by live occupancy.
Preserve probe chains with tombstones or a proven deletion algorithm. Keep empty
slots available, bound probes, and preserve linear fallback on allocation failure.
Use A's count if available, but report H's incremental cost separately. Update
index mutation/invalidation for direct set-result writes, clear, Weak collection
compaction, and GC-driven weak removal if applicable after auditing those paths.

Do not compact the ordered log in H1. Shrinking the index cannot fix retention of
the log itself. Any future log compaction needs iterator-position/lifetime tracking
and a separate design; report residual memory explicitly.

### Experiments and validation

- Fixed live sizes with 10x and 100x historical churn, hit/miss mixes, clear/refill,
  small collections, numeric/string/object keys, and collisions.
- Compare probes, rebuild work, index bytes, total RSS, and get/has/set/delete
  throughput; control append-only construction and iteration speed.
- Check delete/reinsert order, iterators spanning deletion/clear/appends, mutation
  during forEach, set-operation results, and Weak collection paths touched by the
  patch. Run focused collection fixtures and Map/Set test262 subsets; fresh ASAN
  for ownership changes. Preserve current test selection.

Keep only if bounded index memory/probes produce useful churn improvements without
frequent rebuilds or meaningful append-only regressions.

## Integration, decisions, and deliverables

Begin with a common baseline and diagnostic coverage, then A/B/C. Investigate D/E/F
with counters before implementing their gated stages. Run G against allocation
evidence from all tracks, and H after A or with an independently computed live count.
Each track receives a decision even if its evidence gate stops implementation.

After individual decisions, combine retained changes and rerun the unchanged
benchmark controls and relevant semantic suites. Compare the combined build to
the original baseline and, where attribution is unclear, to the combined build
with one candidate removed. Frame compaction and literal registers interact;
Promise records and pools interact; collection counts and churn share metadata.
Do not add individual percentage gains to predict the combined result.

Update `docs/architecture.md` for retained representation or execution changes.
Save checked fixtures, paired measurements, build metadata, and a short decision
record per prototype. Keep machine-specific artifacts outside tracked source;
commit the useful summaries and reproducible benchmark/validation instructions.

| Track | Evidence gathered | Prototype | Semantic checks | Timing / memory | Decision |
|---|---|---|---|---|---|
| A | mutation paths audited | live count + shared append | passed; see results below | interleaved A/B | keep |
| B | reaction property paths audited | dense traced slots | passed with baseline ASAN exception | -18% to -24% time; +4% to +5% RSS | keep speed/memory tradeoff |
| C | source only | pending | pending | pending | pending |
| D | source only | gated | pending | pending | pending |
| E | source only | gated | pending | pending | pending |
| F | source only | gated | pending | pending | pending |
| G | source only | gated | pending | pending | pending |
| H | source only | gated | pending | pending | pending |

Completion means every track has a supported decision, retained changes have
combined validation, and results distinguish throughput, latency, memory, and
workload coverage. A rejected prototype is a completed experiment.


## Track A results: maintained collection counts

Decision: keep. Map/Set size reads use a collection-payload live count.
Insertion publishes a complete reserved entry before incrementing the count;
replacement is count-neutral. Delete, clear, groupBy, get-or-insert, and direct
Set-operation result mutations maintain it. Iterator bounds use the entry log.
Weak collections share append reservation but do not maintain a live count.

The count enlarges the logical collection payload; the existing small-pool block
still accommodates it, so the physical pool stride is unchanged. This is not a
claim of zero overhead for pool-bypass allocations or other value layouts.

Release baseline: `fa9cad5e` (engine sources match `ba8610c8`). Seven alternating
A/B pairs after one warmup pair, with the leading binary swapped each pair.
Times include process startup, compilation, and execution on macOS ARM64,
using C3 0.8.3 with LLVM 22.1.8 and the project release target.
Short fixtures expose the startup floor; the large scan removal is clear, while
small control differences are not attributed to this change.

| Checked workload | Baseline median | Candidate median | Time change |
|---|---:|---:|---:|
| map_size_1024 | 0.0379s | 0.0089s | -76.5% |
| map_size_8192 | 0.2309s | 0.0093s | -96.0% |
| map_grow_size | 0.0416s | 0.0068s | -83.6% |
| map_insert_has | 0.0874s | 0.0865s | -1.0% |
| map_retained_small | 0.0427s | 0.0423s | -0.9% |
| set_size_1024 | 0.0381s | 0.0085s | -77.7% |
| set_size_8192 | 0.2304s | 0.0091s | -96.0% |
| set_grow_size | 0.0418s | 0.0067s | -83.9% |
| set_insert_has | 0.0815s | 0.0806s | -1.1% |
| set_retained_small | 0.0421s | 0.0418s | -0.7% |
| map_deleted_size | 0.2356s | 0.0093s | -96.1% |
| set_deleted_size | 0.2334s | 0.0092s | -96.1% |

The 25 unchanged ES5/ES6 control fixtures range from -2.4% to +1.8% runtime.
Outputs match; only elapsed-millisecond fields in Date/RegExp output are
normalized. Interleaved baseline/baseline insertion controls differ by +0.7%
(Map) and -0.2% (Set), so small insertion changes are treated as noise.
For 100,000 retained two-entry collections, median peak RSS is 38,256,640 bytes
for both Map builds and 38,240,256 versus 38,273,024 bytes for Set (effectively flat).

Validation: 809 selected Map/Set/WeakMap/WeakSet test262 cases pass, with four
scope skips and no failures; 42 Rosetta cases; 465 local scripts and all local
auxiliary suites. The focused live-count fixture also passes in Node and in a
fresh ASAN + GC_STRESS + POOL_BYPASS build. The focused fixture and existing collection hash-index fixture also pass in
a freshly built NONANBOX engine; the release build is restored. The fixture checks threshold crossings, replacement/deletion,
undefined/NaN/zero, groupBy, reentrant computed insertion, Set result mutation,
iterator/forEach mutation, object keys, and named collection properties.

Artifacts: `/tmp/boomkat-perf-093/A/` contains immutable baseline/candidate
binaries, per-run JSON with RSS and output, generated checked workloads, and
validation logs. Reproduce timing with:

```sh
python3 scripts/bench_collection_counts.py /path/to/baseline /path/to/candidate --out /tmp/collection-counts --controls
python3 scripts/bench_collection_counts.py /path/to/baseline /path/to/baseline --out /tmp/collection-counts-aa --only '*insert_has'
```

Every timing comparison, including noise controls, must remain interleaved.
The runner uses macOS `/usr/bin/time -l`; cross-platform timings remain unmeasured.


## Track B results: direct reaction slots

B1 keeps ordinary then/await reactions in four dense traced TVal slots on an
internal plain object with zero named-property capacity. Slots contain fulfillment,
rejection, downstream, and next. Custom capability records retain named storage;
other reaction producers can coexist in the same linked list. The microtask queue
and observable job boundaries retain their existing representation and order.
Generic object tracing and teardown own the dense values. Pending Promise marking
walks either link representation. B2 queue replacement remains gated: these results
establish a reaction-access benefit, not a queue bottleneck.

Seven interleaved A/B pairs against `cc8deb08`, alternating the leading binary:
checked chain/await/fan-out takes 0.1213s to 0.0928s (-23.5%), unchanged Promise
benchmark 0.4626s to 0.3784s (-18.2%). Object/call controls change +1.2%/-0.3%.
Peak RSS grows 57,917,440 to 60,768,256 bytes in the checked workload (+4.9%) and
269,893,632 to 279,560,192 in the Promise benchmark (+3.6%). Keep for throughput;
this representation does not claim a memory reduction. A dedicated inline record
could address the extra dense allocation in a later measured experiment.

Validation: 642 selected Promise tests and 74 async-function tests pass; the 90
Promise skips follow existing scope. Focused fixture passes in Node and release.
Fresh ASAN/GC-stress baseline and candidate both pass the intrinsic fixture.
The mixed fixture's Promise-subclass case triggers the same activation-root
use-after-free in both freshly built baseline and candidate. It is a baseline
limitation, with logs preserved, and is excluded only from the clean ASAN claim.
466 local scripts and all auxiliary suites pass, as do 42 Rosetta cases and
the focused fixture in NONANBOX. The normal release build is restored.
A second interleaved run over all 25 unchanged ES5/ES6 controls shows Promise
time -17.1%; other fixtures range from -1.7% to +1.8%.

Artifacts: `/tmp/boomkat-perf-093/B/`, including exact baseline and candidate
ASAN binaries and logs, paired time/RSS samples, and checked workload. Use
`scripts/bench_interleaved.py` with explicit binaries and fixture paths to repeat.
Git stash lists are shared by worktrees: archive experiments by immutable object
ID and pin experiment refs rather than using a moving `stash@{0}` to restore.

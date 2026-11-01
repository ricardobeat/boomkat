# 113: The 50,000 full-Octane target

Status: **ACTIVE — condensed 2026-11-01; assessed at rat `ec422de6`.**
50K remains unachieved. This is the active JIT roadmap for plans 107–108, 110–112 and 116–118.

## Objective and architecture

Reach 50,000 on original complete Octane, preserving algorithms, validation, warmup
and latency results. Improve integer/buffer, floating-point, object/allocation and
closure/application workloads; profile native-library and frontend costs separately.

Keep SLJIT as the backend and extend the existing graph and lowering:

`decoded bytecode + feedback → cyclic typed SSA + effects/frame states → optimization → representations/global allocation → SLJIT + recovery/root maps`

This is a coordinated architecture refactor. Architectural milestones below
remain required; isolated opcode improvements, larger windows and more baseline
coverage do not substitute for effects, cyclic optimization or global allocation.
Preserve bounded compilation/memory and the existing embedding/execution modes.

## Current capabilities and gaps

- Shared SSA serves loop regions and bounded function regions/frameless callees.
  Whole-body cyclic leaves admit up to 128 bytecodes; nested loops can form one
  cyclic graph. Loop-header joins, late backedges, cycle-valid dominance,
  converting parallel copies and backedge polls exist.
- Frameless refusal replays the call. Admission therefore requires pure reads
  and expanded pure helpers, terminal writes after guards, or narrowly proven
  idempotent writes. This is not general recovery after effects or generic calls.
- Rooted write dependencies and safe invalidation/retirement already support
  watched numeric globals and inherited methods. Reuse these contracts.
- Cyclic graphs skip invariant CSE, CSE, numeric-load refinement and function
  liveness passes. Allocation follows flat definition order; cyclic joins reserve
  private homes conservatively. Embedded field SSA has three integer homes.
  A cyclic graph executing correctly is not yet a cycle-aware optimizing tier.
- A bounded WIDE decoder, sparse loop-register remapping and CFG continuation
  liveness exist. A scalable shared decoded CFG with canonical operand roles,
  recovery uses and general call/register windows remains incomplete.
- Native remainder, numeric typed-array dispatch and regexp rejection are useful
  delivered changes. They do not close the structural gaps above.

The older [typed-array checkpoint](113-fifty-thousand-octane/typed-array-dispatch-2026-10-31/report.md)
records a full-suite median about **6,563**, not a current-revision measurement.
Refresh attribution; historical bytecode shares and CPU percentages are stale.

## Ordered implementation and acceptance

### 1. Refresh evidence and define shared contracts

Use `just sljit-stats` and `scripts/bench_interleaved.py` to rank admission, exits and CPU costs.
Select real consumers across numeric/buffer, floating-point and object/closure
clusters; keep Richards/DeltaBlue as regression checks. Record source/configuration
hashes, compilation CPU, native/metadata bytes and memory. Distinguish interpreter,
baseline, optimized body, helpers, GC and frontend in phase-checked profiles.

Specify the effect/recovery/call interfaces and cycle-aware analysis together
before adding another execution path. Audit existing decoder, compiler liveness,
SSA graph/build/opt/emit and function/loop adapters; reuse their working pieces.

Acceptance: a ranked blocker table, a short representative iteration panel and
one blocked real consumer for each following structural milestone.

### 2. Consolidate the decoded CFG and recovery-aware uses

Build one indexed WIDE-aware instruction view retaining prefix/opcode/next PCs,
branch/fallthrough and exception boundaries. Share canonical read/write roles,
CFG edges, traversal, dominance and phi operands between loop/function analyses.
Constant-pool indices must never become register uses. Separate execution uses
from values needed only by recovery, including inline frames and latch operands.

Replace structural dense PC-by-register matrices and fixed masks with budgeted
nodes, edges and sparse states where required. Preserve sparse register mappings
through emission and re-emission; represent contiguous call windows explicitly.
Keep supported baseline exits for unsupported irreducible/exception cases.

Acceptance: diamonds, multiple backedges, nested loops, WIDE/high registers and
exit-only live values agree with the interpreter. Demonstrate native activation
and completion on real consumers, with bounded compile/memory cost. Remove
superseded analysis as shared consumers migrate; raising caps is not this milestone.

### 3. Add exact-PC effects, calls and runtime continuations

Give IR operations explicit pure/read/write/allocation/call/throw/poll effects.
Carry memory/fact versions through joins and backedges, conservatively killing
facts on unknown mutation. Use proven receiver/location identity for aliasing.
Attach sparse frame states before and after observable operations: exits resume
before an unperformed effect or after a completed effect, never replaying it.
Include inline caller/callee state, exception destinations and ownership.

Model generic calls with argument/result locations, clobbers and recovery states;
inline profitable known callees under rooted dependencies. Define helper outcomes
for completion, exceptions and polls. Publish precise roots or use root maps,
respect string/refcount/barrier rules, reload movable frame pointers, revalidate
facts after mutation and protect active code and incoming links during retirement.
Allocation or watch-registration failure must decline specialization safely.

Acceptance: an effectful cyclic body stores, continues natively and later exits
at the correct PC with exactly-once effects; a hot loop crosses a non-inlined
call; a separate allocation/closure consumer resumes after a completing helper.
Exercise aliasing, mutation, stack growth, collection, exceptions and invalidation.
A single generic call must not disqualify the surrounding computation.

### 4. Optimize and allocate across the connected cyclic graph

Make liveness, representation/type/range inference and memory facts converge over
cycles, with edge phi uses and recovery states included. Enable sound CSE/load
elimination, forwarding, redundant-guard removal, dead-code elimination, invariant
hoisting and proven bounds-check elimination on cyclic graphs. Keep useful values
unboxed across blocks/calls; preserve overflow, shifts, -0, NaN, holes and coercions.

Replace conservative graph-wide join reservations and flat-order allocation with
GPR/FPR live ranges across blocks, call clobbers and target-derived availability.
Coalesce edge copies safely, reuse dead operands and rematerialize cheap values.
Select SLJIT context from actual allocation. Defer scalar replacement until roots
and recovery can reconstruct eliminated objects. Develop these passes alongside
steps 2–3 where possible; do not postpone them for more coverage experiments.

Acceptance: bytecode and native disassembly identify fewer executed checks,
loads/stores, conversions or spills, and matched timings show repeatable wins
across relevant workload clusters. Static instruction counts alone are insufficient.

### 5. Close runtime, admission and full-suite gaps

Profile remaining allocation/GC, strings, environments, regexp and frontend costs.
Optimize dominant runtime kernels; measure code usefulness, compilation, metadata/RSS,
retirement/recompilation and GC before changing budgets.

At capability/performance milestones, run the original full suite with at least
three alternating matched pairs; publish every result, geometric mean and resource
costs. Only an actual score under those conditions closes the 50K objective.

## Iteration rules and retained traps

For each slice prove the intended generated path executes, validate output, then
run uninstrumented alternating timings without concurrent builds/profiling/tests.
Confirm promising gains with longer pairs; investigate repeatable mini regressions
above roughly 3%. Infrastructure may land without a speed claim only when it enables
a concrete consumer with bounded cost. Run appropriate interpreter/JIT differential,
embedding ARM64/x64, ASan/GC and stress checks before promotion.

Blind budget/window/spill increases and interpreter capture/WIDE fusions have
repeatedly lost. Function-tier property continuations also lost despite increased
native coverage; helper joins must reconcile flow/ownership and use the correct
frame window. Do not infer nonaliasing from descriptor IDs or treat entry-only
global snapshots as valid after effects. Reuse experimental pieces selectively.

History: `git show 28d16112:plans/113-fifty-thousand-octane.md`. Evidence remains in
`plans/113-fifty-thousand-octane/`. Keep this file focused on current architecture,
next milestones and measured acceptance.

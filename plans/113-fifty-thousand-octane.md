# 113: The 50,000 full-Octane target

Status: **ACTIVE — architecture correctness accepted; performance blocked by regressions, 2026-11-02.**
50K remains unachieved. This is the active roadmap for plans 107–108, 110–112 and 116–118.

## Objective and design

Reach 50,000 on original complete Octane, preserving algorithms, validation,
warmup and latency results. Cover numeric/buffer, floating-point, object/allocation
and closure/application workloads; attribute frontend and native-library costs separately.

Keep SLJIT and consolidate the existing compiler around:

`decoded bytecode + feedback → cyclic typed SSA + effects/frame states → optimization → representations/global allocation → SLJIT + recovery/root maps`

Preserve bounded compilation/memory and embedding, script and module semantics.
Wider windows and isolated opcode improvements do not substitute for these contracts.

## Current phase: finish the architecture

Milestones 2–4 passed architecture correctness checks; performance acceptance
remains open. [Regression repairs](113-fifty-thousand-octane/repair-2026-11-02/report.md)
and the follow-up [SSA throughput pass](113-fifty-thousand-octane/ssa-throughput-2026-11-02/report.md)
(29da643a dictionary-receiver inherited reads, ea96005b pooled SSA scratch,
feedback-driven plan rebuilds, helper-dominated demotion and a 320-opcode
whole-body bound) now beat the historical baseline on Gameboy (1.19x), hold
Mandreel and DeltaBlue at parity and keep Navier at 2.14x. Box2D (0.75x) and
Crypto (0.94x) remain open regressions. The warmed Gameboy run also exposed
threaded builtin stack growth; rat releases that native frame before tail
dispatch, with failed-before regression coverage. Final-head matched full-Octane
results are still required.

[Matched JSC/native inspection](113-fifty-thousand-octane/jsc-native-2026-11-02/review-report.md)
identifies lost integer induction and repeated binding/storage validation as the
next architectural work. A guarded integer-capture candidate is committed
separately and awaits performance review; hoisting is not implemented. Keep one
SSA compiler and SLJIT. Work is confined to `rat`; plans stay on `plans/archive`.

Accepted architecture:

- Canonical decoded CFG, semantic operand roles and continuation liveness;
  effectful cyclic SSA with exact recovery after committed stores.
- Budgeted dynamic SSA nodes, blocks, predecessor lists, dominance, register
  state and sparse immutable recovery frames; stable IDs separate from scheduling.
  Decoded lowering, work budgets, WIDE/high-register gateway activation and
  dynamic invocation storage are integrated. Shared deopt freezes locations
  once and uses small guard stubs; decoded operand validation and compilation
  work/memory budgets bound admission.
- Generic call/allocation continuation with typed live-home preservation,
  boxed roots, stable activation lookup after stack growth, explicit
  before/after outcomes and exception handoff. Capturing closures, compact
  cells and the single-operation interpreter bridge are integrated. Fresh
  binding reads handle aliases with native stores. Effectful inline prefixes
  execute native stores and reconstruct logical caller/callee frames at the
  exact unsupported or failing child instruction.
- Native dense/typed/own-field access nodes use actual SSA receivers and live
  storage/generation guards, including after a callback moves array storage.
- Guard-safe DCE, CFG effects/CSE, scalar interval facts and proven native
  bounds removal. Explicit import/preheader topology enables real LICM. Cyclic
  allocation includes recovery and phi-edge uses; numeric constant
  rematerialization removes constant homes and helper save/restore traffic.
- Shared executable owners for function, loop and template code; pins through
  native recovery/publication; deferred retirement and exact code accounting.
  Capacity-generation retries and exact-PC loop admission replace sticky waits
  and colliding rejection masks. Policy defaults remain unchanged.

Evidence: [combined architecture acceptance](113-fifty-thousand-octane/architecture-contracts-2026-11-02/report.md)
and [scalable memory/recovery contracts](113-fifty-thousand-octane/ssa-architecture-2026-11-01/contracts/scalable-memory/report.md).
Earlier full-suite scores are roughly 6.4K; 50K is not achieved. Isolated native
activation or lower instruction counts are evidence of mechanism, not a full-suite win.

## Milestones and acceptance

### 1. Attribute the remaining cost — performance phase

Refresh admission, exits and phase-checked profiles across representative workload
clusters. Rank interpreter, baseline, optimized body, helpers, GC and frontend costs.
Record source/configuration hashes, compilation CPU, native/metadata bytes and RSS.
Keep Richards/DeltaBlue as regression checks and identify a blocked real consumer
for each architectural change below.

### 2. Shared scalable CFG and recovery analysis — architecture accepted

Consume WIDE/high-register operands throughout SSA lowering. Replace dense fixed
PC/register structures with budgeted nodes, edges and sparse frame states; preserve
register mappings through emission and re-emission. Consolidate duplicate traversal,
dominance, liveness and phi analysis. Distinguish execution from recovery-only uses.

Acceptance: large real consumers, diamonds, multiple backedges, nested loops,
WIDE/high registers and exit-only values agree with the interpreter. Unsupported
exception/irreducible cases have explicit safe exits. Raising caps alone is insufficient.

### 3. Calls, effects and runtime continuations — architecture accepted

Add graph-level argument/result locations and clobbers, effectful inlining with
caller/callee recovery, and allocation/helper continuations. Model throw/poll
outcomes, ownership and precise roots/root maps; reload movable frames and reset
facts after mutation. Protect active code and incoming links during retirement.
Allocation or watch-registration failure must decline specialization safely.

Acceptance: native stores followed by exact recovery; a loop crossing a generic
call; and a separate allocation/closure consumer continuing after a completed
helper. Exercise aliasing, coercion, mutation, stack growth, collection, exceptions,
interrupts and invalidation. A single call must not disqualify surrounding work.

### 4. Cyclic optimization and allocation — architecture accepted

Extend fixed-point facts with type/range reasoning, DCE, LICM and proven bounds
removal. Preserve overflow, shifts, -0, NaN, holes and coercion semantics. Add
call-aware allocation, safe edge coalescing, rematerialization and contexts selected
from actual allocation. Scalar replacement waits for object reconstruction at exits.

Conservative scope: effectful inlining currently handles straight-line prefixes;
unsupported child instructions resume in a materialized callee. LICM requires a
shared dominating preheader and declines rotated loops with bypassing side
entries. Bounds proofs stop at potentially mutating callbacks. These cases use
the same recovery contracts; widening optimization coverage is follow-up work.

Architecture acceptance: bytecode and disassembly demonstrate working motion,
guard removal, call preservation and allocation on actual native paths; focused
correctness and bounded compile/memory checks pass. Repeatable matched timing
wins remain a separate performance gate; static instruction counts do not close it.

### 5. Close runtime and full-suite gaps — performance phase

Profile remaining allocation/GC, strings, environments, regexp and frontend costs.
Optimize dominant kernels; measure usefulness, metadata/RSS, compilation and
retirement before changing admission budgets. At performance milestones run at
least **three alternating matched full-suite pairs**, preserving every result,
geometric mean and resource costs. Only an actual qualifying score closes 50K.

## Iteration rules

Prove native activation and correct output first. During this phase use focused
correctness, allocation-failure, GC, recovery and native-code checks. Once tuning
resumes, run uninstrumented pairs
without concurrent builds/tests/profiling; investigate repeatable mini regressions
above roughly 3%. Run appropriate differential, embedding ARM64/x64, ASan/GC and
stress checks. Infrastructure can land without a speed claim only when it enables
a concrete consumer with bounded cost. Do not infer nonaliasing from descriptor
IDs, reuse entry snapshots after effects, or replay completed stores on retirement.

Keep commit history in Git and detailed experiments in the linked evidence.

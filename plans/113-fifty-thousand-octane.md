# 113: The 50,000 full-Octane target

Status: **ACTIVE — architecture implementation, 2026-11-01.**
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

Throughput tuning is deferred by user instruction. Complete and integrate the
contracts below before resuming benchmark sweeps. Keep one SSA compiler and SLJIT;
scale the shared IR and runtime boundary instead of adding another specialized tier.
Work is confined to `rat`; plans remain on `plans/archive`.

Implemented foundations (individual milestones remain partial):

- Canonical decoded CFG, semantic operand roles and continuation liveness;
  effectful cyclic SSA with exact recovery after committed stores.
- Budgeted dynamic SSA nodes, blocks, predecessor lists, dominance, register
  state and sparse immutable recovery frames; stable IDs separate from scheduling.
  Decoded lowering, work budgets, WIDE/high-register gateway activation and
  dynamic invocation storage are integrated. Shared deopt freezes locations
  once and uses small guard stubs; scalable admission auditing continues.
- Generic call/allocation continuation with typed live-home preservation,
  boxed roots, stable activation lookup after stack growth, explicit
  before/after outcomes and exception handoff. Capturing closures, compact
  cells and the single-operation interpreter bridge are integrated. Fresh
  binding reads handle aliases with native stores. Effectful inlining remains
  in progress; logical caller/callee recovery frames are now represented.
- Native dense/typed/own-field access nodes use actual SSA receivers and live
  storage/generation guards, including after a callback moves array storage.
- Guard-safe DCE and CFG effects/CSE; dynamic effects, range proofs and LICM
  are being integrated. Cyclic allocation includes recovery and phi-edge uses.
- Shared executable owners for function, loop and template code; pins through
  native recovery/publication; deferred retirement and exact code accounting.
  Capacity-generation retries and exact-PC loop admission replace sticky waits
  and colliding rejection masks. Policy defaults remain unchanged.

Current evidence: [scalable memory/recovery contracts](113-fifty-thousand-octane/ssa-architecture-2026-11-01/contracts/scalable-memory/report.md).
Earlier full-suite scores are roughly 6.4K; 50K is not achieved. Isolated native
activation or lower instruction counts are evidence of mechanism, not a full-suite win.

## Remaining milestones and acceptance

### 1. Attribute the remaining cost — performance phase

Refresh admission, exits and phase-checked profiles across representative workload
clusters. Rank interpreter, baseline, optimized body, helpers, GC and frontend costs.
Record source/configuration hashes, compilation CPU, native/metadata bytes and RSS.
Keep Richards/DeltaBlue as regression checks and identify a blocked real consumer
for each architectural change below.

### 2. Complete shared scalable CFG and recovery analysis — partial

Consume WIDE/high-register operands throughout SSA lowering. Replace dense fixed
PC/register structures with budgeted nodes, edges and sparse frame states; preserve
register mappings through emission and re-emission. Consolidate duplicate traversal,
dominance, liveness and phi analysis. Distinguish execution from recovery-only uses.

Acceptance: large real consumers, diamonds, multiple backedges, nested loops,
WIDE/high registers and exit-only values agree with the interpreter. Unsupported
exception/irreducible cases have explicit safe exits. Raising caps alone is insufficient.

### 3. Complete calls, effects and runtime continuations — partial

Add graph-level argument/result locations and clobbers, effectful inlining with
caller/callee recovery, and allocation/helper continuations. Model throw/poll
outcomes, ownership and precise roots/root maps; reload movable frames and reset
facts after mutation. Protect active code and incoming links during retirement.
Allocation or watch-registration failure must decline specialization safely.

Acceptance: native stores followed by exact recovery; a loop crossing a generic
call; and a separate allocation/closure consumer continuing after a completed
helper. Exercise aliasing, coercion, mutation, stack growth, collection, exceptions,
interrupts and invalidation. A single call must not disqualify surrounding work.

### 4. Complete cyclic optimization and allocation — partial

Extend fixed-point facts with type/range reasoning, DCE, LICM and proven bounds
removal. Preserve overflow, shifts, -0, NaN, holes and coercion semantics. Add
call-aware allocation, safe edge coalescing, rematerialization and contexts selected
from actual allocation. Scalar replacement waits for object reconstruction at exits.

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

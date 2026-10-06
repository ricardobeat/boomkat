# 103: Property regions and small-callee execution

Status: isolated interpreter prototypes; partial measurements retained.
The native copy-and-patch experiment is [plan 104](104-copy-and-patch.md). Worktree:
`.worktrees/hot-regions`, branch `prototype/hot-regions`.

## Baseline and scope

The source starts at `a9f66ceb` plus the working edits captured in
[`start.patch`](../benchmarks/hot-regions/start.patch). Main remains untouched.
The timing baseline compiles the experimental source with both features disabled.
All four production builds use the same O2 target and linker flags. Binary hashes
and sizes are recorded in [`binaries.json`](../benchmarks/hot-regions/binaries.json).

These experiments evaluate validation reuse and frame removal with native C3
helpers inside the existing interpreter. They retain bytecode decoding and do
not generate executable code at runtime. AST expansion, register allocation,
copy-and-patch stencils and a general optimizing tier remain separate work.

## Property regions

`PROTO_PROPERTY_REGIONS` keeps eight direct-mapped, borrowed property-slot
entries in the active dispatch context. A hit can reuse a slot across numeric
operations and loop back-edges. A second key on the same receiver can reuse
validated receiver and prototype-chain evidence when its cache records match.
The slot's current value is read on every visit.

An opcode whitelist identifies threaded paths without observable effects.
Other instructions advance the region epoch before execution. Getter entry,
string concatenation and every switch-to-threaded entry advance it explicitly.
Calls, property/environment writes, allocation and returns end regions; GC and
interrupt safepoints return through the switch. Stale raw pointers are compared
only after their epoch and identity guards; no borrowed slot crosses a barrier.

[`property-coverage.json`](../benchmarks/hot-regions/property-coverage.json)
records a separate instrumented build. Reuse occurs in the class and
destructuring workloads and the inherited-property control. Several ES6
workloads have no eligible hits, while all threaded instructions pay the
region-boundary check. This tradeoff must be judged on whole-workload timings.

## Small-callee execution

`PROTO_INLINE_REGIONS` classifies lean callees with at most 16 registers and
24 instructions. It accepts straight-line numeric operations, register copies,
constants, capture reads and ordinary cached property reads/writes. It rejects
calls, control flow, suspension, dynamic scope, argument objects and rest setup.

Calls still resolve the actual function. The helper borrows its arguments,
receiver and capture descriptors, then executes the body in fixed scratch.
Property writes require existing own writable numeric data slots. Up to eight
distinct writes are staged; later reads see those pending values. Publication
occurs only after the body, result and destination pass their guards. Refusal
leaves the ordinary call path responsible for coercion, accessors and exceptions.

This removes an activation and the body's threaded handler transitions, while
retaining an instruction loop in the helper. It measures a limited form of
callee execution inside the caller rather than AST expansion at the call site.
Native callbacks and tail-call paths retain their existing entry machinery.

[`coverage.json`](../benchmarks/hot-regions/coverage.json) records instrumentation
from the combined build. Class getters/methods, called lexical captures and the
numeric-call control exercise this path. Other ES6 workloads provide controls.
Instrumentation is absent from timing binaries.

## Validation

- Combined build: 577 local scripts and 20 module fixtures pass, plus companion
  syntax, diagnostics, TypeScript, rejection, robustness and private-member checks.
- Rosetta: 42 cases pass.
- [`hot_regions.js`](../test/hot_regions.js) agrees with the saved baseline,
  Node and QuickJS. It covers prototype replacement, shadowing, storage growth,
  coercions, getters, proxies, writes, call barriers, staged writes and fallback
  ordering, numeric boundaries, captures, strict receivers and callee replacement.
- Fresh NONANBOX fixtures pass.
- Fresh optimized ASAN with GC_STRESS, GC_VERIFY and POOL_BYPASS passes the
  focused fixtures and ownership/root checks in
  [`gc-validation.json`](../benchmarks/hot-regions/gc-validation.json).
  C3's configured ASAN runtime is missing; the fresh objects link to the installed
  LLVM 23 runtime. Leak detection is disabled for that run.
- Seven numerical ES6 workload checksums agree across all four builds in
  [`result-checks.json`](../benchmarks/hot-regions/result-checks.json).

## Measurement method

`just build-hot-matrix` builds and saves the four variants sequentially.
`just bench-hot-regions 9` runs the same eight scripts selected by `bench-es6`,
plus inherited-property, trivial-call and numeric-call controls.

Each workload gets one discarded warmup round and nine measured rounds. Variant
order is shuffled with a fixed seed; processes execute serially. The metric is
fresh-process wall time including compilation, execution and teardown. Peak
RSS, child CPU time, output hashes and executable hashes accompany raw timings.

The macOS monitor checks process lists before
each round and every 250 ms during the batch. It waits for benchmark, test and
compiler jobs, and rejects batches that overlap one. Normal desktop activity is
allowed. System and child CPU activity accompany the samples. An optional
`--load-policy idle` also enforces the runner's aggregate CPU threshold.
Rejected batches remain in the report. Builds and tests finish before timing.

The runner relies on read-only Mach CPU statistics and process inspection;
process inspection needs permission outside this session's sandbox. Load checks
reduce interference but do not control scheduling, power state or thermal policy.

## Results

Partial samples are in [`results.json`](../benchmarks/hot-regions/results.json).
The four-variant run ended when the native copy-and-patch prototype took priority;
these partial results do not establish a suite-wide gain.

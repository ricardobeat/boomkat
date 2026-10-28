# Parallel JIT implementation and cloud-review fixes, 2026-10-28

Three GPT-6.1 Terra agents worked independently on property-read continuations, SSA emission/allocation, and code admission. Parent review retained two small performance changes, rejected two larger experiments, and validated/committed the eight cloud-review fixes. This report is evidence for [active plan 113](../../113-fifty-thousand-octane.md), not another roadmap.

## Commits

- `72db32f4`: eight cloud-review fixes and focused regression coverage.
- `3a34a140`: direct floating-point spill loads/stores.
- `456df4ef`: bounded standalone-loop reserve, enabled in standard JIT targets.

The 50K goal remains open. No 5–10x overall gain is established.

## Full Octane: accepted comparison

Baseline is the production fixes in `72db32f4`, without the performance changes. Candidate is `456df4ef` (FP spills plus loop reserve, without either rejected optimization). The ordinary final build is byte-for-byte identical to the measured candidate; binary hashes and compiler version are in the manifest.

Original bundle SHA256: `ef4c74d25100e6308436fb19b14eaefd5b4b690f30a799b60bc9bccbcefdce8e`, unchanged from the earlier milestone. ARM64 macOS, C3 0.8.5, standard boomkat O2 target, `--macos-min-version 27.0`. Command: `boomkat --jit --stats --script /tmp/boomkat-jit-next/octane-full.js`. SLJIT_STATS was not compiled in; --stats only dumps metadata after the benchmarks. Warmup, validations, latency components and algorithms are unchanged.

Three sequential alternating pairs, no overlapping builds/tests/profiling:

| Pair | Baseline | Candidate | Change |
|---|---:|---:|---:|
| 1 | 5771 | 6355 | +10.12% |
| 2 | 5752 | 6353 | +10.45% |
| 3 | 5733 | 6363 | +10.99% |

Median reported aggregate score: **5752 → 6355 (+10.48%)**. All six executions return status 0 and pass the original benchmark assertions. Per-result medians are below; the aggregate row is the median of the reported aggregates, not an aggregate reconstructed from component medians.

| Result | Baseline | Candidate | Change |
|---|---:|---:|---:|
| Richards | 4406 | 4392 | -0.32% |
| DeltaBlue | 3081 | 3065 | -0.52% |
| Crypto | 5051 | 5052 | +0.02% |
| RayTrace | 3169 | 3144 | -0.79% |
| EarleyBoyer | 3118 | 3129 | +0.35% |
| RegExp | 774 | 776 | +0.26% |
| Splay | 8614 | 8858 | +2.83% |
| SplayLatency | 21935 | 22045 | +0.50% |
| NavierStokes | 3921 | 7318 | +86.64% |
| PdfJS | 6398 | 6174 | -3.50% |
| Mandreel | 1926 | 2170 | +12.67% |
| MandreelLatency | 11178 | 24318 | +117.55% |
| Gameboy | 12171 | 13470 | +10.67% |
| CodeLoad | 28543 | 28781 | +0.83% |
| Box2D | 6965 | 7175 | +3.02% |
| zlib | 2898 | 2951 | +1.83% |
| Typescript | 21980 | 22280 | +1.36% |
| Score (version 9) | 5752 | 6355 | +10.48% |

The strongest gains are later numeric workloads: NavierStokes, Mandreel and Gameboy. Richards, DeltaBlue and Crypto are essentially neutral. PdfJS median is 3.5% lower; pair changes are -7.4%, -3.0% and +4.5%, so its direction is not consistent. Investigate its newly admitted loops/GC behavior before broadening the policy; do not hide it behind the aggregate. There are only three pairs, not a confidence interval.

## What changed and the memory tradeoff

Previously the fixed 1 MiB arena filled early in the combined run. Function admission still requires *total tracked native code* below 1 MiB. With SLJIT_LOOP_RESERVE, standalone loops that reach a hot backedge and pass analysis can continue to a 2 MiB total ceiling. It is not an extra MiB for arbitrary functions, an eager allocation, a larger function region, or an eviction/reclamation policy. The opt-in adaptive policy retains its own 256 KiB start / 1 MiB ceiling. `-U SLJIT_LOOP_RESERVE` restores the old fixed shared cap.

Median ending tracked native bytes: **1,048,532 → 1,273,360**, approximately **1.00 → 1.21 MiB**, an extra **219.6 KiB / 21.4%**. Earlier progress wording of “1.27 MiB” used the decimal-MB figure incorrectly; these byte counts are authoritative. Baseline ends with 104–105 functions and 12 loops; candidate ends with 104 functions and 91–92 loops. No evictions occur. Native byte counts exclude plan metadata and allocator overhead; peak RSS, GC pause time and per-compilation CPU were not measured in these timing runs. Therefore this is not a complete memory-cost census or closure of plan E.

Direct FP spill operations replace integer load/bit-copy and bit-copy/integer store pairs with SLJIT MOV_F64 memory forms. They remove ten emitter lines and one intermediate GPR/FPR transfer per affected access. Isolated five-pair mini ablation: NavierStokes 187 → 181 ms; Crypto 150 → 151 ms (neutral). Native totals shrink by 220 bytes for NavierStokes and 44 bytes for Crypto. This is the simpler code-generation winner.

## Rejected experiments and simplicity assessment

- Dead-input register coalescing adds about 32 allocator lines. Although diagnostics prove active Crypto and Navier consumers, it slows Crypto 150 → 156 ms in confirmation, while adding only another 12 bytes of native-code reduction beyond the FP-spill change. It gives no extra NavierStokes gain. That trade does not justify the complexity. The patch is archived and absent from the engine.
- The inherited-read continuation candidate adds about 34 lines to consult inherited IC forms before shared-cache/shape lookup. Focused semantics pass and small local gains appear, but broad gain attribution is not established. A two-line delayed-cacheability ablation also has no repeatable gain. Both are absent from the engine; the larger patch and mutation fixture are archived.
- The three-variant initial full screen includes the rejected inherited-read change. Those scores (5673/5748/6357) are exploratory and are not the accepted comparison. The six-run confirmation uses only FP spills and the reserve.

A local 5% slowdown can be worth real simplicity or significant code-size benefit. Here the slowing change added complexity and saved only 12 additional bytes, so we rejected it. The accepted FP change simplifies code, shrinks emitted code and improves an active workload. The reserve explicitly spends about 220 KiB of ending native code for an approximately 10.5% aggregate gain.

## Cloud-review dispositions

1. Parameter aliases now use the shared MoveelimRoles metadata for actual register operands; constant-pool C fields are preserved. The supplied simple JavaScript example returned 3 in the saved baseline. A direct CompilerContext regression constructs the alias/constant-index collision: it fails on the old implementation and passes after the fix for GETPROPC, GETPROPC_CACHED and GETTHISC.
2. Native push rejects undefined before any store/length/used mutation and falls back to ordinary semantics. The old JIT repro reports missing ownership/in/enumeration/forEach; the fixed binary reports the element present.
3. IC_PROTO requires plain_property_object in the runtime and matching native receiver restrictions. The old interpreter repro reads prototype length 99 from an array of length 3; the fixed modes read 3. SSA prototype storage already has matching receiver/link restrictions and required no change.
4. The 128-frame cap refuses an individual inline before emission; nested refusal records recovery at the call instead of failing the plan. CAPI directly exercises warmed candidate admission at the cap without emitter failure or links. Existing inline recovery covers side exits; an end-to-end 129-site compilation was not separately demonstrated.
5. Adaptive eviction distinguishes genuinely disabled root entries from live/region plans carrying the terminal warmup sentinel. The CAPI test evicts such a linked region, asserts it rearms, and verifies recompilation/relink.
6. The unreferenced sljit_native_call helper is removed (48 lines), eliminating its stale-regs write path and duplicate call implementation.
7. History confirmed min_span=1 deliberately enabled tiny native callees. Preserve that behavior in one caller-owned initialization; remove the overwritten 6/16 initialization and dead constant. Documentation now reflects the effective policy.
8. Exit sharing uses a half-full open-addressed temporary table with full target/flow/inline-frame equality instead of quadratic earlier-link scans. A compact heap-allocated table respects the custom allocator and SLJIT temporary-allocation constraints; it is freed after compilation. Hash collisions never merge different recovery states.

## Parent validation

- Direct negative-control optimizer test fails before / passes after; independently reproduced old undefined-push and inherited-array-length failures.
- 48 final JIT/SLJIT fixtures match in interpreter, JIT and stress modes.
- ARM64/x64 embedding passes, including cap admission and adaptive eviction/relink checks; reserve-enabled final embedding also passes.
- Targeted ASan covers review regressions, float spills, NavierStokes and Crypto. Earlier review-only ASan also passes its focused repro.
- Final local/Rosetta/modules differential outputs match: local status 1 in both modes from existing feature-limited failures, Rosetta/modules 0. This is not a clean full local-suite claim.
- Binding audit: 109 constants, 39 return widths and 188 argument widths match the bundled header.
- Three alternating full-Octane pairs pass. Normal final default binary matches measured candidate SHA256 exactly. Engine worktree is committed without rejected experiments.

## Remaining plan work

A: value-only writes do not advance prototype_epoch, so no unsafe epoch-only global/method constant folding was added. The read-only dependency note records exact mutation gaps and a bounded entry-guard specialization option.

B: general cyclic function SSA and effectful frame-state recovery remain open.

C: FP-spill emission is a scoped improvement; broad representation propagation, cross-block register allocation and useful guard/load elimination remain open.

D: no speculative property-cache expansion is retained. PdfJS and other helper-heavy paths need fresh targeted evidence.

E: the bounded reserve is a demonstrated broad improvement, not a complete usefulness-based admission/retirement policy. Preserve the small-memory opt-out and collect metadata/RSS/compile/GC costs before extending it further. The 50K objective remains open.

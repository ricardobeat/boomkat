# 116: Loop SSA repair and activation

Engine commit: `f5bb66df`. Baseline: `fa1e7f7a`. This activates the existing bounded numeric-loop
SSA tier after repairing its recovery, CFG and representation invariants. It
is a foundation for the optimizing tier in plan 113, not a general function
SSA optimizer or an achievement of the 50,000 Octane target.

## Implemented

- Capture the pre-bytecode SSA frame and keep recovery-only operands live
  through every lowering/guard for that operation. Fix the growing-array
  constant-store regression that originally kept the tier disabled.
- Correct C3 multidimensional array layouts for predecessor and block states.
  Select join representations without narrowing, preserve boxed-copy sources,
  and begin join intervals at the incoming edge copies. Ordinary joins reuse
  homes after their intervals end; loop phis remain live across the backedge.
- Require dominance and equal representation for redundant loads; invalidate
  cached loads across all potentially aliased writes. Conversion facts are
  block-local; exact-index and ToInt32 conversions have distinct cache keys.
- Copy loop-carried register and spill homes in parallel, staging cycles.
  Preserve postfix comparison operands if an edge copy overwrites their homes.
  Emit the IR conversions needed on backedges and retain their recovery inputs.
- Put mixed int32/F64 branch operands in the same register class. Use floating
  comparison instructions for float guards and compare exact-index roundtrips
  against the original value. Preserve unsigned results, multiplication's
  negative zero and safe NaN boxing; restore the heap on graph rebuilding.
- Handle special binding/this memory descriptors without indexing the VM
  register array. ASan found the previous out-of-bounds indexing.
- Share exit materialization only when both PC and the complete recovery frame
  match. Keep direct register copies for acyclic backedges. The observed SSA
  regression kernels shrink by 41–58% versus the repaired unshared version.
- Allow numeric dense loads to survive stores when the load itself guards out
  references. Other borrowed boxed loads, including CSE aliases, keep the
  fallback. This admits Crypto's `am3` loop, with about 1.59M SSA iterations in
  the instrumented mini run instead of zero.
- Enable eligible loops under `--jit`; retain `SLJIT_NO_SSA` for differential
  measurements. `SLJIT_STATS` reports SSA entries/iterations even after a plan
  is retired, distinguishing actual execution from compilation/fallback.

## Correctness evidence

Eight new regression fixtures cover growing-array replay, aliasing/CFG/joins,
spill cycles, postfix conditions, numeric edge cases/NaN payloads, backedge
conversions, mixed branch comparisons and guarded dense loads with coercion.
Each has confirmed SSA entries; the growing-array test deliberately enters and
immediately exits a guard (zero completed SSA iterations).

Before-fix failures include growing shift `0,1,1,2,3` instead of `0,0,1,2,3`,
aliased load/store total 525 instead of 528, rotation result 836 instead of 935,
unsigned shift -1 instead of 4294967295, PdfJS 61694498816 instead of
36788939524096, a missing backedge conversion, and mixed comparison count 26
instead of 32. They are minimized in the regression fixtures, not worked around
by benchmark names or by changing benchmark algorithms/checks.

Final validation:

- 34 focused JIT scripts/corpus in interpreter, JIT and JIT-stress modes; output
  agreement after normalizing timing text.
- A deterministic 36-function CFG corpus and 144 generated branching kernels
  (seed 726113), including mixed arithmetic/comparisons and aliased arrays.
- `run_jit_diff`: local, Rosetta and modules all match, status 0.
- `run_jit_diff --test262`: expressions, statements and Array all match, status 0.
- Embedding JIT runner passes, including GC/interrupt/native frame integration.
- ASan: 27 scripts, including all 15 Octane mini benchmarks, all pass. Rebuilt
  from the final source; `ASAN_OPTIONS=detect_leaks=0`. This is an AddressSanitizer
  result, not a leak-sanitizer result.

## Measurement methodology

C3 0.8.5 / LLVM 23.1.3, Apple arm64, `--macos-min-version 27.0`. Uninstrumented
optimized binaries, same machine and untouched full Octane bundle/settings.
Three alternating mini pairs, and three alternating full-suite pairs. No
builds, tests or sampling run concurrently with timing. Mini Crypto/CodeLoad/
Earley-Boyer figures sum their phases. Latency scores retain the original
harness. Diagnostic timing is not used as performance evidence.

The initial repair-only candidate was effectively neutral: 5500 → 5508 in one
full pair. Its three-pair mini medians were neutral for Richards/DeltaBlue and
370 → 360 ms for PdfJS. The final candidate adds shared exit stubs, further
representation fixes and guarded dense-store admission; final results follow.

## Final full-Octane results

Scores are medians of three runs; higher is better. The aggregate median is
**5500 → 5540 (+0.73%)**, with individual aggregates baseline
5495/5530/5500 and SSA 5540/5532/5545. Crypto improves 16.98%. The broad target
remains unmet: this is roughly one ninth of 50K.

| Score | Before | After | Change |
|---|---:|---:|---:|
| Richards | 3986 | 3989 | +0.08% |
| DeltaBlue | 2926 | 2936 | +0.34% |
| Crypto | 3075 | 3597 | +16.98% |
| RayTrace | 3083 | 3083 | +0.00% |
| EarleyBoyer | 3083 | 3091 | +0.26% |
| RegExp | 777 | 775 | -0.26% |
| Splay | 9200 | 9062 | -1.50% |
| SplayLatency | 21841 | 22291 | +2.06% |
| NavierStokes | 3940 | 3898 | -1.07% |
| PdfJS | 5802 | 5901 | +1.71% |
| Mandreel | 1921 | 1920 | -0.05% |
| MandreelLatency | 11103 | 11054 | -0.44% |
| Gameboy | 12159 | 12126 | -0.27% |
| CodeLoad | 28275 | 28303 | +0.10% |
| Box2D | 6986 | 6857 | -1.85% |
| zlib | 2893 | 2852 | -1.42% |
| Typescript | 21354 | 21811 | +2.14% |
| Score (version 9) | 5500 | 5540 | +0.73% |

The first Box2D run fell 6993 → 5876, but this did not repeat at that magnitude;
the medians are 6986 → 6857 (−1.85%). PdfJS also varies between full runs. These
three-pair results are observations, not statistical confidence intervals.

## Final mini results

Milliseconds, medians of three alternating pairs; lower is better.

| Mini | Before | After | Change |
|---|---:|---:|---:|
| box2d | 223 | 224 | +0.45% |
| code-load | 159 | 159 | +0.00% |
| crypto | 243 | 211 | -13.17% |
| deltablue | 120 | 120 | +0.00% |
| earley-boyer | 175 | 176 | +0.57% |
| gbemu | 292 | 290 | -0.68% |
| mandreel | 685 | 693 | +1.17% |
| navier-stokes | 207 | 207 | +0.00% |
| pdfjs | 368 | 362 | -1.63% |
| raytrace | 166 | 167 | +0.60% |
| regexp | 338 | 337 | -0.30% |
| richards | 89 | 88 | -1.12% |
| splay | 112 | 112 | +0.00% |
| typescript | 1237 | 1223 | -1.13% |
| zlib | 4252 | 4322 | +1.65% |

## Final code-cache check

A separate completed full run of the same uninstrumented binary with `--stats`
reports **1,048,068 / 1,048,576 bytes**, 105 function plans and 16 loop plans.
The latest compiled function is still at source line 3304 (Crypto); all loop
names also belong to Crypto. No Box2D native code was installed. This does not
support attributing its first-run outlier to newly admitted Box2D code. Later
full-suite score changes, including PdfJS, are not evidence of direct SSA gains
there: the isolated mini and the combined full run have different coverage.
The additional run is retained as occupancy evidence, not included in the three
performance pairs. The 1 MiB policy still prevents broad full-suite coverage.

## Scope still outstanding

Richards and DeltaBlue have no SSA loop iterations in the instrumented mini
runs. Their property/call-heavy function regions still use the older function
optimizer. The next substantial step remains a function CFG/SSA representation
with decoded WIDE boundaries, effect/alias information, recoverable calls,
cross-block allocation and profitable inlining. This change establishes and
validates the loop machinery; it does not implement that whole-function tier.

The full-run 1 MiB arena can still be consumed by early suites. Blindly growing
it or applying the prior reclamation policy is not included: plan 113 measured
regressions from those approaches. Later workload coverage needs useful-code
admission and safe retirement alongside better generated code, with full-suite
measurement at each step. The 50K target remains open.

# Shared-heap realms: validation and performance

`bk_open_realm(ctx)` creates independent globals and intrinsics in the same
runtime. The primary realm keeps lightweight builtin values and direct intrinsic
loads. A realm record is allocated when the first sibling is created. Realm
storage lives until the original runtime closes.

The implementation uses C3 inline composition for active realm state,
compile-time reflection for intrinsic GC roots and reset, field tags for named
intrinsics, and `defer` for scoped restoration.

## Performance

Baseline: `9ece46a6`. C3 0.8.4, macOS arm64, release `boomkat` target
(`O2`, small code, threaded dispatch). Each measured invocation starts a fresh
process with `--script`; timing includes startup, compilation, and teardown.
Two warmup rounds precede 19 measured rounds. Each round interleaves the
baseline, changed binary, and an identical baseline copy; alternate rounds
reverse the order. Output must match across all three binaries.

The loop, function-call, and property-lookup workloads use four times their
committed `N`; the other workloads use their committed size. Results are
medians in milliseconds. Positive changes mean slower execution. The control
column measures the identical baseline copy against the baseline.

| Workload | Baseline ms | Realms ms | Change | Control change |
|---|---:|---:|---:|---:|
| loop | 55.08 | 54.70 | -0.7% | +0.1% |
| function_call | 89.64 | 90.73 | +1.2% | +0.1% |
| recursion | 29.76 | 29.85 | +0.3% | -0.3% |
| property_lookup | 96.01 | 92.40 | -3.8% | -0.2% |
| array | 7.35 | 7.33 | -0.2% | -0.8% |
| string | 22.58 | 22.82 | +1.1% | +0.4% |
| closure_capture | 51.50 | 51.84 | +0.7% | -0.2% |
| class | 163.30 | 167.15 | +2.4% | -0.0% |

Geometric mean change: **+0.11%**. The largest measured slowdown is
**2.4%**, below the project's 3% investigation gate.
These measurements cover single-realm workloads; crossing realms saves and
restores state and has an additional cost. They do not establish zero overhead
for every workload.

Raw samples and settings: [cross-realm-performance.json](cross-realm-performance.json).

## Validation

- All 260 newly eligible realm-related test262 files pass in optimized,
  `NONANBOX`, and standard ASAN runners. Other scope exclusions remain active.
- `just test-local`: 602 scripts pass, plus all module, compiler, TypeScript,
  and associated checks. Rosetta passes all 42 cases.
- C API realm, embedding, independent-runtime, and module tests pass. Realm
  checks cover native reentry, shared handles, sloppy `this`, intrinsic
  identity, module caches, promises, prototype invalidation, and lifetime
  after a sibling context closes.
- `GC_STRESS + GC_VERIFY + POOL_BYPASS + ASAN`: 259 of the 260 files pass,
  including the TypedArray reduce/reduceRight test. The dedicated nested-realm
  allocation fixture also passes.

The remaining stress failure is `staging/sm/Reflect/set.js`: ASAN reports a
Symbol use-after-free. Replacing `$262.createRealm().global` with `globalThis`
reproduces the Symbol lifetime failure on the unchanged `9ece46a6` baseline.
The original file passes the standard ASAN runner. Its scope rule stays enabled;
this limitation is recorded rather than hidden by a skip.

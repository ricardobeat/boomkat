# Stable native-call frames and compact arrays

## Implementation

Native callbacks, native constructor calls, and nested module evaluation use
stable segments of the VM's activation storage. A shadow descriptor publishes
the suspended callers in place. Entry advances the active pointer; return
restores it and unlinks the descriptor before further reentry. No activation
prefix is copied or allocated. Value-stack growth relocates register pointers
in both active and suspended segments. All push paths check the remaining
capacity; the 4,096-frame budget covers the complete live stack. Native nesting
also retains its independent 128-run limit.

Arrays allocate from a dedicated pool and have no inline named slots. Dense
storage starts at offset zero. A named-property insertion grows the named
section in the existing combined backing block and invalidates shape caches.
Other object layouts and collector links stay as documented in architecture.md.
The production patch removes more VM code than it adds; profiling hooks are
confined to temporary benchmark binaries.

## Independent measurements

Whole-process milliseconds, medians of five runs after one warmup, rotated and
reversed engine order. Runs are sequential and include startup and teardown.
Peak RSS comes from macOS wait4. The baseline includes GC64 and the string fix.
The retained baseline hash matches the candidate in the string-fix report.

| Workload | Baseline ms | Frames ms | Arrays ms | Combined ms | QuickJS ms |
|---|---:|---:|---:|---:|---:|
| callback-0 | 24.38 | 19.93 | 24.56 | 19.68 | 13.72 |
| callback-32 | 252.15 | 20.57 | 250.47 | 20.14 | 13.82 |
| callback-128 | 1421.69 | 21.58 | 1453.27 | 21.34 | 13.91 |
| bench_function_call | 50.44 | 50.27 | 49.36 | 49.56 | 31.59 |
| es6/bench_class | 680.05 | 667.39 | 675.69 | 674.12 | 276.48 |
| es6/bench_forof | 150.03 | 159.74 | 152.09 | 156.00 | 56.52 |
| es6/bench_destructuring | 610.99 | 596.58 | 584.47 | 581.28 | 243.72 |
| es6/bench_closure_capture | 103.48 | 103.53 | 103.87 | 103.84 | 149.09 |
| bench_string | 37.64 | 37.66 | 38.40 | 37.56 | 21.80 |
| scene-10000 | 147.74 | 149.13 | 142.86 | 139.99 | 76.49 |
| scene-100000 | 1634.98 | 1628.68 | 1527.14 | 1536.55 | 908.08 |
| retained-arrays | 50.83 | 50.96 | 47.56 | 47.92 | 31.95 |
| named-arrays | 44.79 | 44.34 | 53.61 | 53.35 | 30.20 |

The callback probe makes 300,000 callbacks through Array.map, with the requested
number of recursive caller frames kept live. The return adds a value after the
recursive call, preventing tail-call elimination. Its checksum is checked.
The depth-128 baseline requires several GiB of memory: use `--skip-deep` on
machines where that is unsuitable. This is a scaling stress case, not a claim
that an average application speeds up by the same factor.

Ordinary call, class, and closure timings show no substantial improvement.
The five-run follow-up resolves the initial mixed-iteration slowdown:
141.5 ms baseline, 140.3 ms combined. Both raw measurement sets are retained.

## Peak memory

| Workload | Baseline MiB | Frames MiB | Arrays MiB | Combined MiB | QuickJS MiB |
|---|---:|---:|---:|---:|---:|
| callback-0 | 9.55 | 9.52 | 7.88 | 7.86 | 2.52 |
| callback-32 | 1515.42 | 9.53 | 1513.73 | 7.84 | 2.53 |
| callback-128 | 3759.95 | 9.52 | 3746.81 | 7.86 | 2.62 |
| scene-100000 | 197.00 | 196.94 | 164.02 | 164.05 | 72.41 |
| retained-arrays | 70.06 | 70.06 | 49.59 | 49.58 | 36.61 |
| named-arrays | 37.27 | 37.27 | 33.33 | 33.31 | 21.88 |
| es6/bench_forof | 64.34 | 64.30 | 56.17 | 56.16 | 23.12 |
| es6/bench_destructuring | 200.38 | 200.36 | 170.17 | 170.14 | 2.44 |

The frame implementation removes the temporary activation arrays allocated on
each deep native reentry. The measured 128-frame callback case falls from
3.67 GiB peak RSS to 7.9 MiB. Register storage and generator snapshots remain
separate costs.

The compiler reports Activation=128, HObjectBase=88, PropValue=8, compact
ARRAY=96, ARGUMENTS pool=136, and PLAIN=120 bytes for the default arm64 build
(`layout-sizes.txt`). The array header's pool charge falls from 136 to 96 bytes.
For a short dense array, the initial 16-element backing request falls from
160 bytes (including four named slots) to 128 bytes. Pool rounding changes its
physical block from 192 to 128 bytes. Thus the 200k short-array probe removes
about 20.8 MB of header/backing block demand, apart from page slack and the
outer container. Observed peak RSS falls by 20.5 MiB. This accounts for the
changed storage; it is not a complete live-heap composition profiler.

## High-resolution VDOM frame latency

Milliseconds; each value is the median of five per-run statistics. Maximum
means median per-run maximum, not a latency bound. A temporary identical
monotonic Date.now hook supplies Boomkat timing; QuickJS uses performance.now.
These instrumented binaries are separate from the release throughput runs.

| Nodes | Engine | p50 | p99 | Maximum |
|---|---|---:|---:|---:|
| 10000 | baseline | 0.3992 | 0.7929 | 0.9090 |
| 10000 | combined | 0.3766 | 0.7401 | 0.7990 |
| 10000 | quickjs | 0.2160 | 0.2490 | 0.2780 |
| 100000 | baseline | 0.4774 | 1.2655 | 1.8185 |
| 100000 | combined | 0.4560 | 1.1454 | 1.7293 |
| 100000 | quickjs | 0.2610 | 0.3500 | 0.5150 |

## Named-property tradeoff and two-slot alternative

Zero inline named slots minimize retained array memory, but arrays receiving
named properties require an extra backing allocation and element copy. The
named-array stress case is about 19–21% slower. A two-slot alternative avoids
that cost for up to two properties but retains much less of the memory saving.
Both alternatives preserve JavaScript semantics.

Five-run follow-up, whole-process milliseconds:

| Workload | Baseline | Zero slots | Two slots |
|---|---:|---:|---:|
| named-arrays | 44.96 | 54.43 | 44.89 |
| retained-arrays | 51.73 | 48.48 | 52.71 |
| scene-100000 | 1632.54 | 1535.54 | 1588.41 |
| named-4 | 55.98 | 67.66 | 61.46 |
| named-8 | 89.72 | 97.40 | 92.96 |
| forof | 141.48 | 140.34 | 141.61 |

The 100k scene uses 197.0 MiB at baseline, 164.0 MiB with zero slots, and
188.5 MiB with two slots. Zero slots are retained for the engine's low-memory
and retained-scene goals. Separate named and element allocations remain a
possible way to address named-array costs; they require an independent layout
and ownership experiment.

## Validation

- Fresh ASAN, GC_STRESS, GC_VERIFY, and POOL_BYPASS: all **19** lifetime fixtures
  pass, including the new frame and array layout regressions.
- Focused test262: **558 pass, 3 scope skips, no failures** across Array.map,
  array literals, calls, and try statements.
- Rosetta: **42/42**. Module fixtures: **20/20**.
- Frame overflow, stack growth, bound callbacks, and error-stack order pass
  ASAN checks. The shared frame limit throws RangeError and permits later calls.
- The two new fixtures pass QuickJS; five focused fixtures also pass a fresh
  NONANBOX build.
- Final constructor entry uses the shared RangeError guard for frame exhaustion.
  The measured normal paths do not exhaust the frame budget.

Generator register save/restore, ordinary frame compaction, page GC metadata,
and semantic compiler IR are not implemented by this patch. The method-call
gap to QuickJS remains. No broad application speedup is inferred from the
synthetic deep callback case.

## Reproduction

```sh
python3 benchmarks/architecture-investigation/frames-array-layout/build_variants.py --work-dir /tmp/boomkat-frame-repro
python3 benchmarks/architecture-investigation/frames-array-layout/run_bench.py --work-dir /tmp/boomkat-frame-repro
python3 benchmarks/architecture-investigation/frames-array-layout/compare_slots.py --work-dir /tmp/boomkat-frame-repro
```

`manifest.json` records compiler, platform, and baseline revision. `frames.patch`
and `arrays.patch` are independent production patches; `two-slots.patch` applies
after the array patch. The build script keeps its monotonic clock hook inside
the temporary clock variants. Timing-binary hashes, raw throughput samples,
compressed individual frame samples, layout sizes, and validation output are
included in this directory.

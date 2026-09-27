# Bounded nursery results

Measured September 27–28, 2026, on macOS arm64 with C3 0.8.3.

Baseline: `55e0b746`, the cooperative collector with paced safepoints. Candidate: the nursery implementation committed with this report. Both release binaries use `c3c build boomkat`. The profiler binaries use `boomkat_gcprofile`; the baseline profiler was built from a source archive of that commit.

Design: [plan 096](../../plans/096-bounded-nursery-review.md). Runtime invariants and ownership: [architecture](../../docs/architecture.md#memory-the-heap-the-collector-and-strings).

## Release benchmark comparison

One warmup pair and five alternating measured pairs per file; medians include process startup, compilation, execution and teardown. Builds and tests were stopped during measurement. Earlier runs affected by heavy machine load are excluded. Positive changes mean slower execution. Suite totals sum per-file medians.

| Suite | Baseline | Candidate | Change | Geometric mean change |
|---|---:|---:|---:|---:|
| `just bench` (20 cases) | 4.4529 s | 4.4313 s | -0.5% | -0.1% |
| `bench-es6` (8 cases) | 2.7808 s | 2.5689 s | -7.6% | -5.4% |

The ES5 suite is effectively flat overall. Its largest measured regressions are recursion (+5.3%) and deep recursion (+5.4%). ES6 allocation-heavy cases improve: class construction −9.2%, destructuring −9.7%, Promises −10.5%, and spread/rest −8.0%. These are paired measurements, not guarantees for every program.

| Workload | Baseline | Candidate | Change | Median worst frame |
|---|---:|---:|---:|---:|
| 100k scene, 3,000 frames | 2.0629 s | 1.9174 s | -7.1% | 4 → 3 ms |
| Heavy VDOM, 300 frames | 2.9008 s | 2.9198 s | +0.7% | 11 → 12 ms |

The VDOM case uses 150 components and 80 items per list. Maximum worst-frame values across the five runs are 4 → 3 ms for the scene and 12 → 15 ms for VDOM. Whole-frame measurements include application work. No 300k scene was run.

## Collector profiles

Three measured runs after warmup per binary and workload. These instrumented builds differ from the release size-optimization configuration. Times below sum elapsed time inside scheduled GC slices, including profiling overhead; they are not independent process CPU measurements.

| Workload | Slice time, baseline → candidate | Mark time | Sweep time | Largest scheduled slice |
|---|---:|---:|---:|---:|
| 100k scene | 574.3 → 438.4 ms | 248.9 → 167.3 ms | 220.6 → 175.3 ms | 0.502 → 0.502 ms |
| Heavy VDOM | 379.8 → 404.7 ms | 97.4 → 90.7 ms | 149.8 → 189.7 ms | 0.414 → 0.500 ms |

Scene slice time falls 23.7%; VDOM slice time rises 6.6%. The scene uses 129 minors and 7 majors versus 15 full collections at baseline. Median traced-value visits fall from 34.99 million to 26.25 million (25.0%). Steady-state minors skip unchanged old graphs; the direct collector test also checks that a settled old graph needs zero object marks.

VDOM uses zero minors and 240 majors versus 278 full collections. Small surviving heaps do not amortize promotion and remembered-owner scans, so the policy keeps them on full collections. VDOM retains additional sweep bookkeeping, reflected in the profile even though whole-program runtime is nearly unchanged.

The largest observed GC slice is 0.502 ms, with no measured interruption reaching 4 ms. Scene p99 slice upper bounds improve from 20 to 10 µs; VDOM changes from 10 to 90 µs. The 0.5 ms clock allowance remains a soft scheduling target: allocator operations, host callbacks and OS descheduling can exceed it. This is not a hard realtime guarantee.

## Memory and retention

Peak RSS uses `os.wait4` resource usage for each child process, in bytes on macOS. These are individual runs, separate from the paired timing runs. Repeated async entries in the raw data include output verification.

| Workload | Baseline peak RSS | Candidate peak RSS |
|---|---:|---:|
| 100k scene | 197.7 MiB | 198.5 MiB |
| Heavy VDOM | 16.4 MiB | 17.4 MiB |
| 100k closure iterations | 35.5 MiB | 37.0 MiB |
| 400k closure iterations | 42.0 MiB | 43.9 MiB |
| 1.6M closure iterations | 43.5 MiB | 45.4 MiB |
| 100k async calls | 43.1 MiB | 43.7 MiB |
| 500k async calls | 94.5 MiB | 97.3 MiB |
| 2M async calls | 326.6 MiB | 331.2 MiB |

The [auxiliary-storage probe](../gc_nursery_auxiliary.js) keeps 70,000 objects alive. Closure mode uses `with` to require real environment cells; it verifies each captured value. Async mode verifies the sum of values returned through repeated async suspension.

Closure RSS approaches a plateau: four times more work from 400k to 1.6M iterations adds about 1.5 MiB in each build. The O0 counter harness reports 300,002 and 1,200,002 environment allocations for 100k and 400k iterations, and two live cells after a forced major. Its reserved pool reaches 6.5 and 17.9 MiB; reserved blocks are reused, and O0 slice progress differs from release.

**The single-checkpoint async probe does not demonstrate an RSS plateau in either build.** After a forced major, the counter harness reports zero generator states, two live environments and zero queued jobs. However, queue capacity is 65,536 slots after 20k calls and 262,144 after 100k. Queue backing storage grows throughout a drain and stays reserved; transient GC retention and reserved pools can also contribute to peak RSS. The nursery does not resolve this existing queue-capacity behavior. Its measured 2M-call peak is 1.4% above baseline.

DWARF layout checks report an unchanged 24-byte `HeapHeader` and an object header growing from 80 to 88 bytes. Derived plain/array/function pool blocks grow from 112/128/192 to 120/136/200 bytes. The extra remembered-owner link costs eight bytes per object on this build.

## Validation

- Rosetta: **42/0**. Local scripts: **470/0**; module entries: **20/0**, with all ancillary local checks passing.
- Direct collector tests: ASAN, pool bypass and independent `GC_VERIFY`, including one-unit slices, promotion/store ordering, host payloads, retained environments, retired generators, native pins, and reset/teardown; NaN-boxed and NONANBOX builds pass.
- GC lifetime stress: **16/0**, including threaded ASAN + `GC_VERIFY` with both value representations.
- Fresh ASAN test262 runner: Promise **642/0**, generators **289/0**, async generators **622/0**; **1,553 selected passes**, no unexpected compile errors. Full test262 was not rerun.
- ASAN heap reset: **40/40**. Embedding API: **all pass**. Golden bytecode: **28/28**.
- Native temporary-root RSS guard passes. `git diff --check` passes; no `.get().set_` stores remain.

## Reproduction and raw data

Use `scripts/bench_interleaved.py` with an explicit baseline executable, `out/boomkat`, the 20 `benchmarks/bench_*.js` files and eight `benchmarks/es6/bench_*.js` files, `--pairs 5`, and an output directory. For the heavy cases, prepend the override variables used by `scripts/profile_gc.py`: 100,000 nodes/3,000 frames and VDOM 300 frames/150 components/80 list items with timing enabled.

Build `boomkat_gcprofile`, then run:

```sh
python3 scripts/profile_gc.py --runs 3 --workload scene_100000_long --workload vdom_heavy --output /tmp/gc-profile.json
```

For auxiliary probes, prepend `AUX_MODE_OVERRIDE` (`"closure"` or `"async"`) and `AUX_ROUNDS_OVERRIDE` to `benchmarks/gc_nursery_auxiliary.js`, and run with `--script`. `out/env_pool_stats` executes the same probe and forces a full collection before reporting storage counters.

- [Release timings and outputs](results.json)
- [Baseline GC profiles](profile-baseline.json)
- [Candidate GC profiles](profile-candidate.json)
- [Peak RSS measurements](rss.json)

### Per-case release timings

| Case | Baseline | Candidate | Change |
|---|---:|---:|---:|
| benchmarks/bench_arithmetic.js | 0.0392 s | 0.0387 s | -1.1% |
| benchmarks/bench_array.js | 0.0147 s | 0.0149 s | +0.8% |
| benchmarks/bench_date.js | 2.7575 s | 2.7377 s | -0.7% |
| benchmarks/bench_function_call.js | 0.0517 s | 0.0510 s | -1.3% |
| benchmarks/bench_gc_large_container.js | 0.2889 s | 0.2874 s | -0.5% |
| benchmarks/bench_gc_native_reentry.js | 0.0216 s | 0.0215 s | -0.3% |
| benchmarks/bench_ic_monomorphic.js | 0.0844 s | 0.0846 s | +0.3% |
| benchmarks/bench_ic_proto.js | 0.1290 s | 0.1240 s | -3.9% |
| benchmarks/bench_loop.js | 0.0391 s | 0.0399 s | +1.9% |
| benchmarks/bench_memory_heavy.js | 0.0703 s | 0.0670 s | -4.7% |
| benchmarks/bench_object.js | 0.0708 s | 0.0703 s | -0.6% |
| benchmarks/bench_property_lookup.js | 0.0472 s | 0.0470 s | -0.4% |
| benchmarks/bench_recursion.js | 0.0507 s | 0.0534 s | +5.3% |
| benchmarks/bench_recursion_deep.js | 0.2030 s | 0.2139 s | +5.4% |
| benchmarks/bench_regexp.js | 0.1146 s | 0.1132 s | -1.2% |
| benchmarks/bench_scene_churn.js | 0.2872 s | 0.2830 s | -1.5% |
| benchmarks/bench_shape_no_call.js | 0.0392 s | 0.0387 s | -1.1% |
| benchmarks/bench_shape_stress.js | 0.0398 s | 0.0400 s | +0.4% |
| benchmarks/bench_string.js | 0.0354 s | 0.0360 s | +1.8% |
| benchmarks/bench_valstack_copy.js | 0.0686 s | 0.0688 s | +0.3% |
| benchmarks/es6/bench_class.js | 0.7345 s | 0.6667 s | -9.2% |
| benchmarks/es6/bench_closure_capture.js | 0.1028 s | 0.1028 s | -0.0% |
| benchmarks/es6/bench_destructuring.js | 0.6839 s | 0.6175 s | -9.7% |
| benchmarks/es6/bench_forof.js | 0.2192 s | 0.2181 s | -0.5% |
| benchmarks/es6/bench_let_loop.js | 0.1653 s | 0.1599 s | -3.3% |
| benchmarks/es6/bench_promise.js | 0.4640 s | 0.4152 s | -10.5% |
| benchmarks/es6/bench_spread_rest.js | 0.2591 s | 0.2383 s | -8.0% |
| benchmarks/es6/bench_template_literal.js | 0.1519 s | 0.1504 s | -1.0% |

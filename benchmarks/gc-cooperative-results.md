# Cooperative GC validation and measurements

**The measurements below record the initial `e8a4e4f9` collector.** The later
call-pacing improvement and current suite/100k/VDOM results are in the
[pacing follow-up](gc-call-pacing-results.md).

Measured on 2026-09-27: Apple M3, 16 GiB RAM, macOS 27.0 (26A5425a),
C3 0.8.3 (Homebrew 0.8.3_1), LLVM 22.1.8, ARM64. This report covers the
cooperative core of [plan 095](../plans/095-incremental-gc-design.md).

## Method

Release comparisons use one discarded warmup pair followed by five alternating
A/B pairs, identical inputs and checked output checksums. Wall time includes
process startup; RSS is the median process maximum reported by macOS `time -l`.
Profiler measurements use a separate instrumented binary, one discarded warmup
and three measured runs per workload. Builds and test suites were stopped during
measurement. Timing values are elapsed wall time, not thread CPU time.

Baselines are fresh release builds of `8dd4427c2cc9095b8da353299175a0250696e065`
(generational) and `c3c18245b2b3ff8dcef8253ac5cd531919f613c3` (lazy sweep).
The candidate uses 128 work units at function safepoints and 65,536 at loop
safepoints (each 1,024 backward branches), with a 0.5 ms soft deadline checked
between 32-unit batches. No worker threads are enabled.

Scene inputs contain 10k nodes/300 frames, 100k nodes/3,000 frames and
300k nodes/3,000 frames. Heavy VDOM uses 300 frames, 150 components and 80 items.
The large-container workload combines a 100k deep graph, large slot arrays and
500k allocation-only iterations. Native reentry exercises Array.from/reduce
callbacks with 20k anchors. Exact input construction is in `scripts/profile_gc.py`.

## GC interruptions

Counts aggregate three runs. Percentile columns are the largest per-run histogram
upper bound (10 μs buckets), not pooled percentiles. Counts include very short
scheduled steps; the maxima are the more useful latency gate. These figures cover
scheduled GC slices; whole-frame timing is reported separately below.

| Workload | Slices | p50 / p95 / p99 / p99.9 (μs) | Maximum slice (ms) | Slices ≥4 ms | Max string-table maintenance (ms) |
|---|---:|---:|---:|---:|---:|
| scene_10000 | 726,546 | 10 / 10 / 10 / 10 | 0.121 | 0 | 0.019 |
| scene_100000_long | 7,384,092 | 10 / 10 / 10 / 10 | 0.503 | 0 | 0.018 |
| scene_300000_long | 8,498,712 | 10 / 10 / 10 / 10 | 0.493 | 0 | 0.026 |
| vdom_heavy | 6,584,673 | 10 / 10 / 10 / 10 | 0.187 | 0 | 0.006 |
| large_container | 92,139 | 10 / 10 / 80 / 140 | 0.369 | 0 | 0.629 |
| native_reentry | 295,776 | 10 / 10 / 10 / 10 | 0.082 | 0 | 0.005 |

No final measured slice or separately recorded maintenance operation reached 4 ms.
Native shadow-root publication in this workload rounded below 0.001 ms; larger
native frames can cost more. Explicit blocking collection was not exercised by
these latency workloads and has no slice guarantee.

An earlier tuning build with an 8,192-unit function allowance recorded one
18.113 ms slice (18.100 ms in marking). Its cause is unconfirmed. The raw record
is retained in `gc-cooperative-tuning.json`; final measurements above use the
128-unit policy. Neither this finite sample nor a soft deadline establishes a
hard real-time bound. Allocator calls, host callbacks and table rehashing remain
indivisible. The verifier deliberately performs a full trace in verification builds.

## Release throughput, memory and whole frames

Positive time changes mean slower execution. RSS is in MiB. Frame columns show
the median of each run's worst frame, measured with JavaScript's 1 ms clock.
Application work and multiple safepoints contribute to a frame. **Whole frames
are not all below 4 ms**, including heavy VDOM.

### Against generational GC (8dd4427c)

| Workload | Baseline → cooperative (s) | Time change | RSS baseline → cooperative (MiB) | Worst frame baseline → cooperative (ms) |
|---|---:|---:|---:|---:|
| scene_10000 | 0.1287 → 0.1569 | +21.9% | 30.4 → 28.5 | 2 → 1 |
| scene_100000 | 1.5328 → 1.8999 | +24.0% | 240.7 → 226.2 | 31 → 5 |
| scene_300000 | 1.7283 → 2.0259 | +17.2% | 546.6 → 669.7 | 53 → 3 |
| vdom_heavy | 2.6982 → 2.8328 | +5.0% | 39.0 → 16.8 | 11 → 11 |
| bench_gc_large_container | 0.2450 → 0.2772 | +13.1% | 153.1 → 184.0 | — |
| bench_gc_native_reentry | 0.0218 → 0.0234 | +7.3% | 9.6 → 13.2 | — |
| bench_loop | 0.0343 → 0.0400 | +16.7% | 4.2 → 4.3 | — |
| bench_function_call | 0.0526 → 0.0533 | +1.4% | 4.4 → 4.3 | — |
| bench_arithmetic | 0.0409 → 0.0386 | -5.8% | 4.3 → 4.3 | — |
| bench_object | 0.0700 → 0.0708 | +1.1% | 4.4 → 4.4 | — |
| bench_array | 0.0153 → 0.0158 | +3.7% | 10.0 → 10.1 | — |
| bench_string | 0.0371 → 0.0371 | +0.2% | 4.3 → 4.2 | — |
| bench_property_lookup | 0.0400 → 0.0477 | +19.4% | 4.4 → 4.5 | — |
| bench_closure_capture | 0.0883 → 0.1037 | +17.5% | 4.3 → 4.3 | — |

### Against lazy sweep (c3c18245)

| Workload | Baseline → cooperative (s) | Time change | RSS baseline → cooperative (MiB) | Worst frame baseline → cooperative (ms) |
|---|---:|---:|---:|---:|
| scene_10000 | 0.1208 → 0.1567 | +29.7% | 22.2 → 28.5 | 2 → 1 |
| scene_100000 | 1.4799 → 1.8999 | +28.4% | 166.4 → 226.2 | 38 → 5 |
| scene_300000 | 1.6183 → 2.0207 | +24.9% | 489.7 → 669.6 | 63 → 3 |
| vdom_heavy | 2.5735 → 2.8385 | +10.3% | 15.2 → 16.8 | 9 → 11 |
| bench_gc_large_container | 0.2391 → 0.2753 | +15.1% | 172.5 → 183.9 | — |
| bench_gc_native_reentry | 0.0215 → 0.0236 | +9.5% | 9.9 → 13.2 | — |
| bench_loop | 0.0324 → 0.0399 | +23.0% | 4.2 → 4.3 | — |
| bench_function_call | 0.0511 → 0.0537 | +5.0% | 4.2 → 4.3 | — |
| bench_arithmetic | 0.0390 → 0.0385 | -1.4% | 4.2 → 4.3 | — |
| bench_object | 0.0694 → 0.0711 | +2.4% | 4.3 → 4.4 | — |
| bench_array | 0.0158 → 0.0163 | +3.1% | 10.0 → 10.1 | — |
| bench_string | 0.0368 → 0.0370 | +0.6% | 4.2 → 4.3 | — |
| bench_property_lookup | 0.0395 → 0.0474 | +19.8% | 4.3 → 4.4 | — |
| bench_closure_capture | 0.0855 → 0.1036 | +21.2% | 4.2 → 4.3 | — |

The cooperative policy trades throughput and, on some workloads, retained memory
for shorter interruptions. Pool blocks and intern-table capacity remain available
for reuse. A full-cycle delay can retain garbage longer than a minor collection.
Threaded handlers preflight publications and use the normal interpreter for a
value requiring shading; this preserves their fast path without skipping barriers.

## Validation

- Full targeted test262: **48,922 pass, 0 fail, 0 compile errors**, 4,665 skipped.
- Local scripts: **470/0**; module fixtures: **20/0**. Syntax positions 113,
  export names 63, top-level syntax 24, uncaught reporting 20, rejection reporting
  13, robustness 12, compile messages 26 and TypeScript handbook 43: all pass.
- Rosetta: **42/0**. Golden outputs: **28/28**.
- ASAN + GC_VERIFY + POOL_BYPASS stress: **16/0**; optimized threaded variants
  also **16/0** in both NaN-box and NONANBOX builds.
- Direct incremental collector tests pass with ASAN and the independent full-mark
  oracle in both representations, including one-unit slices, mutation behind
  scan cursors, generator retirement, partial destruction and reset, and a
  720k allocation-only loop with bounded retained nodes.
- Embedding ABI/API/module tests, five NONANBOX CLI regressions and ASAN heap-reset
  tests (**40/40**) pass. Rebuilt ASAN test262 Symbol and Iterator repros pass.
- After the final threaded fast-path edit, optimized threaded stress in both
  representations, full test262, Rosetta and local suites were rerun.

## Ownership and safety

The typed `PropValue` boundary has no writable `TVal*` view. Traced publications
shade through heap/root/edge APIs; scoped native roots protect reentrant calls.
Intrusive queues require no mark-time allocation. Resumable scans retain owners
and indexes instead of pointers into movable backing arrays. Generator queue
entries own a state reference, and retirement defers resource destruction.
Independent marking checks reachability before reclamation; ASAN bypasses pools
to expose freed storage.

Regression coverage includes readonly Symbol stores, callback return values,
iterator accumulators, queued async-generator strings, rejection reentry and
compiler default-literal ownership. C3 distinct types and narrow APIs strengthen
these invariants, but C3 does not provide linear ownership and raw pointers still
require discipline. Host finalizers must not allocate or resurrect objects.

String retention predates generations: the same 10,000-iteration native ownership
probe (`'a'.replace(/a/, String.prototype.repeat.bind('x', 2048))`) retains 203 large
strings / 413,723 payload bytes before explicit collection on both c3c18245 and
68faeb5c, versus one string / 27 bytes on 8dd4427c. This is retained string payload,
not RSS. The string-ownership fixes are retained independently of the collector.

## Reproduction and raw data

```
just test-gc-incremental
just test-gc-threaded
just build boomkat_gcprofile
python3 scripts/profile_gc.py --runs 3 --output benchmarks/gc-cooperative-profile.json
```

Use `scripts/bench_interleaved.py BASELINE out/boomkat INPUTS --pairs 5 --out DIR`
for release comparisons; both binaries receive `--script`. On macOS, RSS
collection requires permission for `time -l` to read process statistics.

Raw measurements: [profile](gc-cooperative-profile.json),
[generational comparison](gc-cooperative-vs-generational/results.json),
[lazy-sweep comparison](gc-cooperative-vs-lazy/results.json), and
[tuning history](gc-cooperative-tuning.json).

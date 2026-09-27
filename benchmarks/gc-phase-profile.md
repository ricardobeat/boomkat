# Generational GC phase profile

Status: the collector does **not** meet the requirement that every GC pause
stay below 4 ms.

This profile covers the collector before counted string ownership. The
[string ownership profile](gc-string-ownership-profile.md) records the
current measurements and remaining bottlenecks.

## Method

Measured on macOS ARM64, 2026-09-27, with C3 0.8.3 and the O2
`boomkat_gcprofile` target. These measurements describe the uncommitted
generational collector on top of `68faeb5c`. They compare its adaptive
allocation budget against an experimental cap of 16,384 allocations.
They do not compare against the pre-generational collector.

Each variant runs each workload three times, sequentially, without concurrent
builds or tests. Phase timers use the monotonic nanosecond clock at phase
boundaries; they do not time individual edges or print during a pause.
Reported maxima are the largest observed across the three runs. Cumulative
times are medians across runs. All runs exit successfully. Timings include
scene construction, execution, and any collections performed by CLI cleanup;
the scene's own frame timer covers only its frame loop.

The original measurements are in [gc-phase-profile.json](gc-phase-profile.json).
The repeatable driver adds one discarded warmup for each workload:

```sh
just build boomkat_gcprofile
python3 scripts/profile_gc.py --runs 3 --output /private/tmp/gc-profile.json
```

A second uncapped pass through this driver, with its discarded warmups,
confirms the result: 300k maxima are 31.198 ms minor, 41.817 ms major,
and 4.262 ms deferred sweep. Heavy VDOM stays below 1.712 ms.
The JSON includes these repeat summaries under `_warmup_repeat`.

The profiling CLI defaults to script mode. The workloads are:

- Scene: 10,000 nodes / 300 frames.
- Scene: 100,000 and 300,000 nodes / 3,000 frames.
- Heavy VDOM: 300 frames, 150 components, 80 list items per component.

GC_PROFILE also increments existing per-value counters, so these figures
diagnose collector costs rather than replacing interleaved release benchmarks.
A measured maximum is evidence about these runs, not a hard realtime bound.

## Pause maxima, adaptive allocation budget

| Workload | Minor collection | Major collection | Deferred sweep step |
| --- | ---: | ---: | ---: |
| Scene 10k | 1.141 ms | 1.213 ms | 0.179 ms |
| Scene 100k, 3,000 frames | 18.413 ms | 20.617 ms | 1.631 ms |
| Scene 300k, 3,000 frames | 33.009 ms | 42.362 ms | 4.140 ms |
| Heavy VDOM | 1.317 ms | 1.086 ms | 0.532 ms |

Whole-frame maxima and GC-pause maxima measure different intervals.
Several collections or sweep steps can occur during one frame.

## Bottlenecks

1. **Major tracing is uninterrupted.** At 300k, the root/graph phase takes
   up to 42.271 ms, accounting for almost the entire worst major pause.
   `mark_roots` drains the gray stack; `drain_gray` walks every property,
   shape key and array capacity entry before returning. A budget measured
   only in objects cannot bound the scan of one large container.

2. **Minor collections walk the entire string population.** Clearing string
   marks costs 426.845 ms cumulatively at 300k, about 78% of total minor
   collection time. With the 16k allocation cap it costs 1,987.073 ms.
   `clear_interned_string_marks` scans the complete intern table, and
   `clear_large_string_marks` scans the complete large-string registry.
   This makes minor cost depend on retained old data.

3. **Young sweeping is uninterrupted and its budget follows major live size.**
   A major collection can grant a large allocation budget, allowing a large
   batch of young garbage to accumulate. Young sweeping alone reaches
   14.956 ms at 100k and 21.325 ms at 300k.

4. **Remembered owners are rescanned in full.** The remembered graph phase
   reaches 14.175 ms at 300k. The code scans the entire array part of a
   remembered object. The growing scene array is a likely contributor;
   the phase measurement does not attribute time to individual owners.
   Range/card tracking or resumable container scans are needed to bound this.

5. **A fixed old-sweep node count does not bound elapsed time.** A step of
   4,096 nodes reaches 4.140 ms. Destruction cost varies with object contents;
   completion can also sweep large strings.

Environment cleanup and weak-cache pruning are small in these workloads.
That observation does not establish a bound for programs with many environments.

## Why the nursery cap alone fails

At 300k, the cap lowers worst young sweeping to 1.445 ms, but total minor pauses
still reach 6.908 ms and major pauses reach 43.121 ms. Minor collections rise
from 139 to 1,154 per run; majors rise from 7 to 23. The fixed policy of one
major after 64 minors couples the increased minor frequency to more full
tracing. Median cumulative minor time rises from 547.890 to 2,321.604 ms.

The cap is removed from the working source. Budget changes need to accompany
removal of whole-heap work from minors and a major policy based on actual debt.

## Heavy VDOM

Median measured collector time is about 368 ms:
145.367 ms in minor pauses, 53.158 ms in major pauses, and 169.947 ms in deferred
sweeping. No measured pause exceeds 4 ms. Deferred sweeping is the largest
aggregate GC category; remembered tracing contributes 80.455 ms and minor
string processing contributes 45.861 ms.

A separate 2-second macOS `sample` capture at 1 ms intervals contains 1,479
main-thread samples. Its leading leaf samples include VM execution (335),
memmove (95), memset (76), string allocation (75), cached property reads (69),
decref (63), property lookup (59), shape transitions (55), and property creation
(55). Optimized stacks have limited caller attribution; these are diagnostic
sample counts, not precise percentages of whole-program runtime.

## Work required for the 4 ms target

- Remove whole-string-table clearing from minors using an explicit mark
  lifecycle that preserves major-collection reachability.
- Bound young reclamation independently of total old-generation size.
- Track modified container ranges or resume their scans between slices.
- Slice major marking by edges and elapsed time, with barriers and explicit
  root ownership that preserve correctness between slices.
- Budget old sweeping and string processing by work and elapsed time.
- Repeat phase profiling, release benchmarks, GC_VERIFY, stress and ASAN
  validation after the collector changes.

The phase timers and above-budget counters remain available to check the
requirement directly.

# GC profile with counted string ownership

The collector still exceeds the 4 ms pause requirement on large scenes.
These measurements include the explicit string ownership conversion in
[plan 094](../plans/094-string-ownership.md).

## Method

macOS ARM64, C3 0.8.3, O2 `boomkat_gcprofile`, 2026-09-27. Each workload
has one discarded warmup and three measured runs, without concurrent builds
or tests. Maximum values below are the largest across the measured runs.
Phase timers include collections during construction and CLI cleanup.
GC pauses and whole-frame times cover different intervals.

```sh
just build boomkat_gcprofile
python3 scripts/profile_gc.py --runs 3 --output /private/tmp/gc-profile.json
```

[Raw runs and phase summaries](gc-string-ownership-profile.json).

## Pause maxima

| Workload | Minor | Major | Deferred sweep |
| --- | ---: | ---: | ---: |
| Scene 10k, 300 frames | 0.649 ms | 0.813 ms | 0.340 ms |
| Scene 100k, 3,000 frames | 15.648 ms | 16.504 ms | 3.100 ms |
| Scene 300k, 3,000 frames | 27.012 ms | 33.516 ms | 5.283 ms |
| Heavy VDOM, 300 frames | 0.544 ms | 0.509 ms | 1.133 ms |

Heavy VDOM uses 150 components and 80 list items per component.
A measured maximum does not establish a hard realtime bound.

## Release comparison

Three alternating pairs plus a discarded warmup compare the release binary
against the saved pre-generational `c3c18245` binary. Scene frame times use
the workload's millisecond clock; wall time includes process startup and
cleanup. These results show a throughput regression.

| Workload | Baseline wall | Candidate wall | Change | Median worst frame, baseline → candidate |
| --- | ---: | ---: | ---: | ---: |
| Scene 10k | 0.1203 s | 0.1313 s | +9.1% | 2 → 3 ms |
| Scene 100k | 1.5047 s | 1.6177 s | +7.5% | 40 → 35 ms |
| Scene 300k | 1.6101 s | 1.7388 s | +8.0% | 66 → 56 ms |
| Heavy VDOM | 2.5866 s | 2.7417 s | +6.0% | — |

[Raw alternating pairs](gc-string-ownership-interleaved.json). These wall
times use the release CLI; the phase measurements above use GC_PROFILE.

## Remaining costs

At 300k, major root and graph tracing reaches 33.478 ms, young sweeping
20.460 ms, and minor remembered-owner tracing 9.742 ms. Major string-table
scanning reaches 0.069 ms. Minor collections do not walk string registries.
The string phase timer remains around its conditional branch and rounds
to 0.000 ms at this reporting precision.

The collector needs resumable graph traversal, bounded reclamation and
remembered array ranges to meet the pause target. Per-object budgets alone
cannot bound a large container scan or destructor. The write barrier must
also preserve reachability when a mutator runs between marking slices;
splitting the existing mark loop without that invariant would be unsafe.

## Ownership validation

- 468 local scripts and 20 module tests pass; Rosetta passes 42 tests.
- ASAN plus GC_VERIFY and GC_STRESS passes all 12 lifetime fixtures.
- Temporal identifier lifetime passes 80 checks with the same instrumentation.
- Direct C3 tests pass with ASAN and GC_VERIFY, including shape copies,
  aliased replacement, callback results, register reuse and JSON churn.
- Native add-on payload string ownership passes; ABI version is 2.
- Targeted String, JSON and Iterator test262 runs pass 2,030 tests.

The register/string churn check peaks at 34,238 string allocation bytes,
versus 20,880,068 before the ownership fixes. These are string allocation
bytes, not process RSS. Distinct owner types and scoped `defer` cleanup
enforce specific boundaries; C3 does not provide linear ownership checking.

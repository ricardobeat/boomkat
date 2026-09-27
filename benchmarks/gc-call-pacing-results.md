# GC call pacing follow-up

This follow-up measures the pacing change after the cooperative collector landed
in commit `e8a4e4f9`. The measured policy enters GC after 16 pending call/return
checks and allows 512 work units per entry. Empty mark queues do not consume the
work allowance. Loop safepoints still run every 1,024 backward branches with a
65,536-unit allowance. Steps use a 0.5 ms soft clock budget checked every 32
units. `GC_STRESS` keeps every pending call/return safepoint active.

Measurements ran on the Apple M3 / C3 0.8.3 / LLVM 22.1.8 setup in the main
[cooperative GC report](gc-cooperative-results.md). Release comparisons use one
warmup pair and five alternating pairs, with process startup included. The raw
suite summary compares a fresh `8dd4427c` generational build with the paced
collector. The selected workload comparison uses the committed `e8a4e4f9`
cooperative build. Results include the 100k scene and heavy VDOM; they do not
include the 300k scene.

## Benchmark-suite impact

Each suite total is the sum of per-case median wall times. It is not a single
suite invocation. Positive changes mean slower execution.

| Suite | Generational → paced | Change |
|---|---:|---:|
| `just bench` (20 cases) | 1.6200 → 1.7347 s | +7.1% |
| `bench-es6` (8 cases) | 2.4253 → 2.7770 s | +14.5% |

The ES6 cases most affected by temporary allocation are:

| Case | Generational → paced | Change |
|---|---:|---:|
| Destructuring | 0.5987 → 0.6820 s | +13.9% |
| Spread/rest | 0.2256 → 0.2603 s | +15.3% |
| Promise | 0.3847 → 0.4633 s | +20.4% |
| Class | 0.6249 → 0.7332 s | +17.3% |

## 100k scene and heavy VDOM

| Workload | Generational → paced | Worst frame | RSS |
|---|---:|---:|---:|
| 100k scene, 3,000 frames | 1.6167 → 2.0501 s (+26.8%) | 34 → 4 ms | 240.7 → 197.7 MiB |
| Heavy VDOM, 300 frames | 2.8248 → 2.9055 s (+2.9%) | 13 → 11 ms | 39.0 → 16.0 MiB |

The same paced build compared with the cooperative build from `e8a4e4f9`
reduces the default scene-churn runtime by 9.1%, the 100k scene by a measured
1.2% (worst frame 5 → 4 ms), and heavy VDOM by 2.5% (worst frame 13 → 12 ms).
It reduces destructuring by 19.2% and spread/rest by 27.0% versus that build.
The later `32 checks / 1,024 units` trial gave no consistent ES6 improvement,
so it is not the selected policy.

## Collector work

The measured safepoint entries fell from 1,341,088 to 111,753 for destructuring
and from 785,341 to 50,629 for spread/rest: about 12× and 15× fewer entries.
Marking time in the instrumented runs fell from 94.5 to 41.5 ms for
destructuring and from 242.0 to 15.1 ms for spread/rest. Per-run p99 scheduled
slices were at most 20 μs on the 100k scene and 10 μs on VDOM. Maximum slices
were 0.502 ms and 0.397 ms respectively; no measured slice reached 4 ms.
The p99.9 upper bounds were 0.350 ms and 0.210 ms.

Call pacing removes redundant entries into the collector while keeping progress
on loop backedges. The independent mark verifier, typed publication barriers
and root lifetimes are unchanged. The remaining suite and 100k throughput cost
comes from tracing and reclaiming the full live heap. Further improvement needs
to reduce repeated full-heap work while preserving bounded steps: the next
collector design should use a bounded young-object collection and remembered
owners, with major tracing and sweeping on the same resumable work queues.

The 0.5 ms deadline is soft. Host callbacks, allocator calls and intern-table
rehashing remain indivisible. Whole VDOM frames still exceed 4 ms because this
benchmark includes application work as well as GC.

Raw data: [pacing versus the prior cooperative build](gc-call-pacing-vs-cooperative/results.json),
[full suite summary versus generational GC](gc-call-pacing-generational-summary.json),
and [selected pause profiles](gc-call-pacing-profile.json).

# Engine throughput experiments

Baseline: `972c7f49`. Each retained improvement has its own commit, semantic
checks and alternating measurements against an immutable release binary.
Use C3 0.8.3 and the existing release configuration. Run timings outside the
filesystem sandbox, with no concurrent builds or test suites.

## 1. Date formatting — retained

Local formatting reuses the offset returned with the civil fields. This removes
one duplicate `localtime_r` call from `toString`, `toTimeString`, and local
`toLocale*` formatting. Every public operation still samples the host timezone;
there is no cache or new invalidation policy.

The initial assumption that Date dominates normal execution was false. Inside
the sandbox, repeated timezone lookup makes the original benchmark take about
2.7 seconds. Outside it, the subcases take 0–2 milliseconds each. The earlier
GC report's Date timing and its ES5 aggregate therefore describe sandboxed
execution, not ordinary desktop throughput. Per-case non-Date results remain
separate evidence.

Seven alternating pairs outside the sandbox, after warmup, using the unchanged
Date benchmark with only N raised from 2,000 to 100,000: median 0.7142 to 0.6780
seconds (5.1% less time). This is an amplified Date workload, not an engine-wide
speedup. Raw data: `benchmarks/engine-throughput/date/results.json`.

Validation: Rosetta 42/0; Date test262 591 pass, 3 skip, 0 fail. Baseline/candidate
formatting output matches for 583 dates in each of UTC, America/New_York,
Europe/Amsterdam, Asia/Kathmandu and Australia/Lord_Howe, including DST windows,
negative timestamps, TimeClip extremes and NaN.

## 2. Fixed-shape object literals

The compiler selects a shared transition shape for unique non-index string
keys. `NEWOBJ_SHAPE` reserves the complete property storage once; `INIT_SLOT`
stores values through the existing ownership/barrier helper. All slots start
undefined, including those not yet evaluated when an initializer suspends or
calls user code. Methods, accessors, duplicate/computed keys, spread, prototype
syntax, wide operands and oversized shape IDs keep the general path.

Verified lifetime: `free_shape_slot` only reclaims private shapes. Transition
shapes own their keys and live until heap reset; reset also frees compiled
functions. This design needs no template objects or new root registry.

The first experiment removed key-load instructions entirely. It improved
throughput but raised the 100k scene's peak RSS from 198.5 to 268.9 MiB. Profiles
showed approximately 1.2 million extra positive-refcount strings; extra
collections did not release them. A key load also releases the previous owned
value in that register. The retained implementation replaces it with LDUNDEF,
preserving that ownership effect. An ASAN/GC_VERIFY test executes a reduced
renderer, forces collection, and asserts that string retention stays bounded.
The check passes with both NaN-boxed and NONANBOX values.

Five alternating pairs after warmup, outside the sandbox, against `30bff86a`.
Suite totals sum per-file medians; all outputs match after timing normalization.
Raw data: `benchmarks/engine-throughput/literals/results.json`.

| Workload | Baseline | Candidate | Runtime change |
|---|---:|---:|---:|
| ES5 (20 cases) | 1.7394 s | 1.6634 s | -4.4% |
| ES6 (8 cases) | 2.5852 s | 2.5790 s | -0.2% |
| Heavy VDOM | 2.9275 s | 2.6037 s | -11.1% |
| 100k scene / 3,000 frames | 1.8997 s | 1.7539 s | -7.7% |

Scene peak RSS falls from 198.5 to 196.9 MiB; heavy VDOM from 17.2 to 16.7 MiB.
Median worst frames: scene 2 → 2 ms; VDOM 12 → 11 ms. The ES6 aggregate is
approximately flat; destructuring improves 3.6%. Tiny per-case changes are not
attributed to this optimization.

Preliminary results are not the final benchmark dataset. Two apparent regressions in an earlier run (shape stress
and closure capture) disappeared in an eleven-pair recheck: +0.2% and +0.3%.
Neither workload executes a specialized literal.

Validation: Rosetta 42/0; local scripts and module/ancillary suites pass;
object-literal test262 1,170/0; 28 bytecode goldens; embedding API; 17 threaded
ASAN/GC_STRESS/GC_VERIFY checks before the ownership correction, followed by
fresh direct ASAN/GC_VERIFY tests in both value representations and a rerun of
object test262/local/goldens after the correction. The literal fixture also
checks dynamic compilation, initializer order, descriptors, mutation and
suspension, and agrees with Node (20,194 assertions).


## 3. Register-frame compaction

Pending.

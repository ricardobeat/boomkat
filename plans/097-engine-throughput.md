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

Pending.

## 3. Register-frame compaction

Pending.

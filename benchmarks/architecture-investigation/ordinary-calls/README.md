# Ordinary property stores and `this` dispatch

Baseline: `3ef9118e`. Platform and compiler are in `manifest.json`; binary
hashes and individual measurements are in `results.json`.

## Implementation

- Ordinary own-data property stores resolve `prop_idx` against the current
  receiver. The cache validates key, shape, generation, ownership and descriptor
  flags. Each store retains the heap's string ownership and GC write barrier.
  Proxies, module namespaces and other exotic classes take the generic path.
- `LDTHIS` runs in threaded dispatch when loading the binding requires neither
  collector shading nor string destruction. The fallback handles derived
  constructor TDZ errors and reference-management slow paths. Register root
  tracking remains active.

These changes add no object fields, cache fields, opcodes or allocations.
`runtime.patch` contains the production source changes.

## Measurements

`measure.py` runs sequentially, rotates and reverses binary order, and takes
five measurements after one warmup. Whole-process times include startup,
compilation and teardown. Internal phases use integer-millisecond `Date.now`.
The probes check their results; scene runs check the expected change count;
all class runs produce `CHECK 791665291667649000`.

| Whole-process median, ms | Baseline | `LDTHIS` only | Combined | QuickJS |
|---|---:|---:|---:|---:|
| Class phases | 676.12 | 653.59 | 643.39 | 275.52 |
| Function calls | 49.53 | 50.03 | 49.83 | 31.99 |
| Scene: 10k nodes / 300 frames | 138.18 | 137.57 | 138.24 | 77.55 |
| Scene: 100k nodes / 3000 frames | 1521.45 | 1518.49 | 1515.88 | 897.81 |

The class improvement is 4.8%; VDOM and ordinary function calls show no
meaningful gain. Median peak RSS for the 100k scene is 164.06 MiB baseline,
163.95 MiB combined, and 72.42 MiB QuickJS (macOS `wait4`).

Matched probes execute one million iterations. Calls, reads, methods,
getters, literals and constructors compute the same arithmetic result, but
also execute different bytecode, so subtracting their times does not isolate
a native routine's CPU cost.

| Internal phase median, ms | Baseline | `LDTHIS` only | Combined | QuickJS |
|---|---:|---:|---:|---:|
| Arithmetic | 13 | 13 | 13 | 11 |
| Own-property reads | 22 | 22 | 22 | 15 |
| Plain function calls | 35 | 35 | 35 | 19 |
| Prototype method calls | 67 | 64 | 64 | 29 |
| Prototype getters | 65 | 62 | 63 | 35 |
| Object literals | 63 | 60 | 60 | 40 |
| Constructors | 147 | 146 | 147 | 61 |
| Writes to one receiver | 13 | 13 | 13 | 7 |
| Writes across 1024 receivers | 43 | 43 | 27 | 11 |

The cache change reduces the many-receiver write phase by 37%. The literal
probe contains no `LDTHIS`; its small movement is not attributed to that
handler. Instruction layout and measurement variation affect these results.

The baseline opcode profile (`class-opcodes.txt`) records 14,000,002 `LDTHIS`
switch visits. **This profiler counts switch dispatch only:** successful
threaded instructions do not reach its hook. Its pairs can span threaded
bursts or function boundaries; they are not necessarily adjacent bytecode.
These counts identify fallback traffic, not elapsed CPU time.

### Repository benchmark recipes

`just bench-es6` is the relevant broad suite for the class/method changes.
The default recipe reports best-of-three whole-process times. Baseline and
candidate ran separately; its per-benchmark engine groups are sequential.

| ES6 benchmark, ms | Baseline | Combined | QuickJS (combined run) |
|---|---:|---:|---:|
| class | 668 | 637 | 275 |
| closure_capture | 103 | 103 | 149 |
| destructuring | 572 | 570 | 236 |
| forof | 138 | 140 | 52 |
| let_loop | 160 | 155 | 217 |
| promise | 382 | 381 | 228 |
| spread_rest | 243 | 236 | 181 |
| template_literal | 147 | 146 | 115 |
| Total | 2413 | 2368 | 1453 |

Class improves 4.6%; the sum improves 1.9%. For-of moves 2 ms slower and the
other changes outside class are small. `just bench` and `just bench-fast`
also completed; their raw logs are retained. Reference caches for `bench`
were cleared before the baseline run, then reused by the candidate run.
Those recipes average three and two runs respectively, with millisecond
shell timing. Arithmetic has inconsistent outliers between runs; do not
attribute those to this patch.
Seven alternating follow-up runs (`noise-check.json`) give arithmetic medians
of 35.37/35.26 ms and function-call medians of 50.34/49.78 ms for
baseline/candidate. Neither reproduces a regression.

### Frame latency

`build_clocks.py` builds isolated baseline and candidate binaries with the same
temporary monotonic `Date.now` hook. Production clock behavior is unchanged.
`frames.py` uses that hook for Boomkat and `performance.now()` for QuickJS,
rotates/reverses engine order, and retains five runs after one warmup. The
table gives medians of each run's percentiles and maximum, in milliseconds;
all samples and binary hashes are in `frames.json.gz`.

| Scene | Metric | Baseline | Combined | QuickJS |
|---|---|---:|---:|---:|
| 10k / 300 frames | p50 | 0.3765 | 0.3794 | 0.2120 |
| | p99 | 0.7368 | 0.7231 | 0.2300 |
| | maximum | 0.8109 | 0.8230 | 0.2360 |
| 100k / 3000 frames | p50 | 0.4296 | 0.4319 | 0.2580 |
| | p99 | 1.0888 | 1.1026 | 0.3080 |
| | maximum | 1.7209 | 1.7332 | 0.3690 |

The changes do not improve VDOM throughput or frame latency.

## Validation

- Fresh test262 runner: 1,256 passes, zero failures, two scope skips across
  `language/expressions/this`, `language/expressions/super`,
  `built-ins/Object/defineProperty`, and `built-ins/Proxy/set`.
- `just rosetta`: 42 passes.
- Module suite: 20 passes. The new regression also passes in the release
  binary, a fresh debug build using switch dispatch, and QuickJS.
- Fresh `boomkat_threaded_asan` built with `-O2 -D GC_STRESS -D GC_VERIFY
  -D POOL_BYPASS`: all 20 GC lifetime cases plus the new regression pass.
- `test/test_ordinary_property_fastpaths.js` checks different receivers,
  backing-storage growth, string and object ownership, descriptor changes,
  setters, readonly writes, proxy traps, mapped arguments, primitive and
  lexical `this`, and access before/after `super()`.

## Next experiments

1. **Constructor setup and initial property creation.** The constructor probe
   remains 147 ms versus QuickJS's 61 ms; the literal probe is 60 versus 40 ms.
   Split constructor entry from property insertion with empty constructors,
   one/four/eight-field constructors, and equivalent factory functions.
   Test a guarded constructor entry path and a property-addition cache
   separately. A transition cache must validate prototype setters,
   extensibility, descriptor changes and recycled shapes, and preserve the
   write barrier. It must not pre-create observable fields before their JS
   initialization executes.
2. **Method/getter entry.** Methods and getters remain 64/63 ms versus 29/35 ms.
   Measure a minimal activation path for simple callees against the existing
   general entry. Preserve `this`, exceptions, eval/arguments, stack limits,
   interrupts and GC roots. Existing method-property ICs already validate
   the prototype chain; adding another lookup cache alone is insufficient.
3. **Small-function specialization.** Compare a guarded direct return for
   trivial getters against the minimal activation path before introducing
   general inlining. Require a win in the class suite and ordinary workloads,
   with bounded code growth and invalidation when the callee changes.

VDOM gets no measurable improvement from this patch. Its ordinary calls,
matrix arithmetic, indexed access and allocation need their own attribution;
the class result does not establish a VDOM bottleneck.

## Reproduce

Preserve a release build of the baseline as `/tmp/boomkat-ordinary-calls/baseline`
and the candidate as `/tmp/boomkat-ordinary-calls/combined` before measuring.
Run builds, benchmark comparisons and correctness suites sequentially.

```sh
python3 benchmarks/architecture-investigation/ordinary-calls/measure.py \
  --binary baseline=/tmp/boomkat-ordinary-calls/baseline \
  --binary combined=/tmp/boomkat-ordinary-calls/combined \
  --binary quickjs=out/qjs --out /tmp/ordinary-results.json
just bench-es6
python3 benchmarks/architecture-investigation/ordinary-calls/build_clocks.py \
  --work-dir /tmp/boomkat-ordinary-calls
python3 benchmarks/architecture-investigation/ordinary-calls/frames.py \
  --work-dir /tmp/boomkat-ordinary-calls
```

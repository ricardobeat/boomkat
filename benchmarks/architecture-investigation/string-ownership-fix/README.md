# String accumulator binding ownership

The VM verifies the actual write-back binding before extending a two-owner
string in place. The snapshot store uses its captured environment; ordinary
stores use a conservative lookup that invokes no user code. The binding must
be writable data and still contain the same string. Additional aliases,
accessors, with environments, consts, replaced bindings, and overlapping tails
retain the copying path.

The lexical-loop bytecode contains `GETVAR`, `RESOLVEVAR`, `ADD`,
`PUTVAR_SNAP`. The snapshot store is eligible once its ownership is verified.
The regression fixture also demonstrates rejected writes and RHS coercion
aliases that the baseline mutates incorrectly.

## Scaling

Median of five rotated measured runs after warmup. Inner timing uses Date.now;
0–2 ms values are resolution limited. Wall timing includes startup, consuming
the result through full equality against the expected string, and teardown.

| Appends | Before loop ms | After loop ms | QuickJS loop ms | Before wall ms | After wall ms | QuickJS wall ms |
|---|---:|---:|---:|---:|---:|---:|
| 10,000 | 18 | 1 | 0 | 20.63 | 3.63 | 3.10 |
| 20,000 | 70 | 1 | 1 | 72.26 | 4.20 | 3.52 |
| 40,000 | 259 | 2 | 2 | 262.44 | 5.76 | 4.26 |
| 80,000 | 1019 | 5 | 3 | 1022.06 | 8.89 | 6.25 |

## Wider workloads

Wall milliseconds; changes compare this fix against GC64, which both binaries
include. The class result is 1.5% slower in this run; no class improvement is
claimed. Other non-string changes are small and are not attributed.

| Workload | Before ms | After ms | Change | QuickJS ms | Before RSS MiB | After RSS MiB |
|---|---:|---:|---:|---:|---:|---:|
| bench_string | 36.80 | 36.80 | +0.0% | 21.65 | 4.27 | 4.28 |
| es6/bench_forof | 209.36 | 139.19 | -33.5% | 50.52 | 62.72 | 64.33 |
| es6/bench_template_literal | 147.27 | 147.75 | +0.3% | 115.21 | 4.36 | 4.39 |
| es6/bench_class | 671.00 | 681.03 | +1.5% | 273.52 | 6.44 | 6.45 |
| es6/bench_destructuring | 570.16 | 571.04 | +0.2% | 236.65 | 200.34 | 200.36 |
| es6/bench_closure_capture | 102.09 | 102.30 | +0.2% | 148.48 | 4.36 | 4.36 |
| bench_function_call | 49.84 | 50.40 | +1.1% | 31.48 | 4.33 | 4.38 |
| bench_loop | 28.23 | 28.14 | -0.3% | 25.44 | 4.25 | 4.25 |
| scene-10000 | 135.95 | 137.25 | +1.0% | 74.92 | 26.22 | 26.19 |
| scene-100000 | 1477.32 | 1484.73 | +0.5% | 845.11 | 196.97 | 197.00 |

The mixed-iteration benchmark improves by 33.5%, with peak RSS increasing
about 2.6% (62.7 to 64.3 MiB). At 80k lexical appends, peak RSS falls from
7.44 to 5.75 MiB. The var-loop control remains at 4 ms for 80k appends.

The 100k scene's median worst frame is 2 ms before and after, versus 1 ms in
QuickJS. These are integer-millisecond measurements, not high-resolution tail
estimates. The full per-run results include both retained-scene sizes.

## Copied bytes

Isolated instrumented builds run 20k lexical appends. They are not the binaries
used for timing. Counters cover copies into freshly allocated concat strings,
including growth, and appended tail bytes; they exclude intermediate temporary
buffer copies and other engine traffic.

| Counter | Before | After |
|---|---:|---:|
| Fresh concat results | 20,000 | 7 |
| Geometric buffer growths | 0 | 11 |
| Bytes copied into new backing strings | 1,000,050,000 | 143,430 |
| Bytes appended into spare capacity | 0 | 99,965 |

`copy-instrumentation.patch` contains the temporary counters. No profiling code
is present in the engine changes.

## Correctness

- `test/concat_binding_ownership.js` passes in Boomkat, QuickJS, and Node.
  The baseline fails the RHS-coercion alias case and non-writable-global cases.
- Existing accumulator aliasing and string-identity fixtures pass.
- Five targeted fixtures pass a fresh optimized threaded ASAN build with
  GC_STRESS, GC_VERIFY, and POOL_BYPASS. The expanded regression fixture is
  rerun after its read-only-global cases are added.
- Fresh test262 runner: **454/454** compound-assignment tests pass, no skips.
- Rosetta: **42/42** pass.
- No full test262 run. Captured-cell, wide-store, and other unrecognized stores
  conservatively retain the copying path; this fix does not implement general
  ownership IR, ropes, call-frame changes, or a new object representation.

## Reproduction

`manifest.json` records the baseline revision and build setup;
`binaries.json` records timing-binary hashes. Create an isolated checkout of
that revision, apply `baseline-gc64.patch`, and build with `just build boomkat`.
Preserve that executable. Apply `runtime.patch` for the candidate and rebuild.
The current working-tree `out/boomkat` and `out/qjs` are the candidates consumed
by this script:

```sh
python3 benchmarks/architecture-investigation/string-ownership-fix/run_bench.py --baseline /path/to/preserved/boomkat --out /tmp/boomkat-string-bench
```

Build the copy-counter variants separately with `copy-instrumentation.patch`
and run `copy-probe.js`. Run semantic checks with `--script`; the regression
fixture deliberately exercises sloppy `with` and failed global assignment.

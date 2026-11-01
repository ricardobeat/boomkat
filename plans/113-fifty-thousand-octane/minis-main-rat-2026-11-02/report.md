# Main versus rat: Octane minis and historical regression check

Committed snapshots: main `7533520f`, rat `fec58fc1`, historical rat `b85ef0ba`. Both current branches were built fresh with `c3c build boomkat` (O2, uninstrumented). Main is interpreter-only; rat uses `--jit`. All engine inputs are the same rat mini files; Navier runs 16 frames and reaches its checksum. Strings/Intl is excluded because it is not an Octane mini.

One unmeasured pass per binary/file precedes five measured alternating pairs. Each run is a fresh process. These minis include JIT work during their timed iterations and omit original Octane warmup/latency phases. The initial sandboxed attempt failed in `/usr/bin/time` resource-counter access and was discarded entirely; the recorded run used working counters. All recorded runs completed successfully. No builds or profiling ran concurrently with measurements.

## Current branch comparison

Values are median in-benchmark milliseconds, summing named subtests within each mini file. Rat/main is elapsed-time ratio; lower is better.

| Mini | Main ms | Rat JIT ms | Rat/main |
|---|---:|---:|---:|
| box2d | 226 | 784 | 3.47x |
| code-load | 158 | 165 | 1.04x |
| crypto | 275 | 261 | 0.95x |
| deltablue | 250 | 93 | 0.37x |
| earley-boyer | 168 | 180 | 1.07x |
| gbemu | 235 | 2,873 | 12.23x |
| mandreel | 789 | 645 | 0.82x |
| navier-stokes | 556 | 2,844 | 5.12x |
| pdfjs | 332 | 371 | 1.12x |
| raytrace | 161 | 169 | 1.05x |
| regexp | 338 | 232 | 0.69x |
| richards | 220 | 71 | 0.32x |
| splay | 112 | 121 | 1.08x |
| typescript | 1,124 | 1,315 | 1.17x |
| zlib | 4,847 | 3,739 | 0.77x |

Geometric mean across the 15 mini workload ratios: **1.211x elapsed time** (21.1% longer). Equivalently, throughput ratio 0.826x. This is not a full-Octane score. Individual samples, process wall time and peak RSS are retained in [raw.json](raw.json).

## Check against the user's b85ef0ba baseline

Three alternating configurations per case: historical JIT, current JIT, current interpreter. Identical inputs and build options.

| Measurement | b85ef0ba JIT | Current JIT | Current interpreter |
|---|---:|---:|---:|
| box2d ms (lower better) | 207 | 715 | 225 |
| gbemu ms (lower better) | 278 | 2,865 | 251 |
| navier-original-runner score (higher better) | 7,109 | 838 | 4,162 |
| navier-stokes ms (lower better) | 308 | 2,833 | 568 |

The original Navier runner is recovered by removing only the mini RunSuites override from the self-contained benchmark; original warmup, reference score and validation remain. Its standalone score reproduces the historical ~7.1K performance but falls to 838 on current rat. This establishes a real warmed-throughput regression, not merely cold compilation or the old 10-versus-16-frame mini difference. It does not measure the full-suite geometric mean.

## Runtime profile and source diagnosis

A separate three-second sample of current rat running the original Navier runner has 2,277 main-thread samples. Flat top-of-stack counts: loop_prepare 582 (25.6%), ssa_execution_publish 438 (19.2%), ssa_execution_roots 177 (7.8%), loop_binding_effective 148 (6.5%), ssa_helper_state 147 (6.5%), memmove 140 (6.1%), ssa_execution_reload 83 (3.6%). See [navier-current.sample](navier-current.sample). Profiled execution is excluded from timing results.

Source inspection ties this to recoverable binding reads: historical GETCAP/GETVAR/GLOBAL lowered to BINDING/constants; current recovery paths route them through rooted helpers and a VM step. Each read can pay live-frame publication, root updates, repeated register-window copies and then loop_prepare, which refreshes the plan's bindings/descriptors. Navier's lin_solve tests captured width inside its inner loop; advect reads captured rowSize twice per cell and width in the loop condition. This matches the observed runtime profile. It is evidence for a costly helper boundary; no individual culprit commit has yet been bisected or fix validated.

Per-invocation allocation/root setup and repeated unsuccessful SSA admission are additional source-level concerns, but allocation is not dominant in this Navier sample. They should not be reported as the measured primary cause.

Fresh binding reads and exact recovery are correctness requirements. The repair must provide guarded live binding access and effect-appropriate continuation work; simply restoring stale entry snapshots is unsafe. These regressions block performance acceptance. No engine source changes were made during this benchmark investigation.

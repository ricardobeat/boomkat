# Synchronous generator register ownership

## Implementation

Both generator resume entry paths use the same restore helper. Synchronous
resume transfers references from saved slots into the active registers and
clears the saved slots. It shades each incoming value before releasing the
old destination, using the same ownership-transfer primitive as builtin results.
The generator is executing and cannot be resumed again until it suspends.
Yield repopulates the snapshot. Async restore retains copying.

An accumulator held by both its active register and its saved snapshot has an
extra string owner throughout execution. Removing that snapshot owner permits
in-place growth when no observable alias exists. Retained yielded prefixes
still have their own references and remain immutable.

This change still visits every restored register and copies registers at
suspension. It does not introduce stable generator register segments or eliminate
IteratorResult allocation. Wide numeric loops are controls for those costs.

## Results

Whole-process milliseconds; five measured runs after one warmup, alternating
engine order. Output and expected checksums are consumed. Baseline is commit
016cc2a1, including stable native-call frames and compact arrays. Every append
step also yields and resumes; the final string is compared in full.

| Workload | Baseline ms | Candidate ms | QuickJS ms |
|---|---:|---:|---:|
| append-10000 | 24.99 | 6.20 | 4.58 |
| append-20000 | 83.13 | 8.88 | 5.62 |
| append-40000 | 288.63 | 14.34 | 8.72 |
| append-80000 | 1050.25 | 25.57 | 14.65 |
| wide-8 | 27.11 | 27.46 | 11.82 |
| wide-64 | 67.31 | 68.72 | 16.75 |
| wide-192 | 230.91 | 228.00 | 26.28 |
| forof | 139.36 | 138.54 | 51.77 |
| class | 672.92 | 670.96 | 277.53 |
| scene-100000 | 1522.29 | 1534.46 | 904.10 |

At 80k steps, whole-process time improves about **41x**. Candidate time grows
approximately linearly across the tested sizes; the baseline grows roughly
fourfold when the large iteration count doubles. Date.now loop timings are
integer milliseconds and appear in raw stdout, separate from the wall metric.

Wide numeric generators range from 1.3% faster to 2.1% slower; there is no
broad numeric generator speedup claim. Mixed iteration changes -0.6%, class
-0.3%, and VDOM +0.8%. These small changes are not attributed to the fix.
The existing generator gap to QuickJS remains for wide numeric register files.

| Workload | Baseline peak MiB | Candidate peak MiB | QuickJS peak MiB |
|---|---:|---:|---:|
| append-80000 | 7.95 | 8.52 | 3.45 |
| wide-192 | 7.52 | 7.53 | 2.58 |
| forof | 56.14 | 56.19 | 23.11 |
| scene-100000 | 164.05 | 164.06 | 72.42 |

## Validation

- **616 test262 passes, 1 scope skip, no failures**: GeneratorPrototype,
  generator declarations, and generator expressions.
- **20/20** lifetime fixtures under freshly rebuilt ASAN + GC_STRESS + GC_VERIFY
  + POOL_BYPASS, including the new generator ownership fixture.
- **42/42** Rosetta fixtures.
- All **16** local generator/yield fixtures pass.
- The new ownership fixture passes QuickJS and the baseline too. It covers
  retained prefixes, direct/call/apply/bind resumes, throw/return/finally,
  delegation, mapped arguments, and nested native callbacks.

## Reproduction

Preserve an optimized executable built from the manifest's baseline revision.
Apply `runtime.patch`, build the normal CLI with `just build boomkat`, then run:

```sh
python3 benchmarks/architecture-investigation/generator-register-ownership/run_bench.py --baseline /path/to/baseline --out /tmp/boomkat-generator-repro
```

No production clock hook or profiling counters are needed. Raw wall times,
peak RSS, stdout, binary hashes, source fixtures, and validation results are
included here. VDOM high-resolution before/after frame measurements for the
committed frame/layout step are in the sibling `frames-array-layout` report.

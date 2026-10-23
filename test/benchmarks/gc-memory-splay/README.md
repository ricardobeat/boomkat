# GC memory and Octane Splay

Measured on 2026-10-23, Apple M3, macOS 27.0, C3 0.8.5 / LLVM 23.1.3.
All source changes are in the `boomkat-gcmem` worktree on `gc/memory`.

The baseline is a fresh build of `5ba4bee8`, which checkpoints the original
uncommitted LIFO gray stack, inline short arrays and whole-object small scans.
The first candidate snapshot includes incremental commits through `9b6f6011`.
The final validation after the string and stack-root fixes is recorded below.
Both use `boomkat-full-icu`; the retained release configuration uses O3 with
size optimization disabled, versus the starting configuration's O2/small.
QuickJS is the existing repository-built `../boomkat/out/qjs` reference.
The exact binary and benchmark hashes are recorded in [splay.json](splay.json).

Nine serial rounds rotate the three engines' order. The input is the unmodified
`javascript-zoo/bench/splay.js`, with Boomkat's `--script` flag. No builds or other
tests ran during measurement. Higher throughput and latency scores are better.
Peak RSS is measured with macOS `/usr/bin/time -l`, includes setup and warmup,
and is shown in decimal MB.

| Engine | Splay | SplayLatency | Peak RSS (MB) |
|---|---:|---:|---:|
| Starting worktree (`5ba4bee8`) | 5721 | 19866 | 1241.2 |
| Retained changes (`9b6f6011`) | 7962 | 21296 | 869.7 |
| Local QuickJS 2025-09-13 | 7848 | 19898 | 151.5 |

Splay improves **39.2%** over the starting worktree,
with **29.9% less peak RSS**.
It is **1.45% ahead of local QuickJS** by median,
and wins eight of the nine paired rounds. This is a small local throughput lead;
the table also records QuickJS's substantially smaller memory footprint.

The retained implementation uses contiguous generation vectors instead of
per-object allocation-list links, exact-size pools for short inline arrays,
two inline property slots for known small object shapes, and numeric array
literal templates. Repeated short concatenations use a bounded cache that owns
its operands and result; a hit publishes through the VM's existing reference
helpers. The remaining changes simplify teardown and shared property caches,
specialize numeric branches, and advance incremental collection more often.

Page bitmaps, prefetching, tighter nursery budgets, larger GC slices, releasing
empty sweep buffers, and speculative lookup variants did not give a suitable
speed/memory win and are absent from the retained code. Each retained step is
committed separately. The two existing test262 fixes were cherry-picked as
`45f601f3` and `26e959fc`.

Validation:

- Full local suite, NaN-boxed and NONANBOX: 658 scripts, 32 module fixtures,
  all auxiliary groups, and 39/39 private-class tests pass in each representation.
  The runner intentionally skips `test_async_500k.js`.
- Full optimized test262 gate (NaN-boxed): 53,264 pass, zero failures or compile errors,
  with the existing 352 scope exclusions unchanged.
- Incremental GC suite with ASAN, GC_VERIFY and pool bypass passes in both
  representations, including concat operand ownership, eviction, aliases,
  reset, compact-object growth and bounded teardown.
- Bytecode snapshots: 32/32 pass, including the numeric literal opcode.
- NONANBOX validation exposed a pre-existing threaded boolean comparison bug.
  It compared unused bytes of the payload union. The fix compares its boolean
  member and compiles out of the normal NaN-boxed build. Rebuilding the normal
  full CLI after this fix produced the identical binary hash.
- GC_STRESS + GC_VERIFY + ASAN + pool bypass: **46 pass, zero failures**.
  The two failures at the starting checkpoint (`5ba4bee8`) were regressions
  relative to main, where both tests pass. Faster small-object scanning exposed
  stale native callback roots. `e2de2caf` bounds scanning to live frames and the
  published stack top, initializes the four scratch slots at native entry,
  and tracks object arguments so frame cleanup clears them.
- A deterministic worker-reuse sequence exposed stale register pointers after
  async iterator accessors relocate the stack. `ff7cbf1f` refreshes pointers after
  proxy/getter/method calls. The new forced-growth regression fails under ASAN
  before the fix and passes afterward; all 1,234 for-await tests pass in original
  and shuffled serial order, and in original serial order under ASAN.
- Heap reset under ASAN: 40/40 cycles pass. C and C3 embedding API suites pass.

Reproduce the main measurement from the repository root on macOS:

```sh
mkdir -p out/gcmem-baseline
git archive 5ba4bee8 | tar -x -C out/gcmem-baseline
c3c --path out/gcmem-baseline build boomkat-full-icu
c3c build boomkat-full-icu
python3 test/benchmarks/gc-memory-splay/measure.py \
  --benchmark ../javascript-zoo/bench/splay.js \
  --baseline out/gcmem-baseline/out/boomkat-full-icu \
  --candidate out/boomkat-full-icu \
  --quickjs ../boomkat/out/qjs --rounds 9 --output out/splay-comparison.json
```

The other fourteen Octane benchmarks complete without errors. One serial
baseline/candidate pair per benchmark gives the following validation scores;
these single pairs are a broad regression check. Both engines use `--script`
and `--memory-limit=2048`. Raw scores and RSS are in [octane.json](octane.json).

| Metric | Starting worktree | Retained changes | Change |
|---|---:|---:|---:|
| Richards | 1574 | 1638 | +4.1% |
| DeltaBlue | 1370 | 1444 | +5.4% |
| Crypto | 2523 | 2586 | +2.5% |
| RayTrace | 3704 | 3925 | +6.0% |
| EarleyBoyer | 3109 | 3336 | +7.3% |
| RegExp | 566 | 584 | +3.2% |
| NavierStokes | 2488 | 2666 | +7.2% |
| PdfJS | 5609 | 5927 | +5.7% |
| CodeLoad | 12254 | 13688 | +11.7% |
| Box2D | 5802 | 5905 | +1.8% |
| zlib | 2519 | 2625 | +4.2% |
| Gameboy | 11244 | 11622 | +3.4% |
| Mandreel | 1855 | 1901 | +2.5% |
| MandreelLatency | 10698 | 10885 | +1.7% |
| Typescript | 19272 | 19948 | +3.5% |

Geometric mean across these fifteen metrics: +4.64%.
Some other timed benchmarks have higher peak RSS. For example, CodeLoad
moves from 430.0 to 477.1 MB while its throughput score rises 11.7%.

The repository's mini driver fixes Splay at 100 iterations and reports a
separate timing and peak. Three rotating rounds give [mini.json](mini.json):

| Engine | Splay time (ms, lower is better) | Peak RSS (MB) |
|---|---:|---:|
| Starting worktree | 109 | 277.4 |
| Retained changes | 112 | 181.4 |
| Local QuickJS | 104 | 151.5 |

The fixed-run mini and full timed benchmark have different allocation volumes,
so their peak RSS figures describe separate workloads.


## Follow-up: core timing and memory recipes

`just bench` completes all 21 benchmarks, three fresh-process wall-time samples
per engine, with no runtime errors. QuickJS and Node were measured fresh.
`just bench-memory` also completes both workloads after correcting its stale
`benchmarks/` path to `test/benchmarks/`. [core.json](core.json) records the
standard runs, a starting-revision comparison, and follow-up measurements.

The first arithmetic mean was dominated by a cold-start outlier. Seven
alternating baseline/candidate pairs give these medians (lower is better):

| Workload | Starting worktree (ms) | Candidate (ms) | Time change |
|---|---:|---:|---:|
| arithmetic | 23.06 | 23.07 | +0.0% |
| shape_no_call | 160.89 | 142.14 | -11.7% |
| shape_stress | 163.80 | 142.61 | -12.9% |
| string | 22.73 | 24.71 | +8.7% |
| property_lookup | 23.21 | 24.21 | +4.3% |

The shape workloads vary widely between processes (79–449 ms in the focused
recheck), so their apparent changes are inconclusive. The string and property
lookup slowdowns repeated consistently in that snapshot. Both are resolved in
final measurements below; the shape workload comparison remains inconclusive.

Peak RSS from the memory recipe, one measurement per engine and case:

| Workload | Starting Boomkat (KiB) | Candidate (KiB) | QuickJS (KiB) | Duktape (KiB) |
|---|---:|---:|---:|---:|
| memory_test.js | 7968 | 8464 | 6128 | 6400 |
| bench_memory_heavy.js | 33392 | 33280 | 31840 | 38848 |

The subsequent [string CPU and allocation profile](string-profile.md) traces the
string regression to the bounded concat cache and identifies the zero-hit path.


## Final validation after the string and root fixes

Final runtime source: `ff7cbf1f`, including concat admission fix `eac04dd5`
and native frame root fix `e2de2caf`. The concat cache accepts only short pairs
of retained immutable strings and compares operand identities. Formatted scratch
spans bypass it. This removes the zero-hit content comparisons and cache
replacement work without adding another policy or cache.

One warmup and nine rotating fresh-process rounds give these median wall times.
The starting checkpoint is `5ba4bee8`; before-fix is `90075d64`.
[Raw phase timings and binary hashes](final-phases.json).

| Workload | Starting (ms) | Before concat fix (ms) | Final (ms) |
|---|---:|---:|---:|
| string, whole | 22.183 | 24.029 | 20.976 |
| string, concat | 18.283 | 20.326 | 17.294 |
| string, comparison | 6.694 | 6.669 | 6.606 |
| property lookup | 23.004 | 23.908 | 22.304 |

The whole string benchmark is 12.7% faster than before the fix and 5.4% faster
than the starting checkpoint. No string or property-lookup regression remains
in these measurements.

The final `just bench` run completes all 21 core benchmarks with zero errors;
QuickJS and Node were measured fresh, with third-party caches cleared.
[Raw core results](final-core.json). Shape workloads remain much slower than
QuickJS (138/159 ms versus 18.5/18.5 ms); the earlier variability prevents a
confident baseline speed comparison for those cases.

Final `just bench-memory`, peak RSS in KiB:

| Workload | Boomkat | QuickJS | Duktape |
|---|---:|---:|---:|
| memory_test.js | 8464 | 6144 | 6400 |
| bench_memory_heavy.js | 33488 | 31840 | 38832 |

Nine serial, rotating rounds of unmodified Octane Splay give
[final-splay.json](final-splay.json):

| Engine | Splay | SplayLatency | Peak RSS (MB) |
|---|---:|---:|---:|
| Starting checkpoint | 5761 | 19957 | 1241.4 |
| Final Boomkat | 7937 | 21411 | 869.2 |
| Local QuickJS | 7856 | 19899 | 151.5 |

Final Splay throughput is 37.8% above the starting checkpoint with 30.0% less
peak RSS, and 1.03% above local QuickJS, winning all nine paired rounds. The
throughput lead is small and local; QuickJS still uses substantially less
memory. Boomkat retains its custom 64 KiB page pool, which returns empty pages;
GC allocation enumeration uses generation vectors, without per-page mark bitmaps.

The final local suites pass in both value representations: 658 scripts,
32 module fixtures, all auxiliary groups and 39 private-class fixtures. Full
test262 passes 53,264 tests, and all 46 GC stress fixtures pass under ASAN and
the verification oracle. The incremental collector suites pass in both
representations; repeated-reset and C/C3 embedding checks also pass.


All fourteen remaining Octane benchmarks complete successfully in the final
baseline/candidate check. Every one of the fifteen reported scores improves;
the geometric mean gain is 4.28%. These are single alternating pairs, rather
than repeated estimates like Splay. Both builds use the same feature sets and
benchmark sources, with `--script --memory-limit=2048`.
[Final Octane scores, exit status and peak RSS](final-octane.json).
Memory does not improve uniformly: CodeLoad rises from 432.7 to 478.9 MB while
its score improves 11.2%; PdfJS drops from 149.2 to 140.9 MB with a 7.25% score gain.

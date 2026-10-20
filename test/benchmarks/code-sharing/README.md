# Builtin sharing measurements

Baseline: `c5b87f01`. macOS ARM64, C3 0.8.4 / LLVM 23.1.1. The normal
`boomkat` target uses O2, `optsize=small`, and a single compilation module.
Native link flags and feature profiles remain unchanged.

| Step | Engine lines removed | Machine-code bytes removed |
| --- | ---: | ---: |
| Ordered registration and one method installer | 84 | 1,136 |
| Shared VM error construction | 68 | 408 |
| Date time setters, Array find, string padding | 329 | 3,624 |
| Total | **481** | **5,168** |

Machine code (`__text`) measures 1,882,188 bytes on baseline and 1,877,020
bytes with all changes. The normal executable measures 2,628,296 and
2,628,344 bytes respectively: **48 bytes larger**. Its aligned Mach-O segment
sizes remain equal; section padding absorbs the code savings and link metadata
changes the file length. These measurements establish code savings, not a
smaller macOS executable or mapped segment footprint.

## Performance

Each comparison uses one warmup pair and 15 measured pairs, alternating
binary order. Builds and other task-owned tests finish before measurement.
Outputs match. The four general workloads use ten times their standard `N`
values to reduce startup noise. Positive elapsed changes mean slower execution.

| Workload | Baseline median (s) | Combined median (s) | Elapsed change |
| --- | ---: | ---: | ---: |
| bench_loop.js | 0.1325 | 0.1329 | +0.32% |
| bench_function_call.js | 0.2185 | 0.2194 | +0.38% |
| bench_property_lookup.js | 0.2367 | 0.2349 | -0.76% |
| bench_array.js | 0.0506 | 0.0499 | -1.55% |
| errors.js | 0.0473 | 0.0474 | +0.11% |
| date.js | 1.2367 | 1.2380 | +0.10% |
| array-find.js | 0.1318 | 0.1312 | -0.41% |
| string-pad.js | 0.0736 | 0.0740 | +0.52% |

Geometric mean elapsed change: -0.16%.
These local microbenchmarks show no material regression on this machine.
They do not establish performance on every workload or target.

Date setters share an ordinary runtime worker. Array find and padding use
compile-time macros so direction and result policy remain specialized.
Shared runtime variants measured +2.5% for Array find and +2.8% for padding;
constant-direction Array loops with a runtime result policy measured +5.2%.
The retained specialized implementations measured +0.8% and -0.2% in their
individual comparisons. Raw samples, binary hashes, workload sources and
individual comparisons are in [results.json](results.json).

The completed Date comparison uses 5,000 loop iterations per sample. An
oversized 300,000-iteration run was stopped; it contributes no timing results.

## Validation

- 604 local scripts plus all adjunct suites; 42 Rosetta examples.
- 863 targeted test262 tests: Reflect, `with`, async generators, eight Date
  time setters, four Array find variants, and both padding methods.
- 632 Date differential cases in each of four time zones, 56 Array cases,
  and 282 padding cases match their parent binaries.
- All three focused regression fixtures pass with NONANBOX and with
  GC stress, GC verification, pool bypass and ASAN.
- 18 SLIM profile checks pass; the SLIM executable is 1,626,960 bytes.

The focused workloads are `errors.js`, `date.js`, `array-find.js`, and
`string-pad.js` in this directory. Run comparisons with
`scripts/bench_interleaved.py BASELINE CANDIDATE FILE... --pairs 15 --out DIR`.

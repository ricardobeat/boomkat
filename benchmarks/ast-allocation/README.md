# Bounded AST allocation elimination

Enabled by default in `3403b77a`; baseline `cf72e91e`.

The compiler selects an existing value from a fresh literal, or projects the
one observed value from a spread container. The implementation adds two bounded
AST matchers and one portable VM opcode. Runtime guards retain the ordinary
spread path for observable iteration or property access. The other prototypes
remain on `prototype/ast-peepholes`.

## Measurements

Nine measured rounds after one warmup, with shuffled serial variant order.
Times include process startup, compilation, execution and teardown. The seven
ES6 rows exclude promises. Every benchmark output matches the baseline.

| Workload | Baseline ms | Selected ms | Speedup |
|---|---:|---:|---:|
| class | 163.29 | 165.34 | 0.99× |
| closure_capture | 52.18 | 53.24 | 0.98× |
| destructuring | 123.16 | 123.15 | 1.00× |
| forof | 53.32 | 54.98 | 0.97× |
| let_loop | 71.50 | 72.05 | 0.99× |
| spread_rest | 83.39 | 33.37 | 2.50× |
| template_literal | 73.05 | 70.57 | 1.04× |
| array_spread_length | 100.01 | 25.76 | 3.88× |
| literal_member | 38.71 | 7.15 | 5.41× |
| object_spread_property | 59.43 | 12.39 | 4.80× |

Non-promise ES6 geometric mean: **1.13×**.
Other ES6 workloads range from 0.97× to 1.04×. The gains are concentrated in
spread allocation; these results do not establish a broad 5–10× improvement.

Binary sizes are 2,399,272 bytes baseline and 2,399,576 bytes selected.
[results.json](results.json) includes all wall-time samples and binary hashes.
The measurement runner is archived at
`5ad933b8:scripts/measure_ast_peepholes.py`; the selected build is the normal
`just build boomkat` target. For a follow-up A/B comparison with the repository
runner (which reports best-of-N rather than these medians):

```sh
just build boomkat
just perf-diff cf72e91e benchmarks/es6/bench_spread_rest.js benchmarks/ast-allocation/bench_literal_member.js
```

## Validation

- Release and NONANBOX: 580 local scripts, 21 module entries and all auxiliary
  local suites pass; Rosetta passes 42/42 in each representation.
- Engine suite: 114/114. Golden bytecode: 30/30, including `--check-noop`.
  All 30 golden programs match Node at runtime.
- Targeted test262: 1,170 object-expression, 52 array-expression and 21
  property-accessor cases pass. The object and array directories also pass ASAN.
- ASAN corpus: 694 files, no reports. Threaded GC stress: 35/35, plus the new
  allocation regression. Heap reset: 40/40 cycles.
- C API: embedding, host functions, modules and two-runtime suites pass.
- Validation platform: macOS ARM64, C3 0.8.4. The local Homebrew sanitizer
  runtime link was stale; a temporary compiler wrapper selected the installed
  LLVM 23.1.2 runtime. The ASAN corpus raises its process stack budget to 64 MiB,
  capped by the host hard limit, to accommodate unoptimized sanitizer frames.

## Regression fixes included

VM destruction and failed initialization detach heap pointers to the VM and
its root scanner. Suspended-generator catcher cleanup remains valid during
subsequent heap teardown. Existing tests cover the three ASAN reproductions.

The golden snapshots reflect current callee evaluation order, register
liveness and arithmetic fusion. The no-optimization checker parses opcode
names rather than instruction numbers. C API syntax locations point to the
offending semicolon at column 9. The sanitizer corpus includes the native
overflow test with sufficient stack for its instrumented frames.

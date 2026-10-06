# 105: Native loops with inlined numeric callees

Status: implemented and measured in `.worktrees/hot-regions`, branch
`prototype/hot-regions`, rebased onto main `01df48eb` before implementation.
The matching baseline includes main's constructor and temporary-class optimizations.

`PROTO_COPY_PATCH_LOOPS` compiles a counted numeric loop and one eligible callee
into a native region. Arithmetic values stay in ARM64 floating-point registers
across iterations. Constants with a single definition and no incoming read are
loaded before the loop. Callee arithmetic is copied into the loop body, removing
per-iteration call dispatch, argument conversion and result boxing.

The executed [numeric-loop.s](../benchmarks/copy-patch-loops/numeric-loop.s)
contains the inlined arithmetic, accumulator and induction updates, and a native
backward branch. Its complete region occupies 132 bytes, including entry loads,
constants and exit stores. The same assembler stencil backend serves the callee
prototype in plan 104.

## Entry and exits

Discovery runs at VM reentry. A function records its first candidate backward
`JMP_LT` loop with a final unit increment. Compilation starts after warmup at
that loop header through VM reentry. Ordinary threaded iterations keep their
existing handlers. Functions with unsupported bodies retain the interpreter.

The prototype accepts at most 16 VM registers, 48 body instructions, and one
plain `CALL_VAR` or `CALL_GLOBAL`. The callee has at most six registers and
24 instructions, ignores `this`, and uses numeric arithmetic, constants and
copies. A guard resolves the current callee through the existing variable cache
and checks its compiled-function identity on every native entry. Callee formal
parameter writes, captures, property accesses, nested calls, rest parameters and
control flow decline inlining.

The induction variable and limit must be fastints. The limit is invariant, and
the induction variable has exactly one write: its final unit increment. Other
incoming values must be numeric. The lowering records reads before writes and
publishes every written VM register. Destinations containing heap references
fall back, preserving register ownership. Exact in-range integer outputs use
fastint boxing; negative zero and other doubles retain their number values.

Each native invocation executes at most 256 iterations. GC and interrupt budgets
can shorten that batch. Pending GC work or an interrupt declines native entry.
Internal backward edges consume their budgets; the final comparison executes in
the switch. The native batch publishes its registers before returning to the VM.
Inlined-call batches also fulfil the existing call-burst yield. No native body
allocates JS objects, calls user code or holds a borrowed object slot.

A function owns its native plan through `CompiledFunction`; heap teardown releases
it through the shared bounded code arena. Unsupported native platforms and failed
allocation use interpreter execution. The backend currently supports macOS ARM64.

## Validation

- 582 local scripts, 20 module fixtures and all companion local checks pass.
- 42 Rosetta cases pass.
- Seven ES6 numerical checksums agree with the freshly built baseline in
  [result-checks.json](../benchmarks/copy-patch-loops/result-checks.json).
- `test/copy_patch_loop.js` covers warm loops, callee replacement, coercion
  fallback, fractional bounds, empty ranges, negative indices, negative zero,
  NaN/infinity and unsupported induction/limit updates. QuickJS agrees.
- `test/capi/copy_patch_loop.c` warms a native loop, installs a host interrupt,
  aborts after ten polls under a watchdog, reuses the runtime and closes it.
  The fresh O2 static build passes; generated-code dumping confirms a native
  plan exists before the interrupt test.
- [Coverage](../benchmarks/copy-patch-loops/coverage.json) records 2,932,623 native
  iterations out of 3,000,000 in the loop-plus-callee control, 8,798,955 in the
  three plain numeric `let_loop` loops, 2,932,879 in closure capture's uncaptured
  loop, and 435,352 in destructuring. The captured-cell loops remain interpreted.

## Reproduction

Build a baseline with `just build boomkat` and save it as
`out/boomkat-loop-baseline`. Build `just build-copy-patch-loops` and save the result
as `out/boomkat-hot-loops`. Run:

```sh
python3 scripts/measure_hot_regions.py --rounds 9 \
  --variants baseline,loops --baseline out/boomkat-loop-baseline \
  --output benchmarks/copy-patch-loops/results.json
```

This uses the eight unchanged `bench-es6` scripts and three controls. One warmup
round is discarded; nine serial rounds use shuffled variant order. Timings are
fresh-process wall time, including compilation. Instrumentation is disabled.
Process checks cover other benchmark, test and compiler jobs; normal desktop
activity is allowed. No overlapping jobs were detected in this run's samples.
The old `starting_patch_sha256` field records the worktree's original provenance;
the source head and this report identify the rebased experiment.

## Results

| Workload | Baseline ms | Native loops ms | Speedup |
|---|---:|---:|---:|
| class | 162.65 | 164.05 | 0.991× |
| closure_capture | 52.25 | 45.01 | 1.161× |
| destructuring | 123.65 | 121.17 | 1.020× |
| forof | 53.80 | 54.53 | 0.987× |
| let_loop | 74.26 | 54.39 | 1.365× |
| promise | 271.39 | 273.11 | 0.994× |
| spread_rest | 84.14 | 83.85 | 1.003× |
| template_literal | 70.24 | 71.63 | 0.981× |
| ic_proto | 74.43 | 73.95 | 1.007× |
| function_call | 24.97 | 25.35 | 0.985× |
| numeric_calls | 57.22 | 8.13 | 7.042× |

ES6 geometric-mean speedup is **1.056×**. The sum of ES6 medians falls
from **892.38 to 867.76 ms**, a **2.76%** reduction.

The loop-plus-inlined-callee control improves **7.04×**, from 57.22 to 8.12 ms.
The ES6 suite improves less because most workloads remain outside this numeric
tier. In particular, class construction, captured-cell updates, iterator paths,
promises and strings retain interpreter execution. Changes around 1–2% in those
controls are small and do not establish useful gains.

The native executable adds 17,088 bytes relative to the matching baseline.
The numeric control's median peak RSS increases by 16 KiB. Full raw samples,
RSS, CPU time and binary hashes are in
[results.json](../benchmarks/copy-patch-loops/results.json). The feature remains
optional; `just build-copy-patch-loops` enables it.

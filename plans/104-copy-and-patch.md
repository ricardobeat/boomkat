# 104: ARM64 copy-and-patch prototype

Status: implemented and validated in `.worktrees/hot-regions`, branch
`prototype/hot-regions`; measurements complete.

`PROTO_COPY_PATCH` installs native code for small straight-line callees after
64 eligible call entries. It lowers bytecode into an SSA list, copies assembled
ARM64 instruction stencils, and patches their floating-point registers,
input/output offsets and literal constants. Execution calls the generated code
directly. Numeric outputs retain fastint boxing when exact and in range;
negative zero, fractional values and non-finite values remain doubles.
[numeric-call.s](../benchmarks/copy-patch/numeric-call.s) disassembles an
executed 32-byte function for `(a + b) * c - a`.

The stencil ABI accepts arrays of unboxed doubles and numeric outputs. Values
stay in ARM64 floating-point registers through arithmetic. The register mapping
reserves the ABI's callee-saved d8–d15. The initial backend supports macOS ARM64;
other targets retain interpreter execution. No assembler or compiler runs at
runtime. Stencils are assembled when building the engine.

The classifier accepts at most 16 bytecode registers and 24 instructions. The
lowering caps native values at 24, inputs at 24 and staged property writes at
eight. Eligible operations include constants, argument/capture copies, numeric
arithmetic and ordinary cached property accesses. Repeated property inputs share
one guarded input. Object receivers and captures resolve from the actual callee
on every invocation, so closures sharing bytecode use their own captures.

Guards check numeric inputs, ordinary object shapes, property-cache generations,
prototype chains and writable own data slots. Property writes publish only after
all guards and native execution complete. Reads following a known staged write
use its SSA value. Dynamic aliases that require store/read ordering fall back.
Guard failure enters the ordinary interpreter with caller-visible state intact.
Calls retain the existing call-budget safepoint; bounded bodies allocate no JS
objects and invoke no user callbacks.

The native code arena is capped at 1 MiB. A mutex protects allocation and release;
macOS per-thread JIT write protection surrounds publication, followed by
instruction-cache invalidation. Plans use the heap's allocator and are freed
with compiled functions. The arena releases when the last native plan is freed.
Two experimental metadata fields occupy space in `CompiledFunction` in this
worktree; the production integration can make them conditional or use a sidecar.

Build with `just build-copy-patch`. The feature is disabled in ordinary builds.
`BOOMKAT_COPY_PATCH_DUMP=<path>` appends generated instruction words for inspection.
Instrumentation builds add `-D PROTO_REGION_STATS`; timing builds omit it.

## Validation

- 578 local scripts, 20 module fixtures and the companion local checks pass.
- 42 Rosetta cases pass.
- `test/copy_patch.js` agrees with QuickJS and Node. It exercises register mapping,
  patched constants, negative zero, aliased staged writes, inherited properties,
  prototype replacement, getter fallback and distinct closures sharing a body.
- `test/hot_regions.js` passes numeric boundaries, BigInt/string coercion fallback,
  property changes, exception ordering, captures and callee replacement.
- [Instrumentation](../benchmarks/copy-patch/coverage.json) reports six native plans and 6,554 native executions for the
  dedicated fixture, and two plans and 2,448,613 executions for `bench_class`.

## Measurement

These measurements predate the rebase onto main `01df48eb`. The rebased native
loop implementation and its matching baseline are in [plan 105](105-native-loop-copy-patch.md).

The same source builds both the feature-disabled baseline and native variant.
The runner uses the eight unmodified `bench-es6` scripts, plus three focused
controls. It executes one discarded warmup and nine shuffled, serial rounds per
workload, measuring fresh-process wall time. Process monitoring checks for other
benchmark/test/compiler jobs before and during batches. Normal desktop activity
is allowed. Raw samples include child CPU time, RSS, output hashes and binary
hashes. This is a small-callee native tier; loop lowering and general control
flow remain further work.

## Results

This experiment measures native execution of tiny callees through a generic
interpreter bridge. Loop control, call-site dispatch, input validation and
boxing remain outside the generated region. It does not measure the benefit of
compiling a hot loop or inlining its callee into that loop.

The closure benchmark's eligible `peek` body returns a capture. C3 reads that
capture and publishes the result; its generated function contains only `ret`.
The closure gain therefore demonstrates frame elimination, not native arithmetic
throughput. Native invocation counts alone do not establish useful code coverage.

Nine measured rounds after one discarded warmup; medians below. Speedup is
baseline / native; values above 1 are faster. Raw samples and binary hashes are
in [`results.json`](../benchmarks/copy-patch/results.json).

| Workload | Baseline ms | Native ms | Speedup |
|---|---:|---:|---:|
| class | 218.06 | 227.32 | 0.959× |
| closure_capture | 53.62 | 51.46 | 1.042× |
| destructuring | 122.45 | 122.37 | 1.001× |
| forof | 54.81 | 54.79 | 1.000× |
| let_loop | 71.67 | 71.00 | 1.010× |
| promise | 264.12 | 267.76 | 0.986× |
| spread_rest | 83.66 | 85.35 | 0.980× |
| template_literal | 72.84 | 71.42 | 1.020× |
| ic_proto | 74.48 | 74.28 | 1.003× |
| function_call | 27.39 | 27.03 | 1.013× |
| numeric_calls | 56.65 | 64.66 | 0.876× |

ES6 geometric-mean speedup: **0.9995×**. Sum of ES6 medians:
**941.23 → 951.46 ms**, 1.09% more time.

Two batches overlapping another agent's compiler/benchmark were rejected.
Accepted batches have no detected competing workloads. Each variant passed
the seven numerical checksum comparisons in
[`result-checks.json`](../benchmarks/copy-patch/result-checks.json).

The native executable is 480 bytes larger on disk than this experiment's
baseline. Median RSS increases by roughly 0.08–0.13 MiB across these workloads;
the reserved native arena has a 1 MiB cap. Executable sizes include platform
alignment and do not measure emitted instruction bytes.

The earlier double-output build is included as `copy-patch-v1` in the same
interleaved report. Its ES6 geometric mean is 1.0014×; exact integer boxing
does not improve overall throughput. The first two-variant run is retained as
[`results-v1.json`](../benchmarks/copy-patch/results-v1.json).

**These results do not support a 5–10× gain or enabling this tier by default.**
Closure capture gains about 4%, classes lose about 4%, and the numeric-call
control loses about 14%. Most of the suite remains interpreted. Guards,
marshalling and boxing are plausible costs on these short native bodies;
the experiment does not isolate their individual contributions. Larger native
regions and loop lowering require a separate implementation and measurement.

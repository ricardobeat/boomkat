# 106: Bounded AST allocation and inlining prototypes

Status: experimental, unaccepted. Worktree `.worktrees/ast-peepholes`, branch
`prototype/ast-peepholes`, based on `cf72e91e`. Each experiment emits ordinary
portable bytecode. Default builds leave every prototype flag disabled.

## Candidates

| Feature | Scope |
|---|---|
| `PROTO_AST_INLINE` | Small immediately invoked functions and named functions receiving fresh literal containers; stage argument values, guard named callee identity, inline the expression and omit eligible containers. |
| `PROTO_AST_METHODS` | Small class methods with parameter expressions and own numeric field reads/writes; guard callee identity, numeric arguments and writable data fields, then emit the ordinary body bytecode. |
| `PROTO_AST_DERIVED` | Extend temporary-instance scalar lowering to eligible top-level derived classes with a simple `super(...)`, parameter-to-field stores and a numeric getter reading the base getter. |
| `PROTO_AST_STRINGS` | Flatten nested templates and string-led addition chains into joins. Keep inner length checks and source-position conversions, including the default primitive hint for addition. Existing length-only lowering can consume the resulting join. |
| `PROTO_AST_SPREAD` | Project dense-array spread length or a selected own data property of a plain object spread. The initial matcher covers a two-statement lexical block: a const initializer followed by one accumulator assignment using its member. |
| `PROTO_AST_PEEPHOLES` | Select an own data property from a fresh object literal after evaluating its initializers in source order; preserve anonymous-function name inference. |

The inliner accepts bounded straight-line expressions and flat parameter
patterns. It excludes captured names, parameter writes, nested calls, defaults,
rest, recursion, suspension and dynamic scope. Candidate discovery is capped at
128 scopes and 8192 AST nodes per unit; argument staging is capped at 32 values.
Ordinary calls without literal-container arguments retain their current paths.

Named-call guards reference compiled templates using the same lifetime mechanism
as class-scalar guards. An array-pattern guard preserves iterator overrides.
On refusal, staged values materialize the containers and enter the normal call.
Method field guards prevent accessor calls and stores to non-writable fields
inside the inlined numeric body.

Derived guards validate constructor/getter identities, both prototype links and
inherited field descriptors. The extension is limited to one inheritance level.
Spread guards require built-in dense-array iteration or enumerable data
properties on plain objects; custom iterators, holes, accessors and exotic
objects retain normal materialization. Tail expressions are restricted to
identifiers and numbers. Captured locals and dynamic scope suppress projection.

## Measurement and validation boundary

Nine measured serial rounds follow one discarded warmup, with variant order
shuffled. Timings include process startup, compilation, execution and teardown.
The unchanged ES6 scripts are measured separately from focused controls. The
runner checks for other benchmark/build jobs and allows normal desktop activity.
Raw samples include executable hashes, file sizes, CPU time and peak RSS.

The focused smoke fixture covers callee replacement, literal evaluation order,
method accessors, iterator/getter fallback, coercion hints, Symbol errors and
base-getter replacement. Combined ES6 numerical checksums and focused-control
results match the baseline. Full semantic review, local/Rosetta suites, ASAN and
cross-platform validation are deferred until the user accepts a candidate.
These measurements establish prototype performance, not production readiness.

- `benchmarks/ast-peepholes/results.json`: independent-candidate matrix; its spread
  variant covers array spread, before the shorthand object-tail extension.
- `benchmarks/ast-peepholes/final-es6.json`: final spread and combined ES6 runs.
- `benchmarks/ast-peepholes/controls.json`: focused pattern timings.
- `benchmarks/ast-peepholes/result-checks.json`: focused-control result comparisons.

## Reproduction

Save a baseline built from the base revision as `out/boomkat-ast-baseline`.
For example, build literal-argument inlining and the small object peephole with:

```sh
just -- build-ast-prototypes -D PROTO_AST_INLINE -D PROTO_AST_PEEPHOLES
cp out/boomkat out/boomkat-hot-inline
```

Build the other flags separately into `out/boomkat-hot-methods`, `-derived`,
`-strings` and `-spread`. Build all six flags together into
`out/boomkat-hot-combined`. Then run:

```sh
python3 scripts/measure_ast_peepholes.py --rounds 9
```

Use `--paths` for focused controls outside the generic ES6 suite and `--variants`
to select a subset of saved binaries.

## Results

Final combined ES6 medians, milliseconds:

| Workload | Baseline | Combined | Speedup |
|---|---:|---:|---:|
| class | 160.00 | 109.59 | 1.460× |
| closure_capture | 52.17 | 52.37 | 0.996× |
| destructuring | 121.72 | 95.11 | 1.280× |
| forof | 54.19 | 54.00 | 1.004× |
| let_loop | 70.14 | 71.75 | 0.978× |
| spread_rest | 83.75 | 35.51 | 2.359× |
| template_literal | 70.98 | 49.47 | 1.435× |

Excluding promises, geometric-mean speedup is **1.297×**. The sum of medians
falls from **612.95 to 467.79 ms**, a **23.7%** reduction. The combined executable
is 2,417,096 bytes, **17,824 bytes larger** than the baseline. No batches were
rejected in the final ES6 or focused-control runs.

Focused controls, including startup and compilation:

| Pattern | Baseline ms | Combined ms | Speedup |
|---|---:|---:|---:|
| array spread length | 101.02 | 26.85 | 3.763× |
| object spread property | 58.82 | 12.78 | 4.601× |
| literal arguments | 158.88 | 43.88 | 3.621× |
| derived instance | 185.32 | 85.26 | 2.174× |
| method calls | 41.48 | 41.87 | 0.991× |
| nested template | 31.12 | 22.91 | 1.358× |
| concat length | 57.35 | 34.82 | 1.647× |
| iife literal | 154.52 | 8.18 | 18.884× |
| literal member | 39.69 | 8.08 | 4.914× |

The immediate-function/literal control exceeds the requested 5–10× threshold.
Fresh literal member selection approaches 5×; spread projection and literal
arguments improve 3.6–4.6× on their focused controls. These ratios do not
represent the full ES6 suite. Method inlining has no measured benefit and is
not recommended for retention. All candidates remain unaccepted pending the
user's decision; full correctness review is deferred.

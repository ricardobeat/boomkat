# 102: AST-enabled optimization investigations

Status: **IN PROGRESS**. Candidates 1 and 7 are retained. The ES6 workload
investigation below takes priority over the candidate-number sequence.
Research, source review and first measurements: **2026-10-06**.
These are ten independent experiments. Prefer changes that remove execution work and simplify lowering over
changes that add VM machinery. Measure code size alongside performance.

## Starting point

[Plan 101](101-flat-ast.md) supplies a parsed tree, scope resolution and early
errors before bytecode generation. It makes semantic analysis practical without
reconstructing expressions and declarations from bytecode. The tree is freed
after generation; runtime adaptation must use bytecode or compact metadata.
Retaining whole trees for hot functions needs a separate memory justification.

An AST is an enabler, not a prerequisite for optimization. QuickJS generates
bytecode directly and optimizes that bytecode in several passes. Its design is
a useful check against introducing an IR where a small emitter change suffices.
[QuickJS internals](https://bellard.org/quickjs/quickjs.html#Bytecode).

Boomkat already has register-resident locals, bytecode copy propagation and dead
move removal, immediate and compare/branch fusion, property caches, capture-slot
and cell lowering, fixed-shape object literals, and restricted await liveness.
Those are baselines, not new candidates here. Inspect
[the existing passes](../src/compiler/context.c3),
[literal specialization](../src/compiler/literals.c3), and
[await liveness](../src/compiler/await_liveness.c3) before extending them.

This plan refines the semantic-IR investigation in
[plan 099 §4](099-engine-architecture-investigation.md#4-semantic-compiler-ir-and-allocation-elimination)
and overlaps the compiler opportunities in [plan 087](087-nonjit-vm-optimization-ideas.md).
[Plan 097](097-engine-throughput.md) rejected register-frame compaction after
measurement; [plan 098](098-measured-interpreter-optimizations.md) also records
unretained prototypes. A new abstraction alone is no reason to repeat them.

## ES6 workload priorities

Work in this order: **let_loop, destructuring, spread_rest, closure_capture,
forof**. Prefer idiomatic C3, shared lowering/runtime helpers, and small native
code growth. Refactoring is allowed when it simplifies the implementation or
unlocks measured gains. Keep experiments outside the generic benchmark suite.

The first split measurement uses the production binary from `2a7aca58` (source
unchanged at `90810194`). Each constituent runs in six fresh processes per engine;
discard the first and retain five samples. `Date.now` surrounds the constituent
call after setup, excluding process startup. Millisecond granularity makes the
small cases approximate. Node gets one call per process, not a steady-state JIT
warmup. These are screening measurements, not speedup claims or additive
components of the original whole-process totals. Results agree across engines.

| Workload / constituent | Boomkat ms | QuickJS ms | Node ms |
|---|---:|---:|---:|
| let_loop: ordinary / body local / var | 10 / 12 / 10 | 58 / 69 / 46 | 3 / 3 / 3 |
| let_loop: escaping iteration closures | 67 | 40 | 7 |
| destructuring: array / object / defaults | 37 / 23 / 37 | 61 / 41 / 36 | 4 / 2 / 2 |
| destructuring: rest / parameters | 28 / 68 | 48 / 49 | 7 / 3 |
| spread_rest: array / object | 39 / 64 | 59 / 69 | 7 / 3 |
| spread_rest: rest calls / spread calls | 37 / 11 | 18 / 32 | 2 / 3 |
| closure_capture: uncalled / called / uncaptured | 21 / 18 / 10 | 60 / 27 / 61 | 12 / 4 / 3 |
| forof: array / indexed / set | 3 / 2 / 1 | 6 / 6 / 2 | 4 / 1 / 1 |
| forof: map / string / generator | 13 / 1 / 16 | 10 / 1 / 3 | 4 / 1 / 1 |

Raw samples and the binary hash are in
[`es6/baseline.json`](../benchmarks/ast-optimization/es6/baseline.json).
Reproduce with `python3 scripts/measure_es6_cases.py --output <json>`.

### Shared property and call costs

Keep `ic_proto` and `valstack_copy` as controls alongside the ES6 workload order.
Five measured fresh processes, after one discarded process per engine, give
these medians. Timing surrounds the unchanged benchmark source and excludes
process startup; Node is v24.13.0.

| Benchmark | Boomkat baseline | Working candidate | QuickJS | Node | Node `--jitless` |
|---|---:|---:|---:|---:|---:|
| ic_proto | 91 ms | 92 ms | 106 ms | 5 ms | 118 ms |
| valstack_copy | 35 ms | 35 ms | 61 ms | 7 ms | 37 ms |

Samples and the candidate binary hash are in
[`shared-cost-controls.json`](../benchmarks/ast-optimization/es6/shared-cost-controls.json).
Outputs agree across engines. The JIT-disabled comparison indicates that JIT
execution accounts for much of Node's advantage on these cases; it does not
identify which particular JIT transformation produces the gain.

`ic_proto` performs twenty million inherited-property reads. Boomkat's cache
hit validates prototype identities and shapes, then the owner's storage pointer
(`ic_resolve_owner` and `ic_resolve_slot`). This cost also matters for inherited
methods and iterator lookup. The own-property reads in object destructuring
skip the chain checks, so the prototype benchmark's ratio does not transfer
directly to that workload.

`valstack_copy` combines recursive calls, argument moves, numeric arithmetic,
callee lookup, and frame entry/return. It does not isolate memory copying.
The lean call path already places arguments in the callee's register window.
The emitted function still initializes seven locals immediately before assigning
all seven, and copies parameters into local registers before copying values into
argument windows. Investigate dead initialization and register-copy elimination
alongside call-frame costs. These shared improvements can benefit called
closures, destructured parameters, rest calls, and generators, but their impact
needs separate measurement from allocation elimination.

#### Retained shared-cost changes

Site caches resolve the validated slot index against the owner's current
property storage. Prototype identity and shape checks remain. Removing the
cached slot and allocation pointers simplifies the hit path and reduces cache
storage; the separate megamorphic cache keeps its representation.

Environment-store pruning runs before move elimination. Its removed declaration
sources no longer keep overwritten LDUNDEF initializations live. The existing
call-window-aware liveness analysis removes those dead initializations, with
the existing exception-region and jump-target guards. `copyTest` emits 25
instructions, with all seven redundant local initializations removed.

Seven alternating A/B samples after one warmup pair compare against the saved
working binary containing the captured-binding changes. Whole-process medians:

| Workload | Baseline ms | Candidate ms | Time reduction |
|---|---:|---:|---:|
| ic_proto | 97.93 | 83.66 | 14.6% |
| valstack_copy | 38.43 | 35.42 | 7.8% |

The five ES6 controls change by 0–2.2%; this run does not demonstrate a large
cascading gain. Babel and TypeScript compile checks take 1.1% and 1.4% longer.
Production executable size is unchanged at 2,380,312 bytes. Raw timings, peak
RSS and binary hashes are in
[`shared-cost-changes.json`](../benchmarks/ast-optimization/es6/shared-cost-changes.json),
measured with `scripts/measure_ast_constants.py` and explicit `--runtime`
arguments for both controls and the five ES6 benchmarks.

Validation: `just test-local` passes 564 scripts, 20 module fixtures and the
companion checks. Prototype growth, deletion, shadowing, getter replacement and
chain mutation checks, plus initialization/hoisting checks, agree with Node
and QuickJS. Broader register-copy elimination remains a separate experiment;
these changes remove dead initialization and cached-pointer validation.

### Investigation decisions

1. **let_loop: reduce captured iteration storage and lookup.** The uncaptured
   loops already contain only register arithmetic, increment and fused branches.
   The captured arm allocates a declarative EnvRecord and bindings object per
   iteration, copies the head binding through GETVAR/PUTLEX, and allocates an
   escaping closure. The scoped renewal prototype gained only about 5% on the
   whole benchmark and was rejected. The retained implementation uses value snapshots
   for proven stable iteration captures, inline single-capture descriptors and
   inline property slots for shared cells. Mutable and dynamic lexical captures
   retain environments.
   QuickJS's `close_lexical_var` detaches a `JSVarRef` and clears the frame's slot
   so the next iteration can acquire its own cell (`quickjs/quickjs.c`). Duktape's
   environment/closure code provides the conservative name-based comparison
   (`duk_js_var.c`, `duk_js_executor.c`). Share the mechanism with ordinary
   captures; avoid a special case for `fns.push(() => i)`. Preserve TDZ, sibling
   closure sharing, updates from closures, continue/finally, eval and with.
   Against a fresh `9a2942df` build, whole-benchmark medians are 109.2 ms to
   76.1 ms (30.3% less time); a follow-up measures 110.5 ms to 78.9 ms.
   The closure control ranges from 8.4% slower in the first batch to 1.9% slower
   on repetition. Both batches are retained in
   [`capture-storage-changes.json`](../benchmarks/ast-optimization/es6/capture-storage-changes.json).
   The ownership review, local suite, focused for/bind suites, fresh NONANBOX
   fixture and forced-GC/ASAN fixture pass. C3's configured ASAN runtime is
   missing; the fresh GC-stress objects link against the installed LLVM 23
   runtime with the required v8 ABI. Leak detection was disabled for that run.
   Production executable size grows from 2,363,544 to 2,380,232 bytes
   (16,688 bytes, about 0.7%) against that fresh baseline.

2. **destructuring: parameter setup first, temporary records second.** Review
   `gen_pattern_parameters` and the shared pattern emitter for unnecessary
   scopes, publication and register copies. Reuse declaration identity and
   capture evidence rather than adding another name scan. Then investigate
   scalar replacement for fresh plain records used by object patterns. Arrays
   need iterator guards: even a fresh array literal can inherit a replaced
   iterator. Keep default evaluation order, iterator close and abrupt completion
   in the shared lowering. General inlining is a larger follow-up, not required
   to measure parameter setup independently.

3. **spread_rest: object copying and rest setup.** Object spread is the largest
   arm. Investigate a guarded ordinary-data-property path within the existing
   `copy_data_properties_into`, sharing guards and storage operations with object
   rest. Keep accessors, proxies, symbols, key ordering and descriptor changes
   on the general path. Array spread already has guarded dense copying and
   capacity reservation in `vm_objects.c3`; do not implement those twice.
   Rest arrays already have a shared builder in `vm_calls.c3`. Measure call/frame
   overhead separately before adding escape analysis to remove the array.
   V8's [spread investigation](https://v8.dev/blog/spread-elements) supports
   guarding iteration behavior and reserving capacity, but its reported gains
   cannot be transferred to our already-specialized path.

4. **closure_capture: reuse lexical capture work.** The cell-lowering pass in
   `cells.c3` selects unique VAR bindings; these fixtures use LET. Extending the
   same representation safely can benefit defining-function reads and writes.
   The loop's escaping closures and these ordinary captures should share binding
   identity and ownership rules. Treat uncalled-closure elimination and mutable
   capture inlining as later experiments requiring stronger escape/effect proofs.

5. **forof: generator resume, then map-entry patterns.** Existing intrinsic
   iteration already makes arrays, strings and sets cheap here. The small
   `range` generator gives little reason to expect large savings from wide-frame
   liveness alone. Measure resume dispatch, state transfer and result allocation
   separately. Seek one shared resume path before introducing a specialized
   generator opcode. Map iteration exposes a temporary entry array followed by
   destructuring; reuse findings from step 2, preserving custom iterator and
   close behavior. Include collection construction in final whole-suite timing.

For each experiment, save the production baseline, collect alternating A/B
timings and RSS, and record executable bytes plus Mach-O text/data sizes. Native
growth must be justified by useful repeatable gains; there is no invented fixed
size allowance. Inspect the finished implementation before focused validation.
### Flat destructuring implementation

The AST emits each parameter pattern in source order. The shared flat-pattern
eligibility check handles contiguous bindings in lexical declarations and
simple parameters at any parameter position. It also serves the existing
lexical rest path. The compiler emits the existing guarded extraction opcode
for flat patterns of one through 64 bindings; iterator customization and
unsupported values take the ordinary iterator/close path. Parameter defaults
and computed-key TDZ scopes keep their full lowering.

The obsolete combined object/array parameter special case is removed. The
compiler change removes 112 net lines and reduces the production executable
by 80 bytes. Screening and final measurements put the generic destructuring
benchmark about 16% faster and the focused flat-pattern kernel about 61% faster.
Raw measurements, controls, compile checks and binary hashes are in
[`flat-pattern-changes.json`](../benchmarks/ast-optimization/es6/flat-pattern-changes.json).
The local suite passes 564 scripts and 20 module fixtures plus companion checks.
The expanded parameter regression agrees with Node and QuickJS.

Removing the environment-reuse exclusion for destructured parameters did not
establish a useful gain: the benchmark's function already has `needs_env=false`.
That experiment is dropped.

### Fresh object-pattern allocation elimination

Lexical declarations with a fresh object literal keep its values in registers
when all requested keys are known own data properties. Initializers run in
source order before binding initialization. Duplicate keys select the last
value while preserving every initializer's effects. Function/class name
inference follows the literal key. Missing keys, defaults, computed keys,
methods/accessors, spread, rest, nested patterns and prototype initializers
retain ordinary lowering. A 64-property bound limits temporary register
pressure; no runtime guard or new opcode is needed.

The focused 500k object-pattern kernel drops from 28.3 ms to 9.5 ms (66.4%).
Whole destructuring screening is 166.1 ms to 145.7 ms, while the first final
batch is 173.6 ms to 169.4 ms. A 15-sample follow-up gives 175.3 ms to 158.9 ms
(9.3%). Preserve the variation rather than claiming the largest whole-suite
gain. Production executable growth is 64 bytes. Timings, controls, hashes and
the follow-up samples are in
[`scalar-object-changes.json`](../benchmarks/ast-optimization/es6/scalar-object-changes.json).

Validation passes 565 local scripts, 20 module fixtures and companion checks.
The semantic regression agrees with Node and QuickJS and covers evaluation
order, duplicate keys, TDZ, name inference, escaping closures, heap values and
fallbacks. Disassembly of the generic object-pattern constituent contains no
object allocation or property read. Array literal elimination needs iterator
guards and remains an independent experiment.

## Candidate list

The stages describe investigation order, not commitments to ship. Complexity
includes semantic proof and maintenance, not just the number of changed lines.

| # | Investigation | Work it could remove | Starting mechanism | Stage / complexity |
|---|---------------|----------------------|--------------------|--------------------|
| 1 | Bounded primitive constant folding | Repeated arithmetic and constant loads | AST facts, existing emitter | First / small |
| 2 | Binding-aware propagation and dead execution | Local stores, name synchronization, unreachable instructions | Binding facts; CFG for joins | First / medium |
| 3 | Effect-aware common subexpressions and load forwarding | Repeated pure operations and proven redundant reads | Block-local value/effect analysis | Next / medium |
| 4 | Loop-invariant work and repeated-check elimination | Work repeated on every iteration | CFG, effects and dominance | Later / large |
| 5 | Numeric type and range specialization | Repeated numeric tag checks and generic dispatch | Value facts plus a narrow VM path | Later / large |
| 6 | Small stable-callee inlining | Call setup and activation overhead | Resolved callee plus bounded AST expansion | Later / large |
| 7 | Direct emission of parameter defaults | Internal thunk compilation, closures and calls | Parameter AST and existing prologue | First / medium |
| 8 | Scalar replacement of local records and arrays | Heap allocations, property accesses and GC work | Escape and value analysis | Later / large |
| 9 | Liveness-based suspension storage | Register copies, saved storage and retained objects | Complete suspension CFG and root maps | Next / medium–large |
| 10 | Adaptive bytecode specialization | Generic dispatch at stable hot sites | Optional per-site runtime feedback | Later / large |

### 1. Bounded primitive constant folding

**Precedent.** Lua folds numeric expressions during code generation. CPython's
AST optimizer bounds expensive constant computations and constant sizes rather
than evaluating every expression eagerly.
[Lua `constfolding`](https://www.lua.org/source/5.4/lcode.c.html#constfolding),
[CPython 3.13 AST optimizer](https://raw.githubusercontent.com/python/cpython/v3.13.0/Python/ast_opt.c).

**Boomkat opportunity.** `gen_binary_step` in
[gen.c3](../src/compiler/gen.c3) emits an operation for a binary AST node.
Immediate fusion reduces operand loads but still executes the operation.
Start with literal Number arithmetic, comparisons and unary operations, using
shared JavaScript semantic helpers where they fit. Generate one constant load
for `(2 + 3) * 4`; use compact side facts instead of rebuilding the tree.

**Boundary and experiment.** Preserve IEEE-754 rounding, negative zero, NaN,
Infinity, shift conversions and evaluation order. Leave coercions and potentially
throwing operations at runtime. Budget compile work and output size; exceeding
the budget leaves ordinary code, never rejects a valid program or limits BigInt
magnitude. String folding must not create a `"use strict"` directive. Compare
bytecode size, compile time and repeated-call runtime on generated expressions;
include numeric edge cases and large constants before expanding eligibility.

**Decision: retain the bounded Number-only implementation.**
`src/compiler/constant_fold.c3` probes at most 32 nodes per expression without
allocating analysis storage or changing the AST. Eligible operators are numeric
`+`, `-`, `*`, `/`, `%`, comparisons/equality, and unary `+`, `-`, `!`.
Operands must fold to Numbers; Boolean results can be emitted but do not extend
arithmetic eligibility. Unsupported forms and exhausted probes use ordinary
generation. `--no-optimize` bypasses the probe. Early errors precede folding,
and original source spans remain available to `Function.prototype.toString`.

The baseline is `73a0132a`, including the three value-preservation fixes from
the merge review. Saved production and inspection binaries supply the A/B
comparison; there is no new runtime switch. Both builds use c3c 0.8.4 / LLVM
23.1.1 on macOS arm64, project O2/size-small targets and relaxed floating-point
mode. Runtime measurements use the production threaded-dispatch target;
compile-only measurements use `boomkat_debug --check`.

Seven measured pairs alternate baseline/candidate order after one warmup pair.
These are process wall times including startup; compile-only runs execute no JS.
The tiny changes in the controls do not establish a general speedup.

| Workload | Baseline median | Candidate median | Candidate / baseline |
|---|---:|---:|---:|
| Constant arithmetic kernel | 59.10 ms | 38.31 ms | 0.648 |
| Parameter arithmetic control | 61.29 ms | 60.64 ms | 0.989 |
| Arithmetic suite | 21.46 ms | 21.61 ms | 1.007 |
| Function calls | 33.23 ms | 32.94 ms | 0.991 |
| Recursion | 29.63 ms | 29.56 ms | 0.997 |
| Scene churn | 145.47 ms | 144.55 ms | 0.994 |
| Babel compilation | 269.55 ms | 268.77 ms | 0.997 |
| TypeScript compilation | 631.27 ms | 628.92 ms | 0.996 |

The constant kernel's samples span 58.02–59.54 ms for baseline and 37.95–39.07 ms
for candidate. Its function uses 3 instructions and 4 registers against 16 and 6;
both constant pools contain one entry. `(2 + 3) * 4` alone lowers to `LDINT 20`
and `RET`, against four instructions and two registers. Production executable
size grows by 112 bytes; Mach-O `__TEXT` and `__DATA` segment sizes remain
2,031,616 and 49,152 bytes. No persistent analysis metadata is added.

Peak RSS is 4.52 MB for both constant-kernel binaries, 51.49→51.40 MB for Babel
compilation and 96.67→97.37 MB for TypeScript compilation. These are the largest
per-child `wait4` peaks in the seven pairs, in decimal MB. The measurements show
a useful eligible-kernel gain without a material measured general regression.
Raw samples, binary hashes and sizes are in
[`ast-constant-folding-results.json`](../benchmarks/ast-constant-folding-results.json).
Reproduce with `scripts/measure_ast_constants.py --baseline <saved-boomkat>
--baseline-debug <saved-debug> --revision <baseline-commit> --output <json>`.

Validation includes 561 local scripts, 20 module fixtures and their companion
checks, 42 Rosetta cases and 590 arithmetic/comparison test262 cases. The focused
fixture and a generated 2,925-case numeric matrix pass in Boomkat and QuickJS;
both also pass in a fresh NONANBOX build. The fixture covers negative zero,
NaN/Infinity, overflow/underflow, rounding order, side effects, BigInt exclusions,
source retention and the 32-node fallback. The existing no-optimize path passes
the fixture too.
The official TypeScript run reports the same two endless-iterator runtime
crashes documented in plan 101, with no additional failures.

### 2. Binding-aware propagation and dead execution

**Precedent.** V8 Maglev builds an SSA graph from bytecode, tracks known value
facts and uses a prepass for control flow and liveness. These are useful models
for propagating facts through assignments and joins.
[Maglev design](https://v8.dev/blog/maglev).

**Boomkat opportunity.** Existing copy propagation follows register moves.
[binding_analysis.c3](../src/compiler/binding_analysis.c3) conservatively merges
shadowed declarations by constant-pool name identity when retaining environment
stores. Carry declaration identity from [resolution](../src/ast/resolve.c3)
into optimization. Start with uncaptured function locals: propagate an immutable
primitive initializer, eliminate an overwritten store while retaining RHS
effects, and skip execution of a proven unreachable branch. Measure whether
precise identities also remove unnecessary environment synchronization.

**Boundary and experiment.** Run early errors and declaration collection first.
Dead branches can still declare hoisted `var` names and affect Annex B function
instantiation. Preserve TDZ, closure observations and sloppy mapped arguments;
direct eval, `with` and externally visible bindings require conservative handling.
Compare local-assignment kernels and shadowed-name closures against existing
passes, recording instructions and environment stores removed. Test constant
conditions with hoisted declarations and side-effecting discarded RHS values.

### 3. Effect-aware common subexpressions and load forwarding

**Precedent.** LuaJIT applies common-subexpression elimination and load/store
optimization to its IR, with explicit restrictions for calls, allocations and
GC barriers. Structural equality alone does not establish safe reuse.
[LuaJIT folding and CSE rules](https://raw.githubusercontent.com/LuaJIT/LuaJIT/v2.1/src/lj_opt_fold.c).

**Boomkat opportunity.** Add block-local value numbering over proven primitive
operations, keyed by operand value versions rather than AST spelling. Reuse a
repeated numeric calculation only while its inputs are unchanged. Extend load
forwarding to known own data fields of a fresh, unescaped record only after the
effect and escape model can prove those reads safe. Existing property caches
accelerate lookup; they do not prove that a second read has the same result.

**Boundary and experiment.** Object coercion, getters, proxies, calls and aliasing
writes can change values or throw. Treat them as barriers until a stronger proof
exists. Do not merge allocations by literal equality. Start on arithmetic blocks,
then test repeated-field kernels with accessor, proxy and aliasing controls.
Track removed operations alongside temporary-register pressure: keeping a result
alive longer can cost more than recomputing it.

### 4. Loop-invariant work and repeated-check elimination

**Precedent.** LuaJIT's loop optimizer explains why guards obstruct ordinary
loop-invariant code motion. Its copy-substitution unrolling preserves control
dependencies while enabling redundancy elimination.
[LuaJIT loop optimizer](https://raw.githubusercontent.com/LuaJIT/LuaJIT/v2.1/src/lj_opt_loop.c).

**Boomkat opportunity.** Analyze loop writes and effects to move proven pure,
nonthrowing primitive expressions into a preheader. For example, compute an
unchanging numeric scale once rather than inside every iteration. Investigate
redundant checks only after identifying which checks survive existing threaded
fast paths. Begin with straight loops over uncaptured local values; broad
loop unrolling is unnecessary for the first experiment.

**Boundary and experiment.** A zero-iteration loop must not gain coercions,
exceptions or visible reads. Getters, resizable storage, aliasing writes and
calls invalidate many apparent invariants. Preserve `continue`, `break`,
`finally` and per-iteration lexical environments. Measure numeric loops with
changing bounds and effect barriers, plus small and zero trip counts. Reject
hoisting that increases register pressure or bytecode size enough to erase its
execution benefit.

### 5. Numeric type and range specialization

**Precedent.** Maglev tracks types, chooses value representations and handles
speculation failures with deoptimization. Its representation choices depend on
dataflow, including loop merges, rather than source-level type spelling.
[Maglev value facts and representations](https://v8.dev/blog/maglev).

**Boomkat opportunity.** Numbers already fit directly in `TVal`; the target is
fewer tag tests and generic branches, not eliminating heap boxes for doubles.
Prototype one numeric operation or short region whose inputs are statically
proven, comparing it with [existing arithmetic](../src/vm/vm_arith.c3) and threaded
handlers. If guarded entry is needed, a failure must reach the generic path
before effects. Audit the byte-sized [opcode encoding](../src/bytecode.c3), WIDE
operands and dispatch metadata before adding any opcode family.

**Boundary and experiment.** JavaScript Number is floating point: retain overflow
behavior, rounding, negative zero, NaN and Infinity. BigInt requires separate
semantics. TypeScript annotations are erased and provide no runtime proof.
Do not replace `x * 2` with `x << 1` or reassociate floating-point expressions.
Measure Number and fastint loops, mixed-type transitions and NONANBOX builds;
count checks removed and include native text size and slow-path performance.

### 6. Small stable-callee inlining

**Precedent.** V8's inlining heuristic treats small callees specially while
bounding total expansion and considering call frequency for larger candidates.
The budgets are as relevant to Boomkat as the call removal.
[V8 inlining heuristic](https://raw.githubusercontent.com/v8/v8/main/src/compiler/js-inlining-heuristic.cc).

**Boomkat opportunity.** Inline one small, nonrecursive leaf function at a call
through a proven stable local binding. Begin without defaults, rest parameters,
`this`, `arguments`, suspension or mutable captures. Bind evaluated arguments
once in source order, remap local identities, and lower the body into the
caller. Keep expansion bounded and retain real function objects wherever their
identity or introspection is observable.

**Boundary and experiment.** A stable property name is not a stable callee.
Mutable globals, method overrides, getters, eval and `with` need proof or guards.
Preserve omitted and excess arguments, exceptions, strict/sloppy semantics and
source spans for `Function.prototype.toString`. Define diagnostic stack-frame
behavior before generalizing. Compare tiny helpers and a representative scene
workload; include reassigned-callee controls and recursive exclusions. Measure
compiled code growth and compile peak memory as well as calls removed.

### 7. Direct emission of parameter defaults

**Precedent.** QuickJS emits an undefined check followed by the default expression
in the function's parameter bytecode, with a distinct parameter scope where
needed. It does not introduce a function call for each default expression.
[QuickJS parameter compilation](https://raw.githubusercontent.com/bellard/quickjs/master/quickjs.c)
(`js_parse_function_decl2`, parameter-initializer branch).

**Boomkat opportunity.** [functions.c3](../src/compiler/functions.c3) compiles
nonliteral defaults into inner-function thunks; `emit_param_prologue` creates
and calls their closures. `push_param_default` already replaces eligible
literal thunks with direct loads, and pattern-element defaults have inline
lowering. Extend direct emission to an ordinary default such as
`function f(a, b = a + 1) { return b; }` using its AST node. This can remove
both compiler-generated functions and runtime work.

**Boundary and experiment.** Preserve left-to-right initialization, later-parameter
TDZ, parameter/body environment separation, `arguments`, lexical captures,
inferred names, `this`, `new.target` and derived-constructor `super` behavior.
Start with simple defaults and reuse the existing prologue; expand eligibility
only with semantic evidence. Benchmark missing/undefined arguments against
supplied arguments. Inspect closure/call counts, inner-function storage and
environment requirements; test closures retaining parameters and direct eval
inside defaults. Prefer one shared lowering path as coverage expands.

**Decision: retain bounded direct emission for plain parameters.**
`param_defaults.c3` accepts primitive literals, earlier parameter names, binary
expressions and unary `+`, `-`, `!`, `~`, with a 32-step budget that includes name
lookup. Ordinary functions with plain parameters are eligible; arrows,
generators, async functions, class/super contexts, dynamic capture and
rest/destructured parameters keep thunk lowering. Calls, assignments, closures
and self/later parameter reads also use that path. The shared prologue preserves
left-to-right initialization, TDZ and parameter/body scope separation.
`--no-optimize` disables this eligibility probe.

Saved binaries from `f470aa9b` provide the baseline, using the same build targets
and seven alternating measured pairs described for candidate 1.

| Workload | Baseline median | Candidate median | Candidate / baseline |
|---|---:|---:|---:|
| Missing argument, `b = a + 1` | 158.14 ms | 103.97 ms | 0.657 |
| Supplied argument control | 110.11 ms | 107.62 ms | 0.977 |
| Function calls | 33.19 ms | 32.99 ms | 0.994 |
| Recursion | 28.71 ms | 28.77 ms | 1.002 |
| Scene churn | 148.52 ms | 154.51 ms | 1.040 |
| Babel compilation | 261.18 ms | 262.14 ms | 1.004 |
| TypeScript compilation | 622.30 ms | 630.08 ms | 1.013 |

The missing-argument samples span 155.58–162.52 ms for baseline and
102.96–106.25 ms for candidate. Peak RSS is 8.98→8.47 MB for that kernel,
50.87→50.97 MB for Babel and 96.16→96.60 MB for TypeScript. Scene churn has
substantial spread (141.89–163.18 ms baseline, 142.33–235.93 ms candidate),
so a second seven-pair control run checks the result: scene churn is
142.94→144.71 ms (1.012), Babel 260.88→261.34 ms (1.002), and TypeScript
621.00→617.53 ms (0.994). The overlapping scene samples do not establish a
repeatable regression. These measurements establish a targeted gain, not a
general speedup. The repeat is recorded in
[`ast-parameter-defaults-control-results.json`](../benchmarks/ast-parameter-defaults-control-results.json).

`function f(a, b = a + 1) { return b; }` uses 17 instructions and 5 registers,
against 21 and 7 plus a three-instruction thunk. The inline `ADDI` eliminates
the thunk function, closure and call. Both parent constant pools have two entries.
The production executable grows by 64 bytes, the inspection executable by 144;
Mach-O text/data segment sizes stay unchanged. The AST index is compilation-only
metadata. Raw samples, hashes and sizes are in
[`ast-parameter-defaults-results.json`](../benchmarks/ast-parameter-defaults-results.json).
Use the measurement script's repeatable `--runtime` option to select the two
`benchmarks/ast-optimization/bench_ast_defaults_*` kernels and controls.
Keep optimization experiment kernels in this subdirectory so the generic
`just bench` suite does not discover them.

Validation passes 562 local scripts, 20 module fixtures and companion checks,
42 Rosetta cases and 715 function statement/expression test262 cases. The focused
fixture covers supplied/undefined arguments, coercion and throws, TDZ,
parameter mutation and closure capture, unmapped arguments, eval, strict code,
constructor identity and fallback forms; it also passes in QuickJS and with
the inspection binary's `--no-optimize` option.

### 8. Scalar replacement of local records and arrays

**Precedent.** JavaScriptCore's allocation-sinking phase tracks local allocations,
field values and escapes. Its machinery can materialize objects when necessary;
that recovery machinery is a substantial part of the optimization.
[JSC object allocation sinking](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/JavaScriptCore/dfg/DFGObjectAllocationSinkingPhase.cpp).

**Boomkat opportunity.** Start with a fresh record whose identity never escapes:
`const p = { x: a, y: b }; return p.x + p.y;`. Keep fields as values and emit
no object allocation. Existing fixed-shape literals reduce construction cost
but still allocate. A later experiment can handle short local arrays with
proven indices; records with initialized own fields are the simpler first case.
This directly develops plan 099's semantic-IR candidate.

**Boundary and experiment.** Require all uses to be understood; initially keep
allocations that are returned, captured, passed to unknown/native calls or
observed through identity, enumeration, prototype mutation or dynamic access.
Array holes and out-of-bounds reads can consult prototypes; exclude them until
that behavior is proved equivalent. Preserve initializer effects and GC roots
for field values. Avoid materialization and deoptimization in the first prototype.
Temporary lifetime alone does not
prove nonescape: retained scene vectors and views often escape. Compare an
eligible record kernel, an escaping control and an actual application; require
measured allocation/GC reductions, not just fewer property opcodes.

### 9. Liveness-based suspension storage

**Precedent.** LLVM's coroutine lowering stores values live across suspension in
the coroutine frame so continuation functions can use them.
[LLVM coroutine frame model](https://llvm.org/docs/Coroutines.html#async-lowering).
This is a storage principle to adapt, not a proposal to add LLVM at runtime.

**Boomkat opportunity.** Restricted ordinary async functions already get await
live masks; unsupported cases keep full snapshots. Synchronous generators move
saved ownership on restore but still save and restore dense register arrays in
[vm_generators.c3](../src/vm/vm_generators.c3). Extend sound liveness to simple
synchronous generators first, then investigate broader async eligibility. Start
by skipping dead-slot copies; compare a sparse or packed frame only if saved
storage remains a measured problem.

**Boundary and experiment.** Model normal resume, `.throw()`, `.return()`,
`finally`, delegation, rejected awaits and exception handlers. Captured and
dynamically observable locals may remain live even without a direct future
read. Save all interpreter state needed by those paths, preserve ownership
transfer and GC barriers, and fall back when analysis is incomplete. Measure
bytes copied, saved-frame bytes and objects retained across suspension on wide
generator and async fixtures, including early close and closures over locals.

### 10. Adaptive bytecode specialization

**Precedent.** CPython PEP 659 describes per-instruction specialization with
counters, guards and cheap return to generic execution after misses. It also
accounts for cache memory; the mechanism is distinct from a native-code JIT.
[PEP 659](https://peps.python.org/pep-0659/).

**Boomkat opportunity.** Investigate one hot arithmetic site that generic and
threaded fast paths still handle expensively. Add optional counters and bounded
site metadata, specialize stable inputs, and back off on repeated misses.
Existing property caches already specialize lookup, so duplicating them is not
a useful first experiment. AST facts can narrow eligible sites, but execution
feedback works after the tree is freed.

**Boundary and experiment.** Check types before coercion or writes; a miss must
execute the original operation exactly once. Define metadata ownership, GC
visibility, opcode replacement, tracing and disassembly behavior. Avoid reserving
a large cache at every cold instruction. Compare cold startup, stable numeric
sites, polymorphic sites and changing types; include code/data size, cache bytes
and warmup cost. Fix the profiler issue described below before choosing a site.
Keep this optional unless the benefit justifies the embedded-device footprint.

## Shared implementation constraints

Use resolved binding identities and value versions, not spelling or constant-pool
indices, for semantic proofs. Optimizer facts must be computed before reference
scratch is freed, or explicitly retained in a compact form. Preserve the source
tree's diagnostic spans and original function text; perform early-error and
declaration analysis before omitting execution.

Begin with direct AST/emitter changes for 1 and 7 and a narrow analysis for 2.
Add a function-local control-flow graph only when an experiment needs joins,
exception edges or suspension edges. A small effect model should distinguish
pure primitive operations, potentially throwing operations, observable reads,
writes, calls and suspension. SSA can support 2–5 and 8; its construction is a
shared cost that needs demonstrated benefit, not an eleventh optimization.

Keep analysis in idiomatic C3, reusing stdlib collections, existing allocators,
bytecode decoders and liveness helpers. Do not add an LLVM dependency, a second
JavaScript semantics implementation or arbitrary source-size rejection limits.
Bound optional analysis work and conservatively emit normal code when a budget
is exhausted. Process and free analysis one function at a time; plan 101 already
records increased whole-unit compile peak memory.

Strict and sloppy code remain supported. Eval, `with`, mapped arguments,
proxies, accessors, closure mutation and native reentry are proof boundaries,
not permission to change language behavior. Runtime mutations invalidate
assumptions unless the compiler proves they cannot occur. Each transformed
instruction and suspended value must retain correct refcount and GC-root
ownership, including NONANBOX and WIDE paths.

## Measurement and acceptance

- Keep prototypes light: inspect emitted code and collect performance metrics
  first. Run broader validation only after the gain is worth retaining and the
  implementation is finished and reviewed.
- Establish a fresh optimized baseline from this branch; record compiler,
  platform, flags, dispatch mode and revision. Historical measurements in
  plans 097–101 are context, not results for these experiments.
- Prototype each candidate independently. Compare saved prebuilt binaries and
  verify differing bytecode or counters. A new runtime switch is unnecessary;
  the existing `disable_optimize` flag must cover a retained AST pass.
- Measure compile-only time and peak RSS separately from execution, startup and
  warmup. Alternate baseline/candidate runs and report spread, not only the
  best result. Use the same timing conditions and controls for both binaries.
- Pair a mechanism-specific benchmark with an ineligible control and broader
  workloads from [the benchmark suite](../benchmarks/README.md). Include bundles
  for compile cost and scene/call/iteration workloads for runtime cost. Check
  observable outputs so dead benchmark work cannot manufacture a speedup.
- Record native text/data size, JS bytecode and constant-pool size, metadata and
  peak runtime memory. Count relevant operations, allocations or copied bytes.
  Track net source growth and remove superseded machinery when a simpler path
  covers it. Fewer source lines do not imply a smaller executable.
- Repair opcode profiling before using frequency or adjacency to select VM
  specializations: plan 098 identifies counters that miss threaded bursts and
  pairs that are not adjacent executed bytecodes. AST folding investigations
  can begin with bytecode inspection without waiting for that repair.
- Validate changed semantics with focused local repros, `just rosetta`,
  `just test-local`, relevant narrow test262 directories and TS conformance
  when lowering is affected. Exercise scripts and modules. Use freshly rebuilt
  ASAN/GC-stress targets for allocation, ownership and suspension changes;
  distinguish pre-existing failures. Do not change the test262 skip list.
- Retain a candidate only for a repeatable useful gain that justifies compile,
  memory, binary-size and maintenance costs. Reject noisy microbench wins,
  meaningful general regressions and complexity without eliminated work.
  Published speedups from other runtimes do not predict Boomkat's results.

## Investigation sequence and deliverables

Investigate **1, 7, then 2** first: they can remove work without requiring a new
execution tier. Proceed to **3 and 9** where profiles show repeated calculations
or suspension copying. Use those results to decide whether the shared CFG/value
analysis warrants **5 and 4**, then **6 and 8**. Investigate **10** independently
after reliable hot-site profiling; stop if existing fast paths already remove
its proposed benefit.

For each of the ten candidates, completion means a recorded keep/reject/defer
decision, supporting measurements and semantic evidence. A rejected experiment
is a valid result. Any retained implementation should include focused fixtures
and update `docs/architecture.md` where behavior changes.

- [ ] Record independent results and decisions for candidates 1–10.
- [ ] Retain only justified changes; remove rejected prototype code and flags.
- [ ] Document compile, runtime, memory and size impact of retained changes.

Research links use primary runtime documentation and source. CPython's AST
source is pinned to 3.13.0; several other links track maintained branches.
Record exact upstream revisions when implementing an experiment. The precedent
paragraphs report those sources; eligibility rules, ordering and expected
Boomkat opportunities are proposals inferred from the current code review.

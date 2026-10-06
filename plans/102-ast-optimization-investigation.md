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

### Shared-layout object spread

CopyDataProperties reuses a source's shared layout when both objects are
ordinary, the target is empty, there are no exclusions, and every source
property has default data attributes. It allocates value storage once and
copies through `store_slot_ref`, retaining strings and preserving GC barriers.
Indexed-property metadata follows the layout so an array using the copy as
its prototype still observes inherited indexed values. Private/dictionary
shapes, accessors, proxies, nondefault attributes and nonempty targets retain
the generic path. Shape initialization is shared with shaped allocation and
inlined to avoid an extra call on ordinary object construction.

Seven alternating final A/B samples give spread/rest 151.9 ms to 109.0 ms
(28.3% less time), and the focused object-spread kernel 66.5 ms to 25.0 ms
(62.5%). Destructuring, prototype reads and the Babel/TypeScript compile controls
are effectively unchanged. Production executable growth is 128 bytes. Full
samples, RSS and hashes are in
[`object-spread-changes.json`](../benchmarks/ast-optimization/es6/object-spread-changes.json).

Validation passes 566 local scripts, 20 module fixtures and companion checks.
The expanded ownership regression and Node comparison pass. Local `out/qjs`
differs on a getter deleting a later property: it copies the deleted key.
The regression follows
[CopyDataProperties](https://tc39.es/ecma262/multipage/abstract-operations.html#sec-copydataproperties),
which checks each key's current descriptor before reading its value. Both the
saved Boomkat baseline and candidate agree with Node on that case.

### Rest parameter count elision

A conservative bytecode proof keeps a nonescaping rest parameter as its count
when the only permitted reads are constant-key `.length` accesses. Unused rest
parameters qualify too. The proof rejects writes, closures, dynamic scope,
defaults, generators/async functions, arrows and unknown instructions. Length
reads become register moves; function arity and rest metadata remain intact.

All seven general entry paths share the same rest-value builder. Ordinary
threaded calls and native callbacks have count initialization in their lean
entry. Tail calls use the general entry, which settles argument ownership
before replacing the frame. Native array construction also uses the canonical
builder, including explicit own properties for undefined rest elements.

Final measurements show 24.9% less time for the generic spread/rest suite and
76.4% less time for the focused rest-length kernel. Destructuring, closure and
call-stack controls are within 1%. Babel compilation is 3.8% slower in this
batch; TypeScript is effectively unchanged. Timings, RSS and binary hashes are
in [`rest-length-changes.json`](../benchmarks/ast-optimization/es6/rest-length-changes.json).
Production executable growth is 96 bytes.
The local suite passes 567 scripts, 20 module fixtures and companion checks.
The new regression agrees with Node and QuickJS, including direct, bound,
native callback, reflective, tail-call and fallback cases.

Remaining allocation targets include fresh arrays consumed by destructuring
and escaping iterator results. Captured/modified rest arrays retain ordinary
allocation.

### Mutable lexical cells

Bindings with one integer initialization and no iteration renewal reuse the
existing mutable capture cells. Allocation stays at declaration execution;
closures from separate block executions retain independent owners. Stable
read-only captures still use snapshots. No runtime opcode or representation is
added.

The screening run reduced closure capture time by 5.5%; the recorded seven-pair
run reduces it from 54.01 to 51.91 ms (3.9%). Shared property/call controls and
Babel/TypeScript compile times are within 1%; the let-loop control improves
1.2%. Both executable sizes are unchanged. This is a small retained improvement
from reusing existing machinery, rather than a solution to the remaining call
and instruction-dispatch costs. Samples, RSS and hashes are recorded in
[`lexical-cell-changes.json`](../benchmarks/ast-optimization/es6/lexical-cell-changes.json).

The local suite and Node pass the expanded capture regression, including
repeated block lifetimes, sibling writes, escaped strings/objects and nested
forwarding. A fresh ASAN build with forced GC also passes the capture regression;
linking uses the installed LLVM 23 ASAN runtime because c3c's runtime path is
absent.

### Reference-valued flat array patterns

`DESTRUCT_ARRAY_FAST` copies all present dense values through the existing
reference-counted store and records destination registers for GC. It guards
the array and iterator protocol before any binding writes. Removing the
primitive-only restriction eliminates iterator allocation and calls for flat
patterns containing strings, objects, symbols and functions without adding
an opcode or runtime representation. Holes and observable iterator methods
retain generic handling.

The reference-valued lexical/parameter kernel improves from 130.63 to 42.55 ms
(67.4% less time). Generic destructuring and value-stack controls are within
0.5%; for-of improves 5.6% in this batch. Babel compilation is within 0.4% and
TypeScript is 1.1% slower. Both executable sizes are unchanged. Raw timings,
RSS and hashes are in
[`heap-pattern-changes.json`](../benchmarks/ast-optimization/es6/heap-pattern-changes.json).

The expanded regression agrees with Node and QuickJS and passes a fresh
ASAN/forced-GC build linked with the installed LLVM 23 runtime. The local suite
passes 567 scripts, 20 module fixtures and companion checks.

### Remaining for-of costs

The constituent screen at e7a6c344 records array iteration at 3 ms, indexed
array access at 2 ms, and set/string iteration at 1 ms each. Map entries take
13 ms and generator consumption takes 16 ms; QuickJS takes 10/3 ms and Node
4/1 ms for those two cases. These are single calls after setup in fresh
processes, with millisecond timer resolution, not steady-state JIT results.
See [`forof-breakdown.json`](../benchmarks/ast-optimization/es6/forof-breakdown.json).

Generic Map stepping bypasses iterator-result objects but allocates an entry
pair before destructuring. The fused consumer below removes that pair for
eligible loop heads while guarding its observable iterator methods. Generator YIELD
allocates a result object even for the compiler's internal for-of consumer.
Eliding it needs a continuation that distinguishes internal consumption from
public `.next()` and delegation; ordinary calls must retain distinct results.
These remain allocation-elimination targets, with generator dispatch and
suspension overhead to measure separately from result allocation.

### Map entry scalar consumption

An uncaptured flat two-binding lexical for-of head emits `ITER_ENTRY_FAST`
before ordinary iteration. The VM validates the captured Map iterator `next`
and the pair array's iterator/next/return behavior before copying the map's
key/value slots into registers. The iterator position advances only after
guards succeed. A failed guard leaves the ordinary step intact; both paths
install the same body catcher for IteratorClose. A small threaded refusal
handler keeps non-map sources on their existing dispatch path.

The entry kernel improves from 32.79 to 15.14 ms (53.8% less time), and the
generic for-of suite improves from 61.61 to 53.86 ms (12.6%). The array-of-pairs
control is within 0.3%; destructuring, value-stack and compile controls show
no material regression. Production growth is 48 bytes; the debug executable
grows 16,496 bytes. Measurements, RSS and hashes are in
[`map-entry-changes.json`](../benchmarks/ast-optimization/es6/map-entry-changes.json).

The baseline is a clean build of e992b8d4 exported into a temporary checkout.
The saved workspace binary had a different size after switching build targets,
so its initial screening results are not used for the retained comparison.

The local suite passes 568 scripts, 20 module fixtures and companion checks.
The focused regression agrees with Node and QuickJS and passes a fresh
ASAN/forced-GC build linked with LLVM 23's runtime. It covers reference-valued
and undefined entries, mutation during iteration, iterator overrides before
and during the loop, captured-binding fallback, continue, and IteratorClose
on break, return and throw.

### Fresh array pattern scalar replacement

Flat lexical patterns over bounded, hole-free array literals evaluate their
elements into persistent registers. `ARRAY_PATTERN_GUARD` checks the shared
array iterator assumptions after every element has run. Success copies values
into bindings without allocating the array; refusal materializes the saved
values and runs ordinary destructuring. Element effects, TDZ, iterator
overrides and the fallback array's identity remain observable. The VM shares
the intrinsic guard with flat extraction and Map entry consumption.

The scalar-array kernel improves from 28.27 to 18.31 ms (35.2% less time),
and generic destructuring improves from 144.91 to 124.65 ms (14.0%). Map-entry,
for-of and value-stack controls are within 2%; Babel and TypeScript compile
times are within 0.3%. Production growth is 192 bytes and debug growth 336
bytes. Samples, RSS and hashes are recorded in
[`scalar-array-changes.json`](../benchmarks/ast-optimization/es6/scalar-array-changes.json).

The local suite passes 569 scripts, 20 module fixtures and companion checks.
The scalar-array regression agrees with Node and QuickJS. Fresh ASAN/forced-GC
builds pass the scalar-array and Map-entry regressions, including the shared
guard's fallback cases; linking uses the installed LLVM 23 runtime.

### Straight-line register read forwarding — rejected

A prototype tracked register-copy aliases inside straight-line regions,
invalidated them on writes/branches/unknown instructions, and retained aliases
below ordinary call windows in functions without captures, eval or arguments.
It rewrote known reads and left existing liveness to remove dead copies.

The seven-pair screen regresses value-stack copying from 34.70 to 37.75 ms
(8.8%). Function-call and string timings also regress slightly; template
literals improve 4.9%, and destructuring improves 1.4%. This does not justify
the additional alias analysis. The prototype is removed; samples are recorded
in [`read-forward-rejected.json`](../benchmarks/ast-optimization/es6/read-forward-rejected.json).
Broader propagation remains open; this rejects this local mechanism, not every
form of value analysis or register allocation.

### Direct string join storage

`STRJOIN` writes into final string storage, avoiding the temporary buffer and
second copy. Fastint sizing counts digits; the final write formats each integer
once. String allocation and two-span concatenation share header initialization
and content metadata finishing with joins. This removes 59 net source lines
from the runtime implementation.

Template literals improve from 110.28 to 101.59 ms (7.9% less time). Function
call, prototype IC, string, value-stack and destructuring controls are within
1%; Babel and TypeScript compile times are flat. Production growth is 272
bytes; debug growth is 720 bytes. Timings, RSS and hashes are recorded in
[`direct-join-changes.json`](../benchmarks/ast-optimization/es6/direct-join-changes.json).

The focused regression agrees with Node and the saved Boomkat baseline. The
installed QuickJS differs on object-conversion order for two template
substitutions: it evaluates the second substitution before converting the
first. The expected order follows
[ECMAScript template evaluation](https://tc39.es/ecma262/multipage/ecmascript-language-expressions.html#sec-template-literals-runtime-semantics-evaluation),
which applies ToString before evaluating the remaining TemplateSpans.

The local suite passes 570 scripts, 20 module fixtures and companion checks.
A fresh ASAN/forced-GC build passes direct-join and concatenation ownership
regressions, linked with the installed LLVM 23 runtime. The join fixture
covers integer boundaries, empty and long output, CESU-8 character lengths,
embedded NUL, index-key metadata, object conversion, symbols and retained
strings.

### Direct results for trivial compiled calls

The first-call classification recognizes an undefined return, a returned
parameter, and two parameters added and returned. The threaded call handlers
resolve the current callee and publish these results without creating an
activation. Addition accepts numeric inputs; missing operands, strings,
BigInt and user conversions enter the ordinary body. Existing safepoints,
receiver checks, publication guards and string ownership remain shared with
the call path. Classification uses two spare flag bits and a cold helper.

This is the bounded runtime form of candidate 6. It avoids source expansion
and a proof of binding stability: reassignment selects the current function
on every call. General AST inlining remains a separate possibility.

The retained layout improves function calls from 32.17 to 25.09 ms (22.0%). Prototype IC,
string and template controls are within 0.5%; value-stack, destructuring,
recursion and scene controls are 1.1–1.5% slower. Compiler checks are flat.
Production growth is 64 bytes and debug growth is 144 bytes. Timings, RSS and hashes are in
[`trivial-call-changes.json`](../benchmarks/ast-optimization/es6/trivial-call-changes.json).
An inline classification layout also gains about 21% on calls but regresses
the short string control by 2–4.5%; the cold classification layout removes
that measured regression.

The local suite passes 571 scripts, 20 module fixtures and companion checks.
The hot-call fixture passes scripts and modules and agrees with Node and
QuickJS. A fresh threaded ASAN/forced-GC build passes it and the existing
empty-call fixture, linked with the installed LLVM 23 runtime. Coverage
includes missing/surplus arguments, duplicate sloppy parameters, changing
callees, heap identities, string ownership, integer boundaries, mixed numeric
representations, negative zero, NaN, defaults/rest and conversion exceptions.

### Numeric check probe and guarded addition fusion

An unsafe headroom probe removes the fastint input checks from `ADD` and
`ADDI`, retaining overflow and ownership checks. On the numeric workloads,
prototype IC improves from 81.01 to 71.12 ms (12.2%) and value-stack copying
from 33.81 to 32.09 ms (5.1%). Calls improve 1.7%, arithmetic 0.8%.
The probe's IC source prints the numeric result directly, avoiding its final
string addition; the original generic benchmark is unchanged. Samples,
source override and hashes are in
[`numeric-check-probe.json`](../benchmarks/ast-optimization/es6/numeric-check-probe.json).
The unchecked implementation is removed. These results measure headroom,
not an optimization that preserves JavaScript semantics.

The retained `ADD_FUSED` marks adjacent additions when the second reads the
first result and no branch enters the second instruction. The threaded
handler validates three input fastints rather than checking the intermediate
again and dispatches both operations together. Overflow, other types and
releases requiring string destruction resume ordinary instructions, without
replaying an addition already consumed. Keeping the second opcode as `ADD`
also preserves the switch implementation and intermediate results. The pass
reuses compaction scratch storage; async functions retain their liveness path.
Rest-count analysis recognizes the first instruction's ordinary ADD operands.

Prototype IC improves from 81.35 to 75.15 ms (7.6%) and value-stack copying
from 34.30 to 32.87 ms (4.2%). Destructuring improves 2.3%; calls, template,
spread/rest, recursion and scene controls are within 1%. The string control
is 2.0% slower. Babel and TypeScript compile times grow 0.6% and 0.3%.
Production growth is 96 bytes and debug growth is 144 bytes. Results are in
[`add-fused-changes.json`](../benchmarks/ast-optimization/es6/add-fused-changes.json).

The local suite passes 572 scripts, 20 module fixtures and companion checks.
The focused regression passes scripts and modules and agrees with Node and
QuickJS. It covers both operand positions, repeated/overwritten results,
integer overflow, doubles, negative zero, strings, BigInt, conversion order,
exceptions, rest-count lowering and shared string ownership.
A fresh threaded ASAN/forced-GC build and a fresh NONANBOX build pass the
addition and trivial-call regressions. ASAN links against the installed LLVM
23 runtime. The ownership review requires checking the second destination
after releasing the first: they can hold the same string, whose last release
must resume at the second instruction.

### Shared numeric fusion path

Fusion shares the numeric first-add path with ordinary `ADD` and publishes
the first result before examining the second operation. Its fastint arm
retains fastint results and checks overflow. The double arm preserves source
association and normalizes the intermediate Number before reusing it. A
non-numeric second operand enters its ordinary instruction, so conversion
hooks, strings and BigInt retain their execution order. The same publication
boundary handles string releases requiring destruction.

The controls reject a switch-only numeric fallback: double and mixed-number
chains take 2.11x and 1.49x as long as the pre-fusion baseline. Those results
are recorded in
[`add-fused-number-gap.json`](../benchmarks/ast-optimization/es6/add-fused-number-gap.json).
The shared path improves these workloads from 29.42 to 22.77 ms (22.6%)
and 64.64 to 57.84 ms (10.5%), measured against the same pre-fusion revision.
Prototype IC improves 8.2%, value-stack copying 3.6% and destructuring 3.3%.
String and template controls are flat; other runtime controls improve
0.4–1.2%. Compiler checks grow 0.4% and 0.9%. Production and debug growth
remain 96 and 144 bytes against `fc3f7dc6`. Results are in
[`add-fused-numeric-changes.json`](../benchmarks/ast-optimization/es6/add-fused-numeric-changes.json).

This covers numeric result forwarding and repeated-check elimination in
candidates 3 and 5 without type-flow metadata or speculative source lowering.
The local suite passes 572 scripts, 20 module fixtures and companion checks.
Fresh threaded ASAN/forced-GC and NONANBOX builds pass the arithmetic and
trivial-call regressions; ASAN uses the installed LLVM 23 runtime.

### Adaptive number feedback — rejected

A bounded prototype patches an ordinary `ADD` to a guarded double-pair handler
after observing two double operands. One type miss permanently returns that
site to generic execution. It adds two opcode states, 28 source lines and
48 production bytes, with no counters or feedback allocations. Every miss
occurs before publication or release, preserving ordinary addition semantics.

Eight alternating pairs, with the first discarded, compare single-add sites
against `3e15576f`. Stable double addition grows from 23.33 to 27.51 ms
(17.9%); mixed numeric and coercion controls grow 0.6% and 0.9%.
[`number-feedback-screen.json`](../benchmarks/ast-optimization/es6/number-feedback-screen.json)
records outputs, timings, memory and binary hashes. These workloads contain
no fused addition pairs, isolating feedback from the numeric fusion repair.
Candidate 10 is rejected: the existing threaded numeric path wins without
per-site state. The prototype remains outside the source tree.

### Immutable parameter copies

A prefix of local `var` copies can use its original parameters throughout the
function. A bounded whole-function opcode scan proves the formals are never
written and each unique uncaptured home has exactly one write. Both must stay
below every call window. Entry dominance, declaration identity and operand
formats constrain rewriting; unknown instructions retain ordinary copies.
Existing move elimination runs again only when copies are removed. The pass
uses fixed compiler scratch arrays and adds no execution metadata or opcodes.

The four entry copies in `copyTest` disappear, including reads beyond its
conditional return and recursive calls. Against `f10c8b19`, value-stack copying
improves from 31.64 to 28.97 ms (8.4%). Function calls and prototype IC are flat;
string improves 1.4%. Other runtime controls vary by +0.1–0.8%; Babel and
TypeScript checks grow 0.4% and 0.1%. Peak runtime RSS is flat; production and
debug executables grow 64 and 160 bytes. Raw samples are in
[`parameter-alias-changes.json`](../benchmarks/ast-optimization/es6/parameter-alias-changes.json).

This retains a narrow part of candidate 2. Its focused fixture agrees with
Node and QuickJS and passes both script and module execution. It exercises
branches, loops, nested calls, dependent copies, reads before initialization,
mutation, arguments, capture, eval, coercion and retained heap values.
The local suite passes 573 scripts, 20 module fixtures and companion checks.
A fresh threaded ASAN build with forced GC passes this fixture and the numeric
fusion and trivial-call regressions.

### Increment and comparison fusion

After compaction, an `INC` followed by `JMP_LT` reading that counter and a
distinct bound marks the increment `INC_LT`. The ordinary comparison stays
in place: rotated loops enter there before their first iteration, and a GC or
interrupt safepoint resumes there after a completed increment. Fastint pairs
share one tag guard and dispatch. The Number path retains an integer increment
for fastint counters, uses double arithmetic for Number counters, and compares
against a primitive numeric bound. Coercion and BigInt retain ordinary paths.
Async and wide functions retain their instruction sequence.

The canonical `INC`/`DEC` paths use the existing fastint-or-Number setter.
Their boundary fixture agrees with Node and QuickJS; the saved `5bfacf04`
binary wraps on increment overflow. Fastint overflow now resumes through the
canonical promotion rather than wrapping its payload.

Candidate 4 retains this repeated-check elimination, and candidate 5 retains
its numeric pair handling. A fastint-only prototype slows the double-bound
control by 10.1%; a shared double increment followed by conversion back to
fastint slows it 2.19x. Both are rejected. The retained path avoids that
round trip and keeps the hot fastint arm separate from Number handling.

Seven alternating measured pairs against `5bfacf04` improve integer counting
from 17.42 to 12.97 ms (25.5%), double-bound counting from 17.29 to 15.01 ms
(13.2%) and fractional counting from 37.46 to 22.72 ms (39.3%). Prototype IC
improves from 75.43 to 72.97 ms (3.3%); destructuring improves 1.7% and spread
0.7%. Other runtime controls vary from -0.4% to +0.6%; compiler checks grow
0.8% and 0.2%. Production and debug growth are 48 and 16 bytes. Measurements
are in
[`increment-comparison-changes.json`](../benchmarks/ast-optimization/es6/increment-comparison-changes.json).

The focused fixture covers initial and zero-trip entry, Number and BigInt
operands, mutable bounds and counters, fastint limits, NaN, infinities,
coercion order and exceptions. It agrees with Node and QuickJS, runs as a
script and module, and passes inspection execution with optimization disabled.
The local suite passes 574 scripts, 20 module fixtures and companion checks;
the focused fixture also passes a fresh NONANBOX build.

The long Number-loop kernel exposes recursive handler stack exhaustion in
threaded ASAN at `O0`; LLDB shows alternating increment-handler frames at the
stack guard. The threaded sanitizer target uses `O2` with full debug information
to retain native tail dispatch. The ordinary `O0` sanitizer runner keeps switch
dispatch. Fresh optimized threaded ASAN/forced-GC runs pass all three counting
kernels and both new regression fixtures, using the installed LLVM 23 runtime.

### Deferred fastint template formatting

`TOSTR` leaves a copied fastint in its private substitution slot. `STRJOIN`
counts its digits and formats it directly into the final string. Objects and
Symbols keep their source-position conversions; later assignments and calls
cannot change the copied integer. This removes the intermediate allocation
path and its temporary formatting buffer without adding a representation,
opcode, cache or runtime switch.

Against `845a8c1b`, the generic template benchmark improves from 99.95 to
92.21 ms (7.7%). Other runtime controls vary by -0.8% to +1.5%; compiler
checks vary by -0.7% and +0.2%. Production and debug executable sizes are
unchanged. The version printing the accumulated result returns `20866670`
for both binaries. Results are in
[`deferred-fastint-changes.json`](../benchmarks/ast-optimization/es6/deferred-fastint-changes.json).
The template arm executes 400,000 early integer substitutions; these keep
copied values rather than allocating intermediate strings.

The focused fixture agrees with Node and QuickJS in script and module runs.
It covers integer limits, assignment and call snapshots, mixed primitives,
Unicode, conversion exceptions, retained strings and suspension. The local
suite passes 575 scripts, 20 module fixtures and companion checks.

The exception fixture exposes an existing `STRJOIN` failure: after a caught
conversion error, its materialization loop still reaches length calculation
and copies an unconverted object as a string. The saved pre-deferral ASAN
binary reports the same heap-buffer-overflow on the minimal case. A failed
conversion now leaves the join before sizing or allocation and resumes the
exception handler, including across activation changes and `finally`.
Fresh optimized threaded ASAN with GC stress, GC verification and pool bypass
passes the focused join fixtures and the minimal exception repro. A fresh
NONANBOX build passes the new fixture and repro; restored production and debug
binaries match the measured hashes.

### Length-only template allocation elimination

`STRJOIN_LENGTH` uses the ordinary join's conversions and byte-length limit,
then adds each part's UTF-16 length instead of allocating a result string.
The compiler reuses the move-elimination liveness arena to prove the join
result and its optional local copy have only a following `.length` reader.
Other readers, jump targets, try regions, dynamic environments, captured
locals and suspension retain ordinary joins. No rope representation or
materialization machinery is needed.

JavaScriptCore's rope strings retain their length independently of flattened
contents ([JSString.h, c768c171](https://raw.githubusercontent.com/WebKit/WebKit/c768c171021f611e519a7136b997cd4b21c388e1/Source/JavaScriptCore/runtime/JSString.h)).
Avoiding materialization for this proven single-reader case is a narrower
application inferred from that design. Boomkat keeps its existing string
representation.

Against `b2c07fa2`, the focused kernel improves from 27.63 to 13.48 ms (51.2%)
and the generic template benchmark from 92.52 to 69.98 ms (24.4%). The escaping
control changes by -2.9%; other runtime controls vary by -1.1% to +0.6%.
Babel and TypeScript compile checks change by 0.0% and -0.4%. The executable
grows by 16,576 bytes (0.7%); actual text grows by 3,408 bytes, crossing a
16 KB segment boundary. Debug size grows by 144 bytes. Samples, RSS and
binary hashes are in
[`join-length-changes.json`](../benchmarks/ast-optimization/es6/join-length-changes.json).
Disassembly verifies the escaping control retains its join. The generic
benchmark omits 600,000 final-string allocations; its nested inner join
still materializes a string. Both accumulated-result binaries print `20866670`.

The focused fixture agrees with Node and QuickJS and passes script, module
and unoptimized execution. It covers Unicode and lone surrogates, integer
limits, mixed primitives, copied substitutions, conversion exceptions,
reused destinations, branches, escaping results, closures and eval. The
local suite passes 576 scripts, 20 modules and companion checks. Fresh
threaded ASAN with GC stress, GC verification and pool bypass passes the
join fixtures and eligible/escaping kernels; a fresh NONANBOX build passes
the new fixture and eligible kernel.

### Rejected prototype first-link peeling

Peeling the first identity/shape validation out of `ic_resolve_owner` removes
the loop-entry check for a one-link prototype hit. Against `a37001c4`, seven
alternating pairs change `ic_proto` from 73.28 to 72.82 ms (-0.6%); other
controls vary by -0.3% to +0.8%. Executable size is unchanged. This does not
establish a useful gain, so the source change is removed. Compiler rows use
the same inspection binary and are timing controls, not a compile-impact
comparison. Results are in
[`proto-first-link-screen.json`](../benchmarks/ast-optimization/es6/proto-first-link-screen.json).

### Rejected async template liveness extension

Adding `STRJOIN` to the ordinary async analysis's positive opcode list uses
the existing consecutive-part read set. The focused 100,000-await kernel
changes from 66.18 to 65.21 ms (-1.5%); the generic promise control changes
by -0.2%. Other runtime controls vary by -1.2% to +0.8%, with no executable
growth. Compiler rows use the same inspection binary as a noise control.

Fresh profiling confirms copied registers fall from 700,000 to 400,000,
but saved span stays at 700,000 and allocation counts and GC cycles match.
Conservative destination liveness keeps a high property-result register in
the snapshot. The extension does not reduce saved storage or establish a
useful runtime gain, so it is removed. Raw profiles and measurements are in
[`await-template-screen.json`](../benchmarks/ast-optimization/es6/await-template-screen.json).
The restricted ordinary async masks remain; broader support needs reviewed
property definitions, exception edges and captured roots. Generator work
stays deferred at the user's request.

### Rejected block-local numeric common expressions

A bounded eight-entry cache reuses repeated arithmetic over proven Number
registers. Loads and unary plus establish types; writes invalidate entries
that read or retain their destination. Branch targets and unknown operations
clear the analysis, while uncaptured local Number values survive coercion
callbacks. Dynamic bindings, captured locals, arguments, suspension and wide
registers retain ordinary code. No opcode or runtime feedback is added.

Disassembly confirms one multiplication and one division become register
copies in the eligible kernel. The effectful object control retains both
coercions per call and prints `8400000:400000`. Against `a37001c4`, the kernel
improves from 55.14 to 53.41 ms (3.1%). The control changes by +0.8%; generic
runtime controls vary by -0.2% to +0.6%, with no useful shared gain. Babel and
TypeScript checks grow 0.7% and 0.4%; production/debug sizes grow 64/160 bytes.
The additional analysis and source are removed: this small targeted gain
does not justify another optimizer pass. Results are in
[`numeric-cse-screen.json`](../benchmarks/ast-optimization/es6/numeric-cse-screen.json).
Numeric result forwarding remains covered by the shared addition fusion.

### Investigation outcomes

Each of the ten categories has a measured retained implementation, rejected
trial or concrete scope decision. Broad SSA construction, speculative property
hoisting and general AST call expansion remain outside this implementation:
the retained paths remove identified work with local proofs and runtime guards.

| Candidate | Decision and evidence |
|---|---|
| 1. Primitive constant folding | Keep bounded AST folding; eligible kernels and compiler/runtime controls are recorded below. |
| 2. Binding propagation and dead execution | Keep register promotion, environment-store pruning, dead initialization removal and immutable parameter aliases; parameter aliases reduce `valstack_copy` by 8.4%. |
| 3. Common expressions and forwarding | Keep dependent numeric result forwarding; reject straight-line read forwarding (+8.8% on `valstack_copy`) and numeric CSE (3.1% on its kernel, generic controls flat). |
| 4. Loop work and repeated checks | Keep increment/comparison sharing: counted-loop kernels improve 13.2–39.3% and `ic_proto` 3.3%. Reject prototype first-link peeling. Unproved property/coercion hoisting stays out. |
| 5. Numeric specialization | Keep shared fastint/Number addition and loop paths; double/mixed addition kernels improve 22.6%/10.5%. Avoid broad type/range CFG metadata. |
| 6. Small callee inlining | Keep guarded direct results for trivial compiled callees, reducing `function_call` by 22.0%; dynamic target checks preserve replacement behavior without AST expansion. |
| 7. Parameter defaults | Keep direct AST emission; thunk, closure and call removal is measured below. |
| 8. Scalar replacement | Keep eligible fresh object/array patterns, rest-count elision, Map pair consumption and length-only template results; generic template time falls a further 24.4%. General escaping objects retain materialization. |
| 9. Suspension storage | Retain existing restricted ordinary async masks; reject the template extension because saved storage and allocations match. Generator optimization is deferred at the user's request. |
| 10. Adaptive bytecode | Reject guarded double-site feedback: its stable double kernel regresses 17.9%. |

The hot loops explain the general-hoisting boundary. `ic_proto` reads four
potentially observable properties; a stable key does not prove a data slot.
`function_call` performs dynamically resolved calls and `valstack_copy` is
primarily recursive. String/template construction depends on the changing
counter; converting an invariant unknown parameter can run user code on each
iteration. Literal strings and numeric loop bounds already load outside the
loop. Hoisting these remaining operations needs speculation and invalidation
machinery, beyond the local proofs retained here.

Rejected runtime and compiler code is removed. The final production build
matches the measured length-only-join hash, and debug runtime text matches
the reviewed inspection binary byte for byte. Final focused checks pass for
parameter aliases, increment/comparison, deferred integers and join length.

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

## Class initialization and temporary instances

The retained constructor fast path recognizes up to four parameter-to-property
stores. It uses the warmed absent-property caches to validate every store before
initializing a fresh object, avoiding the constructor activation. Base `super()`
shares that helper and its binding tail. Super reads use the ordinary property
cache and threaded getter entry with the actual receiver.

A guarded AST lowering also eliminates immediate `new C(args).getter` temporary
instances for small numeric getters on eligible base classes. Field reads borrow
argument registers; ordinary expression generation emits the arithmetic. A
single guard validates constructor/getter identities, prototype slots, numeric
arguments and all constructor stores. A miss takes the normal construction and
property read with the original staged arguments. Guard descriptors reuse
compiled-template storage and cache lifetime. The existing optimization-disable
flag covers this lowering; generic benchmark sources and discovery are unchanged.

Seven alternating measured pairs, after a discarded pair, compare prebuilt
`a9f66ceb` and candidate binaries. Whole-process medians:

| Workload | Baseline ms | Candidate ms |
|---|---:|---:|
| Full class benchmark | 281.96 | 159.36 |
| Constructor-only control | 87.52 | 61.53 |
| Derived getter control | 94.22 | 68.30 |
| Retained instances control | 30.63 | 26.07 |
| function_call | 26.27 | 24.89 |
| ic_proto | 73.67 | 73.62 |
| valstack_copy | 31.36 | 31.30 |
| string | 24.28 | 23.34 |
| template_literal | 69.80 | 71.57 |
| Babel compile | 264.04 | 265.34 |
| TypeScript compile | 627.42 | 628.30 |

The full class workload improves **43.5%**. Normal native binary growth is
**1,184 bytes**; debug binary growth is **2,528 bytes**. Compile controls are
within 0.5%. The template control is 2.5% slower in this run; other controls
are flat or faster. Raw samples, output hashes, peak RSS and binary hashes are
in [class-scalar-changes.json](../benchmarks/ast-optimization/es6/class-scalar-changes.json).

Timing individual calls after setup in six fresh processes, discarding the first,
shows where the remaining gap sits:

| Component | Baseline | Constructor/super fast paths | AST scalar lowering | QuickJS | Node |
|---|---:|---:|---:|---:|---:|
| New instance + getter, 1M | 119 ms | 86 ms | 27 ms | 118 ms | 3 ms |
| Method calls, 1M | 36 ms | 36 ms | 37 ms | 36 ms | 2 ms |
| Derived construction + getter, 500K | 139 ms | 92 ms | 92 ms | 117 ms | 4 ms |

All component outputs agree. [class-scalar-breakdown.json](../benchmarks/ast-optimization/es6/class-scalar-breakdown.json)
contains samples and source. The implemented scalar case is
[bench_class_scalar.js](../benchmarks/ast-optimization/es6/bench_class_scalar.js).
The separate hand-written [scalar probe](../benchmarks/ast-optimization/es6/class-scalar-probe.json)
is an allocation-free arithmetic bound, not an automatic transformation.

This is a **4.4×** base-instance component gain, not Node parity. Per-iteration
guards and interpreter arithmetic remain; derived scalar replacement and method
inlining are unimplemented. Keep this compact first lowering and pursue those
larger costs without introducing a separate arithmetic interpreter.

Validation: 579 local scripts, 20 module entries and their companion fixtures,
39 private-class fixtures; focused scalar/fallback and super-read fixtures agree
with Node and QuickJS. The narrow super test262 directory passes 93 tests and
skips one. Fresh optimized ASAN with GC_STRESS/GC_VERIFY/POOL_BYPASS and NONANBOX
pass all three focused fixtures; the scalar fixture also passes as a module.
The ASAN link uses the installed LLVM runtime because c3c's configured runtime
path is absent.

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

- [x] Record independent results and decisions for candidates 1–10.
- [x] Retain only justified changes; remove rejected prototype code and flags.
- [x] Document compile, runtime, memory and size impact of retained changes.

Research links use primary runtime documentation and source. CPython's AST
source is pinned to 3.13.0; several other links track maintained branches.
Record exact upstream revisions when implementing an experiment. The precedent
paragraphs report those sources; eligibility rules, ordering and expected
Boomkat opportunities are proposals inferred from the current code review.

# ES6 bytecode and VM performance review

Reviewed 2026-09-19 at `99a78cf2` on macOS arm64, C3 0.8.3.
QuickJS reports version 2025-09-13; its local source revision is `d73189d`.
The branch includes the environment reclamation work in plan 085.

The best opportunities remove environment allocations, string interning,
and iterator protocol overhead. Tight register loops already beat QuickJS
in the measured subcases. Another general dispatch rewrite is a lower priority.

## Measurements

Fresh `just build boomkat`, followed by `just bench-es6 3`:

| Benchmark | Boomkat | QuickJS | BK / QJS |
|---|---:|---:|---:|
| class | 1.14s | 0.27s | 4.2 |
| closure_capture | 0.22s | 0.14s | 1.6 |
| destructuring | 1.18s | 0.23s | 5.1 |
| forof | 0.35s | 0.05s | 7.0 |
| let_loop | 0.34s | 0.21s | 1.6 |
| promise | 0.71s | 0.22s | 3.2 |
| spread_rest | 0.77s | 0.17s | 4.5 |
| template_literal | 0.92s | 0.11s | 8.4 |
| Total | 5.63s | 1.40s | 4.0 |

Load average was 10.17. These are prioritization measurements, not a stable
performance baseline. The ES6 runner takes each engine's best of three and
runs all Boomkat repetitions before all QuickJS repetitions for a file,
despite its alternating-engines label. The `just bench` changes are included;
that recipe uses a separate runner and corpus.

To separate costs, temporary copies time each synchronous benchmark function
with `Date.now()`, retaining the original setup and call order. Three process
runs per engine alternate engines, reversing order on the middle repetition.
Selected minimum function times in milliseconds:

| Subcase | Boomkat | QuickJS |
|---|---:|---:|
| letLoop | 15 | 59 |
| letBody | 223 | 70 |
| capturedNotCalled | 32 | 60 |
| capturedAndCalled | 171 | 26 |
| constructAndCall | 550 | 117 |
| derived | 493 | 116 |
| withDefaults | 288 | 36 |
| overArray | 35 | 6 |
| byIndex | 6 | 6 |
| arraySpread | 359 | 59 |
| objectSpread | 88 | 68 |
| callWithRest | 115 | 18 |
| templates | 375 | 45 |
| concat | 323 | 42 |

Instrumentation changes the script, these minima are from separate runs,
and short cases have coarse clock resolution. Do not sum them or interpret
them as measured optimization gains. Promise subcases need completion-aware
timing and are excluded from this breakdown.

Two-second `sample` captures use copies with the main iteration count
multiplied by eight. Template execution has 511 top-of-stack samples in
`str_table_lookup`, 149 in `sweep_strings`, 56 in `str_table_insert`, and 52
in `str_table_grow`. The let-loop capture has substantial sweep, marking,
object allocation, and environment allocation activity. These captures cover
parts of the enlarged workloads, not a uniform sample of every subcase.

Temporary scripts, raw samples, bytecode dumps, and timing JSON are in
`/tmp/boomkat-speed-review/`. The bytecode dumps were generated at `13fd12f7`;
the compiler sources are unchanged between that revision and `99a78cf2`.

## 1. Remove empty block environments and register-only const stores

Sources: `src/compiler/context.c3:2142`,
`src/compiler/statements.c3:2145`, `src/vm/vm_control.c3:1318`.

The register-local pass removes some environment writes but leaves
`PUSH_LEX` and `POP_LEX`. A loop body containing only an uncaptured `let t`
still creates an environment and bindings object each iteration. `letBody`
is much slower than `letLoop`, and the allocation/GC sample supports pursuing
this path. The multiply in letBody is another difference, so the timing gap
is not entirely attributable to scopes.

`PUTLEX_C` deliberately survives the pass because const assignment errors
currently consult the environment. Consequently, uncaptured const locals
in templates, destructuring, and spread also populate runtime bindings.

First eliminate scopes proven empty after lowering. Then represent TDZ and
const write checks directly for register locals, allowing more scopes to
disappear. Track scope identity and all abrupt exits; a textual removal of
adjacent push/pop instructions is insufficient. Keep environments for direct
eval, dynamic lookup through with, captured bindings, and Annex B behavior.
Const assignment must evaluate its RHS and throw at the correct runtime point.

This is the broadest allocation opportunity. Environment reclamation bounds
retention, but allocating and collecting an unnecessary scope still costs time.

## 2. Keep concatenation temporaries out of the string table

Sources: `src/vm/vm_execute.c3:2355`, `src/heap.c3:4636`,
`src/compiler/expressions.c3:5504`, `src/hstring.c3:204`.

Short concatenation results generally enter the intern table. The accumulator
fast path requires a particular destination/source register relationship;
the template bytecode forms a chain of ADDs across different temporaries.
It also emits an ADD for the final empty literal in this benchmark.
Both the template and explicit-plus arms are slow, and sampling locates much
of the work in the string table.

Use refcounted, non-interned strings for general concatenation results and
intern when a property-key boundary requires canonical identity. Content
equality and deferred hashing already exist for non-interned strings, but
audit all pointer-equality assumptions and GC ownership before broadening use.
Then consider a string-only append/concat opcode and eliding empty literal
appends after the required substitution conversion.

Keep template ToString semantics distinct from ADD's ToPrimitive semantics.
Preserve left-to-right evaluation and conversion side effects; concatenation
fusion must not postpone conversions past later substitutions.

## 3. Inline simple destructuring defaults

Sources: `src/compiler/functions.c3:1511` and `:4181`.

For `const { a = 1, b = 2 } = { a: i }`, bytecode creates a closure and
calls it to produce the missing `b` value on every iteration. Its inner
function is `PUSH_LEX; LDINT 2; RET; POP_LEX`. The synthetic functions also
make the containing function look closure-bearing, restricting environment
elision.

Start with literal defaults emitted directly behind the undefined check.
Avoid registering a synthetic capture for a literal-only default. Longer term,
compile default expressions at their execution site with the correct lexical
context. Keep defaults lazy and preserve TDZ, inferred names, this, arguments,
new.target, super, and yield/await behavior for general expressions.

This is a small, concrete first compiler experiment with a clear bytecode oracle:
the literal-default path should contain no CLOSURE or CALL.

## 4. Make own-property caches reusable across instances

Sources: `src/vm/vm_execute_threaded.c3:701`,
`src/vm/vm_property.c3:880`, `src/hobject.c3:2723`.

The cache validates a shape, but also requires the receiver/owner's value
storage pointer to equal `cached_prop_alloc`, then loads `prop_value_ptr`.
Different live objects with the same shape therefore miss an own-property
cache when their storage differs. This matters for Point getter reads and
property reads from fresh destructuring objects.

For own data properties, validate the shape and generation, then access the
current receiver's `prop_values()[prop_idx]`. Preserve exotic-object checks,
property flags, and the prototype-chain guards for inherited accesses.
Apply the same reasoning to stores and the megamorphic cache. Measure cache
hits across distinct same-shape receivers rather than only repeated reads
from one object.

## 5. Share an allocation-free builtin iterator step

Sources: `src/vm/vm_control.c3:615`, `src/vm/vm_objects.c3:549` and `:765`,
`src/compiler/functions.c3:801`, `quickjs/quickjs.c:16553`.

ITER_NEXT_FAST already serves array destructuring and for-of. It handles
array/arguments value iterators with a validated builtin next method.
Map, Set, string, and other iterator cases use the generic protocol.
ARRSPRD and SPREAD_ARG have their own loops calling next and extracting
done/value from result objects, rather than sharing that fast step.

QuickJS's JS_IteratorNext2 provides a useful design reference: native iterator
functions return the value and done state separately, avoiding an intermediate
result object when called internally. Use a shared typed helper with explicit
handled/done/value outcomes, serving for-of, destructuring, and spread.
The externally observable next method must continue returning an object.

Validate the resolved iterator and next methods, and preserve holes/prototype
getters, mutations during iteration, Unicode code points, map-entry arrays,
and IteratorClose. A dense-array bulk copy is a later guarded specialization.
Threading the existing successful array step can follow, but avoiding protocol
work and allocation has wider coverage.

## 6. Allocate call environments only when the callee needs them

Sources: `src/compiler/context.c3:2601`, `src/vm/vm_calls.c3:3555` and
`:3969`, `src/vm/vm_property.c3:2368` and `:2640`.

Ordinary CALL and the reentrant call helper consult needs_env. NEW_OBJ,
SUPER_CALL, and the inspected setter frame paths allocate function scopes
unconditionally. Separately, can_skip_env rejects all arrows, even an arrow
such as `() => s` that only reads an enclosing binding and owns no locals.
Captured this is stored separately on the closure.

Unify the eligibility decision across call entry paths and allow simple
arrows to reuse their captured environment. Audit parameter publication and
body declarations before removing an allocation; changing just the predicate
can make a write land in a parent scope. Preserve arguments mapping, parameter
expression scopes, direct eval, lexical this/new.target, and derived constructor
initialization rules. The capturedAndCalled result makes simple-arrow calls
a higher priority than further optimizing capturedNotCalled arithmetic.

## 7. Reduce suspension allocation and register retention

Source: `src/vm/vm_generators.c3:609`.

The inspected await suspension allocates GeneratorState, saved register
storage, resume/reject functions, and a reaction object. It copies all
num_regs slots with refcount operations. Generator suspension also copies
registers, including temporaries whose values may be dead.

Explore one continuation per async invocation and explicit suspension-point
liveness maps. Reuse storage only when no outstanding job owns that state;
save the live slots and release dead references. Exception/finally continuations
must be included in liveness. Keep even already-resolved awaits asynchronous.
Profile individual promise subcases to separate this from then-chain costs
before selecting the first implementation.

## 8. Longer-term: indexed captured cells and compact cache metadata

GETVAR/PUTVAR_ASSIGN perform name/shape/environment checks for statically known
captures. QuickJS's JSVarRef and get_var_ref opcodes access indexed cells
directly (`quickjs/quickjs.c:442`, `:18635`). A capture vector with direct
GET_CAPTURE/SET_CAPTURE operations would remove repeated dynamic resolution
and allow closures to retain only needed bindings. Keep dynamic environments
for eval/with and preserve per-iteration binding identity. This is an
architectural project; first take the simpler call-environment wins.

At `src/compiler/context.c3:2645`, every compiled function allocates both a
property-cache array and a variable-cache array indexed by every bytecode
word. Most instructions cannot use either cache. The regexp cache similarly
reserves a slot per constant even without regexp literals.

First omit an entire cache family when no relevant opcode exists. Then consider
site-indexed compact arrays, including the multiword/fused instruction cases.
This reduces compiled-function memory; it is not yet a demonstrated major
source of ES6 runtime improvement. Update weak-cache invalidation, GC scanning,
reset, and destruction together. Closures share these arrays through their
CompiledFunction, so savings are per template, not per closure instance.

## Measurement prerequisites and implementation order

OP_PROFILE currently records instructions only after run_threaded_burst
returns (`src/vm/vm_execute.c3:2230`, `:2270`). There is no corresponding
record hook in the threaded handlers. Its singles/pairs omit successful
threaded execution and can join switch operations that were not adjacent.
Fix that coverage before using its output to choose superinstructions. Count
each logical instruction once, including bailout and quickened cases.

Use actual interleaving and finer process timing for the ES6 comparison.
Check process status and expected results, and add completion assertions for
promise benchmarks. The ordinary benchmark runner caches competitor results
by filename; invalidate those caches after workload or engine changes.

Suggested sequence: empty scopes, literal defaults, call-environment eligibility,
own-property cache slots, non-interned concat results, shared builtin iterator
steps, then continuation/capture architecture. Strings merit an early parallel
experiment if working with multiple developers because their sampled cost is
large and the implementation is mostly independent of scope lowering.

For each implementation, use a local semantic repro, just rosetta, and narrow
test262 directories matching the affected feature. Include GC-stress validation
for ownership changes. Compare unchanged benchmark scripts against an immutable
baseline binary, reporting absolute time and memory alongside ratios. None of
the proposed speedups has been measured: at the current aggregate ratio,
beating QuickJS requires roughly a 75% time reduction, so several broad wins
are needed.

## Experiment 1: empty lexical environments

The register-local pass removes all lexical pushes and pops when its existing
eligibility checks pass and no lexical binding, catch-parameter environment,
or depth-dependent environment operation remains. All exits lose their pops
together. Const/TDZ environments and functions with captures or direct eval
retain their scope layout. This is the empty-scope portion of opportunity 1;
register-only const enforcement remains separate work.

Three interleaved runs per engine, rotating the engine order each repetition,
compare an immutable baseline binary built at `99a78cf2` with this change.
Median whole-process times for the unchanged ES6 corpus:

| Benchmark | Baseline | Empty scopes elided | QuickJS |
|---|---:|---:|---:|
| class | 1.2227s | 1.2332s | 0.2869s |
| closure_capture | 0.2325s | 0.2292s | 0.1497s |
| destructuring | 1.2425s | 1.1920s | 0.2482s |
| forof | 0.3643s | 0.3661s | 0.0524s |
| let_loop | 0.3461s | 0.1594s | 0.2178s |
| promise | 0.7217s | 0.7207s | 0.2279s |
| spread_rest | 0.7790s | 0.7945s | 0.1812s |
| template_literal | 0.9316s | 0.9321s | 0.1165s |

The let-loop workload takes 54% less time and beats QuickJS in this run.
Other differences are small and need more evidence before attribution.
Disassembly confirms that letBody has no PUSH_LEX or POP_LEX instructions.
A separate maximum-RSS observation is essentially flat: 113,344,512 bytes
for the baseline and 113,606,656 for the candidate. The benchmark also retains
200,000 closures, so this is not an isolated empty-scope memory measurement.

Validation: 42 Rosetta cases; the local suite, including 435 plain scripts
and its module/error/robustness/TypeScript fixtures; and 888 test262 cases
across language/statements/{let,const,block,for,try}, all passing.
The new empty_lexical_environments.js fixture checks nested break/continue,
return/throw through finally, and retained const, TDZ, capture, and eval scopes.

## Experiment 2: literal destructuring defaults

The shared destructuring emitter recognizes a default thunk containing only
a literal load and a matching return. It emits the load into the binding
register behind the existing undefined check, copying constant-pool entries
to the enclosing function where needed. Other expressions keep their thunk
call. The withDefaults benchmark body contains direct loads for 1 and 2,
with no CLOSURE or CALL for either default.

Five interleaved runs, rotating engine order, compare against an immutable
binary containing experiment 1. Median whole-process destructuring times:
baseline 1.1851s, candidate 1.0667s, QuickJS 0.2398s. The candidate takes
10% less time. Synthetic function templates and the parent's conservative
has_closures classification remain; this experiment removes execution cost,
not their compilation or metadata cost.

Validation: 42 Rosetta cases, the local suite including 436 plain scripts,
and 1,013 test262 cases across assignment/dstr, function/dstr, let, const,
and variable declarations, all passing. The focused fixture covers primitive
literals, present values, parameters, member and identifier assignments,
nested patterns, lazy side effects, function names, and fresh mutable defaults.

## Experiment 3: constructor environment eligibility

NEW_OBJ and SUPER_CALL consult the compiled function's needs_env flag before
allocating a function environment. Parameter/default/rest handling and the
lexical-chain setup keep their existing paths. This applies the ordinary-call
eligibility decision to these two constructor entry paths.

Five interleaved runs, rotating engine order, compare against an immutable
binary containing experiments 1 and 2. Median class benchmark times:
baseline 1.1556s, candidate 1.0316s, QuickJS 0.2780s. The candidate takes
11% less time.

Validation: 42 Rosetta cases; the local suite including 437 plain scripts;
and 4,518 passing test262 cases with 16 scope skips across class statements,
new, super, and new.target expressions. The focused fixture covers base and
derived parameters, new.target, defaults/rest, mapped arguments, captured
with scopes, named constructors, and preservation of enclosing bindings.

An additional exploratory check exposes an existing constructor-capture issue
in both the baseline and candidate: `function Capture(value) { this.read =
() => value; } print(new Capture(7).read());` throws ReferenceError instead
of printing 7. A direct eval of a class-constructor parameter also fails in
both binaries. These cases are not counted among the passing checks and need
a separate correctness fix.

## Experiment 4: defer concatenation interning

ADD and ADDI allocate concatenation results without hashing or interning them.
Property-key consumers canonicalize on demand; collection hashing materializes
the hash, and equality compares content when either operand is not interned.
Accumulator alias guards and geometric capacity growth remain in place.

The weak string registry uses a one-based header slot for constant-time
removal. Swapping entries and GC compaction update that slot; registry scans
contribute to the next GC budget. Proxy ownKeys canonicalizes its returned keys
before duplicate and target-invariant checks, preserving the identity contract
of property-key consumers and enumeration snapshots.

Five interleaved runs, rotating engine order, compare against an immutable
binary containing experiments 1–3. Times are whole-process medians:

| Workload | Baseline | Candidate | QuickJS | Speedup |
|---|---:|---:|---:|---:|
| ES6 template/concatenation | 0.9355s | 0.4252s | 0.1174s | 2.20× |
| ES5 string | 0.0495s | 0.0330s | 0.0223s | 1.50× |
| ES6 sum of per-workload medians | 5.3011s | 4.8091s | 1.4704s | 1.10× |

Other ES6 workloads differ by less than 2%. The string workload still takes
3.62× QuickJS's time; the aggregate takes 3.27×.

Three `/usr/bin/time -l` runs give median template peak RSS of 135,512,064 bytes
for the baseline and 54,214,656 for the candidate, a 60% reduction. Retained
repeated content trades memory for avoiding interning: an array containing
100,000 results of `'item ' + (i % 100)` raises peak RSS from 6,979,584 to
13,189,120 bytes. The registry slot also adds a uint to every string header;
allocator size classes determine the resulting allocation cost.

Validation: 42 Rosetta cases; all 438 local scripts and their module, error,
robustness, console, Temporal, and TypeScript fixture groups; and 878 passing
test262 cases with six scope skips across addition, template literals,
Proxy/ownKeys, Map, Set, and JSON. A freshly rebuilt ASAN GC-stress runner passes
the new concatenation identity fixture, proxy_ownkeys_gc_lifetime, and
engine/test_concat_accumulate_aliasing. The new fixture checks retained strings,
collection keys, property descriptors, JSON, Proxy key invariants, surrogate
pairs, lone surrogates, NULs, and accumulator aliases.


## Experiment 5: drain dense array iterators for spread

ARRSPRD and SPREAD_ARG invoke Symbol.iterator, then recognize an intrinsic
array-values iterator whose remaining range contains only dense data slots.
They reserve destination storage once and copy values with owned references.
The iterator is exhausted and releases its source, including when a custom
factory returns an externally visible or partially consumed iterator.

The shared guard checks the resolved next method, rejects proxy iterator
prototype chains, and refuses the undefined/hole sentinel. Custom methods,
indexed accessors, sparse arrays, and other iterator kinds use the generic
protocol. No user code executes between validation and the bulk copy.

Validation: 42 Rosetta cases, all 439 local scripts and fixture groups, and
306 passing test262 cases with three scope skips across array, call, new,
super, and Array.prototype.values. The new dense_array_spread fixture passes
in Boomkat and Node and covers custom factories, partially consumed iterators,
iterator getters, patched next methods, inherited indices, indexed accessors,
undefined, thrown factories, constructor spread, stack growth, and heap-valued
arguments. Fresh ASAN GC-stress builds pass that fixture, concatenation string
identity, and temproot_gc_lifetime.

Five interleaved runs, rotating engine order, compare against the immutable
4ed38276 binary. Whole-process spread/rest medians are 0.8104s baseline,
0.3262s candidate, and 0.1986s QuickJS: a 2.48× speedup. The ES6 sum of
per-workload medians falls from 4.8388s to 4.3929s (9.2%); QuickJS takes
1.5030s. Other ES6 workloads differ by less than 2.6%.

A separate five-run diagnostic times each spread/rest function with Date.now,
retaining setup and call order. Median subcase times:

| Operation | Baseline | Candidate | QuickJS | Speedup |
|---|---:|---:|---:|---:|
| Array spread | 410 ms | 79 ms | 65 ms | 5.19× |
| Call spread | 237 ms | 29 ms | 35 ms | 8.17× |
| Object spread | 97 ms | 95 ms | 75 ms | 1.02× |
| Rest parameters | 124 ms | 126 ms | 20 ms | 0.98× |

These instrumented subcases come from separate runs and must not be summed
with the whole-process table. Call spread beats QuickJS in this measurement;
array spread and the aggregate still trail it.

Three `/usr/bin/time -l` runs give median spread/rest peak RSS of 8,355,840
bytes for the baseline and 6,225,920 for the candidate, a 25% reduction.

## Follow-up bytecode review: allocation and materialization

Fresh boomkat_debug disassembly of the spread/rest, template, and destructuring
benchmarks identifies the following compiler opportunities. These are proposals,
not implemented gains:

- `arraySpread` emits PUSH_LEX at loop-body PC 5, PUTLEX_C at PC 15, and
  POP_LEX at PC 18. The uncaptured array local still forces a runtime binding
  and scope. Templates and destructuring show the same pattern. Register-local
  const/TDZ checks would let these scopes disappear without weakening errors.
- `arraySpread` emits INITPROP, ADDI, LDCONST("length"), PUTPROP after ARRSPRD.
  A register-length counterpart to SETALEN would avoid generic property setting
  at the end of spread literals. Any elimination must preserve trailing holes
  and empty spreads; their final length need not follow from stored elements.
- `restParams` has only DECLVAR, GETPROPC(args, "length"), and RET. Its rest
  array and environment are materialized during call setup. Compiler metadata
  for a nonescaping rest binding used solely for length could return the rest
  argument count directly, with ordinary setup retained for other uses.
- `spreadCall` moves the callee/receiver into r19/r20, loads the source into r21,
  copies it into r22, then writes spread arguments starting at r21. The overlap
  is intentional. An iterator-free copy must retain its source while those
  registers are overwritten; removing the source move alone is unsafe.
- The template body includes a final LDCONST/ADD for the trailing empty segment.
  Eliding an empty segment after the required substitution ToString is a small
  independent opportunity; fusing conversions must preserve their evaluation
  order relative to later substitutions.

Disassembly is in /tmp/boomkat-spread2{,-template,-destructuring}.bytecode.

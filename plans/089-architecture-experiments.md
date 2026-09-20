# Architecture experiments

Baseline: `6445c4b`. Run experiments in order, preserving an immutable binary
before each change. Sol agents at low reasoning implement bounded tasks;
the parent reviews, builds, validates, and measures each candidate. Experiment 3
uses Luna at xhigh reasoning at the user’s request. Keep a
change only with semantic validation and useful measured evidence. Record
unsuccessful experiments and their limitations too.

## Todos

- [x] 1. Remove empty arrow-call scopes — kept; see experiment 1.
- [x] 2. Reuse own-property caches across same-shape instances — kept; see experiment 2.
- [x] 3. Reuse indexed capture caches by stabilizing empty-arrow environments — kept.
- [x] 4. Shared internal built-in iterator stepping — kept.
- [x] 5. Measure rest-length call setup shortcut — rejected as too narrow.
- [x] 6. Reduce async suspension storage using register liveness — kept.
- [ ] 7. Resolved bindings and indexed captures — active; see plan 090.
- [ ] 8. Binding-aware register liveness and frame sizing.
- [ ] 9. Cumulative performance, memory, documentation, and regressions.

Compiler scratch-storage consolidation is deferred. The active work changes
binding representation across the compiler, bytecode, and VM.

Each item requires a bounded implementation experiment, a correctness decision,
and an explicit keep/reject result. A completed experiment does not imply the
entire architectural area has been solved. Avoid speculative speedup claims.

## Validation and measurement

Use unchanged benchmarks, alternating candidate and immutable baseline, with
no simultaneous builds or test jobs. Check exit status and output. Use
Rosetta, focused local semantic fixtures, and relevant test262 directories;
use fresh ASAN/GC-stress builds for ownership changes. Do not run full test262.
Track allocation counts where available; do not equate counts with peak RSS.

## Experiment 1: empty arrow lexical scopes — kept

A conservative zero-parameter, binding-free synchronous arrow can omit its
empty lexical scopes. Variable scopes, call entry, and needs_env remain
unchanged. Dynamic scope, nested closures, owned bindings, parameters, and
async/generator cases retain the regular path. Depth-sensitive operations
continue to preserve lexical scopes.

Five alternating runs of unchanged closure_capture: median 0.2375s baseline,
0.1678s candidate (29.3% less time). Validation: focused fixture in Boomkat
and Node, 42 Rosetta cases, full local suite, 343 arrow-function test262 cases.
Artifacts: `/tmp/boomkat-architecture-experiments/01-*`.

## Experiment 2: same-shape own-data read caches — kept

Own-data reads derive a value slot from the current receiver and cached index.
The shared helper retains receiver shape/generation checks, prototype-chain
validation, and storage checks for inherited/accessor cases. Stores and the
megamorphic cache retain their existing paths.

Five alternating runs against experiment 1: class 0.9166s to 0.7061s (23.0%
less time), destructuring 0.8745s to 0.7788s (10.9%), dedicated alternating
same-shape reads 0.1460s to 0.0519s (64.4%). Monomorphic reads changed -0.1%
and prototype reads -1.3%; these small differences are not attributed.
Validation: focused fixture in Boomkat/Node, 42 Rosetta cases, full local suite,
1,152 property-accessor/defineProperty test262 cases, and a fresh ASAN/GC-stress
run of the fixture. Artifacts: `/tmp/boomkat-architecture-experiments/02-*`.

## Experiment 3: stable environments for indexed capture caches — kept

The same narrow arrow class also omits empty variable scopes. GETVAR already
uses indexed VarIC slots; a stable captured environment lets its head-pointer
guard hit across calls. This reuses that representation rather than adding
new closure cells or changing needs_env.

The initial candidate failed an enclosing-eval shadowing repro (read 1 instead
of 2). New eval var/function bindings now clear variable caches before they
can shadow an earlier resolution. Existing binding writes keep caches. The
clear scans compiled functions and cache slots only for newly introduced eval
bindings, adding no checks to hot reads. This scan is a cost for eval-heavy
code that continually introduces distinct names.

Five alternating runs against experiment 2: closure_capture 0.1686s to 0.0971s
(42.4% less time). Class changed -1.9%, not attributed. Validation: focused
210-check fixture in Boomkat and Node; arrow fixture; 42 Rosetta cases; full
local suite; 699 arrow/eval test262 cases; fresh ASAN/GC-stress capture fixture.
Artifacts: `/tmp/boomkat-architecture-experiments/03-*`.

## Experiment 4: shared built-in iterator stepping — kept

Map, Set, and String iterators share an owned-value step helper. Intrinsic
for-of consumes that value directly, and public next wraps it in a result
object. Guards use the next method resolved by the loop, preserving overrides
and getters. Collection mutation, permanent exhaustion, entry pairs, and
Unicode code points use one implementation.

Five alternating runs against experiment 3: forof 0.2744s to 0.2370s (13.7%
less time); spread_rest changed 1.1%, not attributed. Validation: focused
fixture in Boomkat and Node, 42 Rosetta cases, full local suite, 770 iterator
and for-of test262 cases, fresh ASAN/GC-stress fixture. The existing public
IteratorResult prototype behavior is outside this experiment; its null
prototype is not asserted as correct by the new fixture.
Artifacts: `/tmp/boomkat-architecture-experiments/04-*`.

## Experiment 5: rest-length call shortcut — rejected

The prototype recognizes exactly a side-effect-free `return rest.length` body
and returns the actual excess argument count directly for non-tail calls.
Argument evaluation still runs; other call paths execute the original body.
Five alternating runs against experiment 4: spread_rest 0.2605s to 0.1535s
(41.1% less time), ordinary function_call unchanged at 0.0539s. The throwing
fixture passes in Boomkat and Node, including overridden iterator effects,
heap arguments, defaults, bound/call/apply, and class-constructor rejection.

This isolates substantial frame/rest-array setup cost, but the recognition is
too specific to the benchmark helper to justify permanent compiler metadata
and a call-path branch. Removed the prototype from the candidate. Broader
rest-use analysis and call-frame setup remain architectural work. No broad
suites or ASAN runs are claimed for this rejected prototype. Artifacts include
its immutable binary, source snapshots, patch, and timings under `05-*`.

## Experiment 6: bounded async saved-register liveness — kept

Eligible ordinary async functions reuse the move-elimination liveness solver
and store sparse masks keyed by await continuation. Snapshots copy live values
and stop at the highest live register. LOAD_RESUME overwrites its destination,
so that slot needs no saved value. Both restore paths fill omitted slots with
undefined using balanced reference ownership. Unknown/multiword bytecode,
exception handlers, captures, dynamic scope, and large functions fall back to
full snapshots. Generators retain their full snapshot path.

Five alternating runs against experiment 4: promise 0.9423s to 0.9471s (-0.5%),
checked await-tail 0.2938s to 0.2939s (unchanged). No timing gain is claimed.
The promise profiler records 160,000 suspensions, 1,010,000 full-frame registers,
560,000 registers in saved spans, and 460,000 copied values (54.5% fewer copies).
A checked workload with 12,000 simultaneously suspended calls and large dead
argument windows reduces median child peak RSS from 38,584,320 to 33,980,416
bytes (11.9%, five alternating runs). Its time changed 1.0%, not attributed.
Zero-length snapshots still allocate one TVal; logical span counters are not
allocation-byte counters.

Validation: expanded focused fixture in Boomkat and Node, including live
receivers/argument windows across await, branches, loops, and fallback paths;
42 Rosetta cases; full local suite; 244 async test262 cases; fresh ASAN/GC-stress
fixture. Retained for reduced snapshot work and demonstrated peak-memory
savings, not benchmark speed. Artifacts: `/tmp/boomkat-architecture-experiments/06-*`.

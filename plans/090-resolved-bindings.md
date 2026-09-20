# Resolved bindings and indexed captures

Baseline: `73e87af1`. The first complete performance experiment combines
binding resolution, indexed capture access, and allocation based on actual
binding requirements. Metadata alone does not establish a performance gain.

## Todos

- [x] Persist binding identities and capture classification through scope exit.
- [x] Remove fixed name-table limits from conservative capture discovery.
- [ ] Resolve references to local, captured, or dynamically resolved storage.
- [x] Define capture descriptors and shared mutable storage ownership.
- [x] Compile indexed captured reads and writes; implement VM execution.
- [x] Preserve shared sibling captures and transitive captures after return.
- [x] Allocate environments according to retained bindings.
- [x] Preserve TDZ, const, shadowing, loop iterations, eval, and with semantics.
- [x] Validate focused fixtures, local suite, Rosetta, narrow test262, fresh ASAN.
- [x] Measure alternating baseline/candidate runs and peak memory.
- [x] Document results and commit the validated stages.
- [ ] Extend binding-aware liveness and measure frame-size reductions.

## Assignment and validation

Sol low agents receive bounded implementation tasks and perform minimal
validation. Parent owns interfaces, integration, engine builds, suites, and
measurements. No simultaneous builds or measurements.

Compiler and runtime agents implement bounded storage changes; parent owns
interfaces, integration, validation, and measurement. The indexed-slot stage
is committed as `d52a966a`.

## Compact storage integration todos

- [x] Add a private shared value vector for eligible captured var/parameter bindings.
- [x] Compile defining-function accesses to indexed cell operations.
- [x] Retain cell owners through closure references and trace them during GC.
- [x] Reserve persistent cell storage below sliding call argument windows.
- [x] Record the active closure on native callback and constructor entry.
- [x] Promote false capture flags using compiled child-reference evidence.
- [x] Add fixtures for shared cells, callbacks, lifetime, and register promotion.
- [x] Validate the combined candidate, including fresh ASAN and bytecode goldens.
- [x] Measure speed and retained-closure memory against the committed stage.
- [x] Update architecture documentation and commit the validated candidate.

Lexical bindings requiring TDZ or fresh loop storage, transitive name lookup,
and dynamic scopes retain their environment paths. General register liveness
and frame compaction remain a separate experiment.

## First integration: indexed environment slots

Implemented per-binding producer retention and environment reuse, plus closure
descriptor vectors with GETCAP, PUTCAP, and PUTCAP_SNAP. The snapshot form keeps
its original reference register for fallback. Compiled child consumers retain
synthetic class bindings independently of token capture flags. Wide child
bytecode and dynamic capture fallback retain all parent bindings.

This is an intermediate representation: slots still belong to environment
objects, transitive references can remain name-based, and the enclosing
function still accesses its own captured bindings by name. It does not finish
the compact-storage or precise lexical-reference tasks above.

Five alternating final runs against 73e87af1: alternating independent closures
0.1991s to 0.1751s (12.0% less time); sibling read/write closures 0.2875s to
0.2638s (8.2%); mixed factory/local work 0.1760s to 0.1569s (10.9%);
transitive captures 0.2666s to 0.2537s (4.8%). Destructuring improves 9.0%.
The other ES6 benchmarks range from 2.9% more time to 2.8% less time;
these small differences are not attributed. No step-change claim.

In the unchanged ES5 suite, valstack_copy drops from 0.1536s to 0.0760s
(50.5% less time) with identical output. Its recursive function has several
uncaptured locals; producer pruning now lets calls reuse the enclosing
environment. The other ES5 results range from 3.2% more time to 4.7% less time.
The large result is specific to this allocation-heavy call pattern, not an
engine-wide multiplier.

Five alternating child peak-RSS runs show the descriptor cost: 50,000 retained
closures grow from 32,145,408 to 33,013,760 bytes (2.7%). Closure_capture,
forof, promise, and memory_heavy peaks remain within 1%. Compact storage must
address this retained-closure overhead rather than claiming memory savings.

Validation so far: 453 local scripts plus module/auxiliary checks, 42 Rosetta
cases, 1,174 narrow test262 cases, all 30 bytecode golden tests, and the
36-check capture fixture in Node, Boomkat, and a fresh ASAN/GC-stress build.
Two golden files record captured reads changing to GETCAP. Date and regexp
benchmark comparisons normalize their printed elapsed times only.

Next storage experiment: give eligible captured bindings a private indexed
value vector shared by their defining activation and closures. Reads in the
defining function then use slots too. Dynamic lookup and bindings requiring
fresh storage on scope re-entry keep environments until their scope identities
are represented explicitly.

Measure closure creation, captured reads and writes, alternating factory
instances, mixed captured/local work, and unchanged ES5/ES6 benchmarks.
Keep dynamic name resolution where static binding identity is insufficient.
Do not add sloppy-only optimizations or change the test262 skip list.

## Compact cells and register promotion

Eligible unique captured var and parameter bindings use a private dense value
vector shared by the defining activation and its immediate closures. The
compiler reserves its register before call temporaries; native callback and
constructor entries retain the active closure identity. Descriptor owners have
counted references and independent GC tracing. Unsupported operations,
same-named bindings, lexical re-entry, and transitive name references keep
their environment representation.

A separate pass refines token capture flags from compiled descendant name
consumers before bytecode optimization. Unreferenced unique var/parameter
bindings return to their home registers. The property-name fixture verifies
that child property keys do not force unrelated parent locals into scopes.

The first owner representation, a full Array object, increased retained
closure RSS by 15% and creation/read time by 18%. Rejected that representation.
The final owner is a plain internal object with zero property capacity and
only dense value storage; generic object tracing and teardown cover its cells.

Five alternating runs against d52a966a: a checked three-million-iteration
defining-function capture loop drops from 0.0789s to 0.0671s (14.9% less time).
Creating, retaining, and reading 50,000 closures takes 0.0270s versus 0.0272s,
which is effectively unchanged. Median peak RSS is 32,997,376 versus
33,292,288 bytes (0.9% higher). The four unchanged memory workloads stay within
1%. This experiment demonstrates faster defining-function captured access,
not a memory reduction or an engine-wide speedup.

The final unchanged ES5/ES6 suite ranges from 3.3% less time to 3.3% more time;
no broad gain is attributed. Independent closures, sibling read/write,
factory-local work, and transitive captures change by 0.5%, 2.8%, 0.5%, and
1.4% less time, respectively; these small differences are not attributed.

Validation: 455 local scripts plus module/auxiliary checks, 42 Rosetta cases,
1,174 focused test262 cases, 31 bytecode goldens with optimization-disabled
checks, and fresh ASAN/GC-stress runs of both capture fixtures and register
promotion. The final plain owner passes another full local sweep and fresh
ASAN run. Artifacts: `/tmp/boomkat-architecture-experiments/10-*`.

Remaining compiler work: explicit lexical-scope identities for precise
shadowing and per-iteration captures, transitive capture forwarding, and
binding-aware register liveness/frame sizing. These remain open; the compact
var/parameter representation does not imply they are implemented.

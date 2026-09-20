# Resolved bindings and indexed captures

Baseline: `73e87af1`. The first complete performance experiment combines
binding resolution, indexed capture access, and allocation based on actual
binding requirements. Metadata alone does not establish a performance gain.

## Todos

- [x] Persist binding identities and capture classification through scope exit.
- [x] Remove fixed name-table limits from conservative capture discovery.
- [ ] Resolve references to local, captured, or dynamically resolved storage.
- [ ] Define capture descriptors and shared mutable storage ownership.
- [ ] Compile indexed captured reads and writes; implement VM execution.
- [ ] Preserve shared sibling captures and transitive captures after return.
- [ ] Allocate environments according to retained bindings.
- [ ] Preserve TDZ, const, shadowing, loop iterations, eval, and with semantics.
- [ ] Validate focused fixtures, local suite, Rosetta, narrow test262, fresh ASAN.
- [ ] Measure alternating baseline/candidate runs and peak memory.
- [ ] Document results and commit the validated implementation.
- [ ] Extend binding-aware liveness and measure frame-size reductions.

## Assignment and validation

Sol low agents receive bounded implementation tasks and perform minimal
validation. Parent owns interfaces, integration, engine builds, suites, and
measurements. No simultaneous builds or measurements.

Compiler and runtime agents prepare bounded storage changes; parent owns
interfaces, integration, validation, and measurement. Experiment 10 drafts stay
outside the repository until the first integration is committed.

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

# Ordinary property stores and `this` dispatch

Baseline: `3ef9118e`. Platform and compiler are in `manifest.json`; binary
hashes and individual measurements are in `results.json`.

## Implementation

- Ordinary own-data property stores resolve `prop_idx` against the current
  receiver. The cache validates key, shape, generation, ownership and descriptor
  flags. Each store retains the heap's string ownership and GC write barrier.
  Proxies, module namespaces and other exotic classes take the generic path.
- `LDTHIS` runs in threaded dispatch when loading the binding requires neither
  collector shading nor string destruction. The fallback handles derived
  constructor TDZ errors and reference-management slow paths. Register root
  tracking remains active.

These changes add no object fields, cache fields, opcodes or allocations.
`runtime.patch` contains the production source changes.

## Measurements

`measure.py` runs sequentially, rotates and reverses binary order, and takes
five measurements after one warmup. Whole-process times include startup,
compilation and teardown. Internal phases use integer-millisecond `Date.now`.
The probes check their results; scene runs check the expected change count;
all class runs produce `CHECK 791665291667649000`.

| Whole-process median, ms | Baseline | `LDTHIS` only | Combined | QuickJS |
|---|---:|---:|---:|---:|
| Class phases | 676.12 | 653.59 | 643.39 | 275.52 |
| Function calls | 49.53 | 50.03 | 49.83 | 31.99 |
| Scene: 10k nodes / 300 frames | 138.18 | 137.57 | 138.24 | 77.55 |
| Scene: 100k nodes / 3000 frames | 1521.45 | 1518.49 | 1515.88 | 897.81 |

The class improvement is 4.8%; VDOM and ordinary function calls show no
meaningful gain. Median peak RSS for the 100k scene is 164.06 MiB baseline,
163.95 MiB combined, and 72.42 MiB QuickJS (macOS `wait4`).

Matched probes execute one million iterations. Calls, reads, methods,
getters, literals and constructors compute the same arithmetic result, but
also execute different bytecode, so subtracting their times does not isolate
a native routine's CPU cost.

| Internal phase median, ms | Baseline | `LDTHIS` only | Combined | QuickJS |
|---|---:|---:|---:|---:|
| Arithmetic | 13 | 13 | 13 | 11 |
| Own-property reads | 22 | 22 | 22 | 15 |
| Plain function calls | 35 | 35 | 35 | 19 |
| Prototype method calls | 67 | 64 | 64 | 29 |
| Prototype getters | 65 | 62 | 63 | 35 |
| Object literals | 63 | 60 | 60 | 40 |
| Constructors | 147 | 146 | 147 | 61 |
| Writes to one receiver | 13 | 13 | 13 | 7 |
| Writes across 1024 receivers | 43 | 43 | 27 | 11 |

The cache change reduces the many-receiver write phase by 37%. The literal
probe contains no `LDTHIS`; its small movement is not attributed to that
handler. Instruction layout and measurement variation affect these results.

The baseline opcode profile (`class-opcodes.txt`) records 14,000,002 `LDTHIS`
switch visits. **This profiler counts switch dispatch only:** successful
threaded instructions do not reach its hook. Its pairs can span threaded
bursts or function boundaries; they are not necessarily adjacent bytecode.
These counts identify fallback traffic, not elapsed CPU time.

### Repository benchmark recipes

`just bench-es6` is the relevant broad suite for the class/method changes.
The default recipe reports best-of-three whole-process times. Baseline and
candidate ran separately; its per-benchmark engine groups are sequential.

| ES6 benchmark, ms | Baseline | Combined | QuickJS (combined run) |
|---|---:|---:|---:|
| class | 668 | 637 | 275 |
| closure_capture | 103 | 103 | 149 |
| destructuring | 572 | 570 | 236 |
| forof | 138 | 140 | 52 |
| let_loop | 160 | 155 | 217 |
| promise | 382 | 381 | 228 |
| spread_rest | 243 | 236 | 181 |
| template_literal | 147 | 146 | 115 |
| Total | 2413 | 2368 | 1453 |

Class improves 4.6%; the sum improves 1.9%. For-of moves 2 ms slower and the
other changes outside class are small. `just bench` and `just bench-fast`
also completed; their raw logs are retained. Reference caches for `bench`
were cleared before the baseline run, then reused by the candidate run.
Those recipes average three and two runs respectively, with millisecond
shell timing. Arithmetic has inconsistent outliers between runs; do not
attribute those to this patch.
Seven alternating follow-up runs (`noise-check.json`) give arithmetic medians
of 35.37/35.26 ms and function-call medians of 50.34/49.78 ms for
baseline/candidate. Neither reproduces a regression.

### Frame latency

`build_clocks.py` builds isolated baseline and candidate binaries with the same
temporary monotonic `Date.now` hook. Production clock behavior is unchanged.
`frames.py` uses that hook for Boomkat and `performance.now()` for QuickJS,
rotates/reverses engine order, and retains five runs after one warmup. The
table gives medians of each run's percentiles and maximum, in milliseconds;
all samples and binary hashes are in `frames.json.gz`.

| Scene | Metric | Baseline | Combined | QuickJS |
|---|---|---:|---:|---:|
| 10k / 300 frames | p50 | 0.3765 | 0.3794 | 0.2120 |
| | p99 | 0.7368 | 0.7231 | 0.2300 |
| | maximum | 0.8109 | 0.8230 | 0.2360 |
| 100k / 3000 frames | p50 | 0.4296 | 0.4319 | 0.2580 |
| | p99 | 1.0888 | 1.1026 | 0.3080 |
| | maximum | 1.7209 | 1.7332 | 0.3690 |

The changes do not improve VDOM throughput or frame latency.

## Validation

- Fresh test262 runner: 1,256 passes, zero failures, two scope skips across
  `language/expressions/this`, `language/expressions/super`,
  `built-ins/Object/defineProperty`, and `built-ins/Proxy/set`.
- `just rosetta`: 42 passes.
- Module suite: 20 passes. The new regression also passes in the release
  binary, a fresh debug build using switch dispatch, and QuickJS.
- Fresh `boomkat_threaded_asan` built with `-O2 -D GC_STRESS -D GC_VERIFY
  -D POOL_BYPASS`: all 20 GC lifetime cases plus the new regression pass.
- `test/test_ordinary_property_fastpaths.js` checks different receivers,
  backing-storage growth, string and object ownership, descriptor changes,
  setters, readonly writes, proxy traps, mapped arguments, primitive and
  lexical `this`, and access before/after `super()`.

## Next experiments

1. **VDOM loop.** The ordinary-property changes have not improved frame
   latency. Attribute property access, object creation and collection in the
   10k/100k scene before choosing another VDOM fast path.
2. **Constructor setup.** The absent-property store cache brings 250k
   four-field constructors to 54 ms versus 41 ms in QuickJS, while empty
   constructors remain 20 ms versus 9 ms. Profile `NEW_OBJ` prototype lookup
   and activation setup separately, preserving `constructor.prototype`,
   subclass `new.target`, private fields and GC roots.

## Constructor field-store follow-up

Baseline: commit `edb25e2b` (the ordinary-property fast paths above). The
candidate avoids two pieces of repeated work on a missing-own-property write:

- The receiver miss was already established before insertion, so insertion
  now calls `put_prop_new` and skips `put_prop`'s duplicate own lookup. The
  key comes from `get_prop_key`, which interns it before this path.
- Prototype assignment lookup now returns the first descriptor and its
  writable flag in one walk. The old path performed a descriptor walk and a
  second walk for inherited readonly data properties. The separate scan for
  proxy and typed-array prototypes remains in place.

`constructor.patch` contains the runtime changes. The second change only adds
fields to the existing stack result; it adds no heap metadata or cache state.
The property insertion still uses `put_prop_new`, retaining existing shape
transitions, refcounts and GC barriers.

Sequential, rotated and reversed binary order; six measured runs after one
warmup; process timings include startup and teardown. Constructor probes use
250,000 iterations and validate identical checksums. Phase times use integer
milliseconds. `constructor-results.json` includes every run and binary hash.

| Probe phase, ms | Baseline | Skip duplicate own lookup | Both changes | QuickJS |
|---|---:|---:|---:|---:|
| Empty literal factory | 17 | 17 | 18 | 8 |
| Empty constructor | 19 | 20 | 20 | 9 |
| One-field constructor | 36 | 35 | 32 | 17 |
| One-field factory | 22 | 21 | 22 | 14 |
| Four-field constructor | 86 | 82 | 72 | 41 |
| Four-field factory | 37 | 37 | 38 | 39 |
| Eight-field constructor | 159 | 150 | 132 | 78 |
| Eight-field factory | 54 | 55 | 53 | 76 |
| Four fields assigned after empty construction | 80 | 76 | 67 | 41 |

The combined change improves the four-field constructor probe 16% and the
eight-field probe 17%; factory and empty-constructor timings stay flat. This
supports field assignment as the source of the probe gain.

| Class benchmark | Baseline | Skip duplicate own lookup | Both changes | QuickJS |
|---|---:|---:|---:|---:|
| Whole process | 648 | 635 | 586 | 275 |
| `constructAndCall(N)` | 299 | 290 | 266 | 118 |
| `methodCalls(N)` | 88 | 89 | 88 | 37 |
| `derived(N / 2)` | 258 | 252 | 230 | 118 |

`just bench-es6` reports class at 668 ms for the previous commit and 589 ms
for this candidate; suite total is 2.413 s and 2.323 s respectively. The
class result is 12% faster than the previous commit, while ordinary method
calls do not change. Frame latency was not rerun because these writes execute
during object creation, before the per-frame VDOM loop.

The insertion optimization relies on `get_prop_key` canonicalizing every
property key before `put_prop_new`. The single-walk result preserves
`find_accessor_proto`'s existing accessor result and adds metadata for a data
descriptor. Focused test262 results: 1,660 pass, zero failures, one scope skip
across assignment, Reflect.set, Object.defineProperty and Proxy.set; Rosetta
42 pass. The ordinary-property regression also passes with dynamic keys and
inherited readonly properties covered.

## Absent-property store IC

The pre-cache constructor candidate had repeated prototype and shape-table
work at every field store. A `PUTPROP` site now caches a successful absence
decision for ordinary string keys on plain objects. The hit checks the
receiver shape, extensibility, the shape-recycle epoch, each prototype's
identity and shape, and the chain's null terminator. It then calls the existing
`put_prop_new`, which retains property allocation, shape transitions,
refcounts, GC barriers and allocation-failure behavior. The cache reuses the
existing IC record; it adds no per-site storage. Proxy, typed-array, indexed,
private, descriptor-bearing and longer or exotic chains keep the full path.

The absent marker is excluded by the threaded `PUTPROP` slot cache before it
can be used as a property index. Regression cases cover a prototype setter
added after cache fill, prototype-chain extension, shape-ID reuse, and a
non-extensible receiver.

Six interleaved runs measured each 250k constructor phase and the class
benchmark against the pre-cache candidate and QuickJS. Values below are median
phase times in milliseconds; `property-add-ic-results.json` records each run
and the binary hashes.

| Probe phase | Before IC | With IC | QuickJS |
|---|---:|---:|---:|
| Empty constructor | 19 | 20 | 9 |
| One-field constructor | 32 | 27 | 17 |
| Four-field constructor | 73 | 54 | 41 |
| Eight-field constructor | 131 | 90 | 78 |
| Four-field factory | 38 | 37 | 39 |
| Eight-field factory | 54 | 53 | 76 |
| Four fields after empty construction | 68 | 48 | 41 |

The four-field and eight-field constructor phases improve 26% and 31%; factory
controls stay flat. In the class probe, `constructAndCall(N)` falls from 267 to
230 ms and `derived(N / 2)` from 235 to 197 ms; the method-call phase remains
flat at 91 versus 89 ms. Whole-process class time falls from 596 to 519 ms,
while QuickJS takes 276 ms. `just bench-es6 3` reports class at 494 ms versus
274 ms in QuickJS and a 2.192 s versus 1.430 s suite total. The constructor
store cache narrows the class construction gap; method and getter entry remain
the next target.

## Dense array indexed writes

The dense `PUTPROP` path interned the numeric key and searched the named
property table on every write, even for arrays whose indexed properties all
live in the dense part. It now skips that work while the existing sticky
`has_indexed_named_prop` flag is clear. Once an indexed key enters the named
table, the old lookup remains active so non-writable promoted properties keep
their assignment behavior. No object layout or new metadata was added.

The 250k-operation phase probe was run in rotated engine order, with two
warmups and seven measurements; internal phase times use integer-millisecond
`Date.now`. `indexed-write-fastpath-results.json` contains the samples and
binary hashes.

| Phase median, ms | Before | Candidate | QuickJS |
|---|---:|---:|---:|
| Push | 12 | 12 | 6 |
| Indexed read | 6 | 5 | 5 |
| Pop | 10 | 10 | 9 |
| Indexed write | 22 | 8 | 4 |
| Whole process | 54.84 | 38.57 | 26.15 |

`just bench 1` measures `bench_array` at 11 ms for Boomkat and 8 ms for
QuickJS. The indexed-write improvement accounts for most of the focused
probe's total gain; the push phase was then the slowest array phase.

## Array push length lookup

An ARRAY with no named properties has its authoritative `length` in
`array_len_ptr()`. `Array.prototype.push` now reads that field directly,
skipping the length-key lookup in `array_get_length_raw` and the second own
lookup in the dense append path. Arrays with named properties still use
`array_to_length`, which preserves accessor and array-like behavior.

The same 250k-operation phase probe ran with two warmups and seven rotated
measurements per binary. `array-push-length-fastpath-results.json` records
each sample and binary hash.

| Median, ms | Before | Candidate | QuickJS |
|---|---:|---:|---:|
| Push phase | 12 | 10 | 6 |
| Indexed read | 5 | 5 | 5 |
| Pop | 10 | 10 | 9 |
| Indexed write | 8 | 8 | 4 |
| Whole process | 37.82 | 36.52 | 25.95 |

The candidate lowers the focused process median by 3.4%; the other phases stay
flat. `just bench 3` reports `bench_array` at 10 ms for Boomkat, 8 ms for
QuickJS, and 39 ms for Duktape.

## One-argument intrinsic push call

The CALL handler appends directly when the callee is the exact intrinsic
`Array.prototype.push` and the receiver is an extensible ordinary array with
writable length, spare dense capacity, no named properties, and the standard
prototype chain with no indexed interception. The argument must be defined.
The path uses `set_array_idx` for ownership and GC barriers, then publishes the
new length. All other calls use the existing builtin path.

Seven alternating runs of the numeric array phases reduce the push phase
median from 10 to 8 ms. A bounded heap-value probe (3,000 arrays by 400 pushes)
moves from 51 to 40 ms. The repository `bench_array.js` process median falls
from 9.657 to 9.112 ms (5.6%); QuickJS measures 6.450 ms. Three retained VDOM
pairs are mixed (1,027 to 1,018 ms median), so this shortcut has no established
scene-level gain. `array-push-call-fastpath-results.json`,
`array-push-call-fastpath-bench-array.json`, and
`array-push-call-fastpath-vdom-results.json` contain samples and binary hashes.

`test/array_push_call_fastpath.js` checks object ownership, explicit undefined,
patched push, a getter returning the intrinsic, custom prototype setters, and
non-extensible arrays. It passes in release and a freshly built GC-stress
binary.

## Threaded one-argument intrinsic push

The threaded dispatcher now handles the same plain one-argument `CALL` shape
before leaving its burst. It checks the exact builtin identity and destination
register release eligibility, then reuses `array_push_one_fast`. Pending GC
work and every failed guard return to the switch before mutation, preserving
the call safepoint and generic semantics.

Seven alternating runs of `array-phases.js` move the push median from 9 to
8 ms; read stays at 5 ms, while pop and indexed-write medians vary by 1 ms.
The 1.2-million heap-valued push probe moves from 41 to 37 ms. Process medians
for `bench_array.js` move from 9.35 to 9.11 ms, and the compiled-call control
stays flat at 33.15/33.09 ms. `just bench 3` rounds `bench_array` to 10 ms for
Boomkat and 8 ms for QuickJS. This is a small array-specific gain; it does not
close the QuickJS gap. `threaded-array-push-results.json` records all samples
and binary hashes.

Validation: `built-ins/Array/prototype/push` passes 24/24, the call-expression
directory has 91 passes, zero failures and one scope skip, `just test-local`
passes, and the push fixture passes in a fresh GC-stress build.

## Threaded primitive and receiver returns

`RET` and `RETUNDEF` can pop directly inside threaded dispatch when the
returning and caller frames are ordinary compiled functions, there is no
pending GC work, catcher or for-in chain, mapped arguments, or
constructor/async/super state, and the register watermark is at most 16. The
shared register cleanup releases string references before the sliding window
is reused. Fast results are primitives or an object identical to the current
valid `this`; that receiver is shaded before cleanup and tracked in the
caller's register window. Other heap returns keep the switch path's complete
write-back handling. On a cross-function return the handler restores the
caller's code bounds, constants, property and variable IC bases, current
function and register window before it continues at the saved PC. Native and
re-entrant frames keep the switch path. `ColdCtx.dispatch_ptr` identifies the
active `Vm.run` state; `regs_base_ptr` publishes the restored register window.

The scaled cross-function probe ran in rotated order with two warmups and
seven measurements. It uses five million calls and checks its arithmetic
control against the call result. `threaded-cross-return-scaled-results.json`
records each sample and binary hash; phase times use integer-millisecond
`Date.now`.

| Median, ms | Same-function-only fast path | Cross-function fast path | QuickJS |
|---|---:|---:|---:|
| Arithmetic control | 66 | 65 | 127 |
| Cross-function call phase | 214 | 201 | 167 |
| Whole process | 283.58 | 269.59 | 296.75 |

The call phase improves 6.1%; arithmetic stays within 1 ms. The subsequent
short-register cleanup experiment lowers the million-call numeric method and
getter phases from 66.5/66 ms to 59.5/59 ms; QuickJS takes 29.5/34 ms.
`threaded-ret-cleanup-results.json` records five rotated runs and binary hashes.

In `class.js`, the `return this` path lowers `methodCalls(N)` from 89 to 84 ms.
Construction/getter phases move from 222 to 222 ms and derived construction
from 191 to 189.5 ms. Whole-process medians are 506.7 ms before the receiver
path, 500.9 ms with it, and 274.6 ms in QuickJS. `just bench-es6 3` reports the
class benchmark at 499 ms versus 274 ms and the suite at 2.199 s versus
1.432 s. The method-return change does not close the remaining call-entry gap.
`threaded-ret-cleanup-class-results.json` contains samples and binary hashes.

The return regression covers method and getter primitive results, a method
returning its receiver with a string argument, a retained temporary receiver,
and sloppy global `this`. `just test-local` passes 479 scripts and 20 module
fixtures; `just rosetta` passes 42 cases; `just test-gc-threaded` passes all 21
cases with `GC_STRESS`, `GC_VERIFY`, and ASAN.

A separate `es_delete_prop` experiment passed its known property index into
the removal routine to avoid a duplicate lookup. The delete phase measured
26 ms before and after, so the source change was discarded; the paired samples
remain in `object-delete-fastpath-results.json`.

## Compact ordinary-call entry experiment

A guarded exact-arity path for strict synchronous calls avoided the general
activation initializer. It reduced the focused method-call phase from 55 to
53 ms and the dedicated one-property method phase from 62 to 58 ms; direct
calls stayed at 44/44 and 50/50 ms. The `Point.translate` probe moved from 82
to 80 ms. The generalized path did not improve the ES6 suite total (2.210 s
versus 2.197 s in the preceding run), and it duplicated activation, receiver,
register and dispatch setup. The runtime keeps the shared initializer. The
rotated measurements are in `ordinary-entry-generalized-results.json`.

## Array destructuring iterator lookup

`ITER_OPEN_FAST` checked the iterator prototype chain and resolved its `next`
data property through `spread_intrinsic_next`, then performed the same
property lookup again to populate the `next` register. That helper can now
return the validated value to the caller. The fast path retains the proxy-chain
and depth checks, data-property requirement and builtin identity check;
accessors and patched methods continue through generic protocol handling.

`destructuring-phases.js` times the original ES6 benchmark's five phases and
checks each result. Seven rotated and reversed runs give these median times in
milliseconds:

| Phase | Before | Reused `next` | QuickJS |
|---|---:|---:|---:|
| Array pattern | 146 | 140 | 61 |
| Object pattern | 41 | 41 | 41 |
| Defaults | 50 | 50 | 36 |
| Rest element | 200 | 196 | 48 |
| Destructured parameters | 109 | 106 | 49 |
| Whole phase probe | 561.4 | 549.6 | 237.1 |

The original `bench_destructuring.js` process probe improves from 559.9 to
547.1 ms (2.3%). `just bench-es6 3` reports destructuring at 542 ms and the
suite total at 2.163 s, versus 235 ms and 1.427 s for QuickJS. The samples and
binary hashes are in `destructuring-phase-next-reuse-final-results.json` and
`destructuring-bench-results.json`. The regression
`test/destructuring_array_iterator_next_override.js` covers patched data and
accessor `next` methods; it also passes under GC stress. The focused test262
directory passes all 93 `language/statements/let/dstr` tests.

## Flat lexical array destructuring

`DESTRUCT_ARRAY_FAST` handles a two-name flat `let`/`const` array declaration
when both bindings occupy consecutive registers. It checks the source array,
Array.prototype's own `@@iterator` data property, the iterator's `next`, the
complete iterator prototype chain for `return`, and two dense primitive
elements before writing either binding. Any failed guard enters the existing
iterator lowering before stores begin. This keeps patched iterators, proxy
ancestors, accessors, holes, short arrays, and patterns outside the flat pair
shape on the full protocol path. Captured lexical bindings still use their
normal environment stores after the opcode writes the binding registers.

Seven alternating runs of `destructuring-phases.js` show the 500k pair-array
phase dropping from 143.5 to 78 ms (45.6%); the whole five-phase process drops
from 552.7 to 484.9 ms (12.3%). `just bench-es6 3` reports destructuring at
482 ms versus 237 ms in QuickJS, and the suite at 2.108 s versus 1.434 s. The
object/default/rest/parameter patterns do not select this opcode.
`destructuring-array-fast-results.json` records all samples and both binary
hashes; the baseline was built from the same source with this compiler
selection disabled. The focused regression also covers iterator `return`
methods and getters, an inherited proxy lookup, indexed accessors, short arrays,
holes with inherited getters, non-callable `return`, and closure-captured
bindings.

## Array rest property initialization

Array-rest collection defines each output index with `INITPROP` and increments
a persistent numeric index. This removes the per-value lookup and call of
`Array.prototype.push`, and makes inherited numeric setters unobservable as
required by CreateDataProperty. On seven alternating runs of
`destructuring-phases.js`, the rest phase falls from 202 to 167 ms (17.3%), and
the median combined time for all five phases falls from 467 to 431 ms (7.7%). The
whole-process median falls from 476.8 to 444.5 ms. The fixture checks patched
`push`, an inherited index setter, and nested assignment rest. Samples and
binary hashes are in `destructuring-rest-append-results.json`. `just bench-es6
3` now reports destructuring at 448 ms versus QuickJS at 235 ms, and the suite
at 2.048 s versus 1.422 s.

## Fast steps in array rest

Array rest uses `ITER_NEXT_FAST` before the generic `next()`/`done`/`value`
sequence. The fast result and the generic value share one `INITPROP` append;
both done paths clear the iterator state before the enclosing close. The
existing guards refuse holes and accessors without advancing the iterator, so
the generic path observes inherited getters and live length changes. Patched
`next`, custom iterators, and abrupt completions keep the protocol path.

Seven alternating runs compare this step against the CreateDataProperty-only
candidate. The rest phase falls from 172 to 96 ms (44.2%), and the median
combined five-phase time falls from 440 to 364 ms (17.3%); whole-process time
falls from 451.9 to 371.8 ms (17.7%). `just bench-es6 3` reports destructuring
at 369 ms versus QuickJS at 235 ms, and the suite at 1.971 s versus 1.432 s.
`destructuring-rest-iterator-fast-results.json` records the samples and binary
hashes. The fixture covers sparse arrays, an inherited getter that changes
length, a patched `next`, string code points, map entries, and GC stress.

## Flat lexical array rest

`DESTRUCT_ARRAY_REST_FAST` handles a flat lexical declaration with simple
bindings and a final rest binding. It requires a dense ordinary array with the
intrinsic iterator and `next`, and primitive values throughout the source. The
opcode reserves the result array once, copies its elements through the normal
array store, and writes the bindings before the compiler's ordinary lexical
stores. Iterator changes, holes, accessors, heap values, and other patterns
continue through iterator lowering.

Seven alternating runs of `destructuring-phases.js` reduce the rest phase from
86 to 34 ms; the whole process moves from 295 to 241 ms. `just bench-es6 3`
reduces the destructuring row from 292 to 244 ms, against 234 ms in QuickJS.
The suite total changes from 1.889 to 1.867 s, which is within the noise of
this broad run. No VDOM gain was established. The focused fixture covers short
and empty rests, captured bindings, custom iterators, holes, and fallback
values; it passes in release and fresh GC-stress builds. Samples and binary
hashes are in `array-rest-fast-results.json` and
`array-rest-fast-es6-results.json`.

## Rest parameter array construction

Call entry now builds rest arrays through one helper shared by ordinary calls,
generator creation, constructors, and `super()`. It reserves the dense array
once and copies the full argument window before publishing the rest register,
which may overlap the arguments. Defined values use `set_array_idx`; explicit
`undefined` becomes a named own property because dense `undefined` denotes a
hole. This keeps `hasOwnProperty`, enumeration, deletion, and inherited
indexed accessors correct.

Seven alternating runs of the isolated 400k-call phase reduce its internal
median from 103 to 65 ms (37%); whole-process medians are 106 and 68 ms. QuickJS
measures 17 ms internally. The current `just bench-es6 3` run reports
`spread_rest` at 200 ms versus 179 ms in QuickJS; suite totals are 1.790 and
1.415 s. `rest-parameter-fastpath-results.json` records every sample and the
three binary hashes. The regression covers explicit `undefined`, inherited
indexed accessors, deletion, fresh empty arrays, heap values, defaults,
`arguments`, indirect calls, generators, constructors, `super()`, and GC
stress. `language/rest-parameters` passes all 11 test262 tests.

## Threaded numeric array iteration

`ITER_NEXT_FAST` stays in threaded dispatch for a built-in array iterator over
a dense numeric own element with no indexed named properties. It checks the
captured `next` function on every step and rereads array length, so edits to
elements and length in the loop body remain visible. Holes, accessors, heap
values, explicit `undefined`, other iterator kinds, and completion use the
existing switch path. The handler advances its iterator only after the value
and destination register pass their guards.

Seven alternating runs of `forof.js` reduce the array-iteration phase from 13
to 10 ms; the indexed-loop control remains 2 ms. Whole-process medians move
from 112.5 to 109.9 ms. `just bench-es6 3` reports `forof` at 111 ms versus 50
ms in QuickJS, with suite totals of 1.790 and 1.415 s. The regression covers
live array growth and shrinkage, inherited getters, patched `next`, object and
`undefined` values, `break`, and thrown completions. All 741 selected
`language/statements/for-of` tests pass; the other 10 are scope skips.
`forof-array-thread-fastpath-results.json` contains the samples and binary
hashes.

## Threaded ASCII string iteration

`Heap.str_intern_normalized` caches and pins the existing interned string for
each one-byte ASCII character. `ITER_NEXT_FAST` uses that entry when the
iterator is a genuine String Iterator and its captured `next` is the built-in
method. A cache miss returns to the switch, which fills the cache; non-ASCII
characters stay on the switch path so CESU-8 decoding and surrogate pairs keep
their existing handling. Reset clears the pointers alongside the small-integer
string cache.

Seven alternating runs of 200,000-character probes reduce ASCII iteration from
17 to 14–15 ms. The repeated-`a`, alternating-`ab`, and `abcde` cases all
improve; indexed string reads stay flat, and the astral iteration control stays
at 10 ms. QuickJS takes 2 ms for each ASCII iteration phase. `just bench-es6 3`
moves `forof` from 110 to 106 ms versus 50 ms in QuickJS; class stays near
0.48 s versus 0.27 s. The complete local suite passes 493 scripts and 20
modules, Rosetta passes 42/42, the `for-of` Test262 directory passes 741/741,
String's `Symbol.iterator` tests pass 6/6, and the new fixture passes under a
fresh GC-stress build. Samples, allocation counters, and binary hashes are in
`string-char-iteration-results.json` and `string-char-threaded-results.json`.

## Flat array parameters

A single flat `[a, b]` parameter now uses `DESTRUCT_ARRAY_FAST` under the same
iterator and element guards as a lexical declaration. It keeps `PUTVAR` and
`GETVAR` for both names after extraction, so captures and direct eval read the
published parameter values. Parameters with defaults, rest, async or generator
entry, multiple formals, non-consecutive bindings, or observable iterator
behavior use the generic prologue.

The one-million-call probe compares a reused `[1, 2]` with indexed and scalar
controls, then compares allocating `[i, 1]` sources. Six alternating runs show
the reused destructured call falling from 254.5 to 100 ms (60.7%), and the
allocating call from 358 to 195 ms (45.5%). The indexed controls remain at
37/35.5 ms and 145.5/131.5 ms; scalar calls stay at 15 ms. QuickJS measures
100 ms for the reused pattern and 124 ms for the allocating pattern. The
candidate reaches parity on the reused input and narrows the allocating-input
gap. `destructuring-params-fast-results.json` contains each sample and binary
hash; `destructuring-params-baseline-results.json` records the initial
Boomkat/QuickJS phase comparison. The regression covers captures, direct eval,
reassignment, `arguments[0]`, missing arguments, defaults, patched `next`,
patched `return`, and a patched `Array.prototype[Symbol.iterator]`.

## Mixed object and array parameters

When a function has flat object-pattern leaves followed by a final `[a, b]`
parameter, the object reads and environment stores run first. The pair then
tries `DESTRUCT_ARRAY_FAST`; refusal compiles the whole pair through its own
IteratorClose guard. The fast path keeps both `PUTVAR`/`GETVAR` pairs. It is
limited to synchronous functions without defaults, rest, `with`, or direct
eval, with a root-level object pattern and a separate root-level array source.

Seven alternating runs of `destructuring-phases.js` compare the prior flat
parameter candidate, the mixed path with an empty outer guard, and the final
path. The `params` phase falls from 104 to 69 ms (33.7%), the five-phase sum
from 357 to 326 ms (8.7%), and process wall time from 364.1 to 330.3 ms
(9.3%). Removing the empty outer `TRY`/`finally` accounts for 80 to 69 ms in
the `params` phase. `destructuring-params-mixed-fast-results.json` records
all samples and binary hashes.

The regression checks successful extraction into captured bindings, object
getter order before custom iterator setup, IteratorClose on the fallback, and
a throwing second getter that leaves the array iterator unopened. The focused
test262 directory passes 19/19. `just bench-es6 3` reports destructuring at
330 ms versus QuickJS at 234 ms, with suite totals of 1.943 s and 1.424 s.

## Reproduce constructor experiments

```sh
python3 benchmarks/architecture-investigation/ordinary-calls/build_constructor_variants.py \
  --work-dir /tmp/boomkat-constructor-variants
python3 benchmarks/architecture-investigation/ordinary-calls/measure_constructor.py \
  --baseline /tmp/boomkat-constructor-variants/baseline \
  --putnew /tmp/boomkat-constructor-variants/putnew \
  --combined /tmp/boomkat-constructor-variants/combined \
  --quickjs out/qjs \
  --out benchmarks/architecture-investigation/ordinary-calls/constructor-results-reproduced.json
just bench-es6
```

VDOM gets no measurable improvement from this patch. Its ordinary calls,
matrix arithmetic, indexed access and allocation need their own attribution;
the class result does not establish a VDOM bottleneck.

## Reproduce

Preserve a release build of the baseline as `/tmp/boomkat-ordinary-calls/baseline`
and the candidate as `/tmp/boomkat-ordinary-calls/combined` before measuring.
Run builds, benchmark comparisons and correctness suites sequentially.

```sh
python3 benchmarks/architecture-investigation/ordinary-calls/measure.py \
  --binary baseline=/tmp/boomkat-ordinary-calls/baseline \
  --binary combined=/tmp/boomkat-ordinary-calls/combined \
  --binary quickjs=out/qjs --out /tmp/ordinary-results.json
just bench-es6
python3 benchmarks/architecture-investigation/ordinary-calls/build_clocks.py \
  --work-dir /tmp/boomkat-ordinary-calls
python3 benchmarks/architecture-investigation/ordinary-calls/frames.py \
  --work-dir /tmp/boomkat-ordinary-calls
```

## VDOM array and fixed-slot follow-ups

Array literals with a final dense numeric length reserve that capacity at
`NEWARR`, and threaded `INITPROP` handles numeric writes to empty dense slots.
For the 100k/3,000-frame scene, the capacity hint reduced median engine time
from 1,295 to 1,199 ms (7.4%). Numeric threaded `INITPROP` reduced it from
1,188 to 1,137 ms (4.3%) against the capacity-only binary. Seven runs of the
one-million-call matrix probe moved from 363 to 323 ms. The combined array
change reduced peak RSS from 171.9 to 143.7 MB. Pairwise samples and binary
hashes are in `array-capacity-only-results.json`,
`array-initprop-threading-results.json`, `array-initprop-mul-results.json`,
and `array-capacity-rss-results.json`.

A numeric constant-index read immediately after `LDINT` can read a dense array
slot in the same threaded handler. The fast path reuses the immediate and only
handles fast-int or number elements; heap values, holes and other cases use
the existing `GETPROP` path. A first implementation called the generic array
handler and regressed the matrix probe by 7.8%, so it was dropped. The inline
numeric path improves the probe from 321 to 310 ms (3.4%), with the integer
control unchanged at 28 ms. Three alternating scene pairs move engine time
from 1,125 to 1,101 ms (2.1%) and process wall time from 1.230 to 1.205 s;
worst-frame medians stay at 2 ms. Results are in
`array-read-fusion-array-capacity-mul-results.json`,
`array-read-fusion-scalar-control-results.json`,
`array-read-fusion-inline-mul-results.json`,
`array-read-fusion-inline-scalar-results.json`, and
`array-read-fusion-inline-vdom-results.json`.

Threaded `INIT_SLOT` handles a fast-int or number written to an empty in-range
slot on an ordinary object. It calls `Heap.store_slot`, so the GC barrier stays
on the path; heap-valued initializers use the existing reference-counted
handler. Seven alternating runs of `init-slot-numeric.js` improve the 200k
retained-point probe from 47 to 44 ms (6.4%). Three scene pairs move from
1,121 to 1,107 ms (1.25%); samples are mixed, worst-frame medians remain at
2 ms, and peak RSS is effectively flat at 143.75/143.77 MB. The class control
shows no regression (0.501 to 0.494 s). The detailed samples and binary hashes
are in `init-slot-numeric-probe-results.json`,
`init-slot-numeric-vdom-results.json`, and
`init-slot-numeric-class-control-results.json`.

`just bench-vdom 2` completes in 4.45 s. The current candidate measures 0.109 s
versus 0.073 s in QuickJS at 10k nodes (1.49x), and 1.206 s versus 0.838 s at
100k nodes (1.44x). Median worst frames are 1/1 ms and 2/1 ms respectively.

Validation for the array and object paths: array Test262 52/52, object-literal
Test262 1,170/1,170, Rosetta 42/42, and fresh GC-stress runs of the focused
array and fixed-slot regressions. The tests are
`test/array_literal_capacity_hint.js`,
`test/threaded_array_read_fusion.js`, and
`test/threaded_init_slot_numeric.js`.

## Six-element literal storage

Six-element array literals place the dense slots in the same dedicated pool
block as the header. Growth and the first named property migrate the slots to
ordinary backing storage; the header keeps its original pool identity through
that move. Other literal lengths use the existing allocation path. The inline
path removes one backing allocation and its initialization copy from the
VDOM matrix case.

The generic size-class prototype rounded the combined block to a larger class
and measured only about 1% faster in the matrix probe and retained scene. The
dedicated pool avoids that rounding. Seven alternating matrix-probe runs move
the one-million-call median from 316.0 to 311.2 ms (1.5%). Three paired
100k-node / 3,000-frame runs move median engine time from 1,074 to 1,033 ms
(3.8%); median peak RSS stays flat at 143.75 / 143.82 MB. Samples and hashes
are in `array-inline-literal-dedicated-mul-results.json` and
`array-inline-literal-dedicated-vdom-results.json`.

`just bench-vdom 2` completes in 4.27 s. The candidate measures 0.106 s versus
0.072 s in QuickJS at 10k nodes (1.47x), and 1.125 s versus 0.831 s at 100k
nodes (1.35x); median worst frames are 1/1 ms and 2/1 ms respectively.

Validation: `language/expressions/array` passes 52/52, Rosetta passes 42/42,
and the new migration fixture passes in release and a freshly built
GC-stress/allocator-bypass binary. The fixture covers named-property migration,
dense growth, holes, explicit `undefined`, and truncating then restoring
length.

## Direct string concatenation allocation

The string `ADD` paths allocate the final `HString` from the left and right
byte spans. They preserve deferred hashing, capacity lookahead and registry
ownership, and calculate ASCII, array-index and symbol metadata from the
completed bytes. The temporary assembly and interning path handles allocation
failure.

Fifteen interleaved runs compare the saved binary before this change, the
candidate and QuickJS. Whole-process medians include process startup and
teardown; `concat-spans-results.json` records every sample and binary hash.

| Whole-process median, ms | Before | Candidate | QuickJS |
|---|---:|---:|---:|
| `bench_string` | 37.2 | 34.1 | 20.8 |
| `bench_shape_no_call` | 34.0 | 33.4 | 18.0 |
| `bench_shape_stress` | 34.9 | 34.2 | 18.2 |
| Focused concat probe | 48.5 | 45.2 | 27.5 |

The focused probe's integer-millisecond phase medians are 17/15/10 for short
labels, 1/1/1 for long labels, 2/2/1 for independent 600-byte pairs, and
26/24/14 for short independent pairs (before/candidate/QuickJS). Its checksum
matches across all three engines. `bench_string` improves 8.2%, the focused
probe 6.7%, and the two shape cases 1.5% and 2.0%. QuickJS remains faster in
each whole-process workload.

`test/concat_string_identity.js` checks dynamic keys, CESU-8 surrogate and
non-ASCII content, and array-index metadata across the operand boundary. It
passes in release and a freshly rebuilt ASAN GC-stress binary. Rosetta passes
42/42 and `language/expressions/addition` passes 48/48.

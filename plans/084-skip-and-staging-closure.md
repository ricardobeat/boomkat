# Test262 Closure After Sloppy Mode

**Date:** 2026-09-15
**Status:** 📝 PLANNED

After plan 083 the suite sits at 48,331 pass / 171 fail (99.6%) with 4,961
skips. What is left falls into three kinds of work, in the order below: bugs
the normative suites miss (1-2), exclusions that are engine decisions rather
than scope boundaries (3-5), and proposals to pick up when they reach Stage 4
(6-8).

Items 1 and 2 are the ones with production signal: they are behavior the engine
claims and gets wrong. The rest are features it does not claim to have.

---

## Where the skips are

Every skip was tallied by reason on 2026-09-15, corpus-wide:

| Count | Reason | Disposition |
|---|---|---|
| 426 | `explicit-resource-management` + Disposable/SuppressedError | item 6 |
| 276 | `cross-realm`, `$262.agent`, `CanBlockIsFalse`, `IsHTMLDDA` | out |
| 222 | iterator helpers, second wave (4 tokens) | item 8 |
| 161 | Annex B String/Date/`legacy-regexp` | out |
| 89 | `await-dictionary` (`Promise.allKeyed`) | item 7 |
| 66 | `immutable-arraybuffer` | item 4 |
| 64 | `ShadowRealm` | out |
| 37 | `$DONOTEVALUATE` module-resolution negatives | out |
| 35 | `tail-call-optimization` | item 3 |
| 24 | `decorators` | out |
| 6 | `import-text` | item 5 |
| 2 | `SKIP_FILES` legacy `.caller` stack walk | out |

Items 3-5 take the three tokens excluded by engine decision only. The rest are
excluded because the spec text still moves (items 6-8) or because a
single-realm, single-agent engine has no such concept (see "Not in this plan").
Tail calls are the clearest case: §14.8 is shipped ES6 text, and
`docs/engine-scope.md:66` records it as a flat "Not implemented".

---

## 1. Clear the remaining `staging/sm` failures

171 tests. Low risk per fix, but the work is unbounded until surveyed.

`staging` holds nearly every remaining failure: 1,164 pass / 171 fail / 148
skip, all of them under `staging/sm`, the SpiderMonkey corpus donated in 2024
and still uncurated (`esid: pending`). Its front-matter carries almost no
feature tokens, so the skip list cannot filter it and the failures have to be
read individually.

**These are not SpiderMonkey quirks.** A sample of 14 reduced to ordinary ES
semantics the normative suites happen not to cover. Three found this way are
already fixed:

- `[[PreventExtensions]]` accepted a variable-length TypedArray (§10.4.5.1).
- `Object.values`/`entries`/`assign`, spread and `propertyIsEnumerable` all
  treated TypedArray elements as absent, since they are served lazily and live
  in neither the named table nor `array_part`.
- A dense `undefined` read back as a hole, so `b[2] = undefined` on a dense
  array, and any `undefined` argument, vanished from `in`, `Object.keys` and
  `forEach`.

Each had normative coverage that passed anyway: `built-ins/Object` was
3410/3410 throughout, and the ES5.1 `forEach`/`map`/`filter` tests for
`arr[1] = undefined` all construct via `new Array(10)`, which takes the sparse
path and never reaches the dense one. That is the shape of what is left here —
one spec behavior with two internal representations, tested on one of them.

Remaining leads from the same sample: iterator close not running
(`Array/from-iterator-close.js`, `Map/constructor-iterator-close.js`), a
missing rest-param duplicate rejection (`Function/rest-has-duplicated.js`),
`RegExp` `lastIndex` writability, and `class/boundFunctionSubclassing.js`.

**Steps.**

1. **Survey before fixing.** Run the suite with `--log`, reduce each failure to
   a one-line repro, and bucket by root cause. 171 failures across ~30
   directories will collapse to far fewer causes: `Array` (17), `RegExp` (16),
   `Function` (15) and `class` (13) lead the count, but the sample suggests
   shared causes cut across directories.
2. **Triage each bucket** into a real engine bug (fix it, and add a normative
   regression test, since by definition the normative suite missed it), a
   SpiderMonkey-specific extension (skip-list it with the reason), or a test
   that contradicts the normative corpus. The third case has precedent:
   `staging/sm/lexical-environment/block-scoped-functions-annex-b-arguments.js`
   is already skipped for contradicting
   `annexB/language/function-code/block-decl-func-skip-arguments.js`.
3. **Fix by bucket, not by test**, committing each cause separately.
4. **Handle the 4 non-assertion failures separately**: 2 MEMKILL
   (`sm/regress/regress-596805-2.js`, `regress-619003-1.js`, over the 2 GB
   worker cap) and 2 TIMEOUT (`sm/TypedArray/sort_large_countingsort.js`,
   `sm/statements/for-of-iterator-close-throw.js`). These are resource limits
   or perf problems, not semantics, and may be legitimate skips.

**Gate.** `just test262-suite staging` reaching 0 fail, with every skip added
carrying a written reason. Re-run the full suite afterwards: fixes to shared
machinery like `Object.values` touch far more than `staging`.

## 2. A Promise executor throw must reject, not propagate

6 `harness` tests, plus correctness everywhere `new Promise` wraps a throwing
executor. Medium risk: VM error-propagation plumbing.

ES2015 §27.2.3.1 step 9: when the executor passed to `new Promise` throws, the
constructor rejects the promise and returns it. It never propagates the throw.
The engine does both — it rejects the promise *and* lets the exception escape:

```js
try {
  var p = new Promise(function (resolve) { throw new TypeError("x"); });
  p.then(null, function (e) { print("rejected " + e.constructor.name); });
} catch (e) {
  print("constructor threw " + e.constructor.name);   // reached, and must not be
}
```

Both branches run: the promise is correctly rejected (the rejection tracker
reports it, since nothing handles it in time) and the constructor throws.

What is already ruled out: `builtin_promise_constructor`
(`src/builtins/promise.c3:929-942`) implements step 9 correctly, catching
`ctx.heap.has_error` after the executor call and routing it to reject. A JS
callback that throws through the same `heap.call_fn` propagates correctly
elsewhere (`[1].forEach(function () { throw ... })` is caught as expected), and
an executor calling `reject()` explicitly works. So the error survives the
call; the constructor's `has_error` check is not what fails. The remaining
suspect is `vm.throw_pending`, a second error channel that re-fires after the
builtin returns — `vm_call_fn_impl` populates both channels
(`src/vm/vm_execute.c3:486-489`) and `promise_clear_error_channels` exists
precisely because a stale entry on one of them resurfaces later.

**Steps.** Confirm which channel is still set when the constructor returns.
Clear the one the constructor consumes after routing it to reject, the way the
PromiseReactionJob path clears all channels before running a handler. Then
check the sibling constructors that call an executor — `promise_new_capability`
and the `Construct(C, [executor])` path at `promise.c3:719` — for the same gap.

**Gate.** `just test262-suite harness` (the six `asyncHelpers-throwsAsync-*`
tests below), `built-ins/Promise`, and the async fixtures in `test/`.

These six harness failures are all this one bug. `assert.throwsAsync` reports a
bad argument by throwing a `Test262Error` from inside a Promise executor, so
the test's own `await p` / `catch` never sees it:

```
asyncHelpers-throwsAsync-no-arg.js          asyncHelpers-throwsAsync-single-arg.js
asyncHelpers-throwsAsync-invalid-func.js    asyncHelpers-throwsAsync-func-throws-sync.js
asyncHelpers-throwsAsync-resolved-error.js  asyncHelpers-asyncTest-without-async-flag.js
```

The other two `harness` failures are not engine bugs and want a skip-list entry
with a reason rather than a fix:

- `detachArrayBuffer.js` asserts `$DETACHBUFFER` is undefined when the helper
  is not included, so calling it raises a ReferenceError. This engine defines
  `$262.detachArrayBuffer`, so nothing throws. The test contradicts the host
  surface rather than testing the engine.
- `nativeFunctionMatcher.js` passes standalone in both sloppy and strict mode,
  including on the runner's own concatenated file (`--keep`, exit 0). It fails
  only through the runner, so the defect is in the harness driver, not the
  engine. Diagnose it there before touching engine code.

---

## 3. Proper tail calls (ES2015 §14.8)

35 tests. High risk: it touches the core call path.

A call in tail position reuses the caller's frame, so unbounded mutual
recursion in tail position runs in constant stack. The tests assert
non-overflow at ~100,000 deep, so a faster-but-still-growing call path does not
pass them.

Tail position is syntactic, fixed at compile time (§14.8.1): the last
expression of a `return`, both arms of a conditional in tail position, the RHS
of `&&`/`||`/`??` in tail position, the last expression of a comma in tail
position, and the body of an arrow with an expression body. §14.8 applies to
strict code only, so the `is_strict` bit from plan 083 gates the feature.
Sloppy code keeps mapped `arguments` and the `.caller` walk, neither of which
survives frame reuse.

A call in a syntactic tail position is still not a tail call when the frame
holds state that must outlive it:

- inside a `try` block, or a `catch` with a `finally` still to run
- inside a `with` body, where the env chain stays live
- the callee is a direct `eval`
- the frame owns a generator or async suspension point
- a register-resident local is captured by an escaping closure (the plan
  038a/045 coherence gap; disqualify rather than reason about it)

**Steps.** Thread a `bool in_tail_position` through expression emission, set at
the §14.8.1 sites and cleared at every disqualifier, and emit `CALL_TAIL` /
`CALL_METHOD_TAIL` at a surviving site. Landing that alone with the new opcodes
aliased to the existing handlers is a no-op that can be verified green before
any VM work. Then make `CALL_TAIL` overwrite the caller's frame base with the
callee's arguments and jump rather than recurse, with the receiver,
`new.target`, and env chain following the callee. Cover it with a fixture
asserting 100,000-deep recursion in every §14.8.1 position, plus one per
disqualifier asserting the frame is not reused.

**Gate.** `just test262-dir language/statements/return`, the `tco-*` files
across `language/`, then a full `just rosetta`, since frame reuse is exactly
what breaks unrelated call paths. Drop `tail-call-optimization` from
`UNSUPPORTED_PATTERN` and update `docs/engine-scope.md:66` in the same commit.

**Cost.** An elided frame leaves no stack trace. That is spec-mandated, but it
changes error `.stack` output, and some `test/` fixtures pin it. Expect to
re-baseline a few.

## 4. Immutable ArrayBuffer

66 tests (61 in `built-ins`). Low risk. Needed by item 5, whose `bytes` type
returns one.

Adds `ArrayBuffer.prototype.transferToImmutable()`, an `immutable` getter, and
the rule that a TypedArray over an immutable buffer rejects every write and
cannot be detached or resized.

**Steps.** An `is_immutable` bit on the ArrayBuffer payload, coordinated with
plan 081's per-class `HObjectExtra` sizing. `transferToImmutable()` moves the
data block, detaches the source and marks the result, mirroring `transfer()`.
Then write rejection at every TypedArray and DataView store path, plus
detach/resize rejection.

An immutable buffer's data block never changes after construction, so a missed
store path is a silent correctness hole: enumerate them from `vm_property.c3`
rather than patching the ones a test catches.

Immutable buffers are never extensible, so this phase extends the
`ta_is_fixed_length` check already wired into both `preventExtensions` entry
points: an immutable buffer's views must be rejected there too.

**Gate.** `just test262-dir built-ins/ArrayBuffer` and `built-ins/TypedArray`.
Remove `immutable-arraybuffer` from `UNSUPPORTED_PATTERN`, and update plan
049's note at `plans/049-arraybuffer-typedarray-dataview.md:184`, which names
the same token.

## 5. Import Text and Import Bytes

6 `import-text` tests plus the `language/import/import-bytes/` files item 4
unblocks. Low risk, but it needs a host hook.

```js
import text  from './file.txt' with { type: 'text'  };  // a String
import bytes from './file.png' with { type: 'bytes' };  // an immutable ArrayBuffer
```

`CreateTextModule(source)` is `CreateDefaultExportSyntheticModule(source)`: the
host reads the file and wraps the contents in a synthetic module record whose
only export is `default`. `language/import/import-attributes/text-javascript.js`
is the case that matters — the imported file is valid JavaScript and must still
arrive as a string, unparsed.

**Steps.** `src/module.c3` builds every record by parsing source; add a second
constructor taking a ready value and a single `default` export, which links and
evaluates trivially. That is the bulk of the work and both types share it. Then
dispatch on `with { type }` at resolve time, with an unknown type a link-time
error, behind the same host interface as the existing loader so an embedder can
override the text (UTF-8) and bytes reads.

**Gate.** `just test262-dir language/import` and
`language/expressions/dynamic-import/import-attributes` — dynamic `import()`
takes the same attributes and must share the dispatch.

---

---

The next three are excluded because the spec text still moves, not by engine
decision. `docs/engine-scope.md` keeps Stage 3 proposals out and this plan does
not repeal that; the scoping is done in advance so each can start when its
proposal reaches Stage 4. Together they are 737 tests, the largest implementable
block in the corpus.

## 6. Explicit resource management (`using`)

~426 tests, the biggest single item in the skip list: 190
`explicit-resource-management` in `language`, plus `AsyncDisposableStack` (104),
`DisposableStack` (93), `SuppressedError` (22) and 17 more in `built-ins`.
High risk: a scope-exit protocol, not a library.

The library surface is the cheap half. `DisposableStack`,
`AsyncDisposableStack` and `SuppressedError` are ordinary objects, 219 of the
426 tests, and depend only on the `Symbol.dispose` / `Symbol.asyncDispose`
well-known symbols rather than on the syntax. They can land first and alone.

The declaration forms are the rest. `using x = expr` and `await using x = expr`
bind a disposable to a block scope and call `[Symbol.dispose]()` or
`[Symbol.asyncDispose]()` on scope exit, in reverse declaration order, on every
exit path including `throw`, `break`, `continue` and `return`. That is new
unwinding machinery in the compiler and VM: a per-block disposable stack
interacting with `try`/`finally` and generator suspension, with disposal errors
aggregating into `SuppressedError`. A frame owning pending disposals can never
be elided, so item 3 gains a disqualifier if both land.

## 7. `Promise.allKeyed` (`await-dictionary`)

89 tests. Low risk.

A combinator over an object of promises rather than an iterable, resolving to
an object with the same keys. Structurally `Promise.all` over `OwnPropertyKeys`
instead of an iterator, reusing the existing resolve-element-function
machinery. The test bulk is property-descriptor and key-ordering detail
(`symbol-keys.js`, `getownproperty-throws.js`,
`result-property-descriptors.js`), not new async semantics.

## 8. Iterator helpers, second wave

222 tests. Low to medium risk.

| Tests | Token | Surface |
|---|---|---|
| 82 | `joint-iteration` | `Iterator.zip`, `Iterator.zipKeyed` |
| 78 | `iterator-chunking` | `Iterator.prototype.chunks`, `.windows` |
| 44 | `iterator-includes` | `Iterator.prototype.includes` |
| 18 | `Iterator.prototype.join` | `.join` |

Four independent proposals over machinery the engine has: the first wave
(`map`/`filter`/`take`/`drop`/`flatMap`/`reduce`/`toArray`) reached Stage 4 in
ES2025 and ships, including the iterator-close-on-abrupt-completion
obligations these inherit. They advance separately, so take them one at a time.
`includes` and `join` are near-trivial; `zip`/`zipKeyed` carry the most
semantics, with multi-iterator close on partial exhaustion and the
`longest`/`shortest` padding modes.

---

## Not in this plan

- **The 2 `SKIP_FILES` `.caller` tests**
  (`language/arguments-object/10.6-13-a-{2,3}.js`) exercise the legacy
  `Function.prototype.caller` stack walk, not the §15.3.5.4 poison pill, which
  passes in all 21 of its tests. V8 restricts the walk in strict mode, and it
  is a deoptimization and information-leak wart; returning `null` stays right.
  Item 3 would make it unimplementable regardless, since an elided frame has
  no caller to report.
- **`decorators`** (24) and **`ShadowRealm`** (64) are Stage 3 and, unlike
  items 6-8, not adjacent to machinery the engine has.
- **Host-capability exclusions**, with nothing to implement on a single-realm,
  single-agent engine: `cross-realm` (179 corpus-wide, mostly the
  per-constructor `proto-from-ctor-realm.js` pattern), the `$262.agent`
  multi-worker harness (112), `CanBlockIsFalse` (2), `IsHTMLDDA` (29, the
  `document.all` slot, host-provided by definition), and the `$DONOTEVALUATE`
  module-resolution negatives (37).
- **Annex B legacy browser surface**: the String HTML wrappers (111), Date
  `getYear`/`setYear` (24) and `legacy-regexp` (26). The first two are nearly
  mechanical and could be picked up cheaply. `legacy-regexp` needs static state
  on the RegExp constructor updated on every match, which costs the match path
  for 26 tests of legacy surface. Revisit if a real workload wants them.

## Ordering

Items 1 and 2 come first: they are the cheapest way to find bugs the normative
suites miss, and item 1's survey step is worth running regardless of what else
gets implemented. Item 2 is self-contained.

Item 4 precedes item 5, which needs its immutable buffers. Item 3 is
independent, carries the regression risk, and should not share a commit with
either.

Items 6-8 are gated on proposals advancing. If item 6 lands, item 3 must treat
a frame with pending disposals as a tail-call disqualifier, and item 6's
library surface should precede its declaration forms.

**Totals:** items 1-2 clear 177 tests, items 3-5 close 107, items 6-8 track 737.

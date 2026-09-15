# Test262 Closure After Sloppy Mode

**Date:** 2026-09-15
**Status:** 📝 PLANNED

After plan 083 the suite sits at 48,331 pass / 172 fail (99.6%) with 5,077
skips. This plan covers what is left, in three groups:

- **Part I** — three exclusions that are engine decisions rather than scope
  boundaries: proper tail calls, immutable ArrayBuffer, Import Text/Bytes.
  107 tests, actionable now.
- **Part II** — Stage 3/2 proposals worth adopting once they settle. 737 tests,
  gated on each proposal reaching Stage 4.
- **Part III** — the 172 remaining `staging/sm` failures, which contain real
  engine bugs the normative suites do not cover.

The phases are independent except for the two prerequisites in §10.

---

## 1. Where the skips are

Every skip was tallied by reason on 2026-09-15, corpus-wide:

| Count | Reason | Disposition |
|---|---|---|
| 426 | `explicit-resource-management` + Disposable/SuppressedError | Phase D |
| 276 | `cross-realm`, `$262.agent`, `CanBlockIsFalse`, `IsHTMLDDA` | out — §9 |
| 222 | iterator helpers, second wave (4 tokens) | Phase F |
| 161 | Annex B String/Date/`legacy-regexp` | out — §9 |
| 89 | `await-dictionary` (`Promise.allKeyed`) | Phase E |
| 66 | `immutable-arraybuffer` | Phase B |
| 64 | `ShadowRealm` | out — §9 |
| 37 | `$DONOTEVALUATE` module-resolution negatives | out — §9 |
| 35 | `tail-call-optimization` | Phase A |
| 24 | `decorators` | out — §9 |
| 6 | `import-text` | Phase C |
| 2 | `SKIP_FILES` legacy `.caller` stack walk | out — §9 |

Part I takes the three tokens excluded by engine decision only. The rest are
excluded because the spec text still moves (Part II) or because a single-realm,
single-agent engine has no such concept (§9). Tail calls are the clearest case:
§14.8 is shipped ES6 text, and `docs/engine-scope.md:66` records it as a flat
"Not implemented".

---

# Part I — Engine decisions to revisit

## 2. Phase A — Proper tail calls (ES2015 §14.8)

**Yield:** 35 tests. **Risk:** high, it touches the core call path.

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

## 3. Phase B — Immutable ArrayBuffer

**Yield:** 66 tests (61 in `built-ins`). **Risk:** low.
**Prerequisite for Phase C**, whose `bytes` type returns one.

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

Immutable buffers are also never extensible, so this phase shares the
`ta_is_fixed_length` entry points that §8 covers. Do Phase B after §8 and the
`[[PreventExtensions]]` check is already in place.

**Gate.** `just test262-dir built-ins/ArrayBuffer` and `built-ins/TypedArray`.
Remove `immutable-arraybuffer` from `UNSUPPORTED_PATTERN`, and update plan
049's note at `plans/049-arraybuffer-typedarray-dataview.md:184`, which names
the same token.

## 4. Phase C — Import Text and Import Bytes

**Yield:** 6 `import-text` tests plus the `language/import/import-bytes/` files
Phase B unblocks. **Risk:** low, but it needs a host hook.

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

# Part II — Proposals to adopt when they land

`docs/engine-scope.md` keeps Stage 3 proposals out, and this plan does not
repeal that. What follows is scoping done in advance, so the trigger for each
phase is the proposal reaching Stage 4. Together they are 737 tests, the
largest implementable block in the corpus.

## 5. Phase D — Explicit resource management (`using`)

**Yield:** ~426 tests, the biggest single item in the skip list: 190
`explicit-resource-management` in `language`, plus `AsyncDisposableStack` (104),
`DisposableStack` (93), `SuppressedError` (22) and 17 more in `built-ins`.
**Risk:** high — a scope-exit protocol, not a library.

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
be elided, so Phase A gains a disqualifier if both land.

## 6. Phase E — `Promise.allKeyed` (`await-dictionary`)

**Yield:** 89 tests. **Risk:** low.

A combinator over an object of promises rather than an iterable, resolving to
an object with the same keys. Structurally `Promise.all` over `OwnPropertyKeys`
instead of an iterator, reusing the existing resolve-element-function
machinery. The test bulk is property-descriptor and key-ordering detail
(`symbol-keys.js`, `getownproperty-throws.js`,
`result-property-descriptors.js`), not new async semantics.

## 7. Phase F — Iterator helpers, second wave

**Yield:** 222 tests. **Risk:** low to medium.

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

# Part III — The staging sweep

## 8. Phase G — Clear the remaining `staging/sm` failures

**Yield:** 172 tests. **Risk:** low per fix, but the work is unbounded until
surveyed.

`staging` is the only suite with failures left: 1,163 pass / 172 fail / 148
skip, every failure under `staging/sm`, the SpiderMonkey corpus donated in 2024
and still uncurated (`esid: pending`). Its front-matter carries almost no
feature tokens, so the skip list cannot filter it and the failures have to be
read individually.

**These are not SpiderMonkey quirks.** A sample of 14 reduced to ordinary ES
semantics the normative suites happen not to cover. Confirmed against the
engine directly:

```js
Object.values(new Uint8Array([1, 2]))   // [] — should be [1, 2]
Object.entries(new Uint8Array([1]))     // [] — should be [["0", 1]]
```

`built-ins/Object` passes 3410/3410, so that bug reaches production untouched
by the normative suite. Others in the sample point at iterator close not
running (`Array/from-iterator-close.js`, `Map/constructor-iterator-close.js`),
a missing rest-param duplicate rejection (`Function/rest-has-duplicated.js`),
`RegExp` `lastIndex` writability, and `class/boundFunctionSubclassing.js`.
Two more of the same kind were already fixed out of this suite — the
`[[PreventExtensions]]` gap on variable-length TypedArrays, found the same way.

**Steps.**

1. **Survey before fixing.** Run the suite with `--log`, reduce each failure to
   a one-line repro, and bucket by root cause. 172 failures across ~30
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

This phase is the one with direct signal about production correctness. The
skips in Parts I and II are features the engine does not claim to have; these
are behaviors it claims and gets wrong.

---

## 9. Not in this plan

- **The 2 `SKIP_FILES` `.caller` tests**
  (`language/arguments-object/10.6-13-a-{2,3}.js`) exercise the legacy
  `Function.prototype.caller` stack walk, not the §15.3.5.4 poison pill, which
  passes in all 21 of its tests. V8 restricts the walk in strict mode, and it
  is a deoptimization and information-leak wart; returning `null` stays right.
  Phase A would make it unimplementable regardless, since an elided frame has
  no caller to report.
- **`decorators`** (24) and **`ShadowRealm`** (64) are Stage 3 and, unlike the
  Part II items, not adjacent to machinery the engine has.
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

## 10. Ordering

Part I: §8 → Phase B → Phase C, since Phase B extends the same non-extensible
TypedArray entry points §8 touches, and Phase C needs Phase B's immutable
buffers. Phase A is independent, carries the regression risk, and should not
share a commit with either.

Part II is gated on proposals advancing. If Phase D lands, Phase A must treat a
frame with pending disposals as a tail-call disqualifier, and Phase D's library
surface should precede its declaration forms.

Part III is independent of both and is the only part addressing behavior the
engine already claims. Its survey step should run first regardless of what
gets implemented, since it is the cheapest way to find bugs the normative
suites miss.

**Totals:** Part I closes 107 tests, Part II tracks 737, Part III clears 172.

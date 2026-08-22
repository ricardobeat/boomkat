# Plan 077: Closing the Cross-Engine test262 Failures

**Status:** In progress (session of 2026-08-22)
**Baseline:** 37,878 / 38,020 = **99.63%** on the cross-engine strict-only subset
**Rank:** 4th of 6 — jsc 99.94, v8 99.83, sm 99.67, **boomkat 99.63**, qjs 99.15, duk 41.18

This plan works through the failures found by the cross-engine comparison harness in
`../test262/tools/engine-compare`, which runs six engines over one fixed strict-mode
subset with byte-identical input and no per-engine skip list. Unlike
`scripts/run_test262.py`, that harness gives boomkat no exemptions: everything the other
five engines are held to, boomkat is held to as well.

Reproduce the baseline with:

```sh
cd ../test262/tools/engine-compare
./run.py --engines all --jobs 7          # all six
./run.py --engines boomkat --jobs 7      # boomkat alone, ~3 min
```

---

## A. The two buckets, and why only one of them is ours

Of 142 failures, **90 are boomkat-only** (all four other modern engines pass) and 52 are
shared with at least one production engine. The split matters because the shared bucket
is mostly *not* an engine defect:

| Shared-bucket cause | Count | Ours? |
| --- | ---: | --- |
| `Iterator.prototype.join` / iterator-helpers proposals | ~22 | No — unshipped everywhere |
| Intentionally-unhandled promise rejections | 24 | No — see A1 |
| `Promise.try`, `Promise.any` ctx-ctor, detached-buffer realm | ~6 | Partly, low value |

### A1. The unhandled-rejection false failures

24 shared failures report only `Unhandled promise rejection`. These tests deliberately
construct a rejected promise and never handle it; the assertions all pass. boomkat exits
1 and prints a diagnostic — and so do V8 (`rc=1`) and SpiderMonkey (`rc=3`). Only JSC
exits 0.

```sh
cd ../test262
cat harness/assert.js harness/sta.js test/built-ins/Promise/reject/ctx-ctor.js > /tmp/pr.js
../boomkat/out/boomkat /tmp/pr.js   # rc=1, "Unhandled promise rejection: undefined"
```

This is a **harness** gap, not an engine bug: the runner should not score a diagnostic on
stderr as failure when the test completed its assertions. Fixing it in the comparison
harness is worth ~24 tests for boomkat, V8 and SpiderMonkey alike, and changes no
ranking. Tracked here so it is not mistaken for engine work.

---

## B. The 90 boomkat-only failures

Symptom clustering, from the run above:

| Count | Symptom | Section |
| ---: | --- | --- |
| 21 | `BigInt value exceeds supported precision` | B1 |
| 19 | `SyntaxError in Function constructor` | B2 |
| 7 | function `name` descriptor mismatch | B4 |
| 6 | `undefined is not a function` | B5 |
| 6 | expected TypeError, nothing thrown | B4 |
| 5 | `Object.isExtensible` on primitives | **B3 — FIXED** |
| 5 | `SyntaxError in eval code` | B5 |
| 4 | expected Test262Error, nothing thrown | **B3 — partly fixed** |
| 3 | `VM error: vm::VM_ERROR (at execute)` | B6 |
| 4 | `Cannot create property 'touched' on number/boolean` | B5 |

### B1. Arbitrary-precision BigInt — 21 tests, out of scope

Every one of these is a literal beyond 2^127, rejected at parse time. Plan 056 chose
fixed-width int128 deliberately; closing these means a real bignum backend. **Not
scheduled.** They are counted honestly as failures rather than skipped, since the other
engines pass them.

### B2. Function-constructor duplicate parameters — 19 tests, architectural

```sh
Function('a', 'a', 'return a;')   # jsc: ok. boomkat: SyntaxError in Function constructor
```

A body built by `Function()` without its own `"use strict"` is **non-strict** code
(ES2015 §19.2.1.1.1), where duplicate parameter names are legal. boomkat compiles every
unit strict, so the parser rejects them. This is the same strict-only limit that
`SKIP_FILES` already records for the native runner; it cannot be fixed without a
non-strict compilation path. **Not scheduled** — recorded so the 19 are attributed to a
known design decision rather than looking like a parser bug.

### B3. Coercion and primitive-argument bugs — FIXED

Two genuine, self-contained defects, both now closed.

**`Object.isExtensible` on primitives** (5 tests). Returned `true` for every non-object;
ES2015 §19.1.2.13 step 1 requires `false`. The code carried an ES5-era comment
(§15.2.3.13, where non-objects threw) but implemented neither rule. The sibling methods
(`isFrozen`, `isSealed`, `freeze`, `seal`, `preventExtensions`, `getPrototypeOf`,
`keys`, …) were each checked against JSC and were already correct — `isExtensible` was
the lone outlier.

**`isNaN` / `isFinite` skipped ToNumber on objects** (4 tests, and a wrong-answer bug the
tests did not catch). `isNaN` used `builtin_to_number`, the non-VM coercion that cannot
call user code and answers NaN for any plain object; `isFinite` used `string_to_double`
and skipped ToNumber entirely. So a throwing `valueOf` never ran, *and* the results were
simply wrong:

```js
isNaN({valueOf: () => 42})     // was true,  must be false
isFinite({valueOf: () => 42})  // was false, must be true
```

Both now route through `builtin_to_number_vm`, which runs valueOf/toString, throws
TypeError for Symbol and BigInt, and propagates an abrupt completion. Output is
byte-identical to JSC across the matrix in `/tmp/tn.js`.

### B3a. Lightfuncs are not object-tagged — found in passing, NOT fixed

Fixing `isExtensible` surfaced a wider gap. boomkat stores built-in functions as
**lightfuncs**, a compact representation that is not OBJECT-tagged, so
`TVal.is_object()` is false for `JSON.parse`, `Math.max`, `Object.keys` and friends.
Several observable operations get this wrong:

```js
JSON.parse instanceof Function     // boomkat false, jsc true
Object(JSON.parse) === JSON.parse  // boomkat false, jsc true
Object.isFrozen(JSON.parse)        // boomkat true,  jsc false
Array.prototype.map instanceof Function   // true — allocated differently
```

`object.c3` already carries an explicit `is_lightfunc()` branch in `getPrototypeOf`,
`getOwnPropertyDescriptor`, `setPrototypeOf` and others, and `INSTANCEOF` has one in
`vm_execute.c3` — but `@@hasInstance`, `ToObject` and `isFrozen`/`isSealed` do not, so
coverage is piecemeal. The durable fix is to audit every operation that branches on
`is_object()` and decide, once, whether a lightfunc belongs on the object side (it
nearly always does).

This is how the `isExtensible` fix first regressed 7 `builtin.js` tests: the old code
returned `true` for everything non-object, which was accidentally right for lightfuncs
and wrong for primitives. `isExtensible` now handles lightfuncs explicitly. **The
remaining operations above are still wrong and are not covered by the cross-engine
subset**, which is why they cost 0 tests today and are recorded here instead.

### B4. Function `name` / property descriptors — 13 tests

Seven report `name descriptor value should be ; name value should be` and six expect a
TypeError that never arrives. Not yet diagnosed; the shape suggests
`SetFunctionName`/`DefinePropertyOrThrow` on accessor and computed-key methods.
**Next after B5.**

### B5. Direct eval inside class element initializers — ~15 tests

`SyntaxError in eval code`, `undefined is not a function`, and the
`Cannot create property 'touched' on number/boolean` cases cluster in
`language/statements/class/elements/*direct-eval*`. Plan 075 §D already records a VM
fault for private names in field initializers; these are likely the same root. Worth
diagnosing together with B6.

### B6. `VM_ERROR (at execute)` — 3 tests

```
language/statements/class/elements/private-getter-visible-to-direct-eval-on-initializer.js
```

An internal VM fault rather than a wrong answer, so the **highest-value item here**
regardless of test count: a fault reachable from ordinary source is a robustness problem
before it is a conformance one. Diagnose first.

---

## C. Order of work

1. **B3** — coercion/primitive bugs. ✅ Done, 9 tests.
2. **B6** — the 3 VM faults. A crash-class bug outranks its test count.
3. **B5** — class-element direct eval (~15), likely shares a root with B6.
4. **B4** — function `name`/descriptors (13).
5. **A1** — harness fix for unhandled rejections (24, benefits three engines).
6. **B1/B2** — left open, with the reason recorded above.

Realistic ceiling without a bignum backend or a non-strict compilation path:
142 − 21 − 19 = **102 addressable**, i.e. ~99.90%, which would place boomkat second
behind JSC.

---

## D. Progress

| Date | Change | Tests |
| --- | --- | ---: |
| 2026-08-22 | `$262.evalScript` returns the Script completion value (`b35071f6`) | — |
| 2026-08-22 | `Object.isExtensible` returns false for primitives | 5 |
| 2026-08-22 | `isNaN`/`isFinite` coerce via ToNumber (valueOf/toString, Symbol/BigInt throws) | 4 |
| 2026-08-22 | `isExtensible` handles lightfuncs (fixes the 7 `builtin.js` tests the above regressed) | 0 |

Full native suite after the above: **39,326 pass / 0 fail**.

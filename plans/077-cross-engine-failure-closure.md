# Plan 077: Closing the Cross-Engine test262 Failures

**Status:** In progress (session of 2026-08-22)
**Baseline:** 37,905 / 38,020 = **99.70%** on the cross-engine strict-only subset
**Rank:** 3rd of 6 — jsc 99.94, v8 99.83, **boomkat 99.70**, sm 99.67, qjs 99.15, duk 41.18

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

### B3a. Lightfuncs are not object-tagged — FIXED

Fixing `isExtensible` surfaced a wider gap. boomkat stores built-in functions as
**lightfuncs**, a compact representation that is not OBJECT-tagged, so
`TVal.is_object()` is false for `JSON.parse`, `Math.max`, `Object.keys` and friends.
Several observable operations get this wrong:

| Expression | boomkat | jsc | correct |
| --- | --- | --- | --- |
| `JSON.parse instanceof Function` | `false` | `true` | `true` |
| `Object(JSON.parse) === JSON.parse` | `false` | `true` | `true` |
| `typeof Object(JSON.parse)` | `"object"` | `"function"` | `"function"` |
| `Object.isFrozen(JSON.parse)` | `true` | `false` | `false` |
| `Array.prototype.map instanceof Function` | `true` | `true` | `true` |

boomkat is the wrong column in every row but the last. `ToObject(v)` returns `v`
unchanged when `v` is already an object (ES2015 §7.1.13, the Object case is "return the
argument"), and a function is an object — so `Object(JSON.parse)` must be the same
function. Because a lightfunc is not object-tagged, `ToObject` instead treats it as a
primitive and BOXES it, which is why `typeof` flips from `function` to `object`.
`Array.prototype.map` is allocated as a real HObject and behaves correctly throughout,
which is the clearest evidence the defect is the representation and not the operations.

#### Full extent, measured

A 30-operation probe run against boomkat, jsc and v8 (`/tmp/lf_probe.js`, kept as
`test/lightfunc_conformance.js` — see below) finds **15 operations where boomkat differs
from BOTH reference engines**:

| Operation | boomkat | jsc / v8 |
| --- | --- | --- |
| `Object(f) === f` | `false` | `true` |
| `typeof Object(f)` | `"object"` | `"function"` |
| `f instanceof Function` | `false` | `true` |
| `f instanceof Object` | `false` | `true` |
| `Object.isFrozen(f)` | `true` | `false` |
| `Object.isSealed(f)` | `true` | `false` |
| `Object.preventExtensions(f)` then `isExtensible` | `true` | `false` |
| `Reflect.ownKeys(f)` | TypeError | `length,name` |
| `Reflect.isExtensible(f)` | TypeError | `true` |
| `Reflect.getPrototypeOf(f)` | TypeError | `true` |
| `"name" in f` | TypeError | `true` |
| `Object.defineProperty(f, …)` | TypeError | works |
| `f.qq = 5` | TypeError | `5` |
| `new WeakSet().add(f)` | TypeError | `true` |
| `new Map().set(f,1).get(f)` | `undefined` | `1` |

The same probe over a real HObject function (`Array.prototype.map`) and a user function
matches jsc and v8 on **every one of the 30 operations**. The defect is therefore purely
the representation, not the individual operations.

#### Resolution

Fixed by a lazy promotion path cached by `Builtin` ordinal (`promote_builtin_fn` in
`src/builtins/core.c3`, cache on `Heap`, marked in `mark_roots`). The LIGHTFUNC form
stays canonical — `ToObject` returns the LIGHTFUNC unchanged, since the value the
program holds is that LIGHTFUNC and `Object(JSON.parse) === JSON.parse` must hold
against it — and promotion only supplies the object a write or a `Reflect` call needs.
Read paths consult the promoted object when one exists, so `JSON.parse.tag = 1` reads
back.

The Map/WeakSet rows turned out not to be a promotion problem at all: `strict_eq` and
`same_value_impl` had an `OBJECT` identity arm and no `LIGHTFUNC` one, falling through
to `default: false`. Promoting keys would have been the wrong fix, since a stored key
would be an OBJECT while lookup passes a LIGHTFUNC.

`test/lightfunc_conformance.js` now scores **57 / 0**, matching jsc and v8, and the
whole 11-row identity matrix (including identity across promotion, and via aliases) is
byte-identical to v8.

#### A bug class none of the memory tooling could see

The first complete version of the fix scored 57/57, passed the local suite, and passed
GC_STRESS with POOL_BYPASS and ASan — while test262 dropped to **39,195 / 131**, almost
all MEMKILL, and every one of those tests passed under `--single`.

`Heap.reset` — the per-test teardown in the test262 worker — frees every object, but the
promotion cache survived holding pointers into the heap it had just torn down. Because
the cache is a GC root, the next `mark_roots` followed each stale pointer into freed
memory.

`reset()` is reachable only from `cli/test262_runner.c3`, never from JS, so **no `.js`
test can exercise it**: this class passes standalone, passes conformance, and passes the
gc-stress lane, then appears only as widespread MEMKILL across a full corpus — where the
per-test `--single` reproduction also passes, which is a confusing signal to debug from.

The gap is now closed by `test/heap_reset_lifetime.js` plus
`scripts/run_heap_reset.sh` (`just test-heap-reset`), which feeds one test repeatedly to
`--worker` so each line forces a reset with the caches populated. Validated by deleting
the cache-clear in `Heap.reset`: the lane produces an ASan use-after-free report, and
restoring the clear returns it to 40/40 clean — seconds instead of a 40-minute corpus
run.

#### Why patching call sites is the wrong fix

`is_lightfunc()` already appears at **149 call sites across 25 files**. Every one is an
ad-hoc branch, and the 15 failures above are precisely the sites nobody thought to
cover — `Reflect.*`, the `in` operator, `[[Set]]`/`[[DefineOwnProperty]]`, and the
WeakSet/Map key paths. Adding a 150th branch fixes one row and leaves the class of bug
intact.

The correct fix is a **canonical promotion path**: the first time a lightfunc is used as
an object, materialise a real `HObject` for its builtin index, cache it keyed by that
index, and return the same object every time thereafter. Identity depends on this cache
— `JSON.parse === JSON.parse` is true today only because the builtin index *is* the
value, so promotion must not mint a second object. With promotion in place the ad-hoc
branches can be retired incrementally rather than extended.

Cost: one HObject per builtin actually used as an object, allocated lazily, so the
memory win that motivated lightfuncs is preserved for the common call-only case.

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

### B6. `VM_ERROR (at execute)` — 3 tests — FIXED, and it was a GC use-after-free

Fixed in `9b5e82fa`. The three tests were the reliably-timed repro for a **general
garbage-collection bug**, not a private-names or scoping defect.

`mark_activation_fields` gated the GC mark of `Activation.this_binding` on
`ACT_FLAG_THIS_OWNED | ACT_FLAG_CONSTRUCT`. `vm_call_fn_impl` sets neither: it
raw-assigns the receiver and borrows the caller's reference. That keeps the refcount
correct but never makes the slot a GC root, and the sweep frees whatever the mark phase
did not reach regardless of refcount. `vm_init_private_members` hands the part-built
instance to `__field_init__` as exactly such a borrowed receiver, reachable from no
register and no environment. Compiling the eval body allocates, which trips a safepoint
GC, and the instance is freed while live; its address is then recycled for a different
object, so `CHK_BRAND` tests a stranger. Object-serial tagging confirmed it: serial 504
was branded, serial 512 was checked, at the same address.

The fix adds `ACT_FLAG_THIS_VALID` — "live but borrowed" — and marks the slot under it.
Marking unconditionally is not available: `activation_begin` does not clear
`this_binding` and `call_fn` reuses `activations[0]` without zeroing, so an unflagged
slot holds stale bits. Widening `THIS_OWNED` instead would schedule a bogus decref,
since every release site tests that flag specifically.

**The scope dependence recorded in the first draft of this plan was a red herring.** The
"works inside a function" row was GC timing, not safety — a function-scoped class fails
identically once something allocates first:

```js
function f(){
  var pad=[]; for (var i=0;i<3000;i++) pad.push({x:i}); pad=null;
  class C { get #m(){ return "OK"; } v = eval("this.#m"); }
  var r=[]; for (var j=0;j<200;j++) r.push(new C().v);
  return r[199];
}
```

Verified: faults at `8517d974`, returns `OK` at `9b5e82fa`.

**This is broader than the three tests.** Any `call_fn` re-entry whose receiver is
reachable only through the borrowed frame was exposed — builtin-invoked callbacks,
getter/setter dispatch through `call_fn`, iterator-protocol calls. Re-measuring the
cross-engine subset after the fix confirms it: **142 → 115 failures, 99.63% → 99.70%**.
It closed **27 tests**, not the 3 that led to it.

#### Why the existing tooling missed it, and what to change

The engine already has the right instrument. `boomkat_gc_stress` (`-D GC_STRESS` plus
ASan) collects at every allocation, which is exactly how a missed root is meant to
surface. Two things blunted it:

1. **Coverage.** `scripts/run_gc_stress.sh` runs four files
   (`test_async_loops`, `async_gen_gc_lifetime`, `env_chain_gc_lifetime`,
   `proxy_ownkeys_gc_lifetime`). None exercises a class field initializer, which is the
   lifetime boundary this bug lives on. The script's own header says to add a test when
   it "exercises a new lifetime boundary" — that instruction was right and simply had a
   gap. A `class_fields_gc_lifetime.js` belongs in that list, along with the other
   `call_fn` re-entry shapes above.

2. **ASan cannot see these frees, which is the more important finding.** Objects are
   allocated from `FixedBlockPool` and `hobject_free` returns them to that pool's
   freelist rather than to libc. No `free()` ever happens, so ASan has nothing to poison
   and no use-after-free to report. Confirmed empirically: under
   `boomkat_gc_stress`, the minimal repro faults with `VM_ERROR` and ASan prints
   **nothing** — the recycled-address read is invisible to it.

   The fix is a debug-only allocator bypass: a build flag that makes `hobject_alloc`
   skip `pool_for_class` (taking the existing `pool_fallback` path, which already routes
   `hobject_free` to the real allocator) so every object is a genuine malloc/free pair
   and ASan regains full use-after-free coverage. The plumbing exists — `pool_fallback`
   is already a per-object flag and both paths are already exercised on pool exhaustion —
   so this is a small change that turns ASan from blind to authoritative for the whole
   object graph. **This is the highest-leverage follow-up in this plan**: it converts a
   class of silent, timing-dependent corruption into a deterministic abort at the exact
   offending read.

---

## C. Order of work

1. **B3** — coercion/primitive bugs. ✅ Done, 9 tests.
2. **B6** — the 3 VM faults. ✅ Done: a GC use-after-free, far broader than the 3 tests.
3. **B5** — class-element direct eval (~15). Re-measure first: B6 was a GC bug reachable
   from these same paths, so some of these may already be fixed.
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
| 2026-08-22 | GC root for borrowed `this_binding` in `call_fn` frames (`9b5e82fa`) — a use-after-free, not a scoping bug | 27 |
| 2026-08-22 | POOL_BYPASS so ASan can see pooled frees; `this_binding` setters; two new gc-stress lifetime tests (`db4b40b7`) | 0 |
| 2026-08-22 | LIGHTFUNC promotion path — builtins behave as real objects (`31d88c59`) | 0 in subset, 14 conformance rows |
| 2026-08-22 | `just test-heap-reset` lane for caches that cross `Heap.reset` | 0 |

Full native suite after the above: **39,326 pass / 0 fail**.

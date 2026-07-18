# Duktape C3 — Backlog

## Session 287 (2026-07-18) — eight parallel-agent clusters landed

**Baseline `out/s287.tsv`: 96.5% → 98.5%** (32,814 pass / 509 real-fail;
raw 32814/463/46CE). Verified the 40 "new" fails vs s286 in isolation:
**38 were batch-runner-segv flakes** (pass single-process — see memory
`batch-runner-segv-under-load`), 2 were genuine regressions from this session's
merges, both caught and FIXED (tree regression-free, corpus clean):
- TA: eager `newTarget.prototype` getter access before arg-validation throw —
  fixed `7d6b1c1` (defer proto resolution until after arg validation).
- O: plain async functions wrongly got a `.prototype` (the `is_generator()`
  gate catches async — flag conflation, see `ctx-is-async-conflation`) — fixed
  `359e879` (`is_generator() && !is_async()`, the codebase's existing idiom).

Merged to main (`7c47e9c..6c8d663`), ~549 real tests recovered + 39 reclassified:
- **P1 (`e40cdd9`) — the big one**: the 436 `RegExp/property-escapes` fails were
  NOT a regexp gap. Root cause was a general compiler register-aliasing bug —
  `assignment_expr` freed a live local var's own register (LIFO-recycled into the
  next alloc, clobbering the variable). 18-line fix, zero regressions. See
  memory `register-freeing-lifo` (dual-hazard note).
- **TA (`25d1ad1`)**: TypedArray Integer-Indexed exotic
  [[GetOwnProperty]]/[[DefineOwnProperty]]/[[Set]]/[[HasProperty]] — 46/49.
- **J (`d6cbc2d`)**: JSON.parse/stringify proxy-trap + abrupt-completion
  propagation — 16/19 (3 = Date.toJSON, separate builtin).
- **O (`2916ccd`)**: fn-name inference for object-literal computed keys/methods/
  accessors + generator `.prototype` — +24 (14 fn-name + 10 generator).
- **H1+T (`4a4226f`)**: tagged-template raw text/TRV/site-caching/freeze — 16/16.
  Hashbang was already implemented (28/29; last needs `with`).
- **S (`134ded9`)**: String.prototype Symbol.iterator coercion/constructability,
  ToInteger/ToPrimitive Symbol-throw, byte↔UTF-16 index fixes in regexp-backed
  String methods — 11 fixed (rest BigInt-wrapper-blocked).
- **R (`6c8d663`)**: recovered 5 STALE skip entries (top-level `this` IS global
  now — Date/prop-desc, Map/map, Set/set, WeakMap, WeakSet); Object 9/11,
  Promise 6/11; bonus generator/class fixes + a real object-shorthand compiler bug.
- **F1 (`1ce9eaa`)**: 38 sloppy-`this` apply/call tests correctly skip-listed
  (engine is strict-only by design — see memory `strict-only-engine`); deleted
  dead `fn_to_object_for_this` helper.

### Round 3 (in progress)
- [x] **C7a** (`afaabb7`): `\u` escapes in private names (`#name`) — wired the
  existing identifier-escape decoder into the HASH_IDENT scanner. +31
  (35→66/96). ZWJ/ZWNJ + ID_Start/Continue tables were already correct.
- [ ] **C7a-residual — `MAX_PRIVATE_NAMES = 64` capacity cap** (30 tests):
  `src/compiler/context.c3:1527` — `PrivateNameEntry[64]` is stack-allocated
  inline in the recursively-stack-allocated `CompilerContext`. The
  `start-unicode-*-class.js` generated tests declare 65–8327 unique private
  fields in one class, so decl #65 collides with slot 0 → misleading "duplicate
  private name" error. NOT a Unicode bug (repros with ASCII names). Raising the
  cap has stack-budget implications — needs a deliberate design (heap-allocate
  the table, or grow-on-demand). Round-4 candidate.

### Follow-ups surfaced this session
- [x] **Promise combinator GC-rooting** (~4) + **Promise no-handler microtask
  ordering** (1) — **fixed** by `34a5269` ("promise: fix stale vm.has_error
  channel and no-handler reaction timing"). Both bugs lived in the shared
  error/microtask plumbing rather than GC-rooting as originally suspected:
  1. `promise_clear_error_channels` cleared `heap.has_error` and
     `vm.throw_pending` but left `vm.has_error` (set by `vm_call_fn_impl` on a
     reentrant callee throw) stale — a later CALL-opcode dispatch then
     misreported its own clean result as a re-throw of the earlier error.
     `Promise.{all,any,allSettled,race}` IteratorClose / capability-reject
     error paths intermittently forwarded the wrong value or hung.
  2. `promise_trigger_reactions` settled no-handler reactions inline instead
     of queuing a `PromiseReactionJob` microtask, violating ES2015+ §27.2.2.1.
     Added `BUILTIN_PROMISE_IDENTITY` / `BUILTIN_PROMISE_THROWER` lightfuncs
     so the no-handler case reuses the has-handler job-enqueue path, fixing
     settle-order for chains with no rejection handler.
  All 11 originally-listed Promise combinator/no-handler tests now pass
  (verified 2026-07-18 via `scripts/run_single_test.sh` per file). See
  commit message for the unrelated bound-fn `this`-corruption regression
  (`9566c0c`) that this fix exposes.
- [ ] **`arguments` has no `Symbol.iterator`** — breaks `[...arguments]`/spread.
- [ ] **Iterators lack a shared prototype `next`** (Array/Map/Set/String): each
  instance gets its own `next`, so `Object.getPrototypeOf(iter).next = …`
  patching is silently ineffective across the whole iterator subsystem.
- [ ] **Batch-runner SIGSEGV under sustained load** (heap.reset/GC) — see memory
  `batch-runner-segv-under-load`; verify batch regressions in isolation.
- [ ] **BigInt wrapper** (`BigInt`/`BigInt64Array`/`BigUint64Array`): blocks
  ~14 String/Object/TypedArray tests. Large deferred feature.

---

Baseline: **session 286, `out/s286.tsv` (2026-07-17)** —
32,222 PASS / 1,155 NONPASS (incl. 42 unexpected CE) across 33,377
executable test262 tests = **96.5% pass** (variant-counted; the private
class member suites — ~1,372 tests — are enabled as of plan 054 P2-P5 and
pass at ~89%).

Regenerate with:
```
python3 scripts/run_test262.py --workers 4 --retry-fails --log out/sNNN.tsv
```
Deduped final-status (any-pass wins the retry):
```
awk -F'\t' '{if($1=="PASS")p[$2]=1; else n[$2]=$1} END{for(t in p)delete n[t]; for(t in n)print n[t]"\t"t}' out/sNNN.tsv | sort > /tmp/fails.tsv
```

**Session 284 recap** — three parallel worktree agents landed:
- Array.prototype (`0722cde` + merge `d93ba32`): 23/28 targeted tests fixed;
  5 residuals require `Reflect.get/has/defineProperty` (out of scope).
- Class semantics (`bb9ec51` + merge `d2fec0f`): 23/26 targeted tests
  fixed; 3 residuals = 2 private-fields (unimplemented at lexer) + 1 arrow
  lexical-`this` capture bug.
- RegExp Symbol.split (`33d7c21` + merge `4a5ba27`): 25/25 targeted tests
  fixed; the real root cause turned out to be a strict-mode leak in
  PUTPROP's getter-only-accessor throw + a CESU-8 pattern-compile bug
  in libregexp, not a spec rewrite.
- Fresh baseline before session: 20,210 PASS. After: 20,273 (+63 net).
- **Key methodology note** discovered mid-session: the previous baseline
  (`s283_v3.tsv`) was 3 days stale and understated failures by ~460 tests
  because it aggregated across multiple runs with different worker-skip
  behavior. **Always regenerate a same-day baseline before measuring
  deltas.** Batch-runner flakiness is real and ~10-15 tests per full run;
  verify apparent regressions in isolation before treating them as real.

Plan 052 (`plans/052-road-to-zero.md`) remains the strategic roadmap.

---

## Priority 1 — RegExp Unicode property escapes (436 tests — 50% of remaining fails)

- [ ] **U1 — Implement Unicode property escapes** (`\p{...}` / `\P{...}`
  in unicode-mode regexps). 436 tests under
  `built-ins/RegExp/property-escapes/generated/` all fail with the same
  pattern-compilation gap. libregexp has the property table infrastructure
  (`libregexp/unicode_wrapper.{h,c}` bridges libunicode), but `\p{...}` is
  either not recognised by our lexer/parser side or the property-name
  lookup isn't wired through. Investigate:
  - Does `lre_compile` in the vendored libregexp already support `\p{}`,
    and we're just filtering it out before compilation?
  - Which properties are missing tables (Grapheme_Base, Alphabetic, ASCII,
    Assigned, Bidi_Control, etc. — all 400+ scripts + binary properties)?
  - QuickJS's libunicode (already vendored) has full UCD 17.0 tables —
    port or wire through.
  - Tests: `awk '$2 ~ /^built-ins\/RegExp\/property-escapes\//' /tmp/fails.tsv`

## Priority 2 — Function.prototype call/apply sloppy-mode this (~28 tests)

- [ ] **F1 — Sloppy-mode this-substitution in `apply`/`call`** (28 tests).
  Flagged by the RegExp agent. `Function.prototype.apply()` and `.call()`
  don't perform the ES5 §10.4.3 substitution of the global object for
  `undefined`/`null` `this` when the target function is non-strict — leaves
  `this` as `undefined` instead of the global. Affects 14 apply + 14 call
  tests under `built-ins/Function/prototype/{apply,call}/`. Fix in
  `builtin_apply` / `builtin_call` in `src/builtins/function.c3`: check
  `!target.is_strict()` and substitute `heap.global_obj` for undef/null
  thisArg before invoking.

---

## Priority 3 — Remaining Array.prototype (5 — Reflect-blocked)

- [x] **A9 — Implement minimum `Reflect` surface**. Implemented the full ES6
  Reflect API (`get`, `set`, `has`, `deleteProperty`, `defineProperty`,
  `getOwnPropertyDescriptor`, `getPrototypeOf`, `setPrototypeOf`,
  `isExtensible`, `preventExtensions`, `apply`, `construct`, `ownKeys`).
  The `built-ins/Reflect/` directory is now enabled in phase 3 and the
  runner skip-list entries have been removed.

## Priority 3b — Remaining Class semantics (3)

- [x] **C7 — Private class members P2-P5 landed** (plan 054, session 286):
  fields, methods, accessors, static private all work; suites enabled in
  the runner. Remaining follow-ups from the s286 run (~106 fails + 40 CE):
  - [ ] **C7a — Unicode escapes in private names** (~40 CE): `#℘`,
    ZWJ/ZWNJ, non-ASCII `#names` — lexer HASH_IDENT scanner only takes
    ASCII identifier chars (`language/identifiers/*class-escaped*`,
    `*/private-accessor-name/*escape-sequence*`).
  - [ ] **C7b — Private names visible to direct eval** (~9):
    `*visible-to-direct-eval` — eval bodies compile fresh contexts without
    the enclosing private_names scope.
  - [ ] **C7c — double-initialisation TypeError** (4): stamping the brand
    on an object that already has it (return-override trick) must throw.
  - [ ] **C7d — misc**: proxy interaction (3), PUTPROP evaluation order (2),
    getter/setter own-property asserts (2), newtarget-in-eval errors (3).
  - [ ] **P6 `#x in obj`** and **P7 public fields** still pending
    (plan 054); their suites remain skipped.

- [ ] **C8 — Arrow-function lexical `this` capture bug** (1 test named,
  broader impact). `subclass/class-definition-null-proto-this` failure
  ultimately traces to arrow-function `this` being resolved from the
  *calling* activation (`ds.act.this_binding` at CALL site) instead of
  the arrow's *defining* activation. Reproducible outside classes
  entirely (`arr.forEach(x => this.foo)` breaks when invoked through
  an intermediate function). ~57 call sites reference `this_binding` —
  architectural investigation needed before touching.

---

## Priority 4 — Second-tier clusters

### Symbol.split / Symbol.matchAll et al — done
Cluster fully closed by session 284; nothing remains.

### RegExp (excluding property-escapes) — mostly done
Small residual after session 284: `built-ins/RegExp/CharacterClassEscapes`
(6). Sample after property-escapes lands (may share tables).

### String.prototype (18)
- [ ] **S1 — regexp-prototype-\* v/u flag** (5).
- [ ] **S2 — cstm-\* on BigInt primitive** (6).
- [ ] **S3 — indexOf ToInteger ordering** (3).
- [ ] **S4 — isWellFormed / toWellFormed ToString** (2).
- [ ] **S5 — Symbol.iterator on non-obj-coercible** (2).

### Sloppy-mode `var` + eval (15+8+8 = 31)
- [ ] **L1 — Sloppy-mode var declaration semantics** (15 under
  `language/statements/variable/12.2.1-*-s.js` + `S12.2_A*`). Auto-
  vivification of undeclared identifiers into globals under sloppy mode.
- [ ] **L2 — eval-code direct** (8) + **L3 — eval-code indirect** (8):
  var-hoisting into caller / global scope from direct/indirect eval.

### Object / method-def name inference (14)
- [ ] **O1 — fn-name inference for accessors, arrow, class, gen** (9):
  `fn-name-{accessor-get,accessor-set,arrow,class,cover,fn,gen}`,
  `method-definition/fn-name-{fn,gen}`.
- [ ] **O2 — Computed accessor names, ToPropertyKey ordering** (3):
  `accessor-name-computed-err-to-prop-key`,
  `computed-property-name-topropertykey-before-value-evaluation`,
  `method-definition/yield-newline`.
- [ ] **O3 — Method-def name Symbol + generator proto** (2):
  `method-definition/generator-{name-prop-symbol,prototype-prop}`.

### Date.prototype (13)
- [ ] **D1 — Date algorithm gaps** (13). Enumerate after other clusters
  drop; likely `toISOString` extreme-value handling,
  `setFullYear` argument ToNumber semantics, `toJSON` abrupt propagation.

### Tagged templates (11)
- [ ] **T1 — Site caching** (5).
- [ ] **T2 — Frozen template object** (3).
- [ ] **T3 — Invalid escapes → undefined cooked** (1).
- [ ] **T4 — misc** (2).

### Symbol.prototype (9)
- [ ] **Y1 — Symbol.prototype cluster** (9):
  `constructor`, `description/*` (3), `Symbol.toPrimitive/*` (2),
  `Symbol.toStringTag`, `toString/*` (2). Sample when convenient.

### JSON parse + stringify (9+7=16)
- [ ] **J1 — JSON.parse reviver error propagation** (9):
  `revived-proxy{,revoked}`, `reviver-{array,object}-{define-prop,delete,
  length-coerce,length-get,own-keys}-err`.
- [ ] **J2 — JSON.stringify** (7): sample.

### Optional chaining (8) + Arrow function (8)
- [ ] **X1 — Optional chaining edges** (8).
- [ ] **X2 — Arrow function lexical scoping** (8): partially covered by C8.

### TypedArrayConstructors internals + ctors (15)
- [ ] **TA1 — Integer-Indexed [[DefineOwnProperty]]** (6).
- [ ] **TA2 — Integer-Indexed [[Set]] prototype chain** (2).
- [ ] **TA3 — ctors** (7): sample after TA1/TA2.

### Hashbang comments (7)
- [ ] **H1 — Full hashbang comment support** (7). Lexer addition; small.

### Generators (7 + 8 = 15)
- [ ] **G1 — Expression generators default-proto / prototype descriptor** (7):
  `default-proto`, `has-instance`, `prototype-own-properties`,
  `prototype-property-descriptor`, `prototype-typeof`,
  `prototype-uniqueness`, `prototype-value`.
- [ ] **G2 — statements/generators** (7): sample after G1.

### Long tail (~250 tests across ~130 dirs, <5 tests each)
- [ ] **Z — Long-tail cluster + fix**. Extract remaining rows from
  `/tmp/fails.tsv`, cluster by stderr signature
  (`awk` + `run_single_test.sh`), batch by root cause. Notable bins:
  - `built-ins/Promise/{race,any,prototype/finally}` (~10),
  - `Object/{seal,assign,prototype,defineProperty}` (~12),
  - `Set/Symbol.species` (4), `Array/Symbol.species` (~8),
  - `Number/prototype` (5), `Function/length` (6),
  - `language/expressions/super` (6),
  - `language/expressions/template-literal` (7),
  - `language/block-scope/leave` (4),
  - remaining `RegExp/CharacterClassEscapes` (6).

---

## Infrastructure

- [ ] **I1 — Flake budget**. Verified in session 284 that batch-runner
  flakes are ~10-15/run; the project memory on `batch-runner-flakiness-anatomy`
  is still accurate. Any "regression" against a saved baseline should be
  verified in isolation via `./scripts/run_single_test.sh` before being
  treated as real.
- [ ] **I2 — `$262.detachArrayBuffer` host hook**. Unblocks a fixed
  cluster of TypedArray callback tests.
- [ ] **I3 — CE:unexpected** (6). Enumerate and reclassify or fix:
  `awk '$1=="CE:unexpected"' /tmp/fails.tsv`.
- [ ] **I4 — Two-consecutive-run zero-fail gate**. Once <50 fails, run
  twice back-to-back before declaring done; enforce in CI.
- [ ] **I5 — Baseline hygiene**. `s283_v3.tsv` was aggregated over
  multiple runs and understated true fails by ~460. Any new baseline
  should be a single clean run; delete or archive multi-run aggregates.

---

## Non-goals (out of scope, tracked so they don't get reopened)

- **Reflect API** — currently runner-skipped by policy. If A9 (Priority 3)
  gets picked up, narrow the skip rather than lifting it entirely.
- **Sloppy-mode-only tests** — runner-skipped by policy.
- **Native UTF-16/Latin1 string storage**. Would replace CESU-8 for
  ~1.5x memory savings on non-ASCII and remove the per-regex-exec
  conversion; touches every string builtin and the GC. Big migration,
  not part of the 100% push.

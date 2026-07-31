# Plan 040: Road to 100% on the Targeted test262 Subset

**Status:** Active roadmap (session 250, 2026-07-05)
**Baseline:** 21,121–21,154 pass / 29,459 executable = **71.8%** (two full runs, ±33 run-to-run variance)
**Gap to 100%:** ~8,300 tests (6,297 runtime fails incl. 46 timeouts + 2,035 unexpected compile errors)

## What "100%" means

The targeted subset is every test the shared skip list does **not** exclude: 41,846 tests
under the phase directories, minus 12,390 skips (Annex B, intl402, staging, Stage-3
proposals, Proxy/BigInt/SAB/Atomics, noStrict, unsupported feature flags — rationale in
`docs/engine-scope.md`). That leaves **29,459 executable tests**; 100% means every
one of them passes (or is an expected-parse CE for `negative: phase: parse` tests).

Two legitimate escape valves, both curation rather than engine work:
- Tests that assume sloppy-mode behavior without a `noStrict` flag get added to
  `SKIP_FILES` in `scripts/run_test262.py` **with a per-file rationale comment** (existing
  precedent: the B04/B11/B17 entries).
- If we decide a feature family is permanently out of scope (as with async-iteration in
  B35), its feature flag moves to the skip list and the subset shrinks. Do this
  deliberately and document it here — silent shrinkage would make "100%" meaningless.

## How this baseline was measured

`scripts/run_test262.py` now takes `--log FILE` and writes one `RESULT<TAB>relpath` line
per executed test (PASS / FAIL / TIMEOUT / MEMKILL / CE:expected-parse /
CE:expected-runtime / CE:unexpected). The full run takes ~6–8 minutes with `--workers 4`.
This session's log is at `out/test262_results.tsv` (untracked); regenerate with:

```
python3 scripts/run_test262.py --workers 4 --log out/test262_results.tsv
```

Cluster failures with:
```
awk -F'\t' '$1=="FAIL"{print $2}' out/test262_results.tsv | xargs -n1 dirname | sort | uniq -c | sort -rn | head -30
```

Reproduce a single test with full harness + real error output:
```
bash test262_runner/run_single_test.sh built-ins/Array/prototype/map/15.4.4.19-4-15.js
bash test262_runner/run_single_test.sh <path> --keep   # emit combined file for just lldb / --trace-vm
```

## Per-phase baseline (session 250)

| Phase | Total | Pass | Fail | Skip | CE:unexpected |
|---|---|---|---|---|---|
| 0-1: Core VM | 2185 | 784 | 238 | 1096 | 64 |
| 1: Calling Convention & Closures | 426 | 211 | 114 | 90 | 11 |
| 2: Basic Operators | 1969 | 1196 | 112 | 563 | 98 |
| 3: Object System | 7766 | 5363 | 1050 | 1078 | 275 |
| 4: Error Handling & References | 402 | 141 | 64 | 103 | 94 |
| 5: Built-in Constructors | 8615 | 6314 | 1468 | 809 | 24 |
| 6: Built-in Prototype Methods | 4713 | 3370 | 910 | 423 | 10 |
| 7: Remaining ES5 Features | 1035 | 344 | 124 | 458 | 109 |
| 8: ES5 Built-in Objects | 2747 | 1243 | 981 | 522 | 1 |
| 11: Arrow Functions & Templates | 465 | 191 | 103 | 158 | 13 |
| 12-13: Destructuring & Spread | 19 | 15 | 0 | 2 | 2 |
| 14: for-of | 751 | 137 | 125 | 169 | 320 |
| 15: Classes | 8520 | 680 | 592 | 6318 | 930 |
| 17-20: Map/Set/Symbol/Promise | 1614 | 961 | 145 | 463 | 45 |
| 21: Generators | 619 | 171 | 271 | 138 | 39 |

(Plus 3 expected-parse CEs. Second run of the day: 21,154/6,264/2,035 — treat ±33 as noise; see "Flakiness" below.)

---

## Wave 1 — Parser holes (closes ~2,035 CEs + unlocks many runtime fails)

All verified by minimal repro this session. These are the highest-leverage fixes in the
project: each is one parser change that closes hundreds of tests, and the class/generator
holes also unblock runtime tests currently stuck behind the CE.

### 1a. Reserved words as property names (IdentifierName vs Identifier) — B42
`var o = { default: 1, extends: 2 }`, `o.default`, `{ get default() {} }` all CE today.
Per ES5 §7.6, property-name and member-access positions accept any *IdentifierName*
(including reserved words); only binding positions require *Identifier*. Fix: in the
property-name paths of object literals, member access after `.`, class method names, and
getter/setter names, accept any keyword token and treat its lexeme as a string key.
Clusters: `ident-name-*` tests across `language/expressions/object`,
`language/statements/class`, member-expression dirs. **Est. 400–600 tests.**

### 1b. Generator method shorthand — B43 (the concrete face of B38) — DONE (session 252)
`class C { *m() {} }` and `({ *g() {} })` were already fixed by the generators branch
merge before this item was actioned. Phase 15 CE count 930 → 203 in a fresh run (pass
680 → 933). Remaining phase-15 CEs are B44-adjacent (async arrows, computed-property-names
from `yield`/`await`) and unrelated gaps, not generator-method shorthand.

### 1c. Async arrow functions — B44 — DONE (session 252)
`async () => 42` was parsing `async` as a plain identifier. Fixed with a lookahead in
`src/compiler/tokens.c3` (`is_async_arrow_lookahead`) plus `is_async` propagation into
`compile_arrow_inner`/`compile_arrow_inner_reparse` in `src/compiler/functions.c3` (the
arrow body compiled into a fresh `arrow_ctx` that never inherited the flag — parsing
alone wasn't sufficient, bodies ran sync without Promise wrapping). Verified: no-arg,
single-identifier, multi-param, rest-param, destructured-param, and `await`-in-body forms
all work; `async` as a plain identifier/function name unaffected. Phase 11 CE count
unchanged at 13 (all pre-existing, unrelated to async arrows).

### 1d. for-of/for-in member-expression LHS — B45 — DONE (session 252)
`for (obj.prop of arr)` CEs (`expected ';', got '<identifier>'`) fixed, plus a
pre-existing bare (no `var`/`let`/`const`) `for (x in obj)` gap found along the way.
Real footprint was ~4 tests, not 150–300 — phase 14's 320 CEs turned out to be almost
entirely B37 destructuring patterns (verified by grepping the CE log), which this item
does not touch. Fix re-parses the member LHS fresh each loop iteration from a saved
full-lexer-state snapshot (`ForLhsSnapshot` in `src/compiler/statements.c3`) rather than
a byte offset, since `self.lexer.pos` may already be past a pending lookahead token by
the time the head shape is detected.

### 1e. Destructuring completion — B37/B39 (existing items, still open)
Catch-clause patterns (`catch ([a, b])` CEs — verified), destructuring in for-of heads,
computed keys in patterns, remaining default-parameter interactions. Clusters:
`language/expressions/assignment/destructuring` (98 CE), `language/statements/try` scope-*
(92 CE incl. catch patterns), `language/statements/variable` (31 CE). **Est. 300–450.**

### 1f. Unicode identifier tables
`language/identifiers/start-unicode-*.js` fail (34 tests): the lexer's ID_Start/
ID_Continue classification doesn't cover the full Unicode ranges. libregexp vendors
`libunicode.c` with exactly these tables (`lre_js_is_ident_first/lre_js_is_ident_next` in
quickjs) — bind those rather than hand-rolling ranges. **Est. 34 tests.**

## Wave 2 — RegExp Unicode runtime (~700–800 tests)

- **B32 (byte-mode exec):** `lre_exec` is called with `cbuf_type=0`; any multi-byte UTF-8
  subject mismatches. Convert subject to UTF-16 and pass `cbuf_type=2` (QuickJS wiring:
  `quickjs.c:47884`). Gates `built-ins/RegExp/property-escapes` (448 fails) and
  `unicodeSets` (114). **Depends on the string-model decision in "Architecture issues"
  below — do that first or the conversion layer gets rewritten twice.**
- **B33:** `d`-flag `.indices` + `hasIndices`/`unicodeSets` accessors (part of
  `RegExp/prototype`'s 222 fails).
- **B34:** `String.prototype.match` drops `.groups` for non-global named-capture regexps.

## Wave 3 — Array.prototype conformance sweep (1,323 fails across phases 3/5/6)

Fails span every method (concat 132, map 99, splice 78, sort 67, slice 60, lastIndexOf 60,
copyWithin 57, indexOf 57, reduce 56, filter 56, reduceRight 54, push 51, …), which means
shared root causes, not per-method bugs. Verified examples point to four:

1. **Spec operation ordering** — e.g. `map` must `Get(O, "length")` *before* checking the
   callback is callable (`15.4.4.19-4-15.js`: "lengthAccessed !== true"). Audit every
   method against spec step order: length read → ToLength → callable check → iterate.
2. **Sparse/hole semantics** — `[].concat([,1])` produces wrong elements
   (`S15.4.4.4_A1_T4.js`). Methods must use HasProperty to distinguish holes, and concat
   must preserve holes rather than materializing them.
3. **ArraySpeciesCreate / Symbol.isConcatSpreadable** — the `create-species-*` and
   `concat_spreadable-*` families.
4. **Huge-length array-likes (ToLength / 2^53-1)** — see "Memory bombs" below. `findLast`
   on `{length: Number.MAX_VALUE}` must start at index 2^53-2 (one predicate call), not
   loop; `splice`/`concat` must throw TypeError *before* iterating when the result length
   would exceed 2^53-1. Closes most of the 46 timeouts + 3 memkills too.

## Wave 4 — Property-descriptor matrix (~490 fails)

`Object.defineProperties` (263), `defineProperty` (190), `getOwnPropertyDescriptor` (41).
Sampled failure mode: "Expected a TypeError to be thrown but no exception was thrown" —
the ValidateAndApplyPropertyDescriptor rejection matrix (non-configurable transitions,
writable:false value changes, accessor↔data flips) is incomplete. This is the unfinished
half of `plans/022-property-descriptor-correctness.md`. Implement the full 8.12.9
algorithm as a table-driven validator in one place; the current ad-hoc checks have been
patched piecemeal across sessions 162–167.

## Wave 5 — Remaining runtime clusters

| Cluster | Fails | Root cause sketch |
|---|---|---|
| String.prototype sweep | 572 | @@match/@@search/@@replace protocol dispatch on non-RegExp objects, ToPrimitive/ToString ordering on `this`, replaceAll/matchAll edge semantics, Unicode case mapping (toLocale* 40) |
| Class runtime | ~570 | mostly unblocked by Wave 1b; then accessor descriptors, static-method attribute checks, `scope-*-paramsbody-*` env splits |
| Generators runtime | ~250 | GeneratorFunction prototype chain (`prototype-value.js`), default params in generator scope, fn-name rebinding TypeErrors, yield-newline ASI |
| Function.prototype | 247 | `toString` needs retained source text (82 — see architecture issues), `bind` length/name/prototype-descriptor details (48), call/apply arg-coercion order (80), @@hasInstance (18) |
| for-of iterator close | ~120 | IteratorClose on break/throw, non-callable return handling |
| Phase 0-1 misc | 238 | arguments-object semantics, ASI edge cases, directive-prologue; needs fresh clustering after Wave 1 |
| Error/refs (phase 4) | 64+94CE | `cause` property (CE'd — option-bag ctor), NativeError attribute checks |
| Number.prototype formatting | 67 | toPrecision/toExponential/toFixed conformance — port QuickJS's js_dtoa-based formatters (dtoa.c already vendored since B25) |
| Promise combinator CEs | 32 | tests use async arrows / other Wave-1 syntax |
| Object misc | ~150 | create (35), prototype methods (69), fromEntries (18 CE — syntax) |
| parseInt/parseFloat, Date | 60 | numeric edge cases; Date parsing/formatting leftovers |

## Wave 6 — Flake elimination and the last mile

Two consecutive identical runs differed by ±33 results (21,154 vs 21,121) with no code
change. Before declaring any percentage ≥95%, make runs reproducible:
- Suspects: timeout adjacency under CPU load (10s wall-clock timeout on a loaded machine),
  worker death marking the in-flight test FAIL, allocation-pressure-dependent GC bugs.
- Tooling: add `--retry-fails` (rerun the FAIL/TIMEOUT set once, serially, before
  reporting) and diff two `--log` files to enumerate the flaky set.
- Any test that flips run-to-run is a real bug (likely GC/refcount timing) — track the
  flaky list explicitly.

---

## Architecture issues (must-address)

### A1. String model: UTF-8 codepoints vs UTF-16 code units — **blocking for 100%**
`HString` stores UTF-8; `char_length()` counts **codepoints** (`src/hstring.c3:203`). The
spec defines strings as UTF-16 code-unit sequences: `"\u{1F600}".length` must be 2 (we
return 1), `charCodeAt` must return surrogate halves, and lone surrogates
(`"\uD800"`) must round-trip. This silently mis-scores hundreds of String/RegExp tests
and is a hard prerequisite for B32 (the UTF-16 exec buffer).

**Recommended fix (Duktape's approach):** keep byte storage but switch to CESU-8/WTF-8 —
encode astral codepoints as two 3-byte surrogate encodings instead of one 4-byte
sequence. Then codepoint count == UTF-16 length, `char_at` returns code units, lone
surrogates are representable, and the B32 conversion is a mechanical decode. Touch
points: `encode_codepoint`/`decode_codepoint`/`compute_charlen` (`src/hstring.c3`), the
lexer's `\u{...}` escape emitter, `String.fromCharCode/fromCodePoint`, JSON, and the
libregexp wrapper. Do this **before** Wave 2.

### A2. Function source text is not retained — blocks `Function.prototype.toString`
82 tests compare `fn.toString()` output. The compiler discards source after codegen.
Retain a `(src_start, src_end)` range per `CompiledFunction` plus a heap-owned copy of
(or refcounted handle to) the source buffer. Also needed for better error messages.
Decide early: it changes `CompiledFunction` layout and `compile_inner_function`'s
signature, which later waves would otherwise churn.

### A3. Peephole fused-compare pass has caused 4 miscompiles (B23/B26/B27/B28)
Every symptom was a silent wrong-answer bug found only via rosetta. Before Wave 3's heavy
Array work leans on loops-over-arrays even harder, add a guardrail: a `-D NO_PEEPHOLE`
build flag that skips the fusion pass, plus a CI-style A/B check (`just rosetta` +
one test262 phase with and without). If A/B diverges, the peephole is the suspect —
that heuristic has paid off four times already.

### A4. Spec-operation helpers are inlined ad-hoc across builtins
The Wave 3/4/5 failure modes (Get-before-callable ordering, ToLength clamping, holes via
HasProperty, species construction) recur because each builtin hand-rolls these steps.
Introduce shared helpers mirroring the spec's abstract operations — `LengthOfArrayLike`
(with the 2^53-1 clamp), `ArraySpeciesCreate`, `HasProperty`-aware element iteration,
`ValidateAndApplyPropertyDescriptor` — and migrate builtins onto them. Otherwise each of
the ~2,400 built-in fails gets fixed as its own one-off and regressions recur.

### A5. Memory bombs in huge-length tests (the 30GB+ terminal freeze) — root-caused
Mechanism, verified this session: tests like
`built-ins/Array/prototype/findLast/maximum-index.js` set `{length: Number.MAX_VALUE}`;
the engine's incorrect length handling (Wave 3, item 4) turns a should-be-instant test
into an unbounded loop where every iteration interns a new numeric-index key string
("9007199254740990", …) that stays in the string table. Measured ~250–300 MB/s of RSS
growth per worker (720 MB in 3 s standalone); with a 10 s timeout × 4 workers hitting
the adjacent tests in the same directory simultaneously, transient usage reaches tens of
GB and macOS pauses other processes (ghostty).

Mitigated in the runner (session 250): `run_test262.py` samples worker RSS 2×/second and
SIGKILLs any worker above 2 GB (`MEM_LIMIT_KB`), logging the test as `MEMKILL`. Verified:
phase 6 workers now die at ~2.06 GB instead of ballooning. The *engine-side* fix is Wave
3 item 4 (correct ToLength + early-exit iteration). A defense-in-depth engine cap (heap
`--max-memory` flag honored by `alloc`) is worth adding for embedding anyway.

### A6. Skip-list definitions are still duplicated
`scripts/run_test262.py` (SKIP_DIRS/UNSUPPORTED_PATTERN/SKIP_FILES) and
`scripts/test262_skip.cfg` (sourced by the bash runners) must be edited in tandem — they
have already drifted once (B35 needed both). Single-source it: generate the cfg from the
Python definitions, or have the Python runner parse the cfg. Low urgency, high
drift-risk. (Session 250 already deleted the three stale one-off scripts that carried
*third* copies: `phase_runner.py`, `capture_fails.py`, `analyze_phase3_failures.py` —
`run_test262.py --log` + awk replaces all of them.)

---

## Estimated arithmetic to 100%

| Wave | Tests closed (est.) | Cumulative pass rate |
|---|---|---|
| Baseline | — | 71.8% |
| 1: Parser holes | ~2,300 (2,035 CE + unlocked runtime) | ~79% |
| 2: RegExp Unicode (needs A1) | ~750 | ~82% |
| 3: Array sweep (+A4, +A5 engine fix) | ~1,300 | ~86% |
| 4: Descriptor matrix | ~490 | ~88% |
| 5: Remaining clusters (+A2) | ~2,300 | ~96% |
| 6: Long tail + deflake | ~1,100 | 100% |

Estimates overlap (a class test may need Wave 1 syntax *and* Wave 4 descriptors); treat
the cumulative column as direction, not commitment. Re-run `--log` clustering after each
wave — the cheap awk pipeline above is the steering wheel.

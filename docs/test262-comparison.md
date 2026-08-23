# test262: cross-engine comparison

boomkat measured against seven other engines on an identical set of test262
tests, run by the same harness with the same inputs.

For what the engine does and does not implement, see `engine-scope.md`. For
boomkat's own per-phase numbers see `test262_results/latest.json`.

## Results

test262 at `3655e746` (upstream main, 2026-08-10). 38,002 tests.

| # | Engine | Pass | Fail | Timeout | Rate |
|---|--------|-----:|-----:|--------:|-----:|
| 1 | **boomkat** | 37,984 | 18 | 0 | **99.95%** |
| 2 | JavaScriptCore | 37,979 | 23 | 0 | 99.94% |
| 3 | V8 15.4.41 | 37,939 | 63 | 0 | 99.83% |
| 4 | SpiderMonkey (JavaScript-C155.0) | 37,896 | 106 | 0 | 99.72% |
| 5 | QuickJS-ng 0.15.1 | 37,720 | 282 | 0 | 99.26% |
| 6 | Nova | 35,452 | 2,523 | 27 | 93.29% |
| 7 | Hermes | 23,847 | 14,143 | 12 | 62.75% |
| 8 | Duktape | 15,658 | 22,341 | 3 | 41.20% |

## What this measures, and what it does not

**The scope is the strict-mode subset**, which is 38,002 of the corpus's 53,578
tests. The 15,558 excluded fall out as:

| Reason | Count |
|--------|------:|
| Excluded directory (Intl, staging, …) | 6,042 |
| Unimplemented proposal feature flags | 5,858 |
| `noStrict` | 1,740 |
| Host module loader | 910 |
| Modules | 828 |
| Agent/worker harness | 112 |
| Host global script | 37 |
| `raw` | 29 |
| `CanBlockIsFalse` | 2 |

This subset suits a strict-only engine, so **the ranking is not a claim that
boomkat is more complete than V8 or JavaScriptCore.** It is not: those engines
implement Intl, modules, sloppy mode, and a long tail of proposals that are
filtered out here. What the table shows is conformance *within a shared scope*.

The two failure profiles are also different in kind. A mature engine's failures
are edge cases inside features it fully implements, plus proposals at varying
stages. boomkat's remaining 18 are a design boundary (see below), not a bug
list. Equal rates do not mean equal breadth.

### Fairness of the comparison

Every engine runs byte-identical input: the same harness prelude, the same
`"use strict"` insertion, the same per-test files. No per-engine allowances.

Two adjustments were needed to keep it honest:

- **Parse-phase negative tests.** Engines report syntax errors differently --
  Hermes prints `error: invalid expression`, not the token `SyntaxError`. The
  classifier originally scored all of those as failures, costing Hermes 3,757
  tests (52.84% -> 62.72%). The rule now accepts any parse failure for a
  parse-phase test expecting SyntaxError, provided the engine names no *other*
  error type. It is engine-agnostic: boomkat and qjs re-ran to byte-identical
  scores.

- **`Iterator.prototype.join`.** These 18 tests were filtered for boomkat (an
  unimplemented Stage-3 proposal) after the other engines had already been
  scored on them, and they are not neutral -- jsc/v8/sm pass all 18, qjs fails
  16. Every row above excludes them, so all eight engines are scored on the
  same 38,002. Leaving them in would have flattered boomkat and penalised qjs
  (99.22% vs the 99.26% shown here).

### Caveats

- **Run dates differ.** v8, JavaScriptCore and Duktape were measured before two
  later harness fixes (the parse-phase rule above, and CR-only frontmatter
  parsing). Both fixes only ever *add* passes, so those three rows are
  marginally understated -- by at most a test or two each. Re-run before
  quoting them anywhere load-bearing.
- Versions are recorded where the binary reports one. Nova and Duktape build
  from source without a queryable version string.
- Nova and Hermes needed `$262` shims written for them; Hermes has no host
  detach hook, so `detachArrayBuffer` is absent rather than faked, and the
  tests needing it fail honestly.

## boomkat's remaining 18

None are engine defects. Sixteen are sloppy-mode semantics the engine
deliberately does not implement (see `engine-scope.md`), and two need multiple
realms.

| Count | Group | Why it fails |
|------:|-------|--------------|
| 10 | Duplicate params in the `Function` constructor | `Function()` bodies are sloppy unless they carry their own `"use strict"`. The four marked `onlyStrict` test that a strict *caller* still produces a sloppy *body* -- the test's own description is "allowed if body not strict". |
| 4 | `this`-boxing in `Function.prototype.apply`/`call` | `Function("this.touched = true").apply(1)` expects the primitive `1` to become a `Number` wrapper. Strict mode leaves `this` primitive, so the assignment throws. |
| 2 | Indirect eval is always sloppy | `(0,eval)('var static; with({}){}')` and `eval('arguments = 42')`. Both `onlyStrict`; one is literally named `always-non-strict.js`. |
| 2 | Cross-realm | `$262.createRealm()`. boomkat is single-realm; a host capability, not a language gap. |

That is the ceiling for a strict-only engine on this subset. Moving it would
mean implementing sloppy mode -- a second parse mode, `this`-boxing, `with`,
sloppy `eval` scoping, and duplicate-binding rules throughout -- which is
explicitly out of scope.

## Reproducing

The runner lives outside this repo, in a test262 checkout:

```
cd <test262>/tools/engine-compare
./run.py --engines boomkat,qjs,v8,jsc,sm,hermes,nova,duk --jobs 8 --out results/
```

It writes one TSV per engine (`RESULT<TAB>path<TAB>detail`) plus a
`summary.json`. Per-engine binaries come from `jsvu` except boomkat (built from
this repo) and Nova (built from source).

# test262: historical cross-engine comparison

boomkat measured against seven other engines on an identical set of test262
tests, run by the same harness with the same inputs.

The table records a strict-mode comparison on the 2026-08-10 corpus. Current
Boomkat supports sloppy mode, modules, partial Intl and Temporal; its current
feature inventory is in [features.md](features.md). The scores below need a
fresh comparison run before they can describe the current engine.

For scope, see [engine-scope.md](engine-scope.md). The referenced
`test262_results/latest.json` and external comparison harness are absent from
this checkout; the repository's runner is `scripts/run_test262.py`.

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
tests. The 15,576 excluded tests break down as:

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
| `Iterator.prototype.join` adjustment | 18 |

This snapshot selects a strict-mode subset. Its ranking describes conformance
within that shared scope, with Intl, modules, sloppy scripts and several
proposals excluded.

The failure profiles differ across engines: a mature engine's failures are edge
cases in implemented features and in-progress proposals, whereas boomkat's 18
snapshot failures fall into the four groups below.

### Harness adjustments

Every engine runs byte-identical input: the same harness prelude, the same
`"use strict"` insertion, and the same per-test files, with no per-engine
allowances. Two adjustments apply to all engines:

- **Parse-phase negative tests.** Engines format syntax errors differently;
  Hermes prints `error: invalid expression` rather than `SyntaxError`.
  Scoring those as failures originally cost Hermes 3,757 tests (52.84% ->
  62.72%). The classifier accepts any parse failure for a parse-phase test
  expecting `SyntaxError`, provided the engine names no other error type.
  Re-running boomkat and qjs under this rule produced identical scores.

- **`Iterator.prototype.join`.** These 18 tests were filtered for boomkat (an
  unimplemented Stage-3 proposal) after the other engines had been scored on
  them (jsc, v8, and sm pass all 18; qjs fails 16). Every row above excludes
  them so all eight engines are scored on the same 38,002 tests (including them
  would put qjs at 99.22% instead of 99.26%).

### Caveats

- **Run dates differ.** v8, JavaScriptCore, and Duktape were measured before two
  harness fixes (the parse-phase rule above and CR-only frontmatter parsing).
  Both fixes only add passes, so those three rows may be understated by one or
  two tests. Re-run before citing them.
- Versions are recorded where the binary reports one. Nova and Duktape build
  from source without a queryable version string.
- Nova and Hermes required `$262` shims. Hermes has no host detach hook, so
  `detachArrayBuffer` is omitted and tests requiring it fail.

## boomkat's 18 snapshot failures

This snapshot predates sloppy mode, so the sloppy-mode groups below
(`Function`-constructor duplicate params, primitive `this` boxing, sloppy
indirect eval) are implemented now; the counts are from the snapshot.

Sixteen exercise sloppy-mode semantics and two exercise cross-realm behavior.
Both surfaces are implemented.

| Count | Group | Why it failed |
|------:|-------|--------------|
| 10 | Duplicate params in the `Function` constructor | `Function()` bodies are sloppy unless they carry their own `"use strict"`. The four marked `onlyStrict` test that a strict caller still produces a sloppy body. |
| 4 | `this`-boxing in `Function.prototype.apply`/`call` | `Function("this.touched = true").apply(1)` expects the primitive `1` to become a `Number` wrapper. Strict mode leaves `this` primitive, so the assignment throws. |
| 2 | Indirect eval is always sloppy | `(0,eval)('var static; with({}){}')` and `eval('arguments = 42')`. Both are `onlyStrict` (one is `always-non-strict.js`). |
| 2 | Cross-realm | `$262.createRealm()` and shared-heap realms are implemented. |

## Reproducing

The runner lives outside this repo, in a test262 checkout:

```
cd <test262>/tools/engine-compare
./run.py --engines boomkat,qjs,v8,jsc,sm,hermes,nova,duk --jobs 8 --out results/
```

It writes one TSV per engine (`RESULT<TAB>path<TAB>detail`) plus a
`summary.json`. Per-engine binaries come from `jsvu` except boomkat (built from
this repo) and Nova (built from source).

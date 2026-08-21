# Plan 075: Official test262-harness Run — Skip-List Updates and Remaining Engine Gaps

**Status:** Open (session of 2026-08-21)
**Baseline:** 81,634 / 103,759 test-variants = **78.7%** under `test262-harness` + `eshost`
**ES core** (language + built-ins, minus Temporal and Intl): **94.7%**

This plan records a run of the engine against the **official** test262 harness
(`test262-harness` driving `eshost`), rather than `scripts/run_test262.py`. The two
disagree in instructive ways: the official harness has no notion of our skip list, runs
every test in both a sloppy and a strict variant, and scores some things the native
runner cannot see. Working through the disagreement surfaced four engine bugs (one a
segfault) and one class of test the native runner scores as PASS while the engine is
misbehaving.

Everything below was measured; the reproduction commands are inline so nothing here has
to be taken on trust.

---

## A. The harness setup (lives in the test262 fork, not here)

`eshost` discovers hosts by scanning its own `lib/agents` directory, so adding boomkat
means installing an agent module into the local eshost checkout. The fork at
`../test262` carries:

- `tools/boomkat/agent.js` — an eshost `ConsoleAgent` subclass: handles `--module`,
  recovers the error type of a `negative:` test from the engine's stderr, and strips
  unhandled-rejection lines (see A3).
- `tools/boomkat/runtime.js` — fills in the `$262` members the engine does not provide
  natively (`source`, `destroy`, `getGlobal`, `setGlobal`, `createRealm`). The engine
  already exposes `$262.global`, `$262.evalScript` and `$262.detachArrayBuffer` when
  `vm::test262_host_enabled` is set, which `cli/boomkat.c3` does unconditionally.
- `tools/boomkat/install.js` — copies both into `node_modules/eshost`. **Re-run after
  every `npm install`.**
- `package.json` scripts: `boomkat:install`, `test:boomkat`, `test:diff:boomkat`.

```sh
cd ../test262
npm install                 # test262-harness + eshost only; no engines are downloaded
npm run boomkat:install
BOOMKAT=../boomkat/out/boomkat npm run test:boomkat -- 'test/language/**/*.js'
```

### A1. Three measurement traps, all of which cost real percentage points

**(1) The validator treats any unrecognised stderr as a failure.**
`node_modules/test262-harness/lib/validator.js`:

```js
if (result.stderr) { ranToFinish = result.error ? true : false; }
...
} else if (!ranToFinish && !test.attrs.flags.raw) {
  return { pass: false, message: result.stderr || result.stdout };
}
```

So a diagnostic the engine prints for an error the *script is handling* fails the test.
This is what made the `dynamic-import/catch/*` family red even though the engine was
producing exactly the right rejection — fixed engine-side, see C1.

**(2) Fixture collisions under a whole-tree glob.** eshost copies each test's
`_FIXTURE.js` dependencies into a **single shared temp dir** and unlinks them afterwards.
`dynamic-import/catch/`, `.../usage/` and `.../syntax/` each ship a *different*
`module-code_FIXTURE.js`. Run the tree as one glob and they clobber each other.

Measured on `dynamic-import`: 1,513/1,948 as one glob vs **1,611/1,938 per-directory** —
~98 variants of pure measurement noise in one subtree alone. **Always run
per-directory** (or give each test its own `--out` dir). The headline 78.7% above was
*not* corrected for this, so the true figure is somewhat higher.

**(3) Every test runs twice**, sloppy and strict. The engine ignores `"use strict"`, so
the two variants behave identically — verified: there are **zero** files where the
sloppy variant fails and the strict variant passes. The sloppy run costs nothing; only
tests that genuinely require sloppy semantics fail.

### A2. `$262.agent` is not implemented in our runtime.js

224 failing variants (`built-ins/Atomics/wait`, `waitAsync`, `notify`) are the
multi-worker `$262.agent` harness. `scripts/run_test262.py` skips these deliberately
(`AGENT_HARNESS_RE`, "single-agent engine"). The eshost runtime has no such filter, so
they run and fail on `$262.agent` being `undefined`.

**Action:** either stub `$262.agent` in `tools/boomkat/runtime.js` so it throws a clear
`Test262Error` (matching how `gc`/`createRealm` are handled there), or filter these
tests out of the harness run. Not an engine gap either way.

### A3. Unhandled rejections are not a test262 failure

`INTERPRETING.md` says nothing about unhandled rejections; the pass criterion is
completing without throwing (or `$DONE` for async tests).
`dynamic-import/syntax/valid/top-level-empty-str-is-valid-assign-expr.js` is literally
`import('');` — it rejects with no handler and still passes. The agent therefore strips
`Unhandled promise rejection:` lines from stderr in `normalizeResult`.

The native runner takes the same position: it now **reports** unhandled rejections as a
`NOTE:` diagnostic but never changes the verdict (`cli/test262_runner.c3`). Making it a
FAIL turns 20 valid tests red — this was tried and reverted.

---

## B. Where the ES-core gap actually is

ES core = `language` + `built-ins`, excluding Temporal and Intl: **94.7%**, i.e. 4,606
failing variants out of 83,434. Bucketed by reading each test's frontmatter:

| bucket | variants | share |
|---|---|---|
| Out of scope — Stage 3 / host features | 2,354 | 51.1% |
| Sloppy-only tests (`noStrict`-flagged) | 1,179 | 25.6% |
| Everything else ("real gaps", refined below) | 1,068 | 23.2% |
| Cross-realm | 4 | 0.1% |

In percentage points of ES core the 5.3% gap is roughly **2.7 pts** Stage 3 / host,
**1.4 pts** sloppy mode, **1.2 pts** real gaps.

Refining that last bucket (874 variants after excluding the signatures fixed this
session):

| | variants | verdict |
|---|---|---|
| Newer proposals **not yet in `UNSUPPORTED_PATTERN`** | 254 | skip-list gap — see D |
| `$262.agent` multi-agent tests | 224 | harness gap — see A2 |
| Import attributes / JSON modules | 43 | partial support, needs triage |
| Genuine remainder | 353 | live re-run: 116 now pass → **~237 variants / ~120 files** |

A few of that remainder are still sloppy in disguise: the `Function/15.3.2.1-11-*`
duplicate-parameter tests are already in `SKIP_FILES`, and
`language/statements/variable/binding-resolution.js` uses `with`.

---

## C. Engine bugs, confirmed with repros

### C1. ~~Module compile error printed for a rejection the script handles~~ — FIXED

Landed as `fix: don't print a module compile error the script is handling`.
`resolve_module` took a `quiet` flag, set by the dynamic-import job and inherited by the
dependencies it resolves; the static path still prints. Worth ~128 variants in
`dynamic-import/catch` alone. Regression test: `test/rejections/run.sh`, `silent_quiet`
helper.

### C2. ~~Module evaluation promise reported as an unhandled rejection~~ — FIXED

Landed as `fix: don't report a module's own evaluation promise as unhandled`. A module
body runs as an async activation, so `execute_module_async` (and the module-body path in
`run_module_body`, both in `src/vm/vm_execute.c3`) allocates an evaluation promise. When
the body throws, that promise rejects — but the rejection is handed back through
`heap.error_value` and re-raised on the `import()` promise, so nothing ever attaches a
handler to the internal one. Now marked `is_handled` at allocation.

### C3. **Segfault: TLA dependency with two or more top-level awaits** — OPEN, highest priority

```js
// dep4.js
await 1; await 2; export default 42;
// main.js
import d from './dep4.js'; print('ok', d);
```
```
$ ./out/boomkat --module main.js
$ echo $?
139        # SIGSEGV
```

With a **single** await it does not crash — it silently skips the importing module's
body instead, exit 0 with no output:

```js
// dep2.js
await 1; export default 42;
// main.js  → prints nothing, exits 0.  Should print "ok2 42"
```

`export default await Promise.resolve(42)` on its own works fine, so it is specifically
the suspend-and-resume path when a dependency awaits *before* its exports are in place.
Look at `execute_module`'s `pending != null` branch, `module_attach_pending_finish`, and
`module_ensure_eval_promise` in `src/module.c3`, plus `execute_module_async` in
`src/vm/vm_execute.c3`.

16 variants in `language/module-code/top-level-await`; it is why
`module-graphs-does-not-hang.js` reports "Received unexpected signal". The silent-skip
variant is arguably worse than the crash: nothing reports it at all.

### C4. **Internal VM fault: private name in direct eval inside a field initializer** — OPEN

```js
class C { #m() { return "Test262"; } v = eval("this.#m()"); }
new C();     // → VM error: vm::VM_ERROR (at execute)
```

The same construct inside a *method* works:

```js
class C { #m(){ return 1; } run(){ return eval("this.#m()"); } }
new C().run();   // → 1
```

6 variants (`private-{getter,setter,method}-visible-to-direct-eval-on-initializer.js`).
Note `test/uncaught/run.sh`'s doctrine: `VM error:` is reserved for an internal fault
with no JS error attached and must never appear for a JS-level situation, so this is a
contract violation as well as a bug. Related prior art: plan 059 (function context
capture, eval + private names).

### C5. **`Object.isExtensible` on a primitive returns `true`** — OPEN, trivial

```js
Object.isExtensible(undefined)   // true — spec says false
Object.isExtensible("a")         // true — spec says false
```

ES2015+ returns `false` for any non-object (ES5 threw a TypeError; either way `true` is
wrong). 10 variants in `built-ins/Object/isExtensible`. Check the sibling predicates —
`Object.isFrozen`, `Object.isSealed`, `Object.preventExtensions`, `Object.seal`,
`Object.freeze` — for the same primitive-handling mistake while in there.

### C6. Smaller clusters — OPEN, untriaged (8 variants each)

- `language/module-code/ambiguous-export-bindings` — expected SyntaxError not thrown.
- `built-ins/Function/prototype` — `TypeError: Cannot create property 'touched'`.
- `built-ins/Iterator/prototype` — a RangeError required by spec is not thrown
  (8 variants, plus 4 where a `Test262Error` surfaces instead).
- `language/expressions/dynamic-import` — 32 variants asserting `URIError` where the
  engine produces `Error`.

---

## D. Skip-list updates needed in `scripts/run_test262.py`

These feature tokens are in the current `test262/features.txt` but not in
`UNSUPPORTED_PATTERN`, so 254 variants of unimplemented proposals are scored as real
failures by any analysis that trusts the skip list:

| token | tests | what it is |
|---|---|---|
| `iterator-chunking` | 69 | `Iterator.prototype.chunks` / `.windows` |
| `iterator-includes` | 40 | `Iterator.prototype.includes` |
| `Iterator.prototype.join` | 16 | as named |
| `Atomics.pause` | — | present in features.txt, check coverage |

Decide per proposal whether it is in scope (they are small, and iterator helpers are
already implemented — `map`/`filter`/`take`/`drop`/`flatMap`/`reduce`/`toArray`/
`forEach`/`some`/`every`/`find` all exist) or out of scope. If out, add the token to
`UNSUPPORTED_PATTERN` **with a comment**, per the discipline in plan 040.

`Symbol.dispose` / `Symbol.asyncDispose` tests are covered by the existing
`explicit-resource-management` entry — no change needed.

Also worth confirming: `import-attributes` and `json-modules` (43 variants). The engine
has a JSON-module load path (`wants_json` in `src/module.c3`), so this is partial
support rather than absence — triage before deciding to skip.

---

## E. Suggested order of work

1. **C3** (segfault + silent module skip). A hard crash in the module graph outranks
   every percentage point here, and the single-await variant fails silently.
2. **C5** (`isExtensible`), then sweep the sibling predicates. Trivial, 10 variants.
3. **C4** (private name + direct eval in a field initializer). Internal fault.
4. **D** (skip-list tokens). Curation, not engineering; makes every later measurement
   honest.
5. **A2** (`$262.agent` stub in the fork's runtime.js). Removes 224 phantom failures.
6. **C6** clusters, in whatever order triage suggests.

Sloppy mode is deliberately **not** on this list. It is worth ~1.4 pts of ES core, and
`docs/engine-scope.md` records why the single-mode design is a feature. See the sizing
discussion: the expensive parts are `with` (needs object environment records in the
scope chain — `env_create` exists in `src/env.c3` but its only callers are the global
env in `vm_lifecycle.c3`, and every identifier in a `with` body must deopt off the
register/IC path), mapped `arguments`, and threading a "throw on failure" bit through
every property-store path.

---

## F. Reproducing the measurements

```sh
# Per-directory (collision-free) run of one subtree:
cd ../test262
for d in test/language/expressions/dynamic-import/*/; do
  npx test262-harness --hostType=boomkat \
    --hostPath=../boomkat/out/boomkat -t 8 --timeout 10000 "$d**/*.js"
done

# The native runner, for comparison on the same tree:
cd ../boomkat
python3 scripts/run_test262.py --phase 0     # includes language/expressions/dynamic-import
python3 scripts/run_test262.py --phase 25    # ESM modules
```

A full harness run is ~20 minutes at `-t 8`. **Do not quote a whole-tree-glob figure**
without noting trap A1(2).

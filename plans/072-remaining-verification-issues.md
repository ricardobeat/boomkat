# 072 — remaining issues from the library-verification / review pass

Follow-up to `070-real-world-battle-testing.md`. That effort reached 22/22 on
the real-world library corpus (load sweep) this session; this doc tracks what
is still open, surfaced either by the corpus work itself or by the opus
review pass over its ~28 fix commits (867c1f6a..6377fc14).

## Open bugs

### 1. `class_kw_starts_class()` misses `await` as a class binding identifier — HIGH, confirmed

`src/compiler/functions.c3:1874` (`class_kw_starts_class`), called from
`functions.c3:2052` (`hoist_decls`) and `statements.c3:1215`
(`pre_scan_var_decls`).

```c3
fn bool CompilerContext.class_kw_starts_class(&self) {
    TokenType nt = self.peek_type();
    return nt == TokenType.IDENTIFIER || nt == TokenType.EXTENDS || nt == TokenType.LBRACE;
}
```

`AWAIT` is its own `TokenType`, not `IDENTIFIER`, but `class await {}` is a
legal BindingIdentifier in non-async, non-module code (the parser itself
accepts it). The gate returns false here, so `skip_class_body()` is never
called and the class body's `var`s leak into the enclosing scope — the exact
leak this gate exists to prevent, reintroduced for one name.

Repro:
```js
function f() {
  class await { m() { var leaked = 1; } }
  try { return "" + leaked; } catch (e) { return e.name; }
}
```
Engine currently prints `undefined`; spec/qjs give `ReferenceError`.

Fix: add `nt == TokenType.AWAIT` to the positive test at both call sites
(same function, so one change covers both). Verify `yield`/`static` stay
correctly rejected (strict mode already handles `yield` as reserved; no
change needed there).

### 2. `last_local_var_reg` stale at 2 of 4 `last_was_local_var` set sites — LOW, inspection only

`src/compiler/expressions.c3:916` and `:983` (compound/simple assignment
result paths) set `last_was_local_var = true` without updating
`last_local_var_reg`, unlike the two bare-identifier-read sites (`:3831`,
`:4408`). `free_expr_reg`'s guard is a conjunction
(`last_was_local_var && last_local_var_reg == reg`), so this fails *safe*
(under-protects, never over-frees) — could not turn into a wrong answer in
review (`if ((v = {...}))` / `while ((y = {...}))` matched qjs). Worth
tightening for robustness/completeness, not urgent.

### 3. `BigNumber.prototype.sqrt()` and `new BigNumber("1.1", 24)` — NOT REPRODUCING

**Status: cannot reproduce on commit 6377fc14.** The plan text claimed both
cases were broken — `sqrt(2)` returned `1` and `new BigNumber("1.1", 24)`
threw `RangeError: Invalid array length` — and traced the second to a NaN
reaching `array_set_length_desc` via `src/vm/vm_property.c3:2293`. The
vendored 9.3.1 bundle in `test/libcorpus/_wrapped/bignumberjs.js` (md5
`6898eb155fd3bbf2a7c4c51c0f864c20`) now produces identical output on
`duktape_c3` and `qjs` for every probed case:

| case                              | duktape_c3                              | qjs                                      |
|-----------------------------------|-----------------------------------------|------------------------------------------|
| `new BN("2").sqrt()`             | `1.4142135623730950488`                 | `1.4142135623730950488`                  |
| `new BN("0").sqrt()`             | `0`                                     | `0`                                      |
| `new BN("4").sqrt()`             | `2`                                     | `2`                                      |
| `new BN("0.5").sqrt()`           | `0.7071067811865475244`                 | `0.7071067811865475244`                  |
| `new BN("1.1", 24)`              | `1.04166666666666666667`                | `1.04166666666666666667`                 |
| `new BN("1.5", 24)`              | `1.20833333333333333333`                | `1.20833333333333333333`                 |
| `new BN("1.1", 2)`               | `1.5`                                   | `1.5`                                    |
| `new BN("ff", 16)`               | `255`                                   | `255`                                    |
| `new BN("zz", 36)`               | `1295`                                  | `1295`                                   |
| `new BN("1.1", 36)`              | `1.02777777777777777778`               | `1.02777777777777777778`                |
| `new BN("2e30").sqrt()`          | `1414213562373095.04880168872420969808` | `1414213562373095.04880168872420969808`  |
| `new BN("1").dividedBy("3").toFixed(10)` | `0.3333333333`                | `0.3333333333`                           |

The api-check driver
(`scripts/lib_api_checks/bignumberjs.js`) was previously excluding both
cases pending the fix; as of this commit both are covered and the diff
against qjs is byte-identical (`python3 scripts/verify_libraries.py
--no-fetch --api-checks bignumberjs` reports `7 bignumber.js API checks
recorded, 0 threw` on both engines). A regression in the sqrt path or the
non-decimal-base parse would now surface there.

If the original bug was real (e.g. on a pre-`6377fc14` commit, or with a
different bundle version), some later engine fix in the same area must have
quietly closed it — `proxy.c3::array_set_length_desc` has been touched by
several commits since the bug was filed and `Math.sqrt`/`Math.pow`/`Math.floor`
flow through `dtoa` (out of C3 source) rather than any C3-side arithmetic.
A targeted bisect was not run; a future bisect would start at the last commit
that *did* show the throw (probably post-`f258fb1b`, pre-`0e135315`) and
walk forward.

## Unverified corpus claims

The opus review agent's worktree had no vendored bundles
(`test/libcorpus/` empty, reports 0/22 MISSING), so the 22/22 load and
21/22 (typescript api-check still failing — see below) numbers from this
session are **not independently re-verified**. Re-run
`python3 scripts/verify_libraries.py --api-checks` (with network, or from a
worktree that has `test/libcorpus` populated) to confirm before relying on
those numbers for anything downstream.

## Known-open, not yet investigated further

- **typescript's `--api-checks` driver still fails** even though the load
  sweep now passes (22/22 load, but api-checks was 21/22 as of the
  typescript fix). It reaches TypeScript's own parser and dies with
  `object is not a constructor` at `IdentifierObject`
  (TS's `objectAllocator` pattern). Confirmed not a regression — the
  pre-fix build failed earlier and harder on the same driver. Separate bug,
  own task.
- **`looks_like_module()` false-positive** in `cli/duktape_c3.c3`: flags the
  typescript bundle as ESM because `export: 95,` appears at line start
  inside an object literal, routing a plain script through the ESM
  pipeline. Harmless currently (qjs also passes the file), but is why the
  original typescript failure surfaced as an opaque `module rc=2`/`rc=1`
  instead of a real error location. Worth a proper fix (don't sniff `export`
  as a bare keyword at line start inside braces).
- **Annex B HTML tag methods (`anchor`, `big`, `blink`, `bold`, `fixed`,
  `fontcolor`, `fontsize`, `italics`, `link`, `small`, `strike`, `sub`,
  `sup`)**: swept in the same branch, then **rejected as out of scope**.
  The engine's scope (docs/engine-scope.md) excludes Annex B legacy; only
  `trimLeft`/`trimRight` and the global `escape`/`unescape` functions
  were retained because the real-world library corpus needs them; nothing
  in the corpus uses these 13 HTML-tag methods, and they diverge from the
  spec's `EscapeAttributeValue` (only escaping `"` instead of `&"'<>`).
  Item closed as deliberately not implemented.
- **`captures.c3:222`** has the same unguarded `CLASS` check as the
  original `class_kw_starts_class` bug, but degrades safely to
  `capture_all = true` (over-approximation, not a leak) — deliberately left
  alone by the typescript-fix agent, worth a comment or a matching gate for
  consistency but not a correctness bug.
- **`a6cca422`'s sibling paths** (other compiled-setter staging call sites)
  and **`3aa4544c`'s Reflect.apply note** — both commits self-flagged
  "other similar sites not audited"; opus review could not reproduce decay
  via `Date.prototype.toJSON`/`@@toPrimitive` over 40 iterations, so either
  the original note was conservative or the failing shape needs a
  getter-specific trigger not yet found. Low priority, unconfirmed.
- **`test/engine/shape_id_exhaustion.js`** intermittently exceeds its
  2-second timeout under parallel-agent system load (13-18s observed),
  though it always passes standalone — pre-existing test-infra timing
  issue, not an engine bug.

## Verified clean by the opus review pass (no action needed)

`042e1826` (conditional-write liveness, incl. nested branches/loops/ternary
merges and WIDE-format instructions), `1b3face2` (§14.2.11 block-scoped
function instantiation), `dce04d1f` (Date ToPrimitive hint, all cases incl.
`@@toPrimitive`), `e364575c`/`8a8cd010` (Annex B trimLeft/trimRight/escape/
unescape, byte-identical to qjs), `afc10dd2` (mid-sweep refcount guard
placement), `3aa4544c`/`a6cca422` (ownership-lifetime fixes, not just the
original repro). `Date.parse("0")` returning `NaN` (vs qjs) was checked
against §21.4.3.2 and is a **deliberate, spec-permitted divergence**, not a
bug — 4-digit year is required by the format.

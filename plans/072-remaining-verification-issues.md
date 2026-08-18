# 072 — remaining issues from the library-verification / review pass

Follow-up to `070-real-world-battle-testing.md`. That effort reached 22/22 on
the real-world library corpus (load sweep) this session; this doc tracks what
is still open, surfaced either by the corpus work itself or by the opus
review pass over its ~28 fix commits (867c1f6a..6377fc14).

## Fixed this pass

### 1. `class_kw_starts_class()` missed `await` as a class binding identifier (c8539a8a)

`AWAIT` is its own `TokenType`, not `IDENTIFIER`, but `class await {}` is a
legal BindingIdentifier in non-async, non-module code. The gate returned
false, so `skip_class_body()` never ran during the hoist pre-scans and the
class body's `var`s leaked into the enclosing scope. The gate now accepts
`AWAIT` via the shared `await_is_identifier` predicate (one change covers both
call sites, `hoist_decls` and `pre_scan_var_decls`). `yield`/`static`/`let`/
`package`/`implements` stay rejected. Test: `test/codegen_class_await_bindings.js`.

```js
function f() {
  class await { m() { var leaked = 1; } }
  try { return "" + leaked; } catch (e) { return e.name; }
}
```
Now prints `ReferenceError`, matching qjs.

### 2. `last_local_var_reg` stale at 2 of 4 `last_was_local_var` set sites (c8539a8a)

`expressions.c3`'s assignment result paths (simple `=` and compound `op=`)
set `last_was_local_var = true` without updating `last_local_var_reg`. The
guard in `free_expr_reg` is a conjunction, so this failed safe
(under-protects). Both sites now record the register. No behavioral change
was observable; the contract is pinned by
`test/codegen_assignment_last_local_var_reg.js`.

### 3. `looks_like_module()` false positive on `export:` at line start (c8539a8a)

The detector treated any post-newline position as a statement start, so
`export: 95,` inside a multi-line object literal (typescript 5.4.5's keyword
table) routed a plain script through the ESM pipeline and reported failures
as opaque `module rc=2`/`rc=1`. The scanner now tracks brace/paren/bracket
depth and only matches `import`/`export` whole words at depth 0;
`import(` (dynamic import) is excluded. Strings are still not lexed, same as
before. Test: `test/cli_looks_like_module_depth.js`.

### 4. Shared `__super__` slot: sibling classes clobbered each other (8d951801)

Every class in one function scope declared a single shared `__super__` /
`__static_super__` let-binding, so the last `extends` clause overwrote the
earlier ones. The typescript bundle's services block defines ~10 sibling
classes in one `__esm` callback; `super()` in an early constructor resolved
to the last class's prototype object and threw "object is not a constructor"
(this was the api-check driver failure previously blamed on the
`objectAllocator` pattern itself).

Each class now gets numbered bindings (`__super__0`, `__super__1`, ...) from
a per-context counter, propagated into inner functions, field/static
initializer contexts, static blocks, computed keys, parameter defaults, and
direct eval (the enclosing `CompiledFunction` snapshots the binding name so
`builtin_eval` can re-intern it). `Object.setPrototypeOf`'s class sync
(object.c3) writes the new `[[Prototype]]` under the numbered name, so
`super()` still observes runtime prototype changes
(`language/expressions/super/call-proto-not-ctor.js`). Tests:
`test/test_super_unique_bindings.js`, `test/test_class_super_bindings.js`.

### 5. `captures.c3` `CLASS` comment (c8539a8a)

The unguarded `CLASS` check now carries a comment recording why it stays an
over-approximation (`capture_all = true`) rather than a lookahead gate like
`class_kw_starts_class`: that scan works on raw token streams without lexer
restore, and over-approximation is safe.

### 6. typescript api-check driver: two register-clobber bugs (760855cc)

The `Cannot create property 'jsDoc' on string` failure was two engine bugs
stacked on the same driver, both in the free-a-live-local's-home-register
family:

1. **Member assignment base clobber.** `n.a = v` where `n` is a register
   cached `let`/`const` and `v` sits in a low register (a parameter): the
   store path freed the base register, the result-temp alloc handed the same
   slot back, and the `LDREG` result copy overwrote the variable with the
   RHS. `createBaseIdentifier`'s `node.escapedText = text` turned `node`
   into the string. Fixed with the `last_member_obj_is_local` guard
   (79096c6c introduced it for `typeof local.prop`; the assignment path
   never got it).

2. **Switch discriminant clobber.** `switch (kind)` on a bare `let`/`const`
   read returns the binding's home register, and `switch_statement`'s
   closing `free_reg(disc_reg)` popped `next_reg` below the live binding.
   The next temp allocation landed in the slot: with a second switch on the
   same variable, the first case literal's `LDINT` overwrote the
   discriminant, so every comparison after it was a self-compare and all
   inputs dispatched to the first case. `checkSourceElementWorker` sent a
   kind-260 node to the kind-243 handler, which read `declarationList` off
   a VariableDeclaration and died with `reading 'declarations'`. Same
   guard applied to the for-increment expression result
   (`for (;; ++i)`).

Minimal repros: `test/codegen_member_store_local_base.js`,
`test/codegen_switch_disc_local.js`. After the fixes the driver passes:
**corpus 22/22 load, 22/22 api-checks**, first full-green run. Gates:
rosetta 42/42, local suite green, phase 15 8374/0/0, phases 0/2/3
12476/0.

## Open bugs

### 3. `BigNumber.prototype.sqrt()` and `new BigNumber("1.1", 24)` — NOT REPRODUCING

**Status: cannot reproduce on commit 6377fc14.** The plan text claimed both
cases were broken — `sqrt(2)` returned `1` and `new BigNumber("1.1", 24)`
threw `RangeError: Invalid array length` — and traced the second to a NaN
reaching `array_set_length_desc` via `src/vm/vm_property.c3:2293`. The
vendored 9.3.1 bundle in `test/libcorpus/_wrapped/bignumberjs.js` (md5
`6898eb155fd3bbf2a7c4c51c0f864c20`) now produces identical output on
`boomkat` and `qjs` for every probed case:

| case                              | boomkat                              | qjs                                      |
|-----------------------------------|-----------------------------------------|------------------------------------------|
| `new BN("2").sqrt()`             | `1.4142135623730950488`                 | `1.4142135623730950488`                  |
| `new BN("0").sqrt()`             | `0`                                     | `0`                                      |
| `new BN("4").sqrt()`             | `2`                                     | `2`                                      |
| `new BN("0.5").sqrt()`           | `0.707106...5244`                       | `0.707106...5244`                        |
| `new BN("1.1", 24)`              | `1.04166666666666666667`                | `1.04166666666666666667`                 |
| `new BN("1.5", 24)`              | `1.20833333333333333333`                | `1.20833333333333333333`                 |
| `new BN("1.1", 2)`               | `1.5`                                   | `1.5`                                    |
| `new BN("ff", 16)`               | `255`                                   | `255`                                    |
| `new BN("zz", 36)`               | `1295`                                  | `1295`                                   |
| `new BN("1.1", 36)`              | `1.02777777777777777778`               | `1.02777777777777777778`                |
| `new BN("2e30").sqrt()`          | `1414213562373095.0488...`              | `1414213562373095.0488...`               |
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

## Corpus claims

Independently re-verified from a worktree with `test/libcorpus` populated
(2026-08-16, at 8d951801): load sweep 22/22, api-checks 21/22, the one
failing driver being typescript. At 760855cc both sweeps are 22/22.
`substr` picked up explicit ±Infinity/undefined-length guards in the same
pass (186ca01a); pinned by `test/test_substr_infinity.js`.

## Known-open, not yet investigated further

- **Annex B HTML tag methods (`anchor`, `big`, `blink`, `bold`, `fixed`,
  `fontcolor`, `fontsize`, `italics`, `link`, `small`, `strike`, `sub`,
  `sup`)**: swept, then **rejected as out of scope**. The engine's scope
  (docs/engine-scope.md) excludes Annex B legacy; only `trimLeft`/`trimRight`
  and the global `escape`/`unescape` functions were retained because the
  real-world library corpus needs them; nothing in the corpus uses these 13
  HTML-tag methods, and they diverge from the spec's `EscapeAttributeValue`
  (only escaping `"` instead of `&"'<>`). Item closed as deliberately not
  implemented.
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

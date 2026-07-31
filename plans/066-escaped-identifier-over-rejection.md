# Plan 066 — escaped identifiers rejected where they are valid identifier *names*

The last 4 test262 issues in the whole suite. All `CE:unexpected` in phase 15 —
i.e. **over-rejection**: the engine refuses source that is valid. Everything
else in test262 now passes (49,810 pass / 0 fail).

Confirmed **pre-existing**: both shapes reject identically on a binary built at
`1455e786` (before any of this session's work).

## The 4 tests (2 shapes × expression/statement form)

- `language/{expressions,statements}/class/ident-name-method-def-static-escaped.js`
- `language/{expressions,statements}/class/class-name-ident-await-escaped.js`

Real sources (the escapes matter — see the reproduction note below):

```js
var C = class {
  static() { return 42; }     // a method NAMED "static"
};

var C = class await {};       // a class NAMED "await"
```

Both are valid. Ours rejects both with:

```
SyntaxError: keyword must not contain escaped characters
```

node accepts both.

## Reproduction gotcha — cost me two wrong probes

`a` does not survive shell quoting or heredocs reliably. Both of my
hand-written probes silently tested the *unescaped* spelling (`static()`,
`class await {}`), which is a different construct and passes, making the bug
look absent.

Reproduce by copying the real test262 file instead:

```sh
src=test262/test/language/expressions/class/class-name-ident-await-escaped.js
{ echo '"use strict";'; sed -n '/---\*\//,$p' $src | tail -n +2; } > /tmp/r.js
grep -n 'u0061' /tmp/r.js        # confirm the escape is actually present
./out/duktape_c3 /tmp/r.js
```

Always `grep` the generated file to confirm the escape survived before drawing
any conclusion.

## The distinction to implement

"An escaped keyword is not the keyword" cuts **both ways**, and the engine
currently applies only one direction:

- Where the grammar requires the *reserved word* — `if`, `for`, `class`,
  `static` as a modifier, `await` as an operator — an escaped spelling must be
  REJECTED. This is already correct and must stay correct.
- Where the grammar wants an *IdentifierName* or a BindingIdentifier that the
  word is merely spelled like — a method name, a class name — the escaped
  spelling is a plain identifier and must be ACCEPTED.

So `static(){}` is a method named `static`, not a `static` modifier; and
`class await {}` names the class `await`.

Note the `await` case interacts with plan 064 (landed today), which correctly
tightened `await` as a BindingIdentifier in async contexts. The interaction to
preserve: an **escaped** `await` is not the keyword, so it is a legal class
name — while an **unescaped** `await` as a class name inside an async function
must still reject (plan 064 fixed exactly that, and `test/class_early_errors.js`
plus the new assertions cover it). Do not regress plan 064's tests.

## Likely mechanism

Three sites emit this message:

- `src/compiler/tokens.c3:98`
- `src/compiler/expressions.c3:2893`
- `src/compiler/expressions.c3:3650`

Suspect the check is applied at a point that cannot yet tell "reserved word
position" from "identifier-name position", so it fires for both. Confirm which
of the three fires for each failing shape (the error carries line/col, so a
targeted breakpoint or a temporary distinct message per site will identify it)
before changing anything.

If the three sites hand-roll the same predicate, prefer consolidating to one
that takes the grammatical position as input, rather than adding a fourth
variant. This repo has been bitten by exactly that pattern four times now
(BACKLOG session 302; plans 063, 064 — 064's fix *removed* two copies of an
existing predicate rather than adding any).

## Guard against the opposite error

Tightening this wrongly re-opens real early errors. These must KEEP rejecting:

- `class C {}` — escaped `class` keyword
- `if (x) {} else {}` — escaped `else`
- `class C { static m(){} }` — escaped `static` used as a MODIFIER
  (distinct from the method-name case above: here it precedes another name)
- `async function f(){ class await {} }` — unescaped `await`, plan 064's rule
- `(async function* await(){})` — unescaped, plan 064's rule

Write each of these as a negative test using real escape sequences (per the
reproduction note), not hand-typed approximations.

## Validation

1. All 4 named tests pass via `--single`.
2. Phase 15: currently 8370 pass / 0 fail / **4 unexpected-CE**. Expect
   8374 / 0 / **0**. Unexpected-CE reaching 0 clears the last test262 issue.
3. Every guard shape above still rejects.
4. `just rosetta` 41/41 · `just test-golden-bytecode` 28/28 · `just test-local`
   green (must include `test/class_early_errors.js` and
   `test/binding_identifier_early_errors.js` — plans 062/064's coverage).
5. Regression test under `test/` with both accept and reject cases, using real
   `\uXXXX` escapes.
6. Re-run phases 21, 24, 25 — `await`/module contexts most likely to interact.

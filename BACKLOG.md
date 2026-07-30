# Duktape C3 — Backlog

`[ ]` TODO · `[>]` IN PROGRESS · `[x]` DONE.

Details for the open items: `plans/062-core-language-coverage.md`.

## test262 coverage

- [x] Add the orphaned core-language dirs to `PHASES` (phases 2, 7, 24)

## Core language bugs

- [x] `for (let y in/of ...)` falsely rejected as duplicate when an enclosing function has `var y` (the head's lexical scope must not conflict with function-level var names; no test262 coverage — gate is green)
- [x] `return` inside `finally` in an async function raises a VM error and allocates without bound
- [x] `await` as a plain identifier rejected as an invalid assignment target
- [x] `for-in`/`for-of` head does not accept a bare comma expression
- [x] `for-in` head lexical bindings are not in a TDZ while the head expression evaluates
- [x] `for-in` completion value starts from the preceding statement instead of `undefined`
- [x] `for-in` emits a prototype property shadowed by a non-enumerable own property
- [x] `let`/`const` self-reference TDZ missed for a block nested in a function body
- [x] Assignment to a `const` bound in a `for-in`/`for-of` body must throw TypeError
- [x] `delete (obj.prop)` rejected as an unqualified identifier
- [x] `[[Construct]]` with a non-object `.prototype` must fall back to `%Object.prototype%`
- [x] `for-in` yields keys deleted during enumeration (`S12.6.4_A7_T2` — keys are pre-collected)
- [x] `[no LineTerminator here]` after `async` not enforced; escaped `async` treated as the keyword
- [x] `await` on a non-promise thenable fails under the harness — reproduce before fixing
- [x] Skip-list the two `bigint-and-number-extremes` tests (256-bit literals, fixed-width int128 by design)

## Out of scope

- test262: Temporal, `intl402`, `staging`, annexB, `harness`, other Stage 3 proposals
- test262 dirs: `statements/with`, `statements/labeled`, `statements/using`, `statements/await-using`
- Feature tokens: `cross-realm`, `tail-call-optimization`, `caller`, `__proto__`/`__getter__`/`__setter__`
- In-phase `$DONOTEVALUATE` and `noStrict` skips (strict-only engine)
- Sloppy mode
- qjs CLI/std/os modules
- `(o?.m)()` undefined-this "fix"
- Arbitrary-precision BigInt

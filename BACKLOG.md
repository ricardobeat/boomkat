# Duktape C3 — Backlog

`[ ]` TODO · `[>]` IN PROGRESS · `[x]` DONE.

Details for the open items: `plans/062-core-language-coverage.md`.

## test262 coverage

- [x] Add the orphaned core-language dirs to `PHASES` (phases 2, 7, 24)

## Core language bugs

- [ ] `return` inside `finally` in an async function raises a VM error and allocates without bound
- [ ] `await` as a plain identifier rejected as an invalid assignment target
- [ ] `for-in`/`for-of` head does not accept a bare comma expression
- [ ] `for-in` head lexical bindings are not in a TDZ while the head expression evaluates
- [ ] `for-in` completion value starts from the preceding statement instead of `undefined`
- [ ] `for-in` emits a prototype property shadowed by a non-enumerable own property
- [ ] `let`/`const` self-reference TDZ missed for a block nested in a function body
- [ ] Assignment to a `const` bound in a `for-in`/`for-of` body must throw TypeError
- [ ] `delete (obj.prop)` rejected as an unqualified identifier
- [ ] `[[Construct]]` with a non-object `.prototype` must fall back to `%Object.prototype%`
- [ ] `[no LineTerminator here]` after `async` not enforced; escaped `async` treated as the keyword
- [ ] `await` on a non-promise thenable fails under the harness — reproduce before fixing
- [ ] Skip-list the two `bigint-and-number-extremes` tests (256-bit literals, fixed-width int128 by design)

## Out of scope

- test262: Temporal, `intl402`, `staging`, annexB, `harness`, other Stage 3 proposals
- test262 dirs: `statements/with`, `statements/labeled`, `statements/using`, `statements/await-using`
- Feature tokens: `cross-realm`, `tail-call-optimization`, `caller`, `__proto__`/`__getter__`/`__setter__`
- In-phase `$DONOTEVALUATE` and `noStrict` skips (strict-only engine)
- Sloppy mode
- qjs CLI/std/os modules
- `(o?.m)()` undefined-this "fix"
- Arbitrary-precision BigInt

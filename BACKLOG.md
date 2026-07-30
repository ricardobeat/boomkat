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

## Compiler / codegen correctness (session 302)

Four silent wrong-value or spec bugs, all of the same shape: an invariant hand-maintained in N places, wrong in the copies that omit it.

- [x] Ternary as the right operand of a binary op took the false branch (`5 + (true?10:20)` → 25). Two jump-blind peepholes; three fusion passes already carried a jump-target bitset and were correct, the two without one were the two that were buggy — `073aa16b`
- [x] Bare truthiness test on a loop counter read a stale value (`for(…){if(j)…}` → "333"). The `&&`/`||` bridge correction matched on opcode and offset sign alone, never register identity. Predates `69e65f84` — `4f486724`
- [x] `(u=45)>0` emitted the comparison into `u`'s own home register; `hoist_decls` swallowed a function's closing brace and hoisted a sibling's locals — `b0fdc49c`
- [ ] Arrow functions skip duplicate-param and restricted-name checks — `(a, a) => a` parses clean, node throws SyntaxError. Third parameter prologue, missing the invariant (plan 061 B1)
- [ ] Audit the remaining fusions (`run_move_gg_fusion`, `run_jmp_lt_g_fusion`) for positional-only reasoning; prefer one shared adjacency guard over per-site checks

## Test coverage gaps

- [ ] **4604 `$DONOTEVALUATE` tests are skipped wholesale**, ~95% of them `negative: phase: parse` — the tests that verify the engine *rejects* bad syntax. The suite validates what we accept and never what we must refuse. This is why the arrow duplicate-param bug survived: `arrow-function/params-duplicate.js` exists, `--single` reports FAIL, and the suite reads 0 fails. A `phase: parse` test is trivially checkable — compile and assert SyntaxError, never execute
- [ ] Golden bytecode has no case for control-flow-carrying expressions (ternary, `&&`/`||`, `?.`) — the shapes behind both codegen bugs above. Pair every new golden with a behavioural assertion, or regenerating goldens silently destroys the coverage
- [ ] Two general codegen bugs fixed in `b0fdc49c` are covered only incidentally by the third-party `t11_colord` bundle

## Out of scope

- test262: Temporal, `intl402`, `staging`, annexB, `harness`, other Stage 3 proposals
- test262 dirs: `statements/with`, `statements/labeled`, `statements/using`, `statements/await-using`
- Feature tokens: `cross-realm`, `tail-call-optimization`, `caller`, `__proto__`/`__getter__`/`__setter__`
- In-phase `noStrict` skips (strict-only engine by design — see AGENTS.md §Strict-Only Mode)
- Sloppy mode

  Note: `$DONOTEVALUATE` was previously listed here alongside `noStrict`. That conflated two different things — `noStrict` tests are out of scope because the engine is deliberately single-mode, but parse-negative tests are squarely in scope for a strict-only engine and are now tracked above.
- qjs CLI/std/os modules
- `(o?.m)()` undefined-this "fix"
- Arbitrary-precision BigInt

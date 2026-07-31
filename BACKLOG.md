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

## Host / console

- [ ] **No `util.inspect`, so every object renders as `[object Object]`** — `console.log({a:1})`, `console.dir(obj)`, and the `%o`/`%O` specifiers all fall back to plain ToString. Node prints `{ a: 1 }`. The gap is wider than plain objects: `[1,2,3]` loses its brackets (prints `1,2,3`), `new Map([[1,2]])` prints `[object Map]` rather than `Map(1) { 1 => 2 }`, a function prints its source instead of `[Function: f]`, and a cyclic structure needs `[Circular *1]` rather than recursing. Three call sites already carry a comment naming the absence (`src/builtins/global.c3:92,267`); the format-specifier machinery beside them is complete and node-verified, so this is the one missing piece. Found by the verbatim Rosetta suite, which had to drop several samples that print an object
- [ ] `Date.prototype.toLocaleString` ignores its options bag and `timeZone`, returning `toString()` (`src/builtins/date.c3:903`). ES5 §15.9.5.5 permits an implementation-defined result, so this is conformant today and only a gap against ECMA-402 — listed here rather than under Out of scope because the `intl402` exclusion covers the test suite, not the method's behavior. Cost the verbatim Rosetta suite its `Date_format` sample

## Test coverage gaps

- [ ] **4604 `$DONOTEVALUATE` tests are skipped wholesale**, ~95% of them `negative: phase: parse` — the tests that verify the engine *rejects* bad syntax. The suite validates what we accept and never what we must refuse. This is why the arrow duplicate-param bug survived: `arrow-function/params-duplicate.js` exists, `--single` reports FAIL, and the suite reads 0 fails. A `phase: parse` test is trivially checkable — compile and assert SyntaxError, never execute
- [ ] Golden bytecode has no case for control-flow-carrying expressions (ternary, `&&`/`||`, `?.`) — the shapes behind both codegen bugs above. Pair every new golden with a behavioural assertion, or regenerating goldens silently destroys the coverage
- [ ] Two general codegen bugs fixed in `b0fdc49c` are covered only incidentally by the third-party `t11_colord` bundle
- [x] Engine tests only exercised code we wrote — `test/rosetta-verbatim/` now runs 41 unmodified rosettacode.org samples, cross-checked against qjs and mutation-tested (`just rosetta`). Roughly half the candidate tasks are unusable as verbatim samples; `test/rosetta-verbatim/README.md` records each exclusion reason

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

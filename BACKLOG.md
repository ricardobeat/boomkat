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
- [x] Arrow functions skip duplicate-param and restricted-name checks — `(a, a) => a` now correctly throws SyntaxError (verified session 303; the entry was stale)
- [ ] Audit the remaining fusions (`run_move_gg_fusion`, `run_jmp_lt_g_fusion`) for positional-only reasoning; prefer one shared adjacency guard over per-site checks

## Host / console

- [x] **`util.inspect`-style object rendering** — `console.log`, `console.dir` and the `%o`/`%O` specifiers now route through `src/builtins/inspect.c3`, matched against node v24 byte-for-byte: plain objects and arrays, holes, Map/Set, functions and classes, errors, boxed primitives, null-prototype objects, TypedArrays, symbols, BigInt, `-0`, `[Circular *1]` under a `<ref *1>` marker, the depth-2 limit, and node's line-breaking and column-grouping rules. Getters render as `[Getter]` and are never invoked. `test/console_format/` grew from 59 to 5796 lines of node-captured expectation, the bulk of it a generated shape x kind x size matrix. Remaining deviation: `%o` does not imply node's `showHidden`/depth-4, so it renders as `%O` rather than listing `[length]`/`[prototype]`
- [ ] `Date.prototype.toLocaleString` ignores its options bag and `timeZone`, returning `toString()` (`src/builtins/date.c3:903`). ES5 §15.9.5.5 permits an implementation-defined result, so this is conformant today and only a gap against ECMA-402 — listed here rather than under Out of scope because the `intl402` exclusion covers the test suite, not the method's behavior. Cost the verbatim Rosetta suite its `Date_format` sample

## Test coverage gaps

- [x] **`$DONOTEVALUATE` parse-negative tests are no longer skipped wholesale** — `scripts/run_test262.py:851` compiles `negative: phase: parse` tests and scores rejection as a pass. Un-skipping them surfaced 35 real failures (all cleared in session 303). Only `phase: resolution` module-linking negatives remain skipped, correctly: they need the loader, not the parser
- [ ] Golden bytecode has no case for control-flow-carrying expressions (ternary, `&&`/`||`, `?.`) — the shapes behind both codegen bugs above. Pair every new golden with a behavioural assertion, or regenerating goldens silently destroys the coverage
- [ ] Two general codegen bugs fixed in `b0fdc49c` are covered only incidentally by the third-party `t11_colord` bundle
- [x] Engine tests only exercised code we wrote — `test/rosetta-verbatim/` now runs 41 unmodified rosettacode.org samples, cross-checked against qjs and mutation-tested (`just rosetta`). Roughly half the candidate tasks are unusable as verbatim samples; `test/rosetta-verbatim/README.md` records each exclusion reason

## Parser over-rejection (valid code refused)

Found while clearing the parse-negative clusters in session 303. None are
test262-visible — every phase reports 0 fail / 0 unexpected-CE — so these need
their own regression tests or they will silently persist.

- [ ] **`await` as an arrow parameter outside async** — `await => 1` and `(await) => 1` are rejected; node accepts both. Verified independently of the escaped-keyword family (the unescaped spelling fails identically, and it reproduces with the escape fix stashed). The async-context control is correct: `async function g(){ var f = await => 1; }` still rejects, matching node
- [ ] **ClassHeritage rejects valid non-arrow forms** — `class C extends (() => {}) {}` (parenthesized arrow) and `class C extends [] {}` (array literal) are rejected; node accepts both. Confirmed pre-existing against a binary built at `1455e786`. Distinct from the bare `class C extends () => {}` case, which is correctly rejected — ClassHeritage is a LeftHandSideExpression, and a *parenthesized* arrow satisfies that

## Latent runtime bugs

- [ ] **`test/test_async_loops.js` segfaults under aggressive GC** — reproduces on clean `main` with only `mark_and_sweep`'s phase-4 rescale pinned to 1 (collect at every allocation), so it predates session 303 and is unrelated to the async-generator drain fix. Would likely reproduce under ASAN at normal GC settings given enough load. A real lifetime bug, currently invisible to every gate

## Design debt

- [ ] **One remaining hand-rolled copy of the `await` identifier predicate** — `src/compiler/destructuring.c3:45` (`shorthand_key_is_identifier_ref`) re-implements the same `is_module`/`is_async`/`forbid_await` triple as the shared `await_is_identifier`. Currently correct, so this is consolidation rather than a bug fix. Worth doing: this exact pattern — one invariant hand-maintained at N sites, wrong in the copies that omit it — has now been the root cause five times (the four session-302 codegen bugs, plans 063/064/065/066). Plans 064, 065, and 066 each fixed it by *removing* copies

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

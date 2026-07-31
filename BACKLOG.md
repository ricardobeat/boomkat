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

- [x] **Structured object rendering for console** — `console.log`, `console.dir` and the `%o`/`%O` specifiers now route through `src/builtins/inspect.c3`, matched byte-for-byte against captured reference output: plain objects and arrays, holes, Map/Set, functions and classes, errors, boxed primitives, null-prototype objects, TypedArrays, symbols, BigInt, `-0`, `[Circular *1]` under a `<ref *1>` marker, the depth-2 limit, and the line-breaking and column-grouping rules. Getters render as `[Getter]` and are never invoked. `test/console_format/` grew from 59 to 5796 lines of captured expectation, the bulk of it a generated shape x kind x size matrix. Remaining deviation: `%o` does not imply `showHidden`/depth-4, so it renders as `%O` rather than listing `[length]`/`[prototype]`
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

- [x] **`await` as an arrow parameter outside async** — `await => 1`, `(await) => 1`, `(a, await) => a` and `(...await) => …` all bind a parameter named `await` in script code and were rejected. ArrowParameters inherit the enclosing `[Await]`, so the reservation is read off the enclosing context, not the arrow's own flag. The head scan tested for `IDENTIFIER` directly, which no `await` token ever is, so the head never registered as an arrow. Every async-context reservation still rejects

  ~~**ClassHeritage rejects valid non-arrow forms**~~ — **withdrawn, this was never a bug.** `class C extends (() => {}) {}`, `extends []`, `extends ({})`, `extends 1` and `` extends `t` `` all throw `TypeError: class extends value is not a constructor or null` — a *runtime* error, and exactly what node does. The valid cases (`extends null`, `extends (B)`) evaluate fine in both. The original entry came from probing with `node --check`, which only parses and never evaluates the class, so a correct runtime TypeError read as a parse over-rejection. **Methodology note: `node --check` is the wrong oracle for anything whose error is thrown at evaluation time — run node for real.**

## Latent runtime bugs

- [x] **`test/test_async_loops.js` segfaulted under aggressive GC** — a generator/async resume restores `gs.saved_regs` with `tval_copy_ref`, taking a reference per heap value, but bypassed `track_heap_store` while `activation_begin` had just reset `max_heap_reg = 0`. `decref_callee_regs` sweeps only `[0..max_heap_reg]`, so restored registers above the highest index the resumed body happened to rewrite were never decref'd or cleared: the reference leaked and the slot kept stale pointer bits, which `vm_mark_activations` later read through a different frame reusing that valstack address. `track_restored_regs` raises the watermark over the restored window at both resume sites. Reachable in principle at any GC cadence; it needed collection pressure to surface. `just test-gc-stress` now covers it
- [ ] **`max_heap_reg == 0` is both a sentinel and a valid register index** — `decref_callee_regs` early-returns on zero, so a frame whose only heap register is register 0 leaks it. Found while fixing the above; no repro produced, and the fix (a one-based count) touches every use site, so it was flagged rather than changed speculatively
- [ ] **Bulk register restores must maintain `max_heap_reg` themselves** — the two generator/async resume paths are the complete set today (every other `saved_regs[i]` use is a save, not a restore), but any future path that bulk-copies values into a frame's registers has the same defect and the same signature. The comment at `src/vm/vm_core.c3:164` claiming slots past the live data "are zero-initialised to undefined, which marks harmlessly" is falsified: capping the mark scan at `valstack_top + 4` just moves the crash. The scan is safe only because slots are now cleared correctly

## Design debt

- [x] **`StrBuf` by-value copy hazard documented** — `data` points into the struct's own `inline_buf` until the first growth, so copying by value dangles the copy's pointer. Silent and size-dependent: corrupts buffers <= 256 bytes, looks correct for grown ones. Audited the tree: `src/builtins/inspect.c3:862` is the ONLY by-value copy and it already re-points `data`; no other site copies one. A do-not-copy warning now sits on the struct definition (`src/builtins/core.c3`) so a future copy does not reintroduce it silently

- [x] **The last hand-rolled copy of the `await` identifier predicate is gone** — `shorthand_key_is_identifier_ref` in `src/compiler/destructuring.c3` now calls the shared `await_is_identifier`. Folded into the arrow-parameter fix, since that work routed the scan and binding sites through the same helper. This pattern, one invariant hand-maintained at N sites and wrong in the copies that omit it, was the root cause six times (the four session-302 codegen bugs, plans 063/064/065/066); four of those fixes worked by *removing* copies

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

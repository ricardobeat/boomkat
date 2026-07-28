# Duktape C3 — Backlog

One entry per unique issue. Status: `[ ]` TODO · `[>]` IN PROGRESS (agent running) · `[x]` DONE. Minimum detail to start a task; no history — closed entries are deleted, not archived.

Before scheduling work on an entry, re-probe it against `main`. Several entries in the previous backlog were filed from mid-flight worktree state and were already fixed, or were never bugs, by the time they were read.

## test262 coverage (measured 2026-07-27)

"0 fails" is not "100% pass". Three filters sit between the suite and that number:

| | tests |
|---|---|
| Full suite | 53,319 |
| Reachable by any `PHASES` entry | 38,328 (**14,991 in no phase at all**) |
| Actually attempted | 31,154 (7,174 skipped in-phase, 18.7%) |

The zero-fail claim covers **58%** of the suite. The rest is not failing — it is not running.

Reproduce with a walk over `PHASES` dirs + `skip_reason()` from `scripts/run_test262.py`.

### Un-skip candidates (ranked by tests-per-effort)

- [ ] **`object-rest` — 339 tests.** `{...rest}` in destructuring. Plain ES2018, skipped by feature token with no stated blocker. Probe first: the token may be stale, or may hide real work.
- [ ] **`numeric-separator-literal` — 75 tests.** `1_000_000`. Lexer-local, ES2021.
- [ ] **`error-stack-accessor` — 35 tests.**
- [ ] **Add orphaned directories to `PHASES`.** Cheap, and surfaces real failures rather than creating them. Expect `language/literals/regexp` to fail immediately: the engine never parse-time-validates regexp literals (semantic errors are only caught if the literal is evaluated), acknowledged in the `regexp-modifiers` comment in run_test262.py. Also `built-ins/decodeURI*`/`encodeURI*` (~170), `built-ins/global` (29), `AggregateError` (25).
- [ ] **`built-ins/Iterator` — 514 tests**, in no phase.
- [ ] **Modules — ~726 tests** (`language/module-code` 599 + `language/import` 127), plus unblocks class tests. Biggest block, biggest effort. The runner cannot drive `flags: [module]` tests at all; several class skips exist *only* for that reason and note the engine is correct when verified manually with `--module`.

### Engine gaps behind the class skip-list

1,152 of the 1,275 `SKIP_FILES` entries are class tests, each documenting a real gap:

- [ ] **Public field install through a Proxy receiver.** Per ES2022 §15.7.10 step 8.b, `CreateDataPropertyOrThrow` runs `[[DefineOwnProperty]]` on the receiver, so a Proxy `defineProperty` trap must fire. `INITPROP` uses the raw `hobj.put_prop` path — correct for the no-proxy fast path, observably wrong when the receiver IS a Proxy. Fix named in-source: route through `ordinary_define_own`. **A correctness bug, not just a test gap.**
- [ ] **Private-field return-override.** Spec puts private methods on the class prototype, but a subclass return-override makes `super()` return an object whose [[Prototype]] is not the subclass prototype — the brand isn't stamped and the method chain is broken. Needs private methods copied per-instance: deep architectural change.
- [ ] **Brand propagation across Base→Derived when the superclass returns an object** — field-init/brand stamp doesn't reach the substituted `this`. `vm_calls.c3` / `vm_execute.c3`.
- [ ] **`ContainsArguments` static analysis** (§15.7.10 step 14) for direct eval in a field initializer. `forbid_arguments` rejects at parse time, so the required eval-time SyntaxError never fires.
- [ ] **Same-line class-body parsing.** Multiple class elements on one line separated by `;`; also `fields-asi-1` chained assignment (`x = obj\n['lol'] = 42` must parse as chained, no ASI before `[` per §11.9.1). Needs a unified element boundary respecting ASI-without-bracket-continuation — a parser refactor crossing class-body / expressions.c3.
- [ ] **Forward references to private names from computed property keys.** `private_names.c3`'s pre-scan only recognises direct `obj.#x` via prev_tok_type DOT/OPT_CHAIN; `[self.#x] = ...` in a field initializer doesn't adopt private names from the parent class context.

### Out of scope (do not reopen)

Temporal (4,603), `intl402` (~3,300), `staging` (1,493), annexB, `harness`, other Stage 3 proposals. Feature tokens `cross-realm` (171), `tail-call-optimization` (31), `caller` (23), `__proto__`/`__getter__`/`__setter__`. In-phase `$DONOTEVALUATE` (3,467) and `noStrict` (1,250) skips are legitimate for a strict-only engine.

## Infrastructure

- [ ] **test262 runner cannot complete a full suite in one shot.** Worker desync crash at `run_test262.py:1101` immediately after two `[timeout]`s on RegExp property-escape generated tests. Harness protocol bug in timeout handling, not an engine failure — `7a1a8804` touched exactly this path. Workaround: run phases individually. **Blocks I4.**
- [ ] **I4 — two-consecutive-run zero-fail gate in CI.** Needs a user decision on where CI runs (GitHub Actions / git hook / just recipe). Full suite is 6-8 min, so a two-run gate is ~15 min. Blocked on the desync above: a gate needing two clean full runs can't sit on a harness that dies partway through the first.
- [ ] **Runner config single source of truth.** `UNSUPPORTED_PATTERN` vs `scripts/test262_skip.cfg` doc mirror has drifted twice. Any "pure reorganization" of the skip list needs a machine-checked token-set diff, not a prose claim — a re-tier agent once asserted an empty diff while adding five tokens, two of which would have hidden working features.

## Engine design review

Full-engine pass for duplication/elegance/compactness at constant perf+correctness. Method: read-only Explore survey per subsystem → ranked plan → small fix agents with bench gates (bench-fast + golden + phase sweeps per change).

- [ ] **Generator driver family** — sync YIELD_STAR opcode vs async yield* machinery vs async_generator.c3 drain; unify the delegation/completion surface. Also duplicated activation-teardown in vm_generators.c3 (AWAIT reject/OOM paths repeat ~40 lines).
- [ ] **Three super mechanisms** — plan 059's unification (GETPROTO(homeObject) everywhere).
- [ ] **Builtin error-throw boilerplate** — dozens of hand-rolled alloc ERROR + intern message + put_prop blocks. Helper families exist per-file (arr_throw_*, arraybuffer_throw_*) but aren't shared engine-wide.
- [ ] **ArrayBuffer vs SharedArrayBuffer** — SAB duplicates ctor/getter/slice shapes; growable-SAB vs resizable-AB grow paths.
- [ ] **Keyed-collection internals** — coll_* helpers + group_by_* + getOrInsert grew adjacent copies of key canonicalization.
- [ ] **Lexer scan buffers** — string/template/ident decode paths share arena+normalize logic candidates.
- [ ] **Enum/metadata/dispatch triple registration** in core.c3 for every builtin (persistent merge-conflict magnet) — consider a table macro.

## Known bugs

- [ ] **Date pre-1970 year off-by-one** — `new Date(-1).getUTCFullYear()` → 1970, should be 1969. In `date_break_time*`.
- [ ] **Generator-resume path never assigns `new_target`.** Different mechanism from the frames fixed in 107fe880 (it restores saved state), so it was left unexamined. Worth a look if async/generator × super ever misbehaves.

## Non-goals (do not reopen)

- **Sloppy mode** — engine is strict-only by design (also covers apply/call sloppy `this`). QuickJS has it; out of scope unless the user says otherwise. Note this is why direct `eval("var x=7")` doesn't create a global binding — correct strict-eval semantics per §18.2.1.1 step 12, not a bug.
- **Native UTF-16/Latin1 string storage** — big GC/string-builtin migration.
- **qjs CLI/std/os modules** — not JS-language parity.
- **`(o?.m)()` undefined-this "fix"** — was a misdiagnosis, reverted. Parens preserve the optional-chain receiver (`optional-call-preserves-this.js`). Don't re-introduce.

## QuickJS parity status

Full feature-probe diff vs vendored `out/qjs` (globals, ~80 builtin members, 18 syntax forms): **zero gaps remaining** as of 2026-07-23. We exceed qjs on `Array.fromAsync` and `Atomics.waitAsync`. qjs lacks legacy RegExp statics and Realm, so those aren't parity items; `$262.agent`/`createRealm`/cross-realm are test-harness host features, not engine-language features.

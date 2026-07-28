# Duktape C3 — Backlog

One entry per unique issue. Status: `[ ]` TODO · `[>]` IN PROGRESS (agent running) · `[x]` DONE. Minimum detail to start a task; no history — closed entries are deleted, not archived.

Before scheduling work on an entry, re-probe it against `main`. Several entries in the previous backlog were filed from mid-flight worktree state and were already fixed, or were never bugs, by the time they were read.

## test262 coverage (measured 2026-07-28)

"0 fails" is not "100% pass". Three filters sit between the suite and that number:

| | tests |
|---|---|
| Full suite | 53,319 |
| Reachable by any `PHASES` entry | 39,046 (**14,273 in no phase at all**) |
| Actually attempted | 32,078 (6,968 skipped in-phase) |

Coverage is **60%** of the suite. The rest is not failing — it is not running.

**The suite is currently RED: 31 known failures** (phase 8: 11 + 1 CE, phase 21: 19),
surfaced deliberately by `916ffaed` adding 14 orphaned directories. Down from 66. Root
causes are itemised below; each is real engine work. Do not re-hide them by skip-listing.
All other phases are 0 fails.

Reproduce with a walk over `PHASES` dirs + `skip_reason()` from `scripts/run_test262.py`.

### Un-skip candidates (ranked by tests-per-effort)

- [>] **`object-rest` — 342 tests. NOT a stale token: two real engine bugs.** Rest collection copies properties structurally instead of running CopyDataProperties (§7.3.24), so getters never fire and non-enumerable own properties leak in *carrying their non-enumerable attribute*. Affects every form — var, assignment, param, for-of, for-await-of — so one shared routine is at fault. Probe with `hasOwnProperty`, **never `JSON.stringify`**: the leaked property is invisible to stringify, which makes the bug look absent. Fix in flight (batch1).
- [ ] **`built-ins/Iterator` — 514 tests**, in no phase.
- [ ] **Modules — ~726 tests** (`language/module-code` 599 + `language/import` 127), plus unblocks class tests. Biggest block, biggest effort. The runner cannot drive `flags: [module]` tests at all; several class skips exist *only* for that reason and note the engine is correct when verified manually with `--module`.

### Open failures from the PHASES expansion (916ffaed) — 66 fails, 12 root causes

Ordered by tests-fixed-per-effort. Every one verified against `main`.

- [ ] **Line terminators inside regexp literals — ~10 fails.** `7.8.5-1.js`,
  `S7.8.5_A1.3/1.5/2.3/2.5_*` in `language/literals/regexp`. Distinct from the `/=` bug
  fixed in `9c7ce68b`; the original entry wrongly attributed all ~11 of that directory's
  failures to `/=`, when only `S7.8.5_A1.1_T2.js` was actually caused by it.
- [ ] **`x++ / 2` raises a SyntaxError.** Pre-existing bug in postfix-operand handling —
  `prev_was_operand()` does not treat a postfix `++`/`--` as ending an operand, so the
  following `/` starts a regexp. Found while fixing `/=`, confirmed on main, out of that
  task's scope. Not currently covered by a running test.
- [ ] **`RegExp.prototype[Symbol.matchAll]` ignores a custom `exec` — 7 fails.** Surfaced
  once `%RegExpStringIteratorPrototype%` landed (`07bf4e8a`) and confirmed pre-existing on
  main: `custom-regexpexec*.js` (7) and `regexp-tolength-lastindex-throws.js`. The iterator
  calls the internal matcher directly instead of going through `RegExpExec`, so a
  user-supplied `exec` / a throwing `lastIndex` ToLength never runs.
- [ ] **Iterator `next` methods throw a bare `undefined` instead of a TypeError.**
  `builtin_map_iterator_next` (map.c3), `builtin_set_iterator_next` (set.c3) and
  `builtin_string_iterator_next` (iterator.c3) still use `should_throw=true` +
  `set_undefined()` rather than `builtin_throw`. The array and regexp-string variants were
  fixed in `07bf4e8a`; these three were out of that task's scope and are not currently
  covered by a running test.
- [ ] **`AggregateError` constructor incomplete — 7 fails.** `errors` stored verbatim
  instead of `IterableToList`-spread (`src/builtins/error.c3:159-246`);
  `register_native_error_ctor` (`:688`) hardcodes `length=1` but AggregateError needs 2.
- [ ] **`GeneratorPrototype.next/return/throw` don't validate `this` — 6 fails.**
  `this` = undefined or a plain object must TypeError.
- [ ] **`builtin_to_string` skips ToPrimitive on objects — audit its ~25 call sites.**
  `src/builtins/core.c3:2096-2097` hardcodes `"[object Object]"` instead of running
  `[Symbol.toPrimitive]`/`toString`/`valueOf`, so abrupt completions never propagate.
  The correct helper `builtin_to_string_vm` already exists; the URI builtins were routed
  through it in `eea15205` rather than changing the shared function. 9 other files still
  call the broken one (array.c3, date.c3, json.c3, error.c3, string.c3, object.c3,
  regexp.c3, typedarray.c3). Each site needs deciding: genuine ToPrimitive, or a
  deliberate raw fallback. Feeds the AggregateError `message` bug below.
- [ ] **Generator `.return()` inside nested try/finally — 3 fails.** Finally blocks not
  running / final value not surfacing. May share a cause with the finally-return abort path.
- [ ] **`undefined = 12` rejected at parse time — 1 CE:unexpected.** Must parse and throw
  `TypeError` at runtime, not `SyntaxError` at parse time.
- [ ] **`GeneratorFunction.prototype.constructor` is writable — 1 fail.** Should be non-writable.
- [ ] **`AsyncFunction` `[[Prototype]]` chain wrong — 1 fail.** Expected `Function`.

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

- [ ] **Bound-function internals leak through `Object.getOwnPropertyNames`.** `function.c3` stores `\x00bound_target` / `\x00bound_this` / `\x00bound_args` as NUL-prefixed own properties; `getOwnPropertyNames`/`Reflect.ownKeys` don't filter on enumerability, so `Object.getOwnPropertyNames(fn.bind())` exposes all three. Found while implementing error-stack-accessor, which hit the same trap using that idiom and broke two Object/create tests before switching to real extra-union storage (`643ecbd5`). Same fix applies: give BOUND_FUNCTION union storage instead of internal properties.
- [ ] **Date pre-1970 year off-by-one** — `new Date(-1).getUTCFullYear()` → 1970, should be 1969. In `date_break_time*`.
- [ ] **Generator-resume path never assigns `new_target`.** Different mechanism from the frames fixed in 107fe880 (it restores saved state), so it was left unexamined. Worth a look if async/generator × super ever misbehaves.

## Non-goals (do not reopen)

- **Sloppy mode** — engine is strict-only by design (also covers apply/call sloppy `this`). QuickJS has it; out of scope unless the user says otherwise. Note this is why direct `eval("var x=7")` doesn't create a global binding — correct strict-eval semantics per §18.2.1.1 step 12, not a bug.
- **Native UTF-16/Latin1 string storage** — big GC/string-builtin migration.
- **qjs CLI/std/os modules** — not JS-language parity.
- **`(o?.m)()` undefined-this "fix"** — was a misdiagnosis, reverted. Parens preserve the optional-chain receiver (`optional-call-preserves-this.js`). Don't re-introduce.

## QuickJS parity status

Full feature-probe diff vs vendored `out/qjs` (globals, ~80 builtin members, 18 syntax forms): **zero gaps remaining** as of 2026-07-23. We exceed qjs on `Array.fromAsync` and `Atomics.waitAsync`. qjs lacks legacy RegExp statics and Realm, so those aren't parity items; `$262.agent`/`createRealm`/cross-realm are test-harness host features, not engine-language features.

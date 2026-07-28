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

**The suite is currently RED: 66 known failures**, surfaced deliberately by `916ffaed`
adding 14 orphaned directories. Root causes are itemised below; each is real engine
work. Do not re-hide them by skip-listing.

Reproduce with a walk over `PHASES` dirs + `skip_reason()` from `scripts/run_test262.py`.

### Un-skip candidates (ranked by tests-per-effort)

- [>] **`object-rest` — 342 tests. NOT a stale token: two real engine bugs.** Rest collection copies properties structurally instead of running CopyDataProperties (§7.3.24), so getters never fire and non-enumerable own properties leak in *carrying their non-enumerable attribute*. Affects every form — var, assignment, param, for-of, for-await-of — so one shared routine is at fault. Probe with `hasOwnProperty`, **never `JSON.stringify`**: the leaked property is invisible to stringify, which makes the bug look absent. Fix in flight (batch1).
- [ ] **`built-ins/Iterator` — 514 tests**, in no phase.
- [ ] **Modules — ~726 tests** (`language/module-code` 599 + `language/import` 127), plus unblocks class tests. Biggest block, biggest effort. The runner cannot drive `flags: [module]` tests at all; several class skips exist *only* for that reason and note the engine is correct when verified manually with `--module`.

### Open failures from the PHASES expansion (916ffaed) — 66 fails, 12 root causes

Ordered by tests-fixed-per-effort. Every one verified against `main`.

- [ ] **Regexp literal starting with `=` fails to parse — 12 fails.** `/=/ ` is a
  SyntaxError; `src/lexer.c3:2367` routes `/` + `=` to division-assign
  unconditionally, ignoring whether a regexp is syntactically expected
  (`!prev_was_operand()`). Affects real code, not just tests. Smallest fix, high value.
- [ ] **Lone surrogates not rejected by `encodeURI*`/`decodeURI*` — 17 fails.**
  `encodeURI(String.fromCharCode(0xDC00))` yields `"%ED%B0%80"`; must throw `URIError`.
  Both encode and decode sides.
- [ ] **`%RegExpStringIteratorPrototype%` does not exist — 13 fails.**
  `src/builtins/regexp.c3:2057-2115` puts `.next` as an *own* property on each
  iterator instance and points `[[Prototype]]` straight at `%IteratorPrototype%`,
  with no intermediate layer carrying `[Symbol.toStringTag]`.
- [ ] **`AggregateError` constructor incomplete — 7 fails.** `errors` stored verbatim
  instead of `IterableToList`-spread (`src/builtins/error.c3:159-246`);
  `register_native_error_ctor` (`:688`) hardcodes `length=1` but AggregateError needs 2.
- [ ] **`GeneratorPrototype.next/return/throw` don't validate `this` — 6 fails.**
  `this` = undefined or a plain object must TypeError.
- [ ] **`builtin_to_string` skips ToPrimitive on objects — 2 fails + feeds AggregateError.**
  `src/builtins/core.c3:2096-2097` hardcodes `"[object Object]"` instead of running
  `[Symbol.toPrimitive]`/`toString`/`valueOf`, so abrupt completions never propagate.
- [ ] **Generator `.return()` inside nested try/finally — 3 fails.** Finally blocks not
  running / final value not surfacing. May share a cause with the finally-return abort path.
- [ ] **`ArrayIteratorPrototype.next` missing own `.length`/`.name` — 3 fails.**
  Hand-built native function that skipped `set_func_ctor_name_length`; same pattern as
  the RegExpStringIterator gap.
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

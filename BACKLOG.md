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

**1 known failure** (phase 21, `Iterator/from/return-method-calls-base-return-method.js`)
— see the refcount item below; every other phase is at 0. The measured surface has grown
1,232 tests this session (14 orphaned directories in `916ffaed`, `built-ins/Iterator` in
`0a46d74c`), and the 66 failures that surfaced are all fixed. Nothing was skip-listed.
Note this is ~0 fails on 60% of the suite, not 100% pass — see the table above.

Reproduce with a walk over `PHASES` dirs + `skip_reason()` from `scripts/run_test262.py`.

### Un-skip candidates (ranked by tests-per-effort)

- [ ] **Modules — ~726 tests** (`language/module-code` 599 + `language/import` 127), plus unblocks class tests. Biggest block, biggest effort. The runner cannot drive `flags: [module]` tests at all; several class skips exist *only* for that reason and note the engine is correct when verified manually with `--module`.

### Refcounting

- [ ] **Object values stored in properties or array slots are never refcounted.**
  `HObject.put_prop` and `HObject.set_array_idx` incref/decref only `is_string()` /
  `is_bigint()` values; object values rely entirely on mark-and-sweep for reachability, and
  `hobject_free`'s teardown matches (with a comment saying objects "still use M&S"). The
  gap: a value reachable ONLY through such an edge is refcount-freed the moment its
  producing register is decref'd at frame teardown — no reachability check — before M&S can
  discover it is still live via a sibling closure's `lex_env` chain. This is the single
  known suite failure (`Iterator/from/return-method-calls-base-return-method.js`).
  A prototype extending both writers and the teardown loop to all `is_heap_allocated()`
  values fixed it and the hand-reduced repro, and is preserved at
  `stash@{0}: On batch/slot2: batch2-investigate-putprop-refcount` in `.worktrees/batch2`.
  It was NOT landed: it changes ownership policy for the whole heap and needs its own task
  with full-sweep + leak + bench verification.
- [ ] **`ctx.result` aliases `ctx.this_val` on entry to every builtin.** Every call
  convention seeds the result register with a raw, non-incref'd copy of `this` before the
  builtin runs, because the result slot doubles as the this/callee slot. So
  `tval_copy_ref(ctx.result, &ctx.this_val)` is wrong in a builtin — its aliasing guard only
  catches literal pointer identity, so it cancels the incref and under-refcounts. Cost a
  full agent cycle in `76df18c6`. Audit other builtins for the same call, and consider
  making the guard detect same-heap-object-different-TVal-location.

### Bugs with no test coverage

Real bugs found while fixing the 66, which no running test exercises — they will not show
up in a phase run, so a green suite is not evidence against them. Each verified against
`main` by probe and qjs comparison.

- [ ] **Re-measure the engine's baseline leak count.** A 2000-iteration async-generator
  stress script reported ~27,000 leaks / 4 MB before `dc2945cb`; most of that was the
  generator `GeneratorState` leak, now fixed. Re-run to find what remains beyond the async
  residual above. Leak work must always compare a same-session delta against a baseline
  binary, never read the absolute number.
- [ ] **`error.c3:92` `.stack` name fallback uses raw `builtin_to_string`.** Reachable and
  observable: `Error.prototype.name` is writable, so `Error.prototype.name = {toString(){…}}`
  should invoke that `toString`. The naive fix (swap in `builtin_to_string_vm`) was tried
  and **rejected** — it makes `new Error()` call `toString` during *construction*, so the
  count goes 1 → 2 and diverges from qjs, which never reads `.name` at construction. The
  real fix must make the `.stack` capture not eagerly read `.name` at all, or read it
  without user-visible coercion. Verify with a call-counter probe across construction and
  `.name` access separately, not just the final string.

### Engine gaps behind the class skip-list

The class skip-list entries each document a real gap:

- [ ] **Private-field return-override.** Spec puts private methods on the class prototype, but a subclass return-override makes `super()` return an object whose [[Prototype]] is not the subclass prototype — the brand isn't stamped and the method chain is broken. Needs private methods copied per-instance: deep architectural change.
- [ ] **Brand propagation across Base→Derived when the superclass returns an object** — field-init/brand stamp doesn't reach the substituted `this`. `vm_calls.c3` / `vm_execute.c3`.
- [ ] **`ContainsArguments` static analysis** (§15.7.10 step 14) for direct eval in a field initializer. `forbid_arguments` rejects at parse time, so the required eval-time SyntaxError never fires.
- [ ] **Same-line class-body parsing.** Multiple class elements on one line separated by `;`; also `fields-asi-1` chained assignment (`x = obj\n['lol'] = 42` must parse as chained, no ASI before `[` per §11.9.1). Needs a unified element boundary respecting ASI-without-bracket-continuation — a parser refactor crossing class-body / expressions.c3.
- [ ] **Forward references to private names from computed property keys.** `private_names.c3`'s pre-scan only recognises direct `obj.#x` via prev_tok_type DOT/OPT_CHAIN; `[self.#x] = ...` in a field initializer doesn't adopt private names from the parent class context.

### Out of scope (do not reopen)

Temporal (4,603), `intl402` (~3,300), `staging` (1,493), annexB, `harness`, other Stage 3 proposals. Feature tokens `cross-realm` (171), `tail-call-optimization` (31), `caller` (23), `__proto__`/`__getter__`/`__setter__`. In-phase `$DONOTEVALUATE` (3,467) and `noStrict` (1,250) skips are legitimate for a strict-only engine.

## Infrastructure

- [ ] **RegExp property-escapes tests are load-sensitive.** Under background load the
  generated `Script_Extensions_*` / `General_Category_*` tests hit the 10s per-test timeout
  (7 timeouts in one full run, 1 in another on an idle machine). A timeout counts as a
  failure, so `just test262-gate` can legitimately go red purely from machine load. Either
  raise the timeout for that family or make them faster; a flaky gate gets ignored.
- [ ] **Decide where `just test262-gate` runs.** The recipe exists and works standalone
  (`b0338a09`). Still a user decision whether to wire it into GitHub Actions, a pre-push
  hook, or leave it manual. Blocked on the load-sensitivity item above — wiring a flaky
  gate into CI trains people to ignore it.
- [ ] **Runner config single source of truth.** `UNSUPPORTED_PATTERN` vs `scripts/test262_skip.cfg` doc mirror has drifted twice. Any "pure reorganization" of the skip list needs a machine-checked token-set diff, not a prose claim — a re-tier agent once asserted an empty diff while adding five tokens, two of which would have hidden working features.

## Engine design review

Full-engine pass for duplication/elegance/compactness at constant perf+correctness. Method: read-only Explore survey per subsystem → ranked plan → small fix agents with bench gates (bench-fast + golden + phase sweeps per change).

- [ ] **Generator driver family** — sync YIELD_STAR opcode vs async yield* machinery vs async_generator.c3 drain; unify the delegation/completion surface. Also duplicated activation-teardown in vm_generators.c3 (AWAIT reject/OOM paths repeat ~40 lines).
- [ ] **Three super mechanisms** — plan 059's unification (GETPROTO(homeObject) everywhere).
- [ ] **Builtin error-throw boilerplate — ~55 raw sites left.** The inventory found 75 raw
  `alloc_object(ObjClass.ERROR)` blocks against ~40 existing throw helpers, so this was
  never a missing-abstraction problem: `builtin_throw` (builtins) and `vm_throw_error` /
  `throw_type_error_at` (VM, different signature — needs act/curr_pc/needs_restart) are the
  established convention and most files already use them. The highest-density outliers
  (function.c3 9 sites, vm_control.c3 4, vm_calls.c3 1, vm_core.c3 1) were migrated in
  `bd8bfb50`/`f0a1c2d3` for -183 lines. The tail is object.c3 (12 raw vs 89 already-helper),
  promise.c3 (10), generator.c3 (3), vm_coerce.c3 (3), core.c3 (4), and singles elsewhere.
  Same method applies. **Any further pass must mechanically diff every message literal** —
  test262 does not assert on message text, so a changed message passes the suite while being
  a real user-visible regression.
- [ ] **Keyed-collection internals** — coll_* helpers + group_by_* + getOrInsert grew adjacent copies of key canonicalization.
- [ ] **Lexer scan buffers** — string/template/ident decode paths share arena+normalize logic candidates.
- [ ] **Enum/metadata/dispatch triple registration** in core.c3 for every builtin (persistent merge-conflict magnet) — consider a table macro.

## Known bugs

- [ ] **`async function`'s own `GeneratorState` leaks.** The residual after `dc2945cb`
  fixed the generator case: an async function's GS is shared between its `resume_fn` and
  `reject_fn` reaction closures via `var_env`, so freeing it from either one's
  `hobject_free` risks double-freeing the sibling's reference. Needs a shared-ownership
  scheme (refcount, or a single-owner flag) before it is safe to free. Reproduces with a
  plain array argument — `Promise.all([...])` under async/await — so it is not
  generator-specific.

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

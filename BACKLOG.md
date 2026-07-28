# Duktape C3 — Backlog

`[ ]` TODO · `[>]` IN PROGRESS · `[x]` DONE. Closed entries are deleted, not archived.
Re-probe an entry against `main` before starting it.

## Status

All 18 test262 phases at 0 failures. Coverage: 32,078 of 53,319 tests attempted (60%) —
14,273 in no `PHASES` entry, 6,968 skipped in-phase.

## test262

- [ ] Modules — ~726 tests (`language/module-code`, `language/import`); runner cannot drive `flags: [module]`
- [ ] RegExp property-escapes tests time out under load (~1.1s each, 10s limit) — makes phase 8 and `just test262-gate` report false failures; re-run on an idle machine before believing any phase-8 failure
- [ ] Decide where `just test262-gate` runs (Actions / pre-push hook / manual) — blocked on the item above
- [ ] Single source of truth for `UNSUPPORTED_PATTERN` vs `scripts/test262_skip.cfg`

## Refcounting

- [ ] Re-measure the `6d7e71ca` property-write cost on an idle machine — run-to-run spread currently exceeds the effect
- [ ] Audit builtins for `tval_copy_ref(ctx.result, &ctx.this_val)` — `ctx.result` already aliases `ctx.this_val` on entry

## Known bugs

- [ ] `async function`'s own `GeneratorState` leaks — shared between `resume_fn`/`reject_fn`, needs shared ownership
- [ ] Re-measure baseline leak count after `dc2945cb`
- [ ] `error.c3:92` `.stack` name fallback skips ToPrimitive; naive `builtin_to_string_vm` swap was rejected (fires during construction)
- [ ] Bound-function internals (`\x00bound_target` etc.) leak through `Object.getOwnPropertyNames`
- [ ] `new Date(-1).getUTCFullYear()` → 1970, should be 1969 (`date_break_time*`)
- [ ] Generator-resume path never assigns `new_target`

## Class semantics (behind the skip-list)

- [ ] Private-field return-override — needs private methods copied per-instance
- [ ] Brand propagation across Base→Derived when the superclass returns an object
- [ ] `ContainsArguments` static analysis (§15.7.10 step 14) for direct eval in a field initializer
- [ ] Same-line class-body parsing, incl. `fields-asi-1` chained assignment
- [ ] Forward references to private names from computed property keys

## Engine design review

- [ ] Generator driver family — sync `YIELD_STAR` vs async yield* vs `async_generator.c3` drain
- [ ] Three super mechanisms — plan 059's `GETPROTO(homeObject)` unification
- [ ] Builtin error-throw boilerplate — ~55 raw sites left in object.c3, promise.c3, generator.c3, vm_coerce.c3, core.c3
- [ ] Lexer scan buffers — string/template/ident decode arena+normalize logic

## Out of scope

- test262: Temporal, `intl402`, `staging`, annexB, `harness`, other Stage 3 proposals
- Feature tokens: `cross-realm`, `tail-call-optimization`, `caller`, `__proto__`/`__getter__`/`__setter__`
- In-phase `$DONOTEVALUATE` and `noStrict` skips (strict-only engine)
- Sloppy mode
- Native UTF-16/Latin1 string storage
- qjs CLI/std/os modules
- `(o?.m)()` undefined-this "fix" — was a misdiagnosis, don't re-introduce

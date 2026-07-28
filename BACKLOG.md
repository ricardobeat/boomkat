# Duktape C3 — Backlog

`[ ]` TODO · `[>]` IN PROGRESS · `[x]` DONE. Entries stay in the file when they close.
Re-probe an entry against `main` before starting it.

## Status

All 18 test262 phases at 0 failures. Coverage: 32,078 of 53,319 tests attempted (60%) —
14,273 in no `PHASES` entry, 6,968 skipped in-phase.

## test262

- [ ] Modules — ~726 tests (`language/module-code`, `language/import`); runner cannot drive `flags: [module]`
- [ ] RegExp property-escapes tests time out under load (~1.1s each, 10s limit) — makes phase 8 and `just test262-gate` report false failures; re-run on an idle machine before believing any phase-8 failure
- [ ] Decide where `just test262-gate` runs (Actions / pre-push hook / manual) — blocked on the item above
- [ ] Single source of truth for `UNSUPPORTED_PATTERN` vs `scripts/test262_skip.cfg`
- [x] Add 14 orphaned directories to `PHASES` (+718 tests) — `916ffaed`
- [x] Add `built-ins/Iterator` to phase 21 (+514 tests) — `1a29b357`
- [x] Un-skip `numeric-separator-literal` — `a54af668`
- [x] Un-skip `object-rest` — `245b390f`
- [x] Un-skip `error-stack-accessor` — `643ecbd5`
- [x] Fix runner timeout-kill/reuse race causing worker verdict desync — `b0338a09`
- [x] `just test262-gate` two-consecutive-run zero-fail recipe — `b0338a09`

## Refcounting

- [ ] Re-measure the `6d7e71ca` property-write cost on an idle machine — run-to-run spread currently exceeds the effect
- [ ] Audit builtins for `tval_copy_ref(ctx.result, &ctx.this_val)` — `ctx.result` already aliases `ctx.this_val` on entry
- [x] Refcount object/buffer values in property and array slots — `6d7e71ca`
- [x] Combine incref/decref heap checks in `put_prop`/`set_array_idx` — `8c4cc55e`
- [x] Fix under-refcount in `%IteratorPrototype%[@@iterator]` — `104e61ae`
- [x] Free `GeneratorState` on generator finalize (2 allocs/call leak) — `dc2945cb`

## Known bugs

- [ ] `async function`'s own `GeneratorState` leaks — shared between `resume_fn`/`reject_fn`, needs shared ownership
- [ ] Re-measure baseline leak count after `dc2945cb`
- [ ] `error.c3:92` `.stack` name fallback skips ToPrimitive; naive `builtin_to_string_vm` swap was rejected (fires during construction)
- [ ] Bound-function internals (`\x00bound_target` etc.) leak through `Object.getOwnPropertyNames`
- [ ] `new Date(-1).getUTCFullYear()` → 1970, should be 1969 (`date_break_time*`)
- [ ] Generator-resume path never assigns `new_target`
- [x] `finally` skipped when `return` passes through a catch-only `try` — `79ca7134`, `40076777` (yield* delegation)
- [x] `Array.prototype.sort` segfaulted on a throwing `toString` — `a93ff1a9`
- [x] `Map.set(-0)` / `Set.add(-0)` stored `-0` instead of `+0` — `4bc5bbdf`
- [x] Object-rest: getters never fired, non-enumerables leaked in — `245b390f`
- [x] URI encode/decode accepted lone surrogates; skipped ToString — `eea15205`
- [x] `x++ / 2` misparsed as a regexp literal — `559c181d`
- [x] `/=/` and `/=a/` failed to parse — `9c7ce68b`
- [x] LS/PS line terminators accepted inside regexp literals — `a7640192`
- [x] `RegExp.prototype.source` over-escaped `\/` and in-class `/` — `05da3ef8`
- [x] `RegExp.prototype.test` used `lastIndex` as a byte offset, bypassed custom `exec` — `8cc102c7`
- [x] `replace`/`replaceAll` passed a byte offset to the replacer callback — `8cc102c7`
- [x] `matchAll` iterator bypassed `RegExpExec` — `d0b706c1`
- [x] Numeric separators accepted in `0_1` and `1.5_` — `a54af668`
- [x] `undefined = 12` rejected at parse time instead of throwing at runtime — `d76ca80b`
- [x] `AggregateError` stored `errors` verbatim; wrong `length` — `d76ca80b`
- [x] Map/Set/String iterator `next` threw bare `undefined` — `24abb32e`
- [x] Missing `PUTLEX` in inner-function param prologue — `3c4d8c2e`

## Class semantics (behind the skip-list)

- [ ] Private-field return-override — needs private methods copied per-instance
- [ ] Brand propagation across Base→Derived when the superclass returns an object
- [ ] `ContainsArguments` static analysis (§15.7.10 step 14) for direct eval in a field initializer
- [ ] Same-line class-body parsing, incl. `fields-asi-1` chained assignment
- [ ] Forward references to private names from computed property keys
- [x] Public field install now routes through `[[DefineOwnProperty]]` so Proxy traps fire — `e5fd5da2`

## Engine design review

- [ ] Generator driver family — sync `YIELD_STAR` vs async yield* vs `async_generator.c3` drain
- [ ] Three super mechanisms — plan 059's `GETPROTO(homeObject)` unification
- [ ] Builtin error-throw boilerplate — ~55 raw sites left in object.c3, promise.c3, generator.c3, vm_coerce.c3, core.c3
- [ ] Lexer scan buffers — string/template/ident decode arena+normalize logic
- [x] Enum/metadata/dispatch triple registration in core.c3 — `a1513ec5` (4318→3294 lines)
- [x] ArrayBuffer vs SharedArrayBuffer dedup — `21fe21f6` (1271→1080 lines)
- [x] Error-throw boilerplate, highest-density sites — `47e4e1ec`, `b978b49e` (−183 lines)
- [x] Keyed-collection internals — already unified by earlier work; one leftover deduped in `d88df8b7`
- [x] Param-init prologue triplication — `3c4d8c2e`
- [x] `%RegExpStringIteratorPrototype%` + `ArrayIteratorPrototype.next` metadata — `07bf4e8a`

## Out of scope

- test262: Temporal, `intl402`, `staging`, annexB, `harness`, other Stage 3 proposals
- Feature tokens: `cross-realm`, `tail-call-optimization`, `caller`, `__proto__`/`__getter__`/`__setter__`
- In-phase `$DONOTEVALUATE` and `noStrict` skips (strict-only engine)
- Sloppy mode
- Native UTF-16/Latin1 string storage
- qjs CLI/std/os modules
- `(o?.m)()` undefined-this "fix" — was a misdiagnosis, don't re-introduce

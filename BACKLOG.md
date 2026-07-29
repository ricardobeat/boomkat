# Duktape C3 — Backlog

`[ ]` TODO · `[>]` IN PROGRESS · `[x]` DONE.

## Status

18 of 19 test262 phases at 0 failures; phase 25 (ESM) at 399 pass / 9 fail.

## test262

- [x] Modules — phase 25 wired; 393/729 pass, 15 fail — `13912b8d`..`ed040486`
- [x] Indirect re-exports leaked as local identifiers; relative-path module identity — `ab7d4fc3`
- [ ] Direct self-import of a `class` binding doesn't throw TDZ for `typeof` before the class runs (2 tests)
- [ ] Dynamic-import DFS evaluation order and top-level-await sibling independence (4 tests)
- [ ] Same-module `import {x}; export {x}` re-export needs ParseModule table cross-referencing (2 tests)
- [ ] `top-level-await/new-await-script-code.js` compile error (1 CE)
- [ ] `scripts/test262_skip.cfg` is dead — the live skip mechanism is embedded in run_test262.py
- [ ] RegExp property-escapes tests time out under load
- [ ] Decide where `just test262-gate` runs (Actions / pre-push hook / manual)
- [x] Add 14 orphaned directories to `PHASES` — `916ffaed`
- [x] Add `built-ins/Iterator` to phase 21 — `1a29b357`
- [x] Un-skip `numeric-separator-literal` — `a54af668`
- [x] Un-skip `object-rest` — `245b390f`
- [x] Un-skip `error-stack-accessor` — `643ecbd5`
- [x] Fix runner worker verdict desync — `b0338a09`
- [x] `just test262-gate` two-consecutive-run zero-fail recipe — `b0338a09`

## Refcounting

- [ ] Re-measure the property-write cost on an idle machine
- [x] Audit builtins for `tval_copy_ref(ctx.result, &ctx.this_val)` — `65098c11`
- [x] Refcount object/buffer values in property and array slots — `6d7e71ca`
- [x] Combine incref/decref heap checks in `put_prop`/`set_array_idx` — `8c4cc55e`
- [x] Fix under-refcount in `%IteratorPrototype%[@@iterator]` — `104e61ae`
- [x] Free `GeneratorState` on generator finalize — `dc2945cb`

## Strings

- [x] Cursor cache for non-ASCII string indexing — `85f372ed`
- [x] `char_at` call-site audit — already complete at `85f372ed`
- [ ] Native UTF-16/Latin1 string storage
- [x] Cache `char_length` on `HString` — `b09359d9`
- [x] Skip redundant `char_length` bounds recheck in `char_at` — `688dd30d`

## Known bugs

- [ ] `heap.int_to_hstring` small-int cache increfs without a matching decref
- [ ] Destructuring-assignment to a member target drops `await` in the RHS
- [ ] Re-measure `RET` this_binding-clear cost on an idle machine
- [ ] `async function`'s own `GeneratorState` leaks
- [ ] Re-measure the baseline leak count
- [x] `error.c3` `.stack` name fallback fabricated `[object Object]` — `d5bb7997`
- [x] Generator initial-call `new_target` — verified not a bug (activation popped before any NEWTARGET)
- [x] Bound-function own-property order differed from qjs — `6e1422ec`
- [x] Bound-function internals leaked through `Object.getOwnPropertyNames` — `49e0847e`
- [x] `new Date(-1).getUTCFullYear()` returned 1970 — `bfe1215a`
- [x] Generator-resume path leaked a stale `new_target` — `e57c58a8`
- [x] `finally` skipped when `return` passes through a catch-only `try` — `79ca7134`, `40076777`
- [x] `Array.prototype.sort` segfaulted on a throwing `toString` — `a93ff1a9`
- [x] `yield` rejected in destructuring assignment-pattern defaults (32 tests) — `fa9ca71b`
- [x] Double-decref of `this_binding` on RET corrupted the allocator — `05007aa0`
- [x] `Map.set(-0)` / `Set.add(-0)` stored `-0` instead of `+0` — `4bc5bbdf`
- [x] Object-rest getters never fired; non-enumerables leaked in — `245b390f`
- [x] URI encode/decode accepted lone surrogates — `eea15205`
- [x] `x++ / 2` misparsed as a regexp literal — `559c181d`
- [x] `/=/` and `/=a/` failed to parse — `9c7ce68b`
- [x] LS/PS line terminators accepted inside regexp literals — `a7640192`
- [x] `RegExp.prototype.source` over-escaped — `05da3ef8`
- [x] `RegExp.prototype.test` used `lastIndex` as a byte offset — `8cc102c7`
- [x] `replace`/`replaceAll` passed a byte offset to the replacer callback — `8cc102c7`
- [x] `matchAll` iterator bypassed `RegExpExec` — `d0b706c1`
- [x] Numeric separators accepted in `0_1` and `1.5_` — `a54af668`
- [x] `undefined = 12` rejected at parse time — `d76ca80b`
- [x] `AggregateError` stored `errors` verbatim — `d76ca80b`
- [x] Map/Set/String iterator `next` threw bare `undefined` — `24abb32e`
- [x] Missing `PUTLEX` in inner-function param prologue — `3c4d8c2e`

## Class semantics (behind the skip-list)

- [ ] Private-field return-override
- [ ] Brand propagation across Base→Derived when the superclass returns an object
- [ ] `ContainsArguments` static analysis for direct eval in a field initializer
- [ ] Same-line class-body parsing
- [ ] Forward references to private names from computed property keys
- [x] Public field install routes through `[[DefineOwnProperty]]` — `e5fd5da2`

## Engine design review

- [ ] Generator driver family unification
- [ ] Three super mechanisms unification
- [ ] Builtin error-throw boilerplate — ~55 raw sites left
- [ ] Lexer scan buffers
- [x] Enum/metadata/dispatch triple registration in core.c3 — `a1513ec5`
- [x] ArrayBuffer vs SharedArrayBuffer dedup — `21fe21f6`
- [x] Error-throw boilerplate, highest-density sites — `47e4e1ec`, `b978b49e`
- [x] Keyed-collection internals — `d88df8b7`
- [x] Param-init prologue triplication — `3c4d8c2e`
- [x] `%RegExpStringIteratorPrototype%` + `ArrayIteratorPrototype.next` metadata — `07bf4e8a`

## Out of scope

- test262: Temporal, `intl402`, `staging`, annexB, `harness`, other Stage 3 proposals
- Feature tokens: `cross-realm`, `tail-call-optimization`, `caller`, `__proto__`/`__getter__`/`__setter__`
- In-phase `$DONOTEVALUATE` and `noStrict` skips (strict-only engine)
- Sloppy mode
- qjs CLI/std/os modules
- `(o?.m)()` undefined-this "fix"

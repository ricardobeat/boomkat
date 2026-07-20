# Duktape C3 — Backlog

Status: TODO / IN PROGRESS / DONE. Minimum detail to start a task; no results or test summaries.

## Compiler / language

- [ ] **C7a-residual** — `MAX_PRIVATE_NAMES = 64` cap (`src/compiler/context.c3:1527`); heap-allocate or grow-on-demand the private-name table (65+ private fields in one class overflow slot 0).
- [x] **C7b** — Private names visible to direct eval; eval bodies compile fresh contexts without the enclosing private_names scope. (Session 283, +10 tests)
- [ ] **P6** — `#x in obj` private-field presence check (plan 054; suite skipped).
- [ ] **P7** — Public fields (plan 054; suite skipped).
- [ ] **C8** — Arrow-function lexical `this`: resolved from calling activation instead of defining activation (`ds.act.this_binding` at CALL site). ~57 call sites; architectural investigation before touching.
- [ ] **L1** — Sloppy-mode `var` declaration semantics / auto-vivification of undeclared identifiers into globals.
- [ ] **L2** — Direct eval var-hoisting into caller/global scope.
- [ ] **L3** — Indirect eval var-hoisting into global scope.
- [ ] **X1** — Optional chaining edge cases.
- [ ] **X2** — Arrow function lexical scoping (partially covered by C8).

## Builtins

- [ ] **`arguments` Symbol.iterator** — missing, breaks `[...arguments]`/spread.
- [ ] **Shared iterator prototype `next`** — Array/Map/Set/String iterators each get their own `next`, so prototype-level `next` patching is ineffective.
- [ ] **BigInt wrapper** — `BigInt`/`BigInt64Array`/`BigUint64Array`; large deferred feature, blocks String/Object/TypedArray tests.
- [ ] **S1** — String regexp-prototype-`*` v/u flag handling.
- [ ] **S2** — String cstm-`*` on BigInt primitive (blocked on BigInt wrapper).
- [ ] **S3** — String indexOf ToInteger ordering.
- [ ] **S4** — isWellFormed / toWellFormed ToString.
- [ ] **S5** — String Symbol.iterator on non-obj-coercible.
- [ ] **O1** — fn-name inference for accessors, arrow, class, gen.
- [ ] **O2** — Computed accessor names, ToPropertyKey ordering.
- [ ] **O3** — Method-def name Symbol + generator proto.
- [ ] **D1** — Date algorithm gaps (toISOString extreme values, setFullYear arg ToNumber, toJSON abrupt propagation).
- [ ] **T1** — Tagged template site caching.
- [ ] **T2** — Frozen template object.
- [ ] **T3** — Invalid escapes → undefined cooked.
- [ ] **T4** — Tagged template misc.
- [x] **Y1** — Symbol.prototype cluster (constructor, description, Symbol.toPrimitive, toStringTag, toString). (Session 283, +17 tests: well-known symbol descriptors, Symbol()/Symbol.for() coercion, registry cleanup)
- [ ] **J2** — JSON.stringify edge cases.
- [ ] **G1** — Expression generators default-proto / prototype descriptor.
- [ ] **G2** — statements/generators prototype semantics.
- [ ] **TA1** — TypedArray Integer-Indexed [[DefineOwnProperty]].
- [ ] **TA2** — TypedArray Integer-Indexed [[Set]] prototype chain.
- [ ] **TA3** — TypedArray constructors.

## RegExp

- [ ] **U1** — Unicode property escapes `\p{...}`/`\P{...}` in unicode-mode. libregexp has property-table infra (`libregexp/unicode_wrapper.{h,c}`); wire `\p{}` through lexer/parser and property-name lookup, or confirm `lre_compile` support. QuickJS libunicode (vendored) has full UCD 17.0 tables.
- [ ] **CharacterClassEscapes** — residual RegExp fails; may share tables with U1.

## Long tail

- [ ] **Z** — Cluster remaining ~250 fails by stderr signature and batch by root cause. Bins: Promise race/any/finally, Object seal/assign/prototype/defineProperty, Set/Array Symbol.species, Number/prototype, Function/length, super, template-literal, block-scope/leave.

## Infrastructure

- [ ] **I2** — `$262.detachArrayBuffer` host hook (unblocks TypedArray callback tests).
- [ ] **I3** — Reclassify or fix CE:unexpected cases.
- [ ] **I4** — Two-consecutive-run zero-fail gate once <50 fails; enforce in CI.
- [ ] **Batch-runner SIGSEGV** — under sustained load; verify batch regressions in isolation (see memory `batch-runner-segv-under-load`).

## Non-goals (do not reopen)

- **Reflect API** — runner-skipped by policy (A9 implemented the surface; narrow the skip if reopened).
- **Sloppy-mode-only tests** — runner-skipped by policy; engine is strict-only by design.
- **F1 apply/call sloppy `this`** — unfixable under strict-only design; skip-listed.
- **Native UTF-16/Latin1 string storage** — big GC/string-builtin migration; not part of the 100% push.

## Done

- [x] **P1** — RegExp property-escapes root cause was a compiler register-aliasing bug (`e40cdd9`).
- [x] **C7 / P2-P5** — Private class members: fields, methods, accessors, static private (plan 054).
- [x] **C7a** — `\u` escapes in private names (`afaabb7`).
- [x] **C7c** — Duplicate private-member initialization throws TypeError (`ee660f0`).
- [x] **C7d** — Private-name proxy, evaluation-order, accessor, and eval edge cases.
- [x] **A9** — Reflect API surface implemented.
- [x] **J1** — JSON.parse reviver error propagation (`d6cbc2d`) + Date.toJSON companion (`7bcf02f`).
- [x] **Promise combinators** — GC-rooting + no-handler microtask ordering (`34a5269`).
- [x] **Symbol.split / Symbol.matchAll** — cluster closed (session 284).
- [x] **H1** — Hashbang / tagged-template raw text.
- [x] **try completion + block-scope leave** — eval_acc_reg reset at FINALLY; labeled break POP_LEX unwind. (Session 283, +5 tests)
- [x] **Sloppy-mode/tzdata skip-list** — 17 tests skip-listed (Function ctor dup-params, Date LMT precision, function-code sloppy this/var). (Session 283)

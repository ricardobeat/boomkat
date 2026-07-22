# Duktape C3 — Backlog

One entry per unique issue. Status: `[ ]` TODO · `[>]` IN PROGRESS (agent running) · `[x]` DONE. Minimum detail to start a task; history lives in progress.md.

## QuickJS parity roadmap (goal set 2026-07-22)

Target: feature parity with vendored QuickJS 2025-09-13 (`out/qjs`), measured by feature probe + `UNSUPPORTED_PATTERN`-vs-`test262/features.txt` cross-reference. Agent sizing: strictly one feature per agent; each removes only its own flag token from `UNSUPPORTED_PATTERN`; verification = one relevant phase + golden bytecode (coordinator runs full sweeps at merge).

### Landed (session 292)

- [x] **Class static blocks** (`class-static-block`) — also fixed the `(class { static { } })` parser hang.
- [x] **`Promise.withResolvers`**.
- [x] **`Promise.try`**.
- [x] **`Error.isError`**.
- [x] **`Object.groupBy` / `Map.groupBy`** (`array-grouping`).
- [x] **`Map`/`WeakMap` `getOrInsert` / `getOrInsertComputed`** (`upsert`).
- [x] **Symbols as WeakMap/WeakSet keys** (`symbols-as-weakmap-keys`).
- [x] **Set methods** (`set-methods`) — union/intersection/difference/symmetricDifference/isSubsetOf/isSupersetOf/isDisjointFrom.

- [x] **RegExp duplicate named groups** (`regexp-duplicate-named-groups`) — groups-object/`$<name>`/indices resolve to the matched alternative (quickjs rule: defined value wins); 18/19, the 19th is annexB `RegExp.prototype.compile` (excluded dir).
- [x] **`RegExp.escape`** — 20/21 (last one cross-realm).
- [x] **RegExp modifiers** (`regexp-modifiers`) — libregexp already supported `(?i:...)`/`(?-i:...)` fully; un-skipped.

### In progress

- [>] **Iterator helpers** (`iterator-helpers`) — Iterator global, Iterator.from, lazy map/filter/take/drop/flatMap, eager reduce/toArray/forEach/some/every/find.

### Todo — small (batch 2, one agent each)

- [ ] **`change-array-by-copy` un-skip** — toSorted/with already work; un-skip and fix residuals (toReversed/toSpliced, TypedArray variants).
- [ ] **`Uint8Array.fromBase64`/`toBase64`/hex** (`uint8array-base64`).
- [ ] **`JSON.parse` source access** (`json-parse-with-source`).
- [ ] **`Array.fromAsync`**.
- [ ] **`Math.sumPrecise`** — implemented basic Neumaier compensated summation (handles `sumPrecise([0.1, 0.1]) === 0.2` etc.). The 5 spec tests requiring xsum-style exact summation (intermediate overflow + cancellation like `[1e308, 1e308, 0.1, 0.1, 1e30, 0.1, -1e30, -1e308, -1e308] === 0.30000000000000004`) still fail — would need Radford Neal's xsum 67-chunk accumulator (V8's `src/builtins/builtins-math-xsum.{h,cc}`) or Shewchuk grow-expansion. The basic 5 tests (length, name, prop-desc, not-a-ctor, NaN) pass.
- [ ] **`Iterator.concat`** (`iterator-sequencing`).
- [x] **`#x in obj`** (`class-fields-private-in`, plan 054 P6) — parser + existing brand-check reuse. Fix: `binary_expr` peeks for `HASH_IDENT in` and emits a new `HAS_BRAND` opcode (ABC: A=dst, B=obj, C=brand-reg) that sets a boolean from the existing own-property brand check (no throw on miss). Throws TypeError if RHS is not an object per spec. `class-fields-private-in` removed from `UNSUPPORTED_PATTERN`.
- [ ] **Reflect un-skip** — surface implemented (A9); un-skip and fix what fails.

### Todo — architecture (batch 3)

- [ ] **Async generators** — plan 060 (~2,000 tests, ~3-5 sessions). Until then all four syntactic forms parse-reject; runner skips structurally. for-await-of consumer + AsyncFromSync stay in scope.
- [ ] **Resizable ArrayBuffer** (`resizable-arraybuffer`).
- [ ] **`ArrayBuffer.prototype.transfer`** (`arraybuffer-transfer`).
- [ ] **`Float16Array`**.
- [ ] **WeakRef / FinalizationRegistry** — needs GC hooks; WeakMap/WeakSet are also not truly weak today (plain storage, no GC integration).
- [ ] **Atomics / SharedArrayBuffer** (+ `Atomics.waitAsync`).
- [ ] **Import attributes + JSON modules** (`import-attributes`).

### Parity exceptions (user call needed)

- **Sloppy mode** — QuickJS has it; engine is strict-only by design (also covers F1 apply/call sloppy `this`). Out of scope unless the user says otherwise.
- **qjs CLI/std/os modules** — not JS-language parity; out of scope.

## Known bugs (pre-existing, exposed by un-skips)

- [x] **Getter/setter methods never create `arguments`** — `{get x(){ arguments }}` fails standalone; `static-init-arguments-methods.js`. Fix: getter/setter invocations now declare `arguments` in their activation's var_env (matching CALL paths). Setters get the assigned value at index 0; getters get an empty arguments object.
- [x] **`let x; var x;` redeclaration not rejected** — no conflict detection anywhere; `static-init-invalid-lex-var.js`. Fix: `block()` now pre-scans for `var` declarations (recursively into nested blocks, skipping nested function/class bodies which have their own VarDeclaredNames scope) and rejects overlap with the pre-scanned lexical names per ES2024 §13.2.1.
- [ ] **`await` as BindingIdentifier in nested-function positions** — function-decl name, catch param, generator/accessor param names, `{await}` shorthand, arrow param-default; 9 tests, no class involvement.
- [ ] **`new Set(string)` throws** — `coll_construct` checks is-object before the iterable protocol; affects the whole keyed-collection constructor family.
- [ ] **`Array.from` primitive-wrapper prototype** — writes a named `"prototype"` property instead of the wrapper's [[Prototype]]; masked by the array-like fallback. Port the corrected pattern from `group_by_shared` (core.c3).
- [>] **Large-string refcount leak** — >256-byte (`MAX_INTERN_BYTES`) non-interned strings from fromCodePoint/concat never decref'd (~5-7 MB/property-escapes test); only matters in long single-process runs. Agent running.
- [ ] **`RegExp.prototype.compile` missing entirely** — Annex B method; invisible today (annexB dir excluded), blocks 1 duplicate-named-groups test.
- [ ] **Regexp literals never parse-time-validated** — only `new RegExp(str)` runs `re_compile`, so `/(?g:a)/`-style early SyntaxErrors are silently accepted in literal form; fails 80 `language/literals/regexp/early-err-*` `$DONOTEVALUATE` tests (outside the phase scoring surface). Compiler-wide change; will bite any future "new regexp syntax with early error" feature.

## Compiler / language

- [ ] **C7a-residual** — `MAX_PRIVATE_NAMES = 64` cap (context.c3); grow-on-demand (65+ private fields overflow slot 0).
- [ ] **L2** — Direct eval var-hoisting into caller/global scope.
- [ ] **E1** — Eval-super residuals (plan 059 §2-3): object-literal-method eval-super (`__super__` in uncaptured PUSH_LEX scope); `eval("super()")` in derived ctors (`is_constructable` hardcoded false); nested-eval `new.target` (eval CFs are `is_global`); `super` in plain fn-expr should be an early SyntaxError.
- [ ] **F2** — `Function.prototype.toString` NativeFunction grammar for builtin accessors (getter/setter builtin objects lack toString routing).

## Infrastructure

- [ ] **I2** — `$262.detachArrayBuffer` host hook (unblocks TypedArray callback tests).
- [ ] **I4** — Two-consecutive-run zero-fail gate; enforce in CI.
- [ ] **Runner skip-list re-tier** — regroup `UNSUPPORTED_PATTERN` comments by `features.txt` sections (ratified vs proposal); labels have drifted.

## Non-goals (do not reopen)

- **Native UTF-16/Latin1 string storage** — big GC/string-builtin migration.
- **X1 note** — the `(o?.m)()` undefined-this "fix" was a misdiagnosis and is reverted; parens preserve the optional-chain receiver (`optional-call-preserves-this.js`). Don't re-introduce.

## Done (compressed; details in progress.md by session)

- [x] Private class members complete: fields/methods/accessors/static (plan 054 P2-P5, C7), `\u` escapes (C7a), direct-eval visibility (C7b), dup-init TypeError (C7c), proxy/eval edges (C7d), public fields (P7, s289d).
- [x] Class-method/object-literal eval-super basics (E2) + escaped-arrow `super()` re-binding (s289-290).
- [x] Arrow lexical this/new.target (C8), arrow reparse scopes (X2), param-default capture (X3), template-substitution brace scanning (X4), named-funcexpr envs (X5), array fast-path key truncation (X1).
- [x] Strict PutValue on unresolvable references via RESOLVEVAR (L1); indirect-eval var-hoisting has no failing tests (L3).
- [x] AsyncFromSync tick ordering — AWAIT always via PromiseResolve + suspension; microtask drain gated to outermost reentry (s291).
- [x] Builtin clusters S1-S6, O1-O3, D1, T1-T4, Y1, J1-J2, G1-G2, TA1-TA3, Promise combinators, Symbol.split/matchAll, H1, BigInt (plan 056), `arguments` iterator, shared iterator prototypes — all cleared by s289d-291 full runs.
- [x] RegExp: property-escapes register-aliasing (P1), `\p{}` wiring (U1), >31-capture SIGABRT (R1), CharacterClassEscapes.
- [x] Huge sparse-array timeouts — ArraySetLength own-key scan (s291).
- [x] Valstack relocation corruption (I5) — entry_act.bottom + caller_valstack_top on grow; was the "RegExp flakiness" (s291).
- [x] Batch-runner SIGSEGV (dc0af6d); CE:unexpected 0 since s286 (I3); long-tail clustering (Z); sloppy/tzdata skip-list.

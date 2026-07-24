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

- [x] **Iterator helpers** (`iterator-helpers`) — Iterator global, Iterator.from, lazy+eager methods, %MapIteratorPrototype%/%SetIteratorPrototype%/%StringIteratorPrototype% sub-layers; 538/540 in-scope (2 residuals: cross-realm; captured-method aliasing bug below).

### Todo — small (batch 2, one agent each)

- [x] **ENDTRY freed finally-owning catchers on normal fall-through** — enclosing-catcher lexical env restored early in try-finally-under-try shapes (`for(let x of..){let [a]=arr}` lost bindings); catcher now survives to ENDFINALLY. Found via the 'resizable dstr' test — generic control-flow bug, not TA.
- [x] **`change-array-by-copy` un-skip** — fully landed: TypedArray side (incl. with() coercion order) + all 15 Array-side residuals (holes-as-own-props, toSorted via shared array_sort_compare, toSpliced arg/limit semantics); phases 5/6/22 all 0 fails.
- [x] **`Uint8Array.fromBase64`/`toBase64`/hex** (`uint8array-base64`) — 69/71 (2 need immutable-arraybuffer); Uint8Array dir added to phase 22.
- [x] **`JSON.parse` source access** (`json-parse-with-source`) — reviver context.source spans + JSON.rawJSON/isRawJSON; 21/22 (last is cross-realm staging); also fixed pre-existing `JSON.parse('{}', reviver)` → undefined (zero-alloc mistaken for OOM).
- [x] **`Array.fromAsync`** — native promise state machine; all in-scope tests pass after the param-prologue and length-coercion fixes; 6 async-gen-source tests skipped (plan 060).
- [x] **`Math.sumPrecise`** — Shewchuk algorithm ported from quickjs; 10/10.
- [x] **`Iterator.concat`** (`iterator-sequencing`) — 30/31; the 31st exposed the spread-into-builtin bug below.
- [x] **`#x in obj`** (`class-fields-private-in`, plan 054 P6) — cherry-picked from `console` branch: new `HAS_BRAND` opcode (boolean own-property brand probe, TypeError on non-object RHS), `binary_expr` peek for `HASH_IDENT in`.
- [x] **Reflect** — already un-skipped 2026-07-16 (commit 6bdb0e7); verified 153/153 test262 pass. (The 'runner skips Reflect' memory was stale and has been deleted.)

### Todo — architecture (batch 3)

- [x] **Async generators** — plan 060 A-D complete + tail closed (s294-295); phases 21/24 zero fails.
- [x] **Resizable ArrayBuffer** (`resizable-arraybuffer`) — fully landed across four agent waves + coordinator fixes; phase 22 stable 2600/0. Root-caused along the way: for-let register clobber (compiler), lexer stack-slice escape, GC sweep ordering, three rooting/refcount bugs.
- [x] **`ArrayBuffer.prototype.transfer`** (`arraybuffer-transfer`) — landed s294 (53/0).
- [x] **`Float16Array`** — landed s294 with Math.f16round + DataView f16 (49/50).
- [x] **WeakRef / FinalizationRegistry** — API surface landed (74/76; 2 cross-realm), non-weak semantics matching WeakMap policy (cleanup never fires — spec-legal); also fixed internal collection storage leaking through getOwnPropertyNames. TRUE weakness (all four types) remains a GC-integration project, out of parity scope for now.
- [x] **Atomics / SharedArrayBuffer** — single-agent scope (QuickJS-without-workers): full SAB (incl. growable) 103/0, Atomics ops + isLockFree + wait/notify/waitAsync (real waiter FIFO + promise resolution) 261/0; 112 multi-worker agent-harness tests skipped (no $262.agent host), CanBlock=true chosen (V8/qjs shell model). Phase 22 now includes both dirs: 3164/0.
- [x] **Import attributes + JSON modules** (`import-attributes`) — with-clause parsing (dup/non-string SyntaxErrors), attribute-aware module dedup, JSON modules (default-only export, link-time named-import rejection); +24 tests, plus a RESOLUTION negative-phase runner fix that repaired 22 pre-existing module-negative verdicts.
- [x] **Dynamic `import()`** — landed (s295-296): call form + import attributes, module namespace exotic semantics (§10.4.6, incl. TDZ propagation through the reflective MOP + `export *` expansion), async-gen×import interleaving (per-reaction-job error-channel hygiene), cached evaluation errors (ModuleStatus.ERRORED re-rejects with the same value), indirect-export link validation (§16.2.1.6.2-3 incl. `export * as ns` namespace resolution). Phase 0: 2 residual fails (entry below).
- [x] **Module duplicate-lexical-name static semantics** — landed s296: module-mode hoist_decls/hoist_global_fn_decls reject var/function and duplicate-function clashes (§16.2.1.1); dynamic import rejects with the compile SyntaxError (parked on the heap error channel) instead of a generic TypeError. Phase 0 → 0 fails.
- [x] **`import.meta`** — landed s296: IMPORT_META opcode, module_goal compiler flag (SyntaxError in scripts/eval, escaped forms rejected via Token.has_escape), per-module lazily-cached null-prototype object with `url`, GC-marked on ModuleDef; skip token removed, all 22 tests pass.

### Parity verification (2026-07-23)

Full feature-probe diff vs vendored `out/qjs` (globals, ~80 builtin members, 18 syntax forms): **zero gaps remaining**. The probe found exactly one — `Atomics.pause` — landed same day (phase 22 +6). We now *exceed* qjs on `Array.fromAsync` and `Atomics.waitAsync`. qjs itself lacks legacy RegExp statics and Realm, so those are not parity items; `$262.agent`/`createRealm`/cross-realm are test-harness host features, not engine-language features. Full suite: 41,655/0/0.

- [x] **`Atomics.pause`** — landed s296: no-coercion integral-Number validation matching qjs; skip token removed.
- [x] **ASI over-acceptance** — class elements now reject a line-terminated `accessor` prefix instead of accepting it as two fields; unsupported `using` declarations are rejected before expression/ASI parsing. Focused regressions pass.

### Parity exceptions (user call needed)

- **Sloppy mode** — QuickJS has it; engine is strict-only by design (also covers F1 apply/call sloppy `this`). Out of scope unless the user says otherwise.
- **qjs CLI/std/os modules** — not JS-language parity; out of scope.

## Engine design review (user-requested, run after async-gen tail lands)

Full-engine pass for duplication/elegance/compactness at constant perf+correctness. Known candidates gathered this session:
- **Param-init prologue triplicated** across parse_function_body / compile_inner_function / compile_arrow_inner_reparse (the PUTLEX r0 bug had to be fixed 3x) — extract one emitter.
- **Generator driver family**: sync YIELD_STAR opcode vs async yield* machinery vs async_generator.c3 drain — after the current agents land, unify the delegation/completion surface; also the duplicated activation-teardown blocks in vm_generators.c3 (AWAIT reject/OOM paths repeat ~40 lines).
- **Three super mechanisms** — plan 059's unification (GETPROTO(homeObject) everywhere) still open.
- **Builtin error-throw boilerplate**: dozens of hand-rolled alloc ERROR + intern message + put_prop blocks; one `throw_type_error(ctx, msg)`-style helper family exists in some files (arr_throw_*, arraybuffer_throw_*) but not shared engine-wide.
- **ArrayBuffer vs SharedArrayBuffer**: freshly-added SAB duplicates ctor/getter/slice shapes; growable-SAB vs resizable-AB grow paths.
- **Keyed-collection internals**: coll_* helpers + group_by_* + getOrInsert paths grew adjacent copies of key canonicalization.
- **Lexer scan buffers**: string/template/ident decode paths share arena+normalize logic candidates.
- **Runner config duplication**: UNSUPPORTED_PATTERN vs scripts/test262_skip.cfg doc mirror drifts (bit us twice); single source of truth.
- **Enum/metadata/dispatch triple registration** in core.c3 for every builtin (conflict magnet all session) — consider a table macro.
Method: read-only Explore survey per subsystem → ranked plan → small fix agents with bench gates (bench-fast + golden + phase sweeps per change).

## Known bugs (pre-existing, exposed by un-skips)

- [x] **GC sweep-order use-after-free** — fixed: two-phase sweep (unlink dying → run all teardowns while memory valid → free headers) + decref sweep-guard; bonus fix: vm_mark_activations now marks each activation's full register span (live values above valstack_top were collectable).
- [x] **GC roots audit (survey-driven)** — TWO real UAFs fixed with repros (construct-frame this_binding — freshly-allocated instance sole-rooted in the activation; Catcher.thrown_val — exception collected mid-unwind in alloc-heavy finally); new_target/async_promise/async_gen_state marked defensively; tv_func confirmed dead (unmarked). Benches flat.
- [x] **GC roots follow-up: heap.{error_value,yield_value,resume_gen,gen_initial_gs}** — marked defensively in mark_roots (2026-07-24, cherry-picked 752b609): TVals via mark_tval, GeneratorState* via null-safe mark_generator_state. Benches flat. Plan-061 D2 can absorb error_value later.
- [x] **GC rooting gap: instantiate_closure HObject collected** — fixed: `vm.return_val`/`vm.throw_value` were never GC roots (a top-level RET's closure lived only there across a safepoint). Same fix wave also caught a string double-free in TypedArray join (`str_table_insert` without the interning protocol's owning ref) and an empty-separator `&sep[0]` bounds trap in Array join. Phase 22 stable 2600/0 ×3, ASan-clean over 165 tests.
- [x] **Detached-TA harness perf hole** — get_prop_flags walked N-deep shape chains per read (O(N²) bulk reads on 10k-prop dictionary objects); fixed with a per-object has_nondefault_flags bit (O(1) default path, benches slightly faster). Residual noted: shape-per-property slot consumption (ushort cap 65534) unaddressed.
- [x] **`Object.seal` on TypedArrays** — landed s296: same guard as freeze (throws for non-fixed-length views or any in-bounds elements); verified against QuickJS.
- [x] **`return` inside `finally` doesn't abort the rest of the finally block** — fixed: Catcher caches its ENDFINALLY pc (lazy nesting-balanced scan); RET/RET_GEN/RETUNDEF_GEN jump there when IN_FINALLY. Only return was affected (break/continue/throw already unwound). Nested-finally overrides verified.
- [x] **Dynamic-function parameter yield/await validation** — landed (dynamic + inline forms) via forbid flags gated on a new in_formal_params context flag so body-destructuring defaults stay legal.
- [x] **`yield <operand>` inside a for-await dstr default fails to compile** — fixed by propagating the enclosing async-generator identity into default-expression thunks; array and object patterns now compile and resume through Promise-returning iterator requests.
- [x] **Arrow-rejection flag over-eager on `prototype-rules.js`** — fixed s296: the four parenthesized-grouping exits in primary's LPAREN case now clear `last_was_arrow_expr`, so `"prototype" in (() => {})` parses; illegal bare-arrow operands still SyntaxError (8-probe matrix). Suite CE count: 0.
- [x] **`[...arguments]` fails on the re-entrant call_fn path** — STALE: already fixed by cfb713e (2026-07-18), which factored `finish_arguments_object()` (length/callee/@@iterator) into vm_calls.c3 and routed all 8 construction sites (call_fn re-entry + ctor, ordinary call, generator, bound fallback, super(), new, accessor invocation) through it. Coordinator re-verified spread-over-arguments on all four paths on current main (2026-07-24). Phase 21: 1347/0.
- [x] **AsyncGenerator `.return()` on suspendedStart awaiting promise** — already covered by the landed AwaitReturn work (verified 19/19 in the return/ dir; earlier fail reports were stale worktree bases).
- [x] **`arguments` empty in async-gen bodies (~60 tests)** — fixed: the shared call_fn re-entry rebuilt arguments unconditionally on resume (argc=0), shadowing the call-time object restored via gs.var_env; now gated on !did_resume. 60/60 family, identity stable across yields.
- [x] **fromAsync × async-generator crash (exit 138)** — was COMPILE-time: statement() read a stale lexer token_start after peek-dispatch for nested `async function*` decls → src_start past EOF → unsigned span underflow → OOB read; fixed via refresh_token_start + a span-sanity guard. Same root cause also fixed the toString-declaration [native code] gap.
- [x] **Grep audit: `&slice[0]` on possibly-empty slices** — audited (2026-07-24): 190 hits classified, zero fixable. The only variable-length sources are the already-guarded join sites (array/typedarray) and two `context.c3` `mem::copy` sites inside count>0 checks; ~120 hits are fixed-size stack arrays. One invariant-only site: `statements.c3:552/679/812` capture `&self.lexer.source[0]` for offset math — safe because the block/class pre-scanners only run past a consumed `{`, but not defended by a length check.
- [x] **Lexer returned token slices into dead stack frames** — escaped strings/templates decoded into 64KB stack buffers whose slices escaped via Token.str_value/raw_value; fixed with a lexer arena (pointer-held so lexer snapshot/restore keeps allocations), freed at compile end; dead str_owns_memory removed; ASan-verified across 400+ escape/template tests.

- [x] **Object-literal method + default param + param-capturing closure scrambles param slots** (FIXED: PUTLEX hardcoded source register 0 in all 3 duplicated param prologues — every env-backed param received param 0's value; now uses each param's arg-index register) — `{ m(a, b, c = "") { push(() => b); return String(b); } }`: `b` reads as the CLOSURE OBJECT inside the method. Was breaking temporalHelpers.observeProperty → 6 fromAsync tests; the 7th needed a separate fromAsync length-coercion fix (ToPrimitive on object-valued length).
- [x] **Borrowed array-iterator target in chained `.call().then()`** — array/map/set iterators now own their target reference and release it on exhaustion or iterator teardown, preventing deferred consumers such as `Array.fromAsync.call(Array, source)` from observing freed/reused collections.

- [x] **`test/json_stringify_ext.js` local test fails on main** — assertion `{"toJSON":{"lastIndex":0}}` was an obsolete V8 expectation; current Node 24, QuickJS, and SpiderMonkey all return `{"toJSON":{}}` (non-enumerable `lastIndex`). Test updated to match current engines.

- [x] **Arrows parse at any precedence level** — fixed via a shared `last_was_arrow_expr` marker set by `parse_arrow_function*` and a `check_no_arrow_rhs` macro called after every RHS recursive parse in `binary_expr`. Lone arrows (`[1].map(()=>1)`, `(a, ()=>1)`) still parse because `expression`/`assignment_expr`/`conditional_expr` reset the marker on entry and there is no binary op following the arrow in those contexts.

- [x] **Spread into builtin calls drops the last argument at 5+ args** — two coupled bugs fixed: the spread count register (CALL_S's nargs source) was allocated INSIDE the argv window and got overwritten at 5+ elements, and SPREAD_ARG stored borrowed refs that call teardown over-decref'd. `begin_spread_args` now reserves both control regs below first_arg; SPREAD_ARG takes owned refs.
- [x] **Plain argument AFTER a large spread still miscompiles** — verified fixed on current main: `f(1,...[2,3,4,5],99)` and multiple-spread calls preserve order and arity; regression coverage is in `test/test_spread.js`.

- [x] **Captured-method aliasing** — NOT REPRODUCIBLE on merged HEAD (dedicated agent exhausted alias/IC/GC variants; coordinator re-confirmed 4 repro shapes clean). The iterator-helpers agent's mid-implementation observation was an artifact of its then-uncommitted state. Reopen only with a repro on current main. Note: the triggering test file is absent from our test262 snapshot.

- [x] **Getter/setter methods never create `arguments`** — fixed (console branch cherry-pick): both accessor invocation paths (invoke_getter + the two setter paths) now declare a sized arguments object like ordinary CALLs.
- [x] **`let x; var x;` redeclaration not rejected** — fixed (console branch cherry-pick): `block()` pre-scans var declarators (recursing into nested blocks, skipping function/class bodies) and rejects overlap with lexical names per §13.2.1.
- [x] **`await` as BindingIdentifier in nested-function positions** — fixed via shared `expect_binding_identifier()` honoring [Await]/[Yield] boundaries (arrow params inherit, bodies reset); 9/10, CE:unexpected back to 0; the 10th needs `using` (explicit-resource-management, unimplemented).
- [x] **`new Set(string)` throws** — fixed: `coll_construct` wraps primitives (correct [[Prototype]]) before the iterable check; `new Map("ab")` correctly TypeErrors on non-object entries.
- [x] **`Array.from` primitive-wrapper prototype** — fixed by the iterator-helpers agent (real [[Prototype]] set; numbers/booleans/bigints handled too).
- [x] **Large-string refcount leak** — >256-byte (`MAX_INTERN_BYTES`) non-interned strings from fromCodePoint/concat never decref'd (~5-7 MB/property-escapes test); FIXED (opus agent, s292): builtin/getter result-copy sites now release the transient setter-ref for non-interned non-symbol strings at refcount 1 (`Heap.store_builtin_result`); ~98.6% of the leak class gone (281→4 objects/test), ASan-clean. Residual ~45 KB/test through the same dispatch site left deliberately (needs raw-register-overwrite decref surgery — the Symbol-string UAF trap is documented in the helper). First agent's worktree diff (agent-a178867b5c7d24326) is superseded.
- [x] **Large-string leak residual: raw-register-overwrite surgery** — landed 2026-07-24 (cherry-picked bb6c01e): owned-register discipline at every raw write (resolve_call_var/global entry decref, ADD/ADDI track_heap_store, RET write-back max_heap_reg, LDINT/LD* + INC/DEC + INC/DEC_GLOBAL + NEWOBJ/NEWARR/NEWREGEXP/CLOSURE decrefs), free_catcher_chain at all frame-pop sites (return-from-try leaked 80B Catcher per frame), large-alloc GC-trigger burn in alloc_no_gc, MAX_CALLS borrowed-callee neutralization. Coordinator-verified: leak1.js 2015 leaks→15/880B, phases 0 (1696/0) + 5 (8361/0), golden 10/10, rosetta 100/100. Cost: recursion/function_call/loop +3-7%.
- [ ] **Perf follow-up: non-interned-string registry backstop** — a heap-side registry for >MAX_INTERN_BYTES strings would let hot-path register writes stay raw (recovering the 3-7% on recursion/function_call/loop) and also fix the known heap.reset() batch-runner string leak.
- [ ] **Latent GC-timing bug (batch runner)** — counting EVERY string alloc in the GC trigger exposed 2 batch-mode-only Array.prototype.map failures (resizable-buffer.js, 15.4.4.19-8-c-ii-1.js): something in map is sensitive to GC cadence. Repro recipe: make alloc_no_gc burn the trigger for all sizes, run those two in batch mode.
- [x] **`RegExp.prototype.compile`** — landed s296 via factored regexp_initialize shared with the ctor (which also fixed dropped inherited libregexp flags); 21/23 annexB compile tests (2 need cross-realm legacy-regexp); duplicate-named-groups compile test passes.
- [x] **Regexp literals never parse-time-validated** — CompilerContext.validate_regexp_literal now runs `re_compile` on every literal at parse time (also rejects unknown/duplicate/u-v flags); 80 `language/literals/regexp/early-err-*` $DONOTEVALUATE tests now produce the spec SyntaxError.

## Compiler / language

- [>] **C7a-residual** — `MAX_PRIVATE_NAMES = 64` cap (context.c3); grow-on-demand (65+ private fields overflow slot 0).
- [x] **L2** — CLOSED INVALID (2026-07-24): engine is strict-only, and strict direct eval gets its own var environment (§19.2.1.3) — no hoisting into the caller is correct. 5-probe matrix matches qjs in strict mode; phase 7 (language/eval-code) 598/0 incl. all 11 var-env strict tests; the 437 skips are `noStrict` tests.
- [ ] **Indirect-eval global-property definability** (split from L2 investigation) — 6 tests skip-listed in run_test262.py (~lines 294-299: var-env-var-init-global-exstng, var-env-func-init-multi, non-definable-global-function, etc.) fail on CanDeclareGlobalFunction/CanDeclareGlobalVar TypeErrors and preserving `configurable:false` on existing global props — descriptor semantics, not hoisting.
- [>] **E1** — Eval-super residuals (plan 059 §2-3): object-literal-method eval-super (`__super__` in uncaptured PUSH_LEX scope); `eval("super()")` in derived ctors (`is_constructable` hardcoded false); nested-eval `new.target` (eval CFs are `is_global`); `super` in plain fn-expr should be an early SyntaxError.
- [x] **F2** — CLOSED STALE (2026-07-24): builtin accessors are ordinary FUNCTION-class objects with `.name` = "get size" style and route through the `.name` branch of builtin_function_proto_toString; 8-accessor probe matrix matches qjs (whitespace aside), `built-in-function-object.js` passes, toString subdir 79/80. Coordinator re-verified the probe on main.
- [ ] **User-function `toString` drops `\uXXXX` escapes** (split from F2 audit) — `Function/prototype/toString/unicode.js` fails: source-text slicing doesn't preserve escaped identifiers.

## Infrastructure

- [>] **I2** — `$262.detachArrayBuffer` host hook (unblocks TypedArray callback tests).
- [ ] **I4** — Two-consecutive-run zero-fail gate; enforce in CI.
- [ ] **Runner skip-list re-tier** — regroup `UNSUPPORTED_PATTERN` comments by `features.txt` sections (ratified vs proposal); labels have drifted.

## Non-goals (do not reopen)

- **Native UTF-16/Latin1 string storage** — big GC/string-builtin migration.
- **X1 note** — the `(o?.m)()` undefined-this "fix" was a misdiagnosis and is reverted; parens preserve the optional-chain receiver (`optional-call-preserves-this.js`). Don't re-introduce.

## Done (compressed; details in progress.md by session)

- [x] Global-var perf branch (`land-globalreg-rebased`, 26 commits) rebased onto main and merged (s296): GETGLOBAL/PUTGLOBAL slot resolution, GETGLOBAL_PRIM/PUTGLOBAL_PRIM guard-free primitive slots, INC/DEC_GLOBAL, CALL_GLOBAL + CALL_VAR fusions, MOVE_GG, accumulate move-elimination, halt/restart scoping; plus threaded-dispatch spike behind `THREADED_DISPATCH` (own targets, not default build). bench-fast: arithmetic 120→53ms, loop 49→25, calls 54→34, ic_mono 186→116, recursion 310→236. Earlier phase-5 tamper regression fixed by the branch's soundness commit (verified 0 fails).
- [x] **Un-interned concat strings** — the ADD/ADDI "skip interning for accumulator" fast path produced HStrings that broke pointer-identity string equality (indexOf/includes/keys); live on main via move-elim aliasing, exposed by balanced_brackets.js. All three sites now always intern (s296).
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

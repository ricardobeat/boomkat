# Plan 057: `for await` / async iteration (ES2018)

> **Status (2026-07-20):** ✅ COMPLETE (branch `for-await-async`). All phases
> landed: Phase 0 (for-of unification), Phase 1 (parser + reject cases), Phases
> 2-3+5 (async iterator protocol via GET_ITER_ASYNC + AsyncFromSync adapter,
> await wiring, ITER_CLOSE_ASYNC), Phase 4 (LHS parity), Phase 6 (test262
> un-skip). Note the final design used *conditional codegen + 2 opcodes*
> (GET_ITER_ASYNC, ITER_CLOSE_ASYNC), NOT the 3 INITFOR_ASYNC/NEXTFOR_ASYNC
> opcodes originally scoped below — because Phase 0 had already inlined the
> iterator protocol as codegen, making per-opcode async variants unnecessary.
> Results: test_for_await.js 7/7; test262 Phase 24 for-await-of 347 pass / 0 CE
> (remaining fails are async-generator SOURCES, a deferred feature); no
> regressions (for-of 582, generators 481, Promise/Map/Set 1206, rosetta 100/0).
> Two pre-existing bugs fixed along the way: labeled-break not closing for-of
> iterators, and bare-ident for-of desync into a register-cached local.
>
> _(historical scoping below; superseded where it conflicts with the above)_
>
> Reviewed + refined
> 2026-07-20: anchors verified against tree; Phase 0 refactor promoted to
> mandatory-first; break/return async-close split into its own Phase 5.
> **Phase 0 investigated 2026-07-20** — the "four emitters" picture is refined
> below (see "Phase 0 findings"): four for-of *paths*, only three of them
> functions, with **three distinct register layouts**. The helper shape is
> narrower than "one loop emitter." Verification is test-based (for-of +
> generator fixtures, test262 dirs, rosetta); `boomkat_debug -c` disasm is a
> convenience sanity check, not a byte-identity gate.
>
> **Phase 0 DONE 2026-07-20** (branch `forof-unify-plan057`, commit `948853e`):
> all four for-of paths unified into one `emit_forof(ForOfHead, is_await)`
> skeleton + `ForOfHead` tagged union + `emit_iter_open`/`emit_iter_step`/
> `emit_iter_close`. Value uniformly parked below the callee window (layout
> distinction erased). `is_await` threaded as always-false param; `is_await_loop`
> bit added to `LoopInfo`. Net −101 lines. Gate green: phase 14 for-of 582 pass
> (1 pre-existing array-getter fail, orthogonal), phase 12-13 destructuring 17/0,
> phase 21 generators 481/0, rosetta 100/0. **Phases 1–5 still TODO.**
>
> Motivation: `for await (... of ...)` is entirely unimplemented — even
> `for await (const v of [1,2,3])` fails to parse ("expected '(', got 'await'").
> This blocks the `for-await-of` and top-level-await `for await` test262 family.
> Surfaced while fixing the top-level-await export cluster (commits `88c517c`,
> `7ac0768`, `c01204f`), where 3 of 6 fails were the runnable export cases (now
> fixed) and the remaining `for-await-of` cases are gated behind this feature —
> the suite already SKIPs them via `features: [async-iteration]`, so they are
> deferred, not regressions.
>
> **File paths (verified 2026-07-20):** compiler sources live under
> `src/compiler/` (`statements.c3`, `class.c3`, `entry.c3`, `expressions.c3`,
> `functions.c3`); the VM under `src/vm/` (`vm_control.c3`); `bytecode.c3` and
> `heap.c3` are at `src/`. Line numbers below are approximate anchors, not
> exact — re-grep before editing.

## Scope

**In scope — the ES2018 async-iteration *consumer*:**
- `for await (LHS of expr)` statement, in all LHS forms the sync for-of already
  supports: `var`/`let`/`const` binding, bare identifier, and destructuring
  patterns (array/object, incl. defaults + rest).
- Async-iterator protocol: `GetIterator(expr, async)` — look up
  `@@asyncIterator`; if absent, fall back to `@@iterator` wrapped in an
  `%AsyncFromSyncIteratorPrototype%` adapter (§27.1.4.1) so sync iterables
  (arrays, generators) work under `for await`.
- `await` the result of each `.next()` call (it returns a Promise of an
  IteratorResult) and of `AsyncIteratorClose`.
- Valid only inside an async function/method or at module top level
  (`is_async`); a parse error otherwise.

**Out of scope (separate deferred features — keep failing / skip-listed):**
- **Async generators** (`async function*`, `yield` in async) — already rejected
  at parse (`class.c3:491`). A for-await *source* can be any async iterable, so
  we do NOT need async generators to land this; tests that also require an
  async-generator source stay deferred.
- `Symbol.asyncIterator` as a user-facing writable well-known symbol beyond
  what the protocol lookup needs (the cached `heap.asynciterator_symbol`
  already exists — heap.c3:355).
- `noStrict`-flagged for-await tests — unfixable in a strict-only engine.

## What already exists (build on this)

- **Sync for-of codegen** (`src/compiler/statements.c3` `for_statement`):
  `INITFOR` (set up iterator) → `NEXTFOR` (produce iter var + has_next) → body →
  back-jump → `ITER_CLOSE`. `loop_stack[].iter_close_reg` tracks the close target
  for break/return; `emit_iter_close_for_enclosing` drives break/return unwinding.
  **NB — this is not one path but four independent emitters, each hand-rolling
  the same INITFOR/NEXTFOR/ITER_CLOSE trio:** `emit_forof_loop` (bare + lexical
  identifier), `emit_bare_forof_destruct_loop`, `emit_forof_loop_member`
  (member-target LHS), and the lexical-destructure emitter. See the codegen
  refactor note under Design — threading `is_await` naively means forking all
  four, which the async close bug will hide in.
- **Iterator protocol opcodes** in `src/vm/vm_control.c3`: `INITFOR`/`NEXTFOR`
  (`dispatch_iterator`, ~line 388) and `ITER_CLOSE`. These do the sync
  `@@iterator` / `.next()` / `.return()` dance. Note `NEXTFOR` returns the
  iteration *value* directly — the async form must return a *promise to await*
  instead, which is the real reason to use separate opcodes (below), not just
  hot-path hygiene.
- **`await` suspension** — `AWAIT` + `LOAD_RESUME` opcodes emitted together
  (`src/compiler/expressions.c3:3003-3004`), reusing the generator save/restore
  path (async sets `is_generator`). The VM can already suspend/resume an async
  activation mid-body at any `AWAIT`.
- **`@@asyncIterator` symbol** cached + GC-rooted (`src/heap.c3:355,1967`).
- **Module top-level is async** (`src/compiler/entry.c3` sets
  `ctx.is_async = true`), so top-level `for await` is a first-class case once the
  statement parses.

## Design

### Parser (`src/compiler/statements.c3`, `for_statement`)
After `expect(FOR)`, peek for `await`:
- Only when `self.is_async` — else `fail("'for await' is only valid in an "
  "async function or module")`.
- Consume `await`, set a local `is_await = true`, then expect `(` and proceed
  through the **existing** for-of parse paths, threading `is_await` down so the
  of-detection branch emits async opcodes. Reject `for await (... in ...)`
  (async-iteration has no for-in form) and `for await (...;...;...)`.

### New opcodes (mirror the sync trio, async-aware)
Rather than overload `INITFOR`/`NEXTFOR` with a flag (they already carry the
for-in/for-of duality), add three siblings so the async path is explicit and
the sync path is untouched:
- `INITFOR_ASYNC ra, rb` — `GetIterator(ra, async)`: `@@asyncIterator` else
  sync-wrapped `@@iterator`; store iterator record in `rb`. This call itself
  may be sync (no await needed for GetIterator).
- `NEXTFOR_ASYNC iter_var, promise_out, iter_state` — call `.next()`, leaving
  the returned **Promise** in `promise_out`. Codegen then emits
  `AWAIT promise_out` + `LOAD_RESUME result`, unpacks the IteratorResult
  (`done`/`value`) — reuse a small `ITERRESULT_UNPACK` or inline GETPROPs — and
  branches on `done`.
- `ITER_CLOSE_ASYNC` — `AsyncIteratorClose`: call `.return()`, then codegen
  awaits the returned promise before propagating the completion.

Alternative considered: a single `is_async` immediate on the existing opcodes.
Rejected — `NEXTFOR` currently returns the value directly, but the async form
must return a *promise to await*, a different codegen shape; a separate opcode
keeps the sync hot path and its inline caches pristine (cf. the descriptor-table
lesson — avoid overloading a hot dispatch with a rarely-taken flag).

### Codegen shape (per iteration)
```
INITFOR_ASYNC obj -> iter_state          ; GetIterator(obj, async)
loop_start:
  NEXTFOR_ASYNC iter_state -> nextPromise ; iter.next()
  AWAIT nextPromise ; LOAD_RESUME result   ; await the step
  result.done ? -> exit                     ; unpack IteratorResult
  <LHS> = result.value                      ; bind (reuse for-of LHS emit)
  <body>
  JUMP loop_start
exit:
```
Break/return inside the loop route through `ITER_CLOSE_ASYNC` (await the
`.return()` result) — extend the `iter_close_reg` unwinding in
`emit_iter_close_for_enclosing` / `break_statement` to pick the async close
opcode when the loop is a for-await (add an `is_await_loop` bit to `loop_stack`).

### Codegen refactor — do NOT fork all four emitters
The sync for-of has **four independent emitters** (see "What already exists"),
each pasting the INITFOR/NEXTFOR/ITER_CLOSE trio inline. **Verified 2026-07-20:**
the INITFOR/NEXTFOR pair is emitted at ~6 sites (`statements.c3:2060`, `2173`,
`2743`, `2985`, `3149`; `expressions.c3:3937` `emit_forof_loop`) and ITER_CLOSE
at ~10 sites — so this is if anything *understated*, not a worst case. Threading
`is_await` by copying the async step (get-iter → next → await → unpack
done/value → close) into each re-forks the algorithm — exactly the anti-pattern
the [[destructuring-single-emitter]] lesson warns against, and async close
(§7.4.11 `AsyncIteratorClose`, which awaits `.return()`) is the subtlest part,
so a 6× surface is where its bug will hide. **Before adding async, factor the
per-iteration step into one helper** the four emitters call, parameterized by
`is_await`, so the async wiring lands in exactly one place. Given the measured
6+/10 site count this is **not optional** — it is mandatory Phase 0 (below), not
a "bundle if convenient" step. The ~300–450 line estimate below assumes the
helper-first path; forking inline runs larger *and* riskier.

### Break/return unwinding — a separate ITER_CLOSE surface
Beyond the four value-binding emitters, ITER_CLOSE is also emitted by the
break/return/labeled-break unwinding paths (`statements.c3:3246`, `3876`,
`3912`, driven by `emit_iter_close_for_enclosing`). These are **physically
separate** from the per-iteration step and the Phase 0 helper will *not* cover
them. This is precisely the `AsyncIteratorClose`-awaits-`.return()` surface the
refactor note warns about, so it gets its own named sub-task in Phase 4: add an
`is_await_loop` bit to `loop_stack`, and at each of those three unwind sites pick
`ITER_CLOSE_ASYNC` (and emit the AWAIT of its returned promise) when the enclosing
loop is a for-await. Do not fold this into the per-iteration codegen.

### Phase 0 findings (investigated 2026-07-20)
Reading all four paths end-to-end refines the "four emitters" model. There are
four sync for-of **paths**, but only three are functions, and they use **three
distinct register layouts** — a single mega-helper would rewrite one layout and
break the byte-for-byte gate. Map:

| # | Path | Location | Value dest | Distinguishing features |
|---|------|----------|-----------|--------------------------|
| 1 | bare / lexical / var **identifier** | `expressions.c3:3937` `emit_forof_loop` | `loop_var`, **above** callee | `CHKOBJ`; `eval_mode` acc resets; per-iter env (PUSH_LEX/INITTZ) |
| 2 | **bare destructure** `for ([a] of)` | `statements.c3:2774` `emit_bare_forof_destruct_loop` | `val_holder`, **persistent below** callee | no CHKOBJ; no per-iter env; `emit_destruct_bindings(ASSIGN_TARGET)` |
| 3 | **member LHS** `for (o.m of)` | `statements.c3:3032` `emit_forof_loop_member` | value **above** callee | `CHKOBJ`; lexer-snapshot LHS re-parse per iter |
| 4 | **lexical destructure** `for (const [a] of)` | **inline in `for_statement`**, `statements.c3:~1840–2010` (NOT a function) | `val_holder`, **persistent below** callee | head-TDZ PUSH_LEX; per-iter env; `emit_destruct_bindings(DECLARE)` |

Two consequences for the Phase 0 shape:
1. **Path 4 is not a function** — it's ~170 lines pasted inline into the parser.
   Lifting it into its own emitter (behavior-preserving) is a prerequisite before
   any shared helper can be introduced.
2. **The value-register layout genuinely differs.** Paths 2 & 4 deliberately hold
   the yielded value in a *persistent register below the callee window* so it
   survives a generator source clobbering the sliding call-frame window on resume;
   paths 1 & 3 keep it above. A helper must take the **value-destination register
   and a `below_callee` layout flag as parameters** — it cannot pick the layout
   itself.

**The three "layouts" are not a real design axis — they reduce to one rule.**
Path 1 (identifier) has no `val_holder` yet handles generator sources fine
(`test_generator_forof.js` T1 = `for (var v of range())`): its generator-clobber
fix is *reloading callee/this from the below-window `next_reg`/`method_reg` each
iteration* (`expressions.c3:4036-4037`), and `loop_var` is allocated FIRST so it
already sits below the callee window — a single `LDREG loop_var, val_reg` needs
no nested allocation. Paths 2 & 4 need the explicit below-callee `val_holder`
only because **destructuring runs a nested iterator protocol on the value**,
which allocates in the callee window. Path 3 (member) doesn't nest, so above is
fine. The single invariant behind all three:

> The yielded value must live in a register **below the callee window** before
> any consumer that runs a nested iterator protocol (destructuring).

So the elegant design **always parks the value below the callee window** and the
distinction disappears (uniform parking is a superset of every path's need; the
generator tests are the proof). Cost: paths 1 & 3 gain one persistent reg + one
`LDREG` they don't strictly need — negligible, and it's what buys a single
skeleton. No compat concern makes this the right trade.

### Chosen design — one loop skeleton + a `consume` union
All four paths are the *same loop*; only **what you do with each yielded value**
differs. Collapse them into one emitter, `is_await` as a boolean:

```
fn void? CompilerContext.emit_forof(&self, ForOfHead head, bool is_await)
  1. iter_src = eval RHS
  2. rec = emit_iter_open(iter_src, is_await)     ; @@iterator | @@asyncIterator + .next
  3. val_slot = alloc_persistent_reg()            ; ALWAYS below-callee (the one rule)
  4. push_loop; loop_stack.is_await_loop = is_await
  5. loop:
       head.prologue()                            ; PUSH_LEX/INITTZ for lexical, else no-op
       emit_iter_next(rec, val_slot, is_await)     ; reload callee, CALL .next,
                                                   ;   [AWAIT], CHKOBJ, unpack done/value,
                                                   ;   done? -> exit ; value -> val_slot
       iter_close_guard(rec, is_await):            ; TRY/CATCH -> ITER_CLOSE(throw)+rethrow
           head.bind(val_slot)                     ; <-- the ONLY per-path difference
           self.statement()                        ; body
       head.epilogue()                             ; POP_LEX
       back-jump
     exit:
       emit_iter_close(rec, is_await, normal)
```

`ForOfHead` is a **tagged union** (C3 has no closures; the bind step calls back
into `self` with borrowed pattern state, so make it explicit data + a `switch`):
```
enum ForOfKind { IDENT, DESTRUCTURE, MEMBER }
struct ForOfHead {
    ForOfKind kind;
    // IDENT:       loop_var, name_idx, is_lexical, is_const, is_bare
    // DESTRUCTURE: DestructBind[] + count + regs, store_mode (DECLARE|ASSIGN_TARGET),
    //              is_lexical, is_const, is_array_pattern   (covers old paths 2 & 4)
    // MEMBER:      ForLhsSnapshot lhs_snap
}
```
`emit_forof` switches on `kind` at exactly three points — `prologue`, `bind`,
`epilogue`. Each arm is 3–15 lines (the old per-path "bind the value" tail):

| kind | prologue | bind(val_slot) | epilogue |
|------|----------|----------------|----------|
| IDENT | per-iter env if lexical | `emit_var_store`/`PUTVAR` | POP_LEX if lexical |
| DESTRUCTURE | per-iter env + INITTZ if lexical | point binds at `val_slot`, `emit_destruct_bindings` | POP_LEX if lexical |
| MEMBER | — | `emit_member_lhs_store(lhs_snap, val_slot)` | — |

`is_await` threads through **exactly three call sites** (`emit_iter_open`,
`emit_iter_next`, `emit_iter_close`) plus the `is_await_loop` bit for
break/return. That is the whole feature — no fourth emitter, no forked algorithm,
nowhere for the async-close bug to hide.

**Verification is test-based, not byte-based.** Correctness = the sync for-of
tests still pass (`test/` fixtures incl. the generator-clobber case, test262
for-of/destructuring/generator dirs net ≥ 0 / zero regressions, rosetta 100/0).
The refactor may emit different — even cleaner — bytecode; that is fine, and
unifying the two register layouts is on the table *if* the generator tests still
pass (the below-callee `val_holder` is justified only by that generator-clobber
case, so it stands or falls on those tests, not on byte-identity).

`out/boomkat_debug -c <file>` disassembles without executing (built
2026-07-20); a diff of the seven captured baselines is a handy "did I move this
cleanly" sanity check while refactoring, but it is not the acceptance gate. NB:
`boomkat` (the plain runner) has **no** `-c` flag — disasm is
`boomkat_debug` only; the [[disasm-one-level-only]] note's `-c` refers to this
debug binary.

### AsyncFromSyncIterator adapter
When only `@@iterator` exists, wrap it so `.next(v)` calls the sync
`.next(v)`, then `Promise.resolve`s the result's `value` and re-wraps as
`{ value, done }` (§27.1.4.2.1). Two options:
1. A real `%AsyncFromSyncIteratorPrototype%` object built at heap init (closest
   to spec, reusable).
2. Handle the wrapping inside `NEXTFOR_ASYNC` when the iterator record is flagged
   sync-origin (less machinery, no new prototype object).
Prefer (2) for the first landing (smaller surface), leaving (1) as a refactor if
a test needs the observable adapter object.

## Phases

0. **Codegen refactor (mandatory, first)** — build the one-skeleton
   `emit_forof(ForOfHead, is_await)` design (see "Chosen design" under Design).
   `is_await` is present as a parameter/field from the start but always `false`
   in this phase (async wiring is Phases 2–3). Suggested landing order, each
   staged so a broken generator test bisects cleanly:
   - **0a. Introduce `ForOfHead` + `emit_forof` skeleton** with the three
     sub-emitters (`emit_iter_open`, `emit_iter_next`, `emit_iter_close`) and the
     TRY/CATCH close-guard, `is_await=false` hardcoded. Uniform below-callee
     `val_slot`.
   - **0b. Port the DESTRUCTURE arm** (old paths 2 & 4 — same layout already) and
     delete both: `emit_bare_forof_destruct_loop` and the ~170-line inline
     lexical block in `for_statement`.
   - **0c. Port the IDENT and MEMBER arms** and delete `emit_forof_loop`
     (`expressions.c3`) and `emit_forof_loop_member`. Rewire the `for_statement`
     dispatch to build a `ForOfHead` and call `emit_forof`.

   Gate: the sync for-of **tests** stay green — `test/` for-of fixtures (incl.
   `test_generator_forof.js`, the generator-clobber case), test262
   for-of/destructuring/generator dirs (net ≥ 0, zero regressions), rosetta
   100/0. Correctness = tests pass, not byte-identity; cleaner/different bytecode
   is expected and fine. `boomkat_debug -c` disasm is a convenience sanity
   check only.
1. **Parser + reject-cases** — `for await` recognized in async/module, errors
   elsewhere. Explicitly **reject** `for await (... in ...)` (no async for-in
   form) and C-style `for await (;;)` — with a parse error, not silent
   acceptance. Wire `is_await` through the of-detection branches. Land with a
   temporary "not yet implemented" codegen stub that compiles the simplest
   `for await (const v of asyncIterable)` to the new opcodes (opcodes stubbed).
2. **VM opcodes** — `INITFOR_ASYNC` (GetIterator async + sync fallback flag),
   `NEXTFOR_ASYNC` (call next → promise), `ITER_CLOSE_ASYNC`. Unpack
   IteratorResult. Validate with a hand-written async-iterator object test.
3. **Await wiring + sync-iterable fallback** — emit AWAIT/LOAD_RESUME around
   each step; AsyncFromSync wrapping so `for await (x of [1,2,3])` works.
4. **LHS parity** — destructuring patterns, bare identifier, let/const per-iter
   scoping.
5. **Break/return async close** — the separate unwinding surface (see Design):
   add `is_await_loop` to `loop_stack`; at the three `emit_iter_close_for_enclosing`
   unwind sites (`statements.c3:3246`, `3876`, `3912`) select `ITER_CLOSE_ASYNC`
   and await its returned promise when the enclosing loop is a for-await. Not
   covered by the Phase 0 helper — do this as its own step with `break`/`return`
   /labeled-break fixtures.

## Validation

- `test/` async-iteration fixtures: `for await` over (a) a hand-written async
  iterable, (b) a plain array (sync fallback), (c) early `break`/`return`/throw
  (async close runs), (d) destructuring LHS.
- Un-skip `language/statements/for-await-of/**` and
  `language/module-code/top-level-await/**` that are `features:[async-iteration]`.
  **This is a per-test judgment, not a pattern toggle:** the skip is currently a
  blanket `features:[async-iteration]` filter, so simply dropping the pattern
  un-skips async-generator-*source* tests too and eats regressions. Use an
  explicit allowlist (or a secondary check that keeps `async-generator` sources
  skipped) — treat this as its own small task, not a one-line edit. Diff vs
  baseline: require net positive, 0 regressions. The `noStrict` for-await tests
  stay skipped (strict-only engine), and tests observing the actual
  `%AsyncFromSyncIteratorPrototype%` object stay failing until adapter option (1)
  lands — mark both as expected-fail, not surprises.
- Rosetta 100/0; no Phase 15 (classes) / Phase 21 (generators) regression — the
  async save/restore path is shared.

## Estimated size

~300–450 lines across `src/compiler/statements.c3` (parse + codegen),
`src/bytecode.c3` (3 opcodes + disasm), `src/vm/vm_control.c3` (3 handlers +
AsyncFromSync), `src/heap.c3` (adapter proto if option 1). A real feature, not a
quick fix — the payoff is the whole async-iteration consumer surface, not just
the 2 residual tests. Note: this estimate assumes the Phase 0 helper refactor;
forking all four emitters inline runs larger *and* riskier.

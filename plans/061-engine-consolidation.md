# Plan 061 — Engine-wide consolidation (design review)

**Status:** RE-SURVEYED against main @ 073aa16b (session 302). Originally DRAFT (session 295). User-requested full-design review: reduce duplication, increase elegance/compactness at constant performance and correctness. Method: four read-only subsystem surveys → this ranked plan → one fix agent per item, each gated on golden bytecode + bench-fast + relevant phase sweeps.

**Re-survey verdict:** ~70% still valid. Three high-ranked items are wrong: **C1 and D1 are already done** (a1513ec5, d366a2c5 — deleted from the ordering below), and **D2 conflates two unrelated mechanisms** and overstates its scope. The survey also turned up one *live shipping spec bug* (B1's arrow prologue gap) and the structural reason the suite never saw it (4604 parse-negative tests skipped wholesale). Both are now tracked independently of this plan; B1's narrow fix should ship on its own, ahead of any consolidation work.

**Ranking principle (revised):** rank by how much of the *hand-maintained-invariant* bug class an item forecloses, not by lines saved. Session-302 evidence: 073aa16b (three fusion passes carried a jump-target bitset and were correct; the two without one were the two that were buggy), 0ee9fd78 (four of nine activation push sites never wrote the field), 4f486724 (a guard matching on opcode alone, never register identity). When an invariant is hand-copied N times, the bugs live in the copies that omit it.

**Evidence baseline:** this session alone, duplication caused: the PUTLEX-r0 param bug (fixed 3×), the in_formal_params flag (chased through 5 sites), ~15 core.c3 merge conflicts, the arguments-object divergence (4 builders, 2 missing @@iterator), and the resume-routing drift.

## A. Generator/async machinery (survey complete)

Ranked consolidations (full details + file:line in survey; invariants noted per item):

- **A1 `pop_to_caller(ds, …)` epilogue** — the caller-frame restore tail is copied 9+ times across YIELD/AWAIT/ays_*/GEN_START paths; single helper with the halt-at-zero branch and conditional ds.code_* reload. Highest mechanical win, lowest risk.
- **A2 `suspend_generator(ds, gs, kind, save_pc)`** — one register/env/pc save routine replacing 4 copies (sync yield, sync yield*, ays_save_body, ag_suspend_on_await). save_pc stays a parameter; must not clobber GEN_AWAITING_RETURN; thunk case keeps pending_resume_reg + gen_act frame source.
- **A3 `attach_await_reaction(...)` factory** — six hand-rolled fulfill/reject pair builders → one, parameterized by ordinals + state carrier (var_env+is_async_state vs property slot). Centralize the OOM rollback (is_async_state/var_env clearing) with it; is_async_state is what GC-marks the gs.
- **A4 Single suspend-outcome channel** — drop gs.ag_suspend_kind (never branched); make async_gen_resume_body RETURN a {SETTLED_YIELD|SETTLED_RETURN|SETTLED_THROW|SUSPENDED_AWAIT} outcome replacing the heap.ag_did_await + heap.has_error + returned-object triple the drain currently sniffs.
- **A5 Tagged completion {kind, value}** — replace the resume_kind + resume/throw/return_value 4-field union; preserve the stale-completion resets in LOAD_RESUME/YIELD_STAR_ASYNC.
- **A6 One resume_into_frame(gs)** — unify vm_calls.c3 inline-CALL and vm_execute.c3 call_fn resume copies; reconcile the divergent this_binding restore. Also demote heap.resume_gen to a single-shot handoff consumed at resume-push (opcodes already distrust it in favor of act.async_gen_state).
- **A7 (cleanup) retire heap.did_yield/yield_value on async paths; delete delegated_index if truly unused.**

Ordering: A1 → A2 → A3 (mechanical, independently verifiable) → A5 → A4 → A6 (semantic). Each gates on: phases 21/24/15 zero, golden 9/9, rosetta, bench-fast flat, ASan over generator families.

## B. Compiler (survey complete)

- **B1 ParamListPlan + emit_param_prologue(ProloguePolicy)** — the three prologues (parse_function_body / compile_inner_function / compile_arrow_inner_reparse) are ~600 lines of interleaved byte-identical stages with 4 real policy axes (push_var, default-tail putlex, deferred destruct defaults, dup-check). Split parse→plan→emit; policy flags select existing branches so golden bytecode stays byte-identical. Kills the fix-in-every-copy class (PUTLEX-r0, in_formal_params). Also: arrow reparse is MISSING the dup/restricted-name check (functions.c3:3562) — a real gap the merge should close.
- **B2 in_formal_params owned by compile_default_expr** — 13 call sites in two inconsistent camps (4 self-guarding, 9 ambient); make it a parameter + internal defer; assert-equal transition build.
- **B3 CallableCtx defer-frame** for {is_async,is_generator,is_user_generator,forbid_*} — 26 manual far-apart restores leak the mutated flag on `!` error paths (LATENT BUG); defer-based frame at ~10 multi-flag sites. Exclude cross-context propagation copies (they carry per-flag spec rationale).
- **B4 Finish TemplateScan rollout** — skip_expr_lex still hand-rolls template_depth (no per-level brace counting) and the three statements.c3 pre-scanners have NO template handling (a `let` inside `${...}` misclassifies). Drop-in TemplateScan; add fixtures. Plus a shared DepthTracker primitive for the 6 walkers duplicating paren/bracket arithmetic (full 12-walker unification NOT warranted — different stop conditions/payloads).
- **B5 Error-emission normalization** — 136 bare `COMPILE_ERROR~` returns with no message/position vs 51 self.fail; mechanical conversion, strictly better diagnostics, zero bytecode impact.

## C. Builtins/registration (survey complete)

- **C1 Fold BuiltinMeta into the dispatch table** — replace the 461-arm metadata switch + separate fn-pointer array with one `BuiltinDef{fn,name,arity}[Builtin.LAST.ordinal]` designated-init table (C3 supports it; dispatch array already is one). Per-feature edit drops from 3 synchronized sites to enum + one row — kills the session's #1 merge-conflict magnet. Preserve O(1) [ordinal] access + null-fn hole behavior.
- **C2 One ToObject/boxing ladder** — three copies (arr_to_object, builtin_to_object, inline Object()-ctor copy) differing only in return convention; the Array.from bug family's divergence risk. One `to_object_hobject` + thin ctx wrapper; preserve exotic-string flags/.length and Symbol-before-String ordering.
- **C3 Merge registrars** — register_array_proto_method ≡ register_string_proto_method (byte-identical) → one register_proto_method; 6 accessor registrars → one (getter+optional setter); keep ctor-shaped ones separate. Preserve name/length prop-flags + "get " prefix + lookup-first interning.
- **C4 Throw-helper unification** — 7+ per-module {type,range}-error wrapper families → shared builtin_throw_type/range; retire the 72 hand-rolled alloc(ERROR) blocks onto builtin_throw. Keep the result-changing vs no-result split (load-bearing).
- **C5 AB/SAB merge** — ctor/slice/resize-grow parameterized by (obj_class, is_shared, allow_shrink, alloc_full_max); preserve SAB grow-in-place stable-pointer invariant + detach/RangeError ordering.
- **C6 (none needed)** — keyed collections already model-consolidated (coll_* + one canonicalizer); use as the reference pattern.
## D. VM/heap conventions (survey complete)

- **D1 (URGENT, dispatched as bug-fix ahead of the plan) Missing GC roots** — six more fields of the return_val class unmarked: Activation.{this_binding,new_target,async_promise,tv_func}, Catcher.thrown_val chains, heap.{error_value,yield_value}; plus verify resume_gen/gen_initial_gs-only reachability. Pure fix, near-zero risk.
- **D2 Single PendingThrow error channel** — FIVE channels today (vm.has_error, heap.has_error+error_value, vm.throw_pending+throw_value, ctx.should_throw+throw_value, return_val-as-payload) with 4 hand-copied conversion epilogues and documented workaround comments; collapse to one heap-owned {value, active} + a commit_throw(ctx). Kills afa_clear_stale_error and the boundary-clear workaround; the coercion-path visibility invariant is the one to protect. Biggest semantic item in the whole plan — do LAST, after everything is green and baselined.
- **D3 reload_dispatch_for_act(Dispatch*)** — the 8-line CompiledFunction→ds reload copied 8× (overlaps A1; do together); plus pop_frame_head for the ~30 decref+count-- pairs. RET twins share only the head; their async/super tails stay inline.
- **D4 ta_base_ptr(HObject*) getter** — consolidates the ab.data+byte_offset math at 6+ fast-path sites WITHOUT touching the deliberate resizable-length branch (bench-gated).
- **D5 (cosmetic, optional) PropFlags** — conventions clean; ~88 inline mutations could start from named constants.
- **Untouchable without bench proof:** TA length fast-path branch; RET twins' refcount fast paths.

## Synthesis — execution order (REVISED, session 302)

The original ordering front-loaded C1 and D1 (both since completed) and back-loaded B1, which contains the only confirmed live bug. Inverted.

| # | Item | Files | Sites | Risk | Notes |
|---|---|---|---|---|---|
| 1 | **B1 arrow dup/restricted-name check** — narrow fix only | 1 | 1 fn | Low | Confirmed live bug. Ship standalone; do NOT couple to the ~600-line prologue merge. |
| 1b | **Un-skip parse-negative test262** | 1 (runner) | — | Low | Independent of 061. Without it, item 1 has no regression net. Expect a fail-count jump — that is the blind spot becoming visible. |
| 2 | **A4** delete `ag_suspend_kind` | 2 | 5 | Very low | Provably write-only dead state. Warm-up commit. |
| 3 | **C3** registrar merge | 6 | ~10 | Very low | `diff`-proven byte-identical. |
| 4 | **A1 + D3** pop/reload helpers | 5 | 22 | Medium | Must parameterize the two `valstack_top` variants — they are NOT interchangeable. Golden-gated. |
| 5 | **B3** CallableCtx defer-frame | 3 | 14 | Low-med | 14/14 sites lack `defer` — a 100% defect rate, not partial. |
| 6 | **A3** `is_async_state` factory | 3 | 8 | Med-high | GC-visible: the flag is the sole reason the GC marks a GeneratorState. |
| 7 | **B1 full ParamListPlan merge** | 1 | 3 prologues | High | ~600 lines. Only after 1b provides coverage. |
| 8 | **B4** TemplateScan rollout | 2 | 4 | Low-med | `let` inside `${...}` misparses. |
| 9 | **A5/A6** state-model collapse | 3 | ~10 | High | A6 must PRESERVE the documented `this_binding` split, not erase it. |
| 10 | **B2/B5/C2/C4/C5/D4/A7** | various | — | Low | Fill-in; independent; parallelizable. |
| 11 | **D2** error channel | 6+ | ~50 | Very high | Last, alone, on a green baseline. |

**Do NOT attempt while wrong-value or lifetime bugs are in flight:** D2 (rewrites the mechanism in-flight ASAN work reads), A3 and A5/A6 (generator state model), and A1 is borderline since `vm_generators.c3` is hot for that work.

**Load-bearing for correctness:** B1, A3, B3, D2, plus the unlisted `activation_begin` bypass. **Cosmetic, say so plainly:** B5, D5, C2, C4, C5, A7.

## Corrections from the session-302 re-survey

- **C1 (BuiltinDef table) — DONE**, landed a1513ec5. `core.c3:101` is now `enum Builtin : uint (String js_name, int js_arity, BuiltinFunc handler)` with metadata and dispatch generated via `$foreach`; the 461-arm switch is gone.
- **D1 (GC roots) — DONE**, landed d366a2c5. All six named fields are covered by `mark_activation_fields` (`vm_core.c3:84-111`).
- **D2** — "five channels" is wrong; there are **three** ambient channels (`vm.has_error`; `heap.has_error`+`error_value`; `vm.throw_pending`+`throw_value`), of which only the first two are genuinely redundant. `ctx.should_throw` is the *native-builtin return convention* on `BuiltinContext` — a per-call stack-scoped out-parameter, not an ambient channel; folding it in would make every builtin write global VM state and break re-entrancy. **Drop it from this item.** `return_val` is a value carrier, never tested as an error flag — not a channel either. "4 epilogues" → **12**, in four distinct shapes, and only **1 of the 12** sets `throw_pending` — either the other 11 are correct by construction or latently wrong, and that is undocumented. The real workaround to kill is `promise_clear_error_channels` (36 call sites), not `afa_clear_stale_error` (4, a one-line wrapper around it).
- **Counts corrected:** A1 9→11 (in two non-interchangeable variants), A2 4→7, A3 6→"5 hand-set sites + 3 hand-rolled rollbacks", D3 8→11, D4 6→18, C4 72→32, B3 26→14, B5 136→134 / 51→60.
- **A6** — the `this_binding` divergence the plan wants "reconciled" is **deliberate and documented** (`vm_execute.c3` restores out-of-line with a raw assign). Reconcile means preserve, not merge.
- **A7** — `delegated_index` already deleted (0 refs). `heap.did_yield`/`yield_value` remain.
- **B2** — largely already fixed with `defer`; re-scope before assigning.
- **C5** — `arraybuffer_slice_impl` already exists and both slice paths delegate to it; only the ctor and resize/grow pairs remain.
- **NEW ITEM — `activation_begin` bypass.** `vm_calls.c3:862` deliberately cannot call `activation_begin()` and hand-repeats its initialization, with a comment asking the next reader to "keep the two in sync." 0ee9fd78 is proof that request already failed once. A compile-time-enforced shared init would foreclose the class.

## Execution rules

One item per agent (Opus for A-series and anything touching vm_generators.c3); byte-identical golden bytecode unless a change is justified in the commit; no behavioral drift — this plan changes SHAPE, not semantics. Fail counts must stay at their pre-refactor values (currently: full suite 65 fail / 1 CE with 3 fix agents in flight; re-baseline before starting).

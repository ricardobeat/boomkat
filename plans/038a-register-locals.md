# Plan: Register-resident locals (close the QuickJS call-perf gap)

## Problem

Deep-recursion / call-heavy code is ~11× slower than QuickJS
(`bench_valstack_copy` steady-state: 2.84s vs 0.26s). Profiling shows the cost
is **not** the interpreter dispatch loop — it is per-call heap traffic:

| function | ~samples | what it is |
|---|---|---|
| `HObject.put_prop` | 486 | writing each param/local into the scope object |
| `ensure_prop_hash` / `grow_props` | 530 | growing that object's property store |
| `transition_shape_new` | 95 | shape transition per binding |
| `hobject_alloc` | 45 | allocating the scope object |
| `hobject_free` | 333 | freeing it on return |

Every call to a function with params or `var`s allocates a **scope HObject**
(`env_create_function_scope`), runs a `DECLVAR` (→ `put_prop`, refcount, shape
churn) for each binding, then frees the object on return.

The waste: **reads already use registers.** `s += i` compiles to
`ADD r1=r1,r2`, `return s` to `RET r1`. The env is essentially write-only dead
state for any function that doesn't need a real scope. QuickJS keeps locals in
the stack frame's register array with zero heap traffic — that is the gap.

## What already exists (build on, don't reinvent)

- `CompiledFunction.flags.needs_env` — already computed in
  `CompilerContext.finish()` (context.c3:1069-1089). True iff the function needs
  a runtime scope: var/param bindings **captured by a nested closure**, OR
  `arguments`, OR direct `eval`, OR default/rest params. For a plain
  function like `copyTest`, `can_skip_env` is already true → `needs_env=false`.
- `scope_stack[i].reg` — every local/param already has an assigned register;
  `resolve_var(name)` returns it for non-captured locals (scope.c3:79).
- `scope_stack[i].is_captured` — set when an inner closure / `let`-TDZ /
  `catch` forces a var through the env (statements.c3:374, 2128).
- A peephole pass + `NOP` opcode already run in `finish()` (context.c3:456+),
  and `NOP` is a safe jump target.

## The gap that blocks naive elision

`needs_env=false` does **not** currently mean "no env." The CALL fast path still
allocates a scope whenever `num_args > 0` (vm_calls.c3:119, and the slow path at
866), because **param `DECLVAR`s would otherwise clobber the parent env**.
And a few non-captured locals still emit `GETVAR`/`PUTVAR`/`INC_VAR` (env ops)
rather than register ops — observed on for-loop update vars. So we cannot just
NOP every `DECLVAR`; some env reads still happen.

Two cases to handle:
1. **Dead env writes** — `DECLVAR` whose value is only ever read via register.
   Safe to elide once we prove (2).
2. **Live env ops on non-captured locals** — stray `GETVAR`/`PUTVAR`/`INC_VAR`
   for a local that has a register. These must be rewritten to the register
   form, or the var must be treated as captured (kept in env). The for-loop
   update var is the known instance; there may be others (audit required).

## Design

When `needs_env == false`, the function runs with **no own scope object**: it
reuses the parent env for the (rare) lookups that escape to outer scopes, and
all of its own params/locals live purely in registers.

### Phase 0 — Instrumentation & invariant (safety net)
- Add a debug assertion (compile-time-gated, e.g. `-D ENV_STRICT`): in the VM,
  if a function has `needs_env=false` and executes `DECLVAR/GETVAR/PUTVAR/
  INC_VAR/DEC_VAR/PUTLEX*/INITTZ/TYPEOFIDENT` that resolves to **its own**
  binding (not a parent/global), trap. This catches any missed live-env op
  during development before it becomes a silent wrong-value bug.
- Add a focused regression corpus first (see Testing) so every step is gated.

### Phase 1 — Compiler: make non-captured locals fully register-resident
Goal: for `needs_env=false` functions, **no opcode references the function's own
env** for a non-captured local.
1. Audit every site that emits `GETVAR/PUTVAR/INC_VAR/DEC_VAR/TYPEOFIDENT` and
   confirm it first tries `resolve_var` and only falls back to env when the name
   is genuinely not a local (parent/global) or is `is_captured`.
   - Known fix: for-loop update var emits `PUTVAR`/`GETVAR` (cf2.js lines 17-18)
     even though it has a register — route through the register.
   - `INC_VAR`/`DEC_VAR` (the `i++` fusion) is **env-based by construction**.
     Add a register-based counterpart (`INC_REG`/`DEC_REG`, or reuse `INC`/`DEC`
     which already operate on a register) and emit it when the target resolves
     to a non-captured local register.
2. Keep `is_captured` as the single source of truth: any var that *must* live in
   the env (closure capture, TDZ let, catch param) stays `is_captured=true` and
   continues to use env opcodes. `needs_env` already becomes true in that case
   (has_closures path), so such functions keep their scope object — correct.

### Phase 2 — Compiler: elide dead env writes
In `finish()`, once `needs_env` is final:
- If `needs_env == false`: rewrite every `DECLVAR` / `PUTLEX` / `PUTLEX_C` /
  `INITTZ` for the function's own bindings to `NOP` (safe: not read; NOP is a
  valid jump target). After Phase 1 there are no remaining env reads, so these
  writes are provably dead.
- Also drop the param `DECLVAR`s emitted at functions.c3:986 under the same
  condition (or NOP them in the same pass for uniformity).

### Phase 3 — VM: stop allocating the scope object
- `vm_calls.c3:119` and `:866`: change the env decision from
  `needs_env() || (num_args > 0 && !needs_lex_bridge())`
  to just `needs_env()`. With param `DECLVAR`s elided (Phase 2), the
  "params clobber parent" rationale no longer applies, so the `num_args > 0`
  clause is removed. `needs_env=false` functions reuse `func.var_env` (parent)
  directly — no `env_create_function_scope`, no per-call alloc/free.
- Audit the other `env_create_function_scope` call sites (vm_core.c3,
  vm_execute.c3, vm_property.c3) — these are callback/construct/resume paths;
  apply the same `needs_env` gate where the fast-call rationale matches.
- Confirm the return path (`dispatch_returns` inline in vm_execute.c3) does not
  try to tear down a scope object that was never allocated. Since `var_env`
  points at the parent, no decref/free of an own-scope happens — verify the
  decref logic is keyed on "did we allocate" not "is there a var_env."

### Phase 4 — Cleanup & dead opcode pruning
- If `DECLVAR`/`PUTLEX` for own-locals are always elided in `needs_env=false`
  functions and always present in `needs_env=true` ones, the opcodes stay (still
  needed for the env case) but the hot path no longer hits them.
- Re-run the var-IC code: VarIC entries for elided DECLVARs are now unused; make
  sure no stale IC path references them.

## Risks & correctness obligations

- **Hoisting semantics**: `var` is function-scoped and hoisted. Eliding the env
  must preserve that a `var` referenced before its declaration reads `undefined`,
  not a ReferenceError. With register residency, the compiler must initialize the
  local's register to `undefined` at function entry (LDUNDEF) — verify this
  already happens (cf2.js shows `LDUNDEF r1; ... ` at entry — looks present).
- **`typeof undeclaredLocal`**: must still work; `TYPEOFIDENT` on a true global
  stays env-based (not a local), unaffected.
- **Shadowing / `let` in blocks**: already forces `is_captured` → env path →
  `needs_env=true`. Unaffected.
- **`arguments`, `eval`, closures, defaults, rest, generators, async, arrow**:
  all already force `needs_env=true`. Unaffected — they keep the scope object.
- **`with`**: removed in this engine (strict-only). N/A.
- **Re-entrancy / recursion**: registers are per-activation (sliding window), so
  recursion is naturally correct once locals are register-resident.

## Testing (gate every phase)

1. **Build a regression corpus** under `test/` before touching code:
   - params + locals, control flow, loops with update vars, nested blocks,
     shadowing, hoisted `var` use-before-decl, `typeof` local/global,
     closures capturing outer locals (must stay correct), `arguments`, default/
     rest params, recursion, try/catch param, generators.
2. After each phase: `bash test/rosetta/run.sh ./out/boomkat` must stay 44/44.
3. test262 phases 1 (closures/calling convention) and 3 (object/scope) — compare
   pass counts to the recorded baseline; no regressions.
4. The `-D ENV_STRICT` trap (Phase 0) must not fire on the full corpus + rosetta.

## Success metric

- `bench_valstack_copy` (N=30): from 2.84s toward QuickJS's 0.26s. Realistic
  target after env elision: large multiple improvement (the env alloc+put_prop+
  free is ~60-70% of profile samples). Remaining gap vs qjs is dispatch/
  refcount floor, addressed separately.
- No rosetta/test262 regressions.

## Sequencing

Phase 0 (corpus + trap) → Phase 1 (register-resolve all non-captured locals,
verified by trap) → Phase 2 (elide dead writes) → Phase 3 (drop alloc) →
Phase 4 (cleanup). Each phase independently builds, passes rosetta, and is
measurable. The big perf jump lands at Phase 3; Phases 1-2 are the correctness
groundwork that makes Phase 3 safe.

## KNOWN PRE-EXISTING BUG (not introduced here)

`function inner(){...}` **declared inside a loop body or nested in another
function and called from a loop** throws "number is not a function" — fails on
baseline d0ef268 too. Nested-function-declaration hoisting bug. The corpus
avoids it (helper hoisted to top level). Track/fix separately; the register-
locals work must not regress it further.

## PHASE 0 — DONE

- Corpus: `test/test_register_locals.js` — run `./out/boomkat test/test_register_locals.js`, must print `RESULT:PASS`.
- Trap: project.json target `boomkat_envstrict` (O0 + `"features":["ENV_STRICT"]`).
  Build with `c3c build boomkat_envstrict`. Run a script through `./out/boomkat_envstrict`;
  it panics `ERROR: 'ENV_STRICT: needs_env=false fn touched own env: <OP>'` if a needs_env=false
  function touches its own env. **Goal after Phase 1-2: this build runs the corpus + rosetta clean.**
  NOTE: `$feature` flags do NOT work via `-D` in project/build mode — they must be in the target's
  `features` array in project.json. (`-D` only works in `c3c compile-run <files>` mode.)
- Guards use compile-time `$if types::ENV_STRICT:` (NOT runtime `if`) so they cost nothing when off.

## PHASE 1 + 2 — DONE

Combined (needs_env is only final in finish(), so elision lives there too).

**Phase 1 (compiler: register-resolve non-captured locals):**
- `typeof local` now emits register `TYPEOF` (not env `TYPEOFIDENT`) when the
  identifier resolves to a non-captured local (expressions.c3, the typeof case).
- Added `CompilerContext.has_captured_local` flag, set wherever a local is forced
  through the env (let/const block shadow at statements.c3:380, catch param at
  ~2128). Feeds both `can_skip_env` and the elision gate so shadowed/caught vars
  keep their env.

**Phase 2 (finish(): elide dead env writes):**
- New pass in context.c3 just BEFORE the NOP-compaction (so its NOPs get
  compacted). When the function needs no scope (recomputed `elide_ok`: no
  closures/eval/arguments, no default/rest params, no captured local, not
  global/arrow/generator/async) it NOPs: DECLVAR, PUTLEX, PUTLEX_C, INITTZ
  (always own-scope), and the loop-sync `PUTVAR rX,n`+`GETVAR rX,n` adjacent
  same-reg/same-name pair.
- CRITICAL: gated on `!self.is_global` — global/eval vars are env-resident
  (resolve_var skips global scope), so eliding them breaks all global var access.

**ENV_STRICT trap refined:** only the 4 write-op traps (DECLVAR/PUTLEX/PUTLEX_C/
INITTZ) remain meaningful. The read-op traps (GETVAR/TYPEOFIDENT/INC_VAR) were
removed: for needs_env=false, var_env/lex_env == parent env, so a "found at own
env" check false-positives on legitimate parent lookups. A real own-local read
leak instead surfaces as a "not defined" throw → caught by the corpus.

**Validation (against test262, not just rosetta):**
- Corpus `test/test_register_locals.js`: PASS on both normal and ENV_STRICT builds.
- rosetta 44/44.
- test262 phase 1: 80→81 pass, 5→3 fail. phase 3: 4818→4856. phase 8: 1065→1077.
  No regressions (the 2 var-scope tests that touch this area fail at HEAD too —
  pre-existing param-env-vs-body-env gap).
- Corpus hardened with the two regressions found & fixed during this phase:
  global-scope var read, and calling a non-function (var holding a primitive).

NOTE: env writes are now NOP'd but the VM STILL allocates the scope object per
call (Phase 3 removes that). So no perf win yet — this is the correctness
groundwork. ENV_STRICT confirms the writes are gone; Phase 3 is now safe.

## PHASE 3 — DONE  ★ THE PERF WIN

Changed the VM call path (vm_calls.c3, both the fast-call ~line 119 and the
slow-call ~line 866) from
  `needs_env() || (num_args > 0 && !needs_lex_bridge())`
to just `needs_env()`. With param/local DECLVARs elided in Phase 2, a
needs_env=false function has nothing to write to a scope, so it reuses the
parent env (func.var_env) directly — NO per-call scope HObject allocation.

### Results

**valstack_copy (N=30, the target): 2.84s → 0.40s — 7× faster.**
Gap to QuickJS: 11× → ~1.5× (0.40s vs 0.26s).

bench-fast vs session baseline:
- bench_valstack_copy  −78%  (59→13ms)
- bench_recursion      −49%  (596→303ms)
- bench_function_call  −22%  (72→56ms)
- bench_arithmetic     −12%
- (loop/ic_proto unchanged — that's the separate dispatch-split overhead.)

### Validation
- corpus PASS (normal + ENV_STRICT oracle).
- rosetta 44/44.
- test262 phase 1: 81 pass / 3 fail (matches Phase 1+2; baseline was 80/5).
- test262 phase 3 / phase 8: the apparent drops were PARALLEL-RUNNER FLAKINESS —
  deterministic one-by-one recheck of all 30 "regressed" tests showed 0 real
  failures. No regressions.

## DONE. Remaining gap to qjs (~1.5×) is general dispatch/refcount floor, not
## the scope-object architecture — a separate effort if desired.

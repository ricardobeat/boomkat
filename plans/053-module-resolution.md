# Plan 053 — Module Resolution & Evaluation (test262 module tests)

**Status:** planned — execute AFTER the four in-flight lexer/compiler fix agents
(HTML comments, LS/PS line terminators, switch lexical scoping, restricted-global
+ eval-parse) have landed and merged.

**Author context:** written 2026-07-12. Prerequisite work (harness correctness)
already committed on `main`: `79e7110` (await-in-module), `55f14b9`
(negative:phase:runtime scoring + `flags:[module]` routing), `a146961`
(error-type + phase matching). The harness is now spec-faithful per test262
`INTERPRETING.md`, so pass/fail on module tests is trustworthy.

---

## Motivation

The corrected harness exposed a cluster of `flags:[module]` test failures. The
root cause is **not** parsing — `compile_module` works — it is that the
**resolve → link → evaluate pipeline is dead code**: `resolve_module`,
`link_module`, and `execute_module` exist in `src/module.c3` (`boomkat::esm`)
but **nothing calls them**. The batch worker's `exec_js_module` only calls
`compile_module` (parse) and then runs the module body via `execute_in_env`
with **no dependencies loaded**. So any module test that imports a sibling file
cannot work.

### Target tests (in priority order)

**Tier 1 — synchronous multi-file resolution (no async):**
- `language/module-code/eval-rqstd-abrupt.js` — imports two `_FIXTURE.js` files;
  the first does `throw new TypeError()` at evaluation. The outer
  `throw new RangeError()` must be **unreachable**. Expected uncaught error:
  `TypeError`. This is the canonical "imported module throws → error propagates
  with its real type" test.
- Many other `language/module-code/*.js` and `language/export/*`,
  `language/import/*` positive tests become runnable once the pipeline is wired
  (currently they FAIL because imports resolve to nothing). Re-measure after
  Tier 1; the earlier before/after showed ~172 module pass-equiv (mostly
  accidental script-mode CEs) collapsing to ~112 once routed — Tier 1 should
  recover the legitimate ones.

**Tier 2 — top-level await (TLA):** requires async module evaluation.
- `top-level-await/module-import-rejection.js` — imports a `_FIXTURE.js` whose
  body is `export const resolved = await 42; export default await
  Promise.reject(new TypeError(...))`. Expected uncaught: `TypeError`.
- `top-level-await/module-import-rejection-body.js` — expected `TypeError`.
- `top-level-await/module-import-rejection-tick.js` — expected `RangeError`.
- `top-level-await/await-dynamic-import-rejection.js` — also needs
  **dynamic import** `import(...)`. Expected `TypeError`.

`noStrict` is **explicitly out of scope** (engine is strict-only), so
`eval-code/direct/var-env-global-lex-non-strict.js` is permanently skipped, not
part of this plan.

---

## Current state of `src/module.c3` (verified)

What exists and works:
- `struct ModuleDef`, `enum ModuleStatus` (UNLOADED→LOADING→LOADED→LINKING→
  LINKED→EVALUATING→EVALUATED).
- `heap_ensure_module` — allocates/caches a `ModuleDef` (used by the worker).
- `resolve_module` — normalizes specifier (via `call_resolve_name`, which
  already handles relative `./x.js` against a base dir), reads source
  (`default_module_read` via `fopen`), `heap_ensure_module`, recurses into
  dependencies. **Never called.**
- `link_module` — resolves import/export bindings across the dep graph.
  **Never called.**
- `execute_module` — creates a module env parented to global, executes deps
  first, wires import bindings into the env, runs the body via
  `execute_in_env`. **Never called.**
- `build_namespace_object`, `resolve_export_local_name` — namespace + name
  mapping helpers.

What is missing / broken for our tests:
1. **No pipeline entry point.** No code path drives resolve→link→execute for a
   top-level module program. The worker's `exec_js_module` stops at
   `compile_module`.
2. **Dependency-throw type is lost.** `execute_module` line ~579: a dep that
   throws makes `vm.execute_in_env` return an error; the fn returns bare
   `false`. The actual thrown value (the fixture's `TypeError`) is dropped —
   the caller learns "failed" but not *what*. For `eval-rqstd-abrupt` the
   harness needs the real `TypeError` to surface as the uncaught error.
3. **No top-level await.** `execute_module` is fully synchronous
   (`execute_in_env`). Module bodies containing `await` have no
   suspend/resume/promise-driven evaluation. Async infra exists for async
   *functions* (`Opcode.AWAIT`, `act.async_promise`, microtask drain,
   `promise_proto`) and could be leaned on, but module TLA has different
   semantics (module evaluation returns a promise; a rejected dependency
   rejects the importer).

---

## Design

### Phase 1 — Wire the synchronous pipeline (Tier 1)

**Goal:** `eval-rqstd-abrupt` passes; positive sync-import module tests run.

1. **Add an entry point** in `boomkat::esm`, e.g.:
   ```
   fn TVal? run_module_program(Heap* heap, Vm* vm, char[] module_name, char[] source)
   ```
   that:
   - `heap_ensure_module(name)`, compiles `source` via `compiler::compile_module`
     into `mod.func` (or accept a pre-compiled `mod`),
   - `resolve_module` for each `req_modules` entry (recursively loads + compiles
     dependencies; sets `rme.resolved`),
   - `link_module(mod)`,
   - `execute_module(heap, vm, mod)`,
   - returns the uncaught error (if any) as a `TVal?` fault carrying the real
     thrown value — see #2.

2. **Propagate the real thrown value out of `execute_module`.** Change its
   contract from `bool` to something that carries the error, OR (less invasive)
   leave the thrown value in `heap.error_value` / `vm.throw_value` on failure
   and have the entry point read it — mirror how the worker already reads
   `heap.error_value` in `thrown_type_matches`. Verify: after a dep throws
   `TypeError`, `heap.error_value` holds that TypeError object when
   `run_module_program` returns its fault.
   - Cycle/order caveat: `execute_module` executes deps depth-first (line ~491).
     The first throwing dep must abort the whole chain and preserve its error —
     confirm the early-return at line ~496 doesn't get overwritten by later
     sibling evaluation or by the `EVALUATING` cycle guard.

3. **Call it from the worker.** In `test_vm_runner/batch_test_vm.c3`,
   `exec_js_module` currently only compiles. Replace its body (for the
   full-program case) with a call to `esm::run_module_program`, then map:
   - fault carrying a thrown value → runtime error (rc 1), leaving
     `heap.error_value` populated so the negative-test type check works;
   - compile failure → rc 2;
   - success → rc 0.
   The worker must pass an on-disk path/name as `module_name` so relative
   imports resolve against the test file's directory (the fixtures sit next to
   the test). NOTE: the worker currently hands `exec_js_module` the *source
   string* with a synthetic name `"__test262_module__"`; for relative-import
   resolution to work it must instead hand the **absolute test path** as the
   base name so `call_resolve_name` resolves `./x_FIXTURE.js` correctly. This is
   the single most important wiring detail.

4. **Harness scoring already handles the rest.** `eval-rqstd-abrupt` is
   `negative:phase:runtime,type:TypeError`; once the TypeError propagates
   uncaught, `thrown_type_matches` scores PASS. No harness change needed.

**Phase 1 exit check:**
```
echo "$(pwd)/test262/test/language/module-code/eval-rqstd-abrupt.js" \
  | out/batch_test_vm --worker 2>/dev/null      # expect PASS
```
Then re-run the whole `language/module-code`, `language/import`,
`language/export` dirs and record pass-equiv before/after. Watch for
regressions in the negative-parse early-error tests (the 85 that flipped
pass→fail when module routing landed — those need Phase 3, not Phase 1).

### Phase 2 — Top-level await (Tier 2)

**Status: 3 of 4 targets pass — commits `8247079` + `d6d4140` (2026-07-12).**
Pass: `module-import-rejection`, `module-import-rejection-body`,
`module-import-rejection-tick`. How it works now:
- `compile_module` sets `ctx.is_async = true`, so top-level `await` emits
  AWAIT/LOAD_RESUME (previously a module `await` was a COMPILE_ERROR).
- `Vm.execute_module_async` (new, in vm_execute.c3) allocates the module's
  evaluation Promise, runs the body as an ACT_FLAG_ASYNC activation, drives the
  microtask queue until it settles; a REJECTED promise → reason in
  `heap.error_value` → `execute_module` returns false → runtime-throw verdict.
- Fixed a latent VM crash: the dispatch restart loop indexed
  `vm.activations[-1]` when a top-level async frame unwound to count 0 (only
  reachable once modules became top-level async bodies). Now halts at count 0.
- **Promise-chain-rejection fix (`d6d4140`)** — got `-tick` to pass. A `.then`
  fulfillment handler that returned a native Promise (e.g. `Promise.reject(e)`)
  was FULFILLING the downstream with the promise object instead of ADOPTING its
  state (`promise_coerce_thenable` returns null for native promises, so
  `promise_microtask_after` fell through to settle-fulfilled). Added
  `promise_adopt_native`. This was a pre-existing bug independent of modules;
  verified no regressions across 361 built-ins/Promise tests.

**FOLLOWUP PASS (2026-07-13, later): review + fix cluster.** After the review
below, five pre-existing/adjacent bugs were fixed via parallel agents, each
independently regression-verified before merge:
- **Promise chains never settled for non-thenable handler results.**
  `promise_coerce_thenable` signals "not a thenable" with a *null return*, not
  a fault, but `promise_microtask_after` distinguished the cases with
  `if (catch)` — dead code — so every non-thenable `.then` result (undefined,
  numbers, strings, objects) left the derived promise pending. Fixed to check
  `!= null`. built-ins/Promise 432→557 PASS; dynamic-import 188→286.
- **Module namespace is now a proper exotic object**: null [[Prototype]],
  exports {w,e,¬c} (`PROP_FLAGS_NEC`), `ns[@@toStringTag]="Module"` {¬w,¬e,¬c}.
  namespace subdir 28→42 PASS. (Own-key order deferred — needs prop-table work.)
- **`import(x)` is not a SimpleAssignmentTarget**: `import('')++`, `= v`, etc.
  now early-SyntaxError (shares the call-expression reject path; also fixed a
  latent `binary_expr` bug that dropped `last_was_local_var`). 0 PASS
  regressions across 2100+ assignment/update tests; 50 FAIL→CE.
- **`import(spec, options)` 2nd arg** parsed (evaluated+ignored; full attribute
  semantics deferred). NOTE: import-attributes + import-defer are in the
  run_test262.py skip regex (Stage-3), so these are correctness wins, not
  official scored gains.
Net after followups: dynamic-import ~286+ PASS (from 50 pre-feature), module
dirs 226→237, zero crashes/timeouts.

**DONE (2026-07-13): all 4 targets PASS.** Dynamic `import()` landed:
`DYN_IMPORT` opcode (A=result, B=specifier) + `esm::dynamic_import`
(resolve → link → evaluate → settle a promise with the namespace object or
the real evaluation error) + `Vm.execute_module_nested` — the re-entrancy
piece the paragraph below called for: full activation/valstack snapshot &
restore mirroring `vm_call_fn_impl`, module frame placed at valstack_top
above all live registers, async promise drive loop. `vm.run_depth > 0`
routes `execute_module` through it. Self/cyclic import: `link_module`
early-outs on EVALUATING (re-linking replaced the live env → SIGSEGV) and
the EVALUATING cycle guard yields the in-progress namespace. Statement-level
`import(...)` is routed to expression_statement (the statement dispatch
consumed it as an import declaration). Relative specifiers resolve against
the compiled function's filename (stamped in resolve_module), falling back
to heap.current_module_name (set around body execution; the worker also
sets it to the test path for script tests). Whole-dir sweep of
`language/expressions/dynamic-import` vs pre-feature baseline:
50 → 125+ PASS, zero crashes/timeouts (an intermediate landing had 2
SIGSEGVs + 6 hangs; all fixed — the hangs were a pre-existing compiler bug
where hoisting/function_expr/arrows conflated "this declaration is async"
with the enclosing body's is_async, so an async fn containing any nested
function lost its promise and an awaited rejection looped the frame
forever). Remaining FAILs in the dir are dominated by a PRE-EXISTING
promise-chain bug (`Promise.resolve(7).then(h).then($DONE)` never settles
the second promise when h returns undefined — reproduced on the old
baseline) — that is the highest-value follow-up, plus module early errors
(Phase 3) and `import.meta`.

Original notes:
**One remains — `await-dynamic-import-rejection`:** needs a real `import(...)`.
Currently a `LDUNDEF` stub in `primary_expr` (expressions.c3 ~line 2379).
An attempt in this session got all 4 targets green but was REVERTED because it
introduced SIGSEGV/SIGABRT/hangs on edge cases (self dynamic-import,
namespace-manipulation tests that were FAIL-but-stable before). Root cause: the
module execution entry (`execute_in_env`/`execute_module_async`) owns
`vm.activations[0]`, but `import()` is invoked from *within* a running module
body — nested evaluation clobbers the caller's frame. A snapshot/restore of the
activation stack (mirroring `vm_call_fn_impl`) handled the simple cases but not
re-entering an already-EVALUATING module. **A correct implementation needs
proper VM re-entrancy** (run the nested module at `activations[activation_count]`
with full state save/restore, and treat a cyclic/self import by exposing the
in-progress module's namespace without re-running it). New opcode + heap
`dynamic_import_fn` bridge + `heap.current_module_name` base were the right
shape; the re-entrancy is the hard part. Do NOT ship until it is crash-free on
`language/expressions/dynamic-import/**`.

Original notes on the subsystem (still accurate):

1. **Module evaluation returns a promise.** Per spec, `Evaluate()` on a module
   returns a Promise; a module with TLA (or an async dependency) evaluates
   asynchronously. A rejected dependency promise rejects the importer's
   evaluation.
2. **Reuse async-function infra where possible.** `Opcode.AWAIT`,
   `act.async_promise`, the microtask queue, and `hp.drain_microtasks(vm)`
   already exist for async functions. A TLA module body is compiled much like
   an async function body; `execute_module` for such a module must:
   - run the body as a resumable/async activation,
   - register continuations so that when an awaited promise settles the body
     resumes,
   - on rejection, propagate the rejection value as the module's evaluation
     error.
3. **The worker already drains microtasks** after execution
   (`hp.drain_microtasks(v)` in `run_one_test`), so a TLA module that rejects
   during the drain should surface `heap.error_value` = the rejection reason.
   Confirm the drain runs for the module path too (the RUNTIME-negative branch
   returns before the existing drain — this ordering must be revisited so TLA
   modules get their microtasks drained *before* the verdict is read).
4. **`module-import-rejection-tick.js`** distinguishes `RangeError` vs
   `TypeError` by tick ordering — it validates the *order* of rejection
   settlement. This is the strictest correctness bar; do it last.
5. **`await-dynamic-import-rejection.js`** additionally needs `import(...)`
   dynamic-import returning a promise that rejects. Check whether the `IMPORT`
   opcode (currently emits `LDUNDEF`, per `primary_expr`) needs real
   implementation, or scope it out as a follow-up.

**Phase 2 exit check:**
```
for t in module-import-rejection module-import-rejection-body \
         module-import-rejection-tick await-dynamic-import-rejection; do
  echo "$(pwd)/test262/test/language/module-code/top-level-await/$t.js" \
    | out/batch_test_vm --worker 2>/dev/null
done      # expect PASS for as many as the phase covers; document any deferred
```

### Phase 3 (optional / follow-up) — module early-errors

Separate from resolution: the ~85 negative-parse module tests
(`early-dup-export-*`, escaped-keyword specifiers, `export` in nested position)
need the **parser** to detect module early errors. Currently `compile_module`
accepts them, so they compile clean and then FAIL. Not required for resolution;
track as its own effort. (Before module routing, these were *accidental* passes
because script-mode rejected all import/export — routing correctly removed that
cover.)

---

## Risks & constraints

- **Do not touch the harness scoring** to make these pass. The negative-test
  contract (throw + matching constructor name + phase) is now correct; the
  engine must produce the real errors.
- **GC roots:** module envs and namespace objects must stay rooted across
  evaluations (`execute_module` already registers `mod.env.bindings` as a GC
  root; any new long-lived module state needs the same — see memory
  `gc-root-before-next-alloc`).
- **Heap.reset between tests:** the worker resets the heap per test. Module
  cache (`module_cache`) is freed in `Heap.reset` via `free_module_cache`
  (see `check_heap_reset_drift.py` allowlist). Confirm a module-loading test
  leaves no stale `ModuleDef*` that a later test could reuse — run the
  contamination check: `just test262-contamination` on the module phase.
- **Phase 1 is high-value and self-contained**; Phase 2 (TLA) is a genuine
  subsystem and may itself want to be split. Prefer landing Phase 1 alone.

## Verification (all phases)

- Per-test: `echo "<abs path>" | out/batch_test_vm --worker`.
- Whole dirs: run `language/module-code`, `language/import`, `language/export`,
  `language/module-code/top-level-await` through the worker and diff pass-equiv
  before/after (use `scripts/run_test262.py` categorize_ce for the CE split).
- No regressions in non-module phases (rebuild both binaries — see memory
  `rebuild-both-binaries` — and spot-check a couple of ordinary tests).
- `just check-heap-drift` still green.

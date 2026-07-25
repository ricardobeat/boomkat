# Progress: Duktape C3 — test262 Conformance Tracker

**Last Updated:** Session 299 — **41,830 pass / 0 fail / 0 CE** (7,406 skipped). Cleared the remaining backlog: large-string registry backstop (recovering the leak-fix perf cost and exposing a call-callee use-after-free), a GC temproot invariant break affecting every builtin that re-enters the VM, a lexer scratch-buffer borrow corrupting escaped declaration names across params/classes/modules, the bare-`var` inline-cache clobber, and six spec fixes.

**Target:** 100% test262 pass rate on the targeted subset (see plan 040).

## Test Infrastructure

- **Full suite / single phase**: `python3 scripts/run_test262.py [--phase N] --workers 4` (~6-8 min full, <1 min per phase). MEMKILL cap 2 GB RSS.
- **Per-test results**: add `--log out/test262_results.tsv`; cluster with `awk -F'\t' '$1=="FAIL"{print $2}' … | xargs -n1 dirname | sort | uniq -c | sort -rn`.
- **Single-test repro**: `python3 scripts/run_test262.py --single <path>` (warns if the suite skips the test; `--debug`/`--keep` concat harness for `just lldb` / `--trace-vm`).
- **Phase counts**: `bash scripts/count_test262_by_phase.sh` · **Delta**: `bash scripts/test262_delta.sh`.
- **Build**: `c3c build test262_runner` or `c3c build duktape_c3` (plain runner; `duktape_c3_debug` for `-c`/`-t` inspection).

## Session 299 (2026-07-24)

Nine-agent fleet over the remaining backlog. **41,781 → 41,830 pass, 2 → 0 fail.** Three agents' framings turned out to be wrong in instructive ways.

- **Large-string registry backstop** (faa59dd2 + 37252db2) — `HString.registry_slot` reuses the dead `next` field (header stays 24B); Heap holds a swap-with-last array of >256B strings, swept in phase 3b under `string_sweep_safe`, drained in reset()/destroy(). With a collector that can find these strings, the bb6c01e hot-path decrefs came back out: function_call 335→318ms, loop 278→233, recursion 284→239, arithmetic 641→517. Leaks hold at 15/880B; 100k abandoned large strings peak at 13.7MB RSS. The agent's own near-miss is worth recording: it first stored the slot in `hash`, which `equals_hstring` uses as a fast-reject *specifically* for non-interned strings — silently breaking `===` on large strings until phase 0 caught it.
- **The decref revert fixed a real crash** (37252db2) — the last full-suite failure, `FinalizationRegistry/.../unregister-symbol-token.js`, segfaulted deterministically on main and *predated* the whole session (reproduced on e53cb15). Bisecting the day's commits put the fix squarely on the decref revert: `resolve_call_var`/`resolve_call_global` had been releasing the callee register while it was still the borrowed callee slot in flight for the fused CALL path. So bb6c01e's "owned-register discipline" was too strong a claim — that slot is a borrow — and what read as a 3-7% perf tax was also a latent use-after-free.
- **GC temproots vs. native frames** (e87df06f) — `mark_and_sweep(safepoint)` cleared every temproot because "at a safepoint nothing is in flight." False whenever a builtin allocates a result and re-enters the VM holding it only in a raw C3 local: `Array.prototype.map`'s result array was swept mid-loop and the next write hit a recycled header. Fixed with a `native_frame_depth` counter at the `dispatch_builtin` chokepoint. Verified by bisection under an aggressive all-sizes GC trigger — both target tests fail without it, pass 3/3 with it. Not map-specific and not batch-only, contrary to the original repro recipe.
- **Spec fixes** — accessor frames never assigned `new_target`, so a getter reached via `super.x` inherited the enclosing constructor's (107fe880). Strict `delete ta[i]` computed the failure but never threw, and missed string keys entirely (82546d30, +8). `includes()` short-circuited on detach instead of matching undefined, and `[[Set]]` skipped ToNumber on non-arridx canonical indices (0d5c8697, +4). Global function declarations shared DECLVAR with `var`, so redeclaring over a non-configurable global flipped `configurable` back to true — new DECLGLOBALFUNC opcode, kept off the VarIC (06aee563, phase 7 +6).
- **The toString "escape" bug was a stale borrow** (ee740c2d) — `hoist_decls` captured the decl name as a borrow into the lexer's shared `ident_buf`, which `compile_inner_function` then overwrote by re-lexing the body. A top-level `function a(bcd){...}` created a global named after the last identifier scanned *inside* the body. Interning the name at capture fixes it. The escaped name is still decoded in toString output; the test only passes because its harness accepts either form, so verbatim-name preservation is still unimplemented and untested.
- **Skip-list re-tier needed correction** (1784700b + 57ccfad7) — the agent reported an empty token diff while actually adding five tokens, two of them (`Atomics.pause`, `regexp-duplicate-named-groups`) for features we implemented and ship passing. Its `logical-assignment` → `logical-assignment-operators` "typo fix" would have started skipping 8 passing tests; logical assignment is implemented, so the dead misspelling was load-bearing and the token is now gone. Verified by a machine-checked token-set diff against pre-re-tier main.
- **Escaped identifiers corrupted declaration names** (7d9cba20) — the lexer decodes escaped identifiers into one shared `ident_buf` and returns a borrow; declaration sites stored that borrow into `scope_stack`, class `methods[]`, and module tables, so any later identifier scan in the same function/class/module silently corrupted the earlier name. `function f(\u{62}, \u{63}){ return b + c; }` threw `'b' is not defined` (qjs: 3). Fixed by interning at capture across params, declarators, loop heads, function/class names, method names, and every import/export form. Wider than the repro: class methods and module imports were broken too, both confirmed pre-fix and now matching qjs.
- **Bare-`var` inline-cache clobber, and the regression fixing it caused** (8654b5f → 3ea265c) — `DECLVAR`'s VarIC wrote unconditionally, so a hoist stub in a loop body overwrote a live global with undefined on the second iteration (`var x=5; for(...){var x;}` gave undefined; qjs 5). Pre-existing. The first fix tested the runtime value for undefined, which broke `for (var v of [1,2,3,,5])` — a hole legitimately declares undefined and must store it (phase 14 −3, caught by the full suite). Corrected with a `DECLVAR_HOIST` opcode: the initializer-less case is static, not a property of the value. An investigating agent had declared this unreachable; its env-pooling analysis was right but its "never inside a loop" premise was not.
- Gates: full suite 41,830/0/0, golden 10/10, rosetta 100/100, benches at or better than baseline.
- **Batch-runner leak, mostly still open** (75bf5ce5) — Symbols belonged to no owning list, and ~39 sites inserted into the string table without taking ownership. Fixed, and coordinator-measured at 33.54 → 32.37 KB/cycle over 1000 cycles: real, but ~3.5% of the problem. The remaining ~31.8 KB/cycle is *not* in `reset()` — every heap-owned allocator is provably balanced while the malloc zone still grows, and it scales at roughly one leaked byte per byte of JS source compiled and executed. Details and tooling caveats in BACKLOG.

## Session 298 (2026-07-24)

- **Large-string leak plugged** (bb6c01e): owned-register discipline at every raw register write, `free_catcher_chain` at frame-pop (return-from-try leaked a Catcher per frame), large-alloc GC-trigger burn. leak1.js: 2015 leaks/12.3MB → 15/880B. Phases 0+5 zero-fail; golden/rosetta clean; recursion/function_call/loop pay 3-7% (registry-backstop follow-up queued).
- **GC roots hardened** (752b609): error_value/yield_value/resume_gen/gen_initial_gs marked defensively.
- **Backlog closures from agent audits**: `&slice[0]` audit (190 hits, zero fixable), `[...arguments]` re-entrant path (stale — unified by cfb713e on 07-18), L2 direct-eval hoisting (invalid for a strict-only engine; phase 7 598/0), F2 builtin-accessor toString (already conformant, 8-probe matrix matches qjs). New split-off items: indirect-eval global definability (6 skip-listed tests), user-function toString `\uXXXX` escapes, latent GC-cadence bug in Array.prototype.map.
- **I2 landed** (e3f324e): $262.detachArrayBuffer consolidated onto shared `arraybuffer_detach()`; skip token removed → phase 22: 3170→3290/0. Three latent TypedArray gaps split out (strict delete, includes-after-detach, [[Set]] OrdinaryGet).
- **E1 landed** (009ffe3): `eval("super()")` in derived ctors + nested-eval `new.target`; phase 15 5794/0 (+2).
- **C7a landed** (ff90372): private-name table shared across borrowing contexts (by-value adoption dangled the buffer on growth; field-init entry-pointer UAF); 120-field and nested-70-field repros verified.
- All landings coordinator-verified: phases 0/5/7/15/22 zero-fail, golden 10/10, rosetta 100/100.

## Current Session

- ASI over-acceptance fixed in `src/compiler/class.c3` and `src/compiler/statements.c3`.
- Async-generator identity now propagates into destructuring default-expression thunks, allowing `yield <operand>` in for-await array and object patterns.
- Array, Map, and Set iterators own their collection targets until exhaustion or teardown, keeping deferred iteration safe across `.call().then()` chains.
- Regression tests: `test/test_asi_overacceptance.js`, `test/test_for_await_yield_operand.js`, `test/test_iterator_target_lifetime.js`.
- Validation: focused tests pass; Rosetta 100/100.

## Remaining Clusters

Open engineering work remains tracked in `BACKLOG.md`, including GC-root hardening, the re-entrant arguments iterator path, direct-eval scope semantics, eval/super residuals, and builtin accessor `Function.prototype.toString` formatting.

# Progress: Duktape C3 — test262 Conformance Tracker

**Last Updated:** Session 297 — **41,655 pass / 0 fail / 0 CE** (7,581 skipped). Fixed ASI over-acceptance, for-await destructuring `yield <operand>`, and iterator target lifetime across deferred consumers. Focused regressions and Rosetta pass.

**Target:** 100% test262 pass rate on the targeted subset (see plan 040).

## Test Infrastructure

- **Full suite / single phase**: `python3 scripts/run_test262.py [--phase N] --workers 4` (~6-8 min full, <1 min per phase). MEMKILL cap 2 GB RSS.
- **Per-test results**: add `--log out/test262_results.tsv`; cluster with `awk -F'\t' '$1=="FAIL"{print $2}' … | xargs -n1 dirname | sort | uniq -c | sort -rn`.
- **Single-test repro**: `python3 scripts/run_test262.py --single <path>` (warns if the suite skips the test; `--debug`/`--keep` concat harness for `just lldb` / `--trace-vm`).
- **Phase counts**: `bash scripts/count_test262_by_phase.sh` · **Delta**: `bash scripts/test262_delta.sh`.
- **Build**: `c3c build test262_runner` or `c3c build duktape_c3` (plain runner; `duktape_c3_debug` for `-c`/`-t` inspection).

## Session 298 (2026-07-24)

- **Large-string leak plugged** (bb6c01e): owned-register discipline at every raw register write, `free_catcher_chain` at frame-pop (return-from-try leaked a Catcher per frame), large-alloc GC-trigger burn. leak1.js: 2015 leaks/12.3MB → 15/880B. Phases 0+5 zero-fail; golden/rosetta clean; recursion/function_call/loop pay 3-7% (registry-backstop follow-up queued).
- **GC roots hardened** (752b609): error_value/yield_value/resume_gen/gen_initial_gs marked defensively.
- **Backlog closures from agent audits**: `&slice[0]` audit (190 hits, zero fixable), `[...arguments]` re-entrant path (stale — unified by cfb713e on 07-18), L2 direct-eval hoisting (invalid for a strict-only engine; phase 7 598/0), F2 builtin-accessor toString (already conformant, 8-probe matrix matches qjs). New split-off items: indirect-eval global definability (6 skip-listed tests), user-function toString `\uXXXX` escapes, latent GC-cadence bug in Array.prototype.map.

## Current Session

- ASI over-acceptance fixed in `src/compiler/class.c3` and `src/compiler/statements.c3`.
- Async-generator identity now propagates into destructuring default-expression thunks, allowing `yield <operand>` in for-await array and object patterns.
- Array, Map, and Set iterators own their collection targets until exhaustion or teardown, keeping deferred iteration safe across `.call().then()` chains.
- Regression tests: `test/test_asi_overacceptance.js`, `test/test_for_await_yield_operand.js`, `test/test_iterator_target_lifetime.js`.
- Validation: focused tests pass; Rosetta 100/100.

## Remaining Clusters

Open engineering work remains tracked in `BACKLOG.md`, including GC-root hardening, the re-entrant arguments iterator path, direct-eval scope semantics, eval/super residuals, and builtin accessor `Function.prototype.toString` formatting.

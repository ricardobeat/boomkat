# Plans Index

| Plan | Status | Notes |
|------|--------|-------|
| [001-architecture-improvements.md](001-architecture-improvements.md) | ✅ DONE | NaN-boxing implemented and default |
| [002-tval-inlining.md](002-tval-inlining.md) | ✅ DONE | TVal methods converted from `@inline fn` to `macro` |
| [003-hotpath-optimization.md](003-hotpath-optimization.md) | ✅ DONE | CALL/RET three fixes applied |
| [004-codebase-review.md](004-codebase-review.md) | ✅ DONE | Review completed; findings actioned across later plans |
| [005-libc-memory-removal.md](005-libc-memory-removal.md) | ✅ DONE | Zero direct `libc::malloc` call sites remain; all allocation routes through the Heap allocator |
| [006-tech-debt.md](006-tech-debt.md) | ✅ DONE | All 4 items: buffer constants, CallableKind, PropLookupResult, `is_prototype_of` |
| [007-vm-dispatch-optimization.md](007-vm-dispatch-optimization.md) | ✅ DONE | Debug printf removed; threaded dispatch deferred/superseded |
| [008-ic-crash-gc-roots.md](008-ic-crash-gc-roots.md) | ✅ DONE | IC crash fixes, GC root marking, iterator support all applied |
| [009-hobject-subtype-split.md](009-hobject-subtype-split.md) | ✅ DONE | `HObjectExtra` tagged union exists; derived pointers are methods |
| [010-VM-GC-issues.md](010-VM-GC-issues.md) | ✅ DONE | Bug 1 (IC base) + Bug 2 (delete_prop) fixed; Bug 3 resolved by refcounting |
| [011-memory-optimization.md](011-memory-optimization.md) | 🔶 STALLED | Superseded by plans 029–033; kept for historical context |
| [012-speed-optimization.md](012-speed-optimization.md) | ✅ DONE | All items completed across Sessions 114–123 |
| [013-speed-optimization-2.md](013-speed-optimization-2.md) | ✅ DONE | All items done: RC, RET restart, valstack_top cache |
| [014-test262-review.md](014-test262-review.md) | ✅ DONE | Status snapshot; remaining gaps tracked in progress.md |
| [018-rebase-rc-on-delta-shapes.md](018-rebase-rc-on-delta-shapes.md) | ✅ DONE | String RC rebased on delta shapes (Session 146) |
| [019-shape-optimize-bench.md](019-shape-optimize-bench.md) | ✅ DONE | bench_shape 73×→0.8× (Session 147) |
| [020-fable-review.md](020-fable-review.md) | ✅ DONE | All 8 items complete per plan 021 status table |
| [021-struct-cleanup.md](021-struct-cleanup.md) | ✅ DONE | Items B (CallableKind→accessor) & C (PropHashInfo side struct) complete |
| [022-property-descriptor-correctness.md](022-property-descriptor-correctness.md) | ✅ DONE | Remaining work folded into plan 047 (landed); all ES5 §8.12.9 descriptor paths correct |
| [024-fused-opcodes.md](024-fused-opcodes.md) | ✅ DONE | GETPROPC + compare-and-branch fused opcodes; peephole passes; rotated loops (Session 148–149) |
| 025-callback-error-propagation | ✅ DONE | vm_call_fn_impl Case 3 fix; arr_call_callback error handling; find/findIndex native builtins; print toString (Session 149) |
| [023-missing-prototype-methods.md](023-missing-prototype-methods.md) | ✅ DONE | Date.toDateString/toTimeString, String.replaceAll/matchAll/normalize, Array.find/findIndex thisArg all present; no missing ES5/ES6 prototype methods remain |
| 027-declvar-ic | ✅ DONE | DECLVAR inline cache: skip find_prop_idx on repeat calls (Session 150) |
| 028-test262-conformance | ✅ DONE | arr_throw_type_error propagation; sloppy-mode PUTPROP; Array.prototype metadata; Object.seal/freeze non-objects; global `this` (Session 151) |
| [029-memory-low-hanging-fruit.md](029-memory-low-hanging-fruit.md) | 🔶 PARTIAL | Items 1, 3, 4 done. Items 2 (default proto), 5 (sparse IC) remain; see plan 033 |
| [030-memory-profiling.md](030-memory-profiling.md) | ✅ DONE | Inline props, unified prop_alloc, and FixedBlockPool object pools implemented. Boxed accessor pairs deferred to plan 033 |
| [031-string-intern-bloat.md](031-string-intern-bloat.md) | ✅ DONE | Skip-interning for ADD concat + lazy intern in get_prop_key; memory 15,776→6,688 KB. Fix 2 (GC in alloc_no_gc) retracted post-completion — caused double-frees and the ~1s shape bench regression |
| [032-gc-safepoints.md](032-gc-safepoints.md) | ✅ DONE | `gc_pending`, `safepoint_gc()`, and `temproot` protection implemented in heap.c3/vm.c3 |
| [033-memory-next-steps.md](033-memory-next-steps.md) | 🔄 IN PROGRESS | GC on backward jumps (item 2) done; boxed accessor pairs (item 1) done. Remaining: default-prototype elision |
| [034-async-await.md](034-async-await.md) | ✅ DONE | Async/await implemented via resumable execution on the generator save/restore path (see AGENTS.md invariants). Async generators (`async function*`) remain out of scope (B35 skip) |
| [035-enforce-strict-mode.md](035-enforce-strict-mode.md) | ✅ DONE | Engine is strict-only, single mode; no `is_strict` flag remains (see AGENTS.md "Strict-Only Mode") |
| [036-vm-split.md](036-vm-split.md) | ✅ DONE | vm.c3 split into `src/vm/` (vm_execute, vm_calls, vm_objects, vm_property, vm_arith, …) |
| [037-esm-modules.md](037-esm-modules.md) | ✅ DONE | `boomkat -m/--module` runs ESM via `esm::resolve_module`; `test/mod_*.js` exercise it |
| [038-numeric-separators-bigint.md](038-numeric-separators-bigint.md) | 🔶 PARTIAL | Numeric separators lex (covered by `test/test_dtoa_edges.js`); BigInt deferred (skip-listed) |
| [039-binary-size-dedup.md](039-binary-size-dedup.md) | 🔄 IN PROGRESS | Binary 1.23MB→1.12MB via build flags (082f193); Phase 1: dead code removal + disassembler gate; Phase 2: Map/Set/WeakMap/WeakSet dedup, error-throw helper done (8d5d034), compiler/VM dedup remaining |
| [040-test262-100-percent.md](040-test262-100-percent.md) | ✅ DONE | **Target reached**: full-suite run 2026-08-16 = 49,814 pass / 0 fail / 0 CE / 3,010 skipped (100% of the targeted subset, roadmap from session-250 baseline 71.8%) |
| [041-array-set-elem-retirement.md](041-array-set-elem-retirement.md) | ✅ DONE | Hidden-dense-write hazard retired; oracle `test/test_041_array_like_gaps.js` at 12/12 |
| [042-call-callee-register-overlay.md](042-call-callee-register-overlay.md) | 📝 DOCUMENTED | CALL overlays the callee frame onto the caller's register array at `callee_reg+2`, clobbering caller-owned live state (surfaced in destructuring rest loops). Compiler workaround in place (low-register pre-allocation); proper fix planned in [043-call-frame-isolation.md](043-call-frame-isolation.md) |
| [043-call-frame-isolation.md](043-call-frame-isolation.md) | ✅ IMPLEMENTED | Systematic fix for the plan-042 overlay: `reserve_call_frame` centralizes the sliding-window CALL danger-zone reservation (replaced all 8 open-coded `next_reg` bumps; corrected two `Object.assign` sites to reserve both arg slots), `alloc_persistent_reg` documents loop-carried state. Compiler-only, VM untouched. Oracle: `test/test_call_frame_overlay.js`. `emit_call` skipped (no fusible site); COMPILE_VERIFY deferred to the SSA-IR milestone |
| [044-statement-destructure-iterator.md](044-statement-destructure-iterator.md) | ✅ IMPLEMENTED | Statement-level array destructuring (`var/let/const [h, ...t] = x` and assignment form) rerouted through the shared iterator-protocol emitter `emit_destruct_bindings` with a new `DestructStoreMode` (declare vs param-sync vs assign); legacy index/`.slice()` emitters deleted. Oracle: `test/test_statement_destructure_iter.js` |
| [045-capture-analysis.md](045-capture-analysis.md) | ✅ IMPLEMENTED (Phase A) | Captured locals must be env-resident: closure/eval writes are invisible to the outer function's register reads (and vice versa). Token pre-scan marks captured names `is_captured` before body compile; per-iteration `for(let…)` bindings tracked as sub-item |
| [046-architecture-review.md](046-architecture-review.md) | 📋 ROADMAP | Session-267 architecture & code review: findings register (correctness + size audits), 81.6% test262 baseline, prioritized waves toward QuickJS parity (destructuring consolidation = conformance + 40–70 KB, VM error-throw dedup, string-model decision before RegExp Unicode) |
| [047-descriptor-validation-matrix.md](047-descriptor-validation-matrix.md) | ✅ DONE | B49 wave landed: ToPropertyDescriptor + ValidateAndApplyPropertyDescriptor helpers routed through defineProperty/defineProperties/create; plan 022 remainder folded in |
| [049-arraybuffer-typedarray-dataview.md](049-arraybuffer-typedarray-dataview.md) | ✅ DONE | ArrayBuffer + 9 TypedArrays + DataView landed with test262 phase 22; green in the 2026-08-16 full-suite run |
| [050-proxy.md](050-proxy.md) | ✅ DONE | Proxy + Reflect landed with test262 phase 23 (13 essential-internal-method traps, invariant matrix); green in the 2026-08-16 full-suite run |
| [051-async-iteration.md](051-async-iteration.md) | ✅ DONE | ES2018 async iteration landed: `for await…of`, Symbol.asyncIterator, async-from-sync adapter, async generators (plan 060), `yield*` delegation; unskipped in the runner |
| [048-destructuring-completion.md](048-destructuring-completion.md) | ✅ DONE | Destructuring completion wave landed: NamedEvaluation defaults, non-identifier keys, IteratorClose, nullish-source TypeError, member/paren targets, for-in-head patterns |
| [068-multi-runtime.md](068-multi-runtime.md) | ✅ DONE | Multiple runtimes per process: `_active_heap` global deleted, `Heap*` threaded explicitly; verified by `test/capi/two_runtimes.c` + `compile_threads.c` |
| [053-module-resolution.md](053-module-resolution.md) | ✅ DONE | resolve→link→evaluate pipeline wired (`src/module.c3`); ResolveExport enforced at link time, async cycle roots, `export * as ns`; module test262 groups green |
| [059-function-context-capture.md](059-function-context-capture.md) | ✅ DONE | Phase 1 + residuals landed: obj-literal eval-super, eval `super()`, nested-eval new.target; P7 public fields route through [[DefineOwnProperty]] |
| [060-async-generators.md](060-async-generators.md) | ✅ DONE | `async function*` implemented (request queue, yield-awaits-operand, drain invariant per plan 063); `*async-gen*` globs unskipped, phases green |
| [061-engine-consolidation.md](061-engine-consolidation.md) | 🔄 IN PROGRESS | B1 arrow dup/restricted-name check fixed; C1/D1 done. Open: A-series generator/async unification, B1 full ParamListPlan (~600 lines), fastint arithmetic opcodes |
| [063-async-gen-drain-invariant.md](063-async-gen-drain-invariant.md) | ✅ DONE | GC root separated from re-entrancy guard; drain never stalls after rejected `throw()`; pinned by `test/test_async_gen_drain_reentry.js` |
| [068a-host-functions.md](068a-host-functions.md) | ✅ DONE | `jse_register_fn` + full host ABI (argc/arg/this/return/throw) in `src/capi.c3`; JS→host and host→JS both work; pinned by `test/capi/host_fn_abi.c` |
| [069-typescript-conformance.md](069-typescript-conformance.md) | ✅ DONE | TS conformance harness (`scripts/run_ts_conformance.py`, `just ts-conformance`) against the Microsoft corpus with tsc as oracle; ~189 parser gaps closed (overloads, namespaces, exports, templates, destructuring, labels); two JS bugs surfaced and fixed; full run 62 min to 43s; 0 failures |
| [073-runtime-typescript.md](073-runtime-typescript.md) | ✅ DONE | Runtime TS validation: handbook syntax corpus (`test/typescript/handbook/`, 43 files, node-captured reference output, part of test-local) + real-library sweep (`just ts-runtime`: microdiff, zustand, valtio byte-identical to node); 4 parser gaps closed (swallow ASI, keyof-object, export-type generics, inline type specifiers + exported overloads) |
| [038a-register-locals.md](038a-register-locals.md) | ✅ DONE | Register-resident locals optimization; validated by the ENV_STRICT oracle (`boomkat_envstrict` target + corpus). Known gap: captured-local coherence — see plan 045 |
| [026-rosetta-remaining-failures.md](026-rosetta-remaining-failures.md) | ✅ DONE | Rosetta suite at 100/100 since session 248 (B24–B30 closed) |
| [052-road-to-zero.md](052-road-to-zero.md) | ✅ DONE | Route to 0 test262 failures reached: full-suite run 2026-08-16 = 0 FAIL / 0 CE:unexpected across all phases (49,814 pass) |
| [074-embedding-c-api.md](074-embedding-c-api.md) | ✅ LANDED | C embedding API (QuickJS-referenced): interrupt handler + uncatchable abort, property access/enumeration, value/object/array construction, script-name + line/col error info, host-side call; bytecode serialisation and memory-limit deferrals sketched |
| [075-test262-harness-and-remaining-gaps.md](075-test262-harness-and-remaining-gaps.md) | 🔄 OPEN | Official `test262-harness`/eshost run (78.7%; ES core 94.7%): harness setup in the test262 fork, three measurement traps, ES-core gap decomposition (51% Stage 3, 26% sloppy, 23% real), four engine bugs with repros (TLA dependency segfault, private-name-in-field-initializer VM fault, `Object.isExtensible` on primitives, smaller clusters), and the feature tokens missing from `UNSUPPORTED_PATTERN` |
| [076-embedding-c-api-2.md](076-embedding-c-api-2.md) | 📝 PLANNED | Embedding API v2 (C3-side): typed-array handle, byte buffer access, opaque user-data on objects, slot-tagged persistence, ref-cycle break on dispose, ESM resolver hook |
| [077-cross-engine-failure-closure.md](077-cross-engine-failure-closure.md) | 📝 PLANNED | Cross-engine diff vs V8/SpiderMonkey/JavaScriptCore on shared fixtures, surfacing genuine engine bugs that the targeted test262 subset does not cover |
| [080-temporal.md](080-temporal.md) | 📝 PLANNED | `Temporal.*` (Stage 4, post-`Date`) — calendar arithmetic + IANA tzdb blob + Instant + ZonedDateTime + Duration, no ICU/CLDR; ~4,603 currently skipped test262 tests; phased plan with verification gates |

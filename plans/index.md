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
| [008-quicksort-refcount-fix.md](008-quicksort-refcount-fix.md) | ✅ DONE | Refcount underflow in sliding-window calls fixed (`be0410b`, merged as `6485f46`) |
| [009-hobject-subtype-split.md](009-hobject-subtype-split.md) | ✅ DONE | `HObjectExtra` tagged union exists; derived pointers are methods |
| [010-VM-GC-issues.md](010-VM-GC-issues.md) | ✅ DONE | Bug 1 (IC base) + Bug 2 (delete_prop) fixed; Bug 3 resolved by refcounting |
| [011-memory-optimization.md](011-memory-optimization.md) | ✅ DONE | Superseded by plans 029–033; kept for historical context |
| [012-speed-optimization.md](012-speed-optimization.md) | ✅ DONE | All items completed across Sessions 114–123 |
| [013-speed-optimization-2.md](013-speed-optimization-2.md) | ✅ DONE | All items done: RC, RET restart, valstack_top cache |
| [014-test262-review.md](014-test262-review.md) | ✅ DONE | Status snapshot; remaining gaps tracked in progress.md |
| [018-rebase-rc-on-delta-shapes.md](018-rebase-rc-on-delta-shapes.md) | ✅ DONE | String RC rebased on delta shapes (Session 146) |
| [019-shape-optimize-bench.md](019-shape-optimize-bench.md) | ✅ DONE | bench_shape 73×→0.8× (Session 147) |
| [020-fable-review.md](020-fable-review.md) | ✅ DONE | All 8 items complete per plan 021 status table |
| [021-struct-cleanup.md](021-struct-cleanup.md) | ✅ DONE | Items B (CallableKind→accessor) & C (PropHashInfo side struct) complete |
| [022-property-descriptor-correctness.md](022-property-descriptor-correctness.md) | ✅ DONE | Remaining work folded into plan 047 (landed); all ES5 §8.12.9 descriptor paths correct |
| [023-missing-prototype-methods.md](023-missing-prototype-methods.md) | ✅ DONE | Date.toDateString/toTimeString, String.replaceAll/matchAll/normalize, Array.find/findIndex thisArg all present; no missing ES5/ES6 prototype methods remain |
| [024-fused-opcodes.md](024-fused-opcodes.md) | ✅ DONE | GETPROPC + compare-and-branch fused opcodes; peephole passes; rotated loops (Session 148–149) |
| 025-callback-error-propagation | ✅ DONE | vm_call_fn_impl Case 3 fix; arr_call_callback error handling; find/findIndex native builtins; print toString (Session 149) |
| [025-remaining-014-gaps.md](025-remaining-014-gaps.md) | ✅ DONE | Plan 014 follow-ups (iterators, class features, Promise jobs, nested `call_fn` errors); covered by the zero-fail test262 gate |
| [026-rosetta-remaining-failures.md](026-rosetta-remaining-failures.md) | ✅ DONE | Rosetta suite at 100/100 since session 248 (B24–B30 closed) |
| 027-declvar-ic | ✅ DONE | DECLVAR inline cache: skip find_prop_idx on repeat calls (Session 150) |
| 028-test262-conformance | ✅ DONE | arr_throw_type_error propagation; sloppy-mode PUTPROP; Array.prototype metadata; Object.seal/freeze non-objects; global `this` (Session 151) |
| [029-memory-low-hanging-fruit.md](029-memory-low-hanging-fruit.md) | 🔶 PARTIAL | Items 1, 3, 4 done. Items 2 (default proto), 5 (sparse IC) remain; see plan 033 |
| [030-memory-profiling.md](030-memory-profiling.md) | ✅ DONE | Inline props, unified prop_alloc, and FixedBlockPool object pools implemented. Boxed accessor pairs deferred to plan 033 |
| [031-string-intern-bloat.md](031-string-intern-bloat.md) | ✅ DONE | Skip-interning for ADD concat + lazy intern in get_prop_key; memory 15,776→6,688 KB. Fix 2 (GC in alloc_no_gc) retracted post-completion — caused double-frees and the ~1s shape bench regression |
| [032-gc-safepoints.md](032-gc-safepoints.md) | ✅ DONE | `gc_pending`, `safepoint_gc()`, and `temproot` protection implemented in heap.c3/vm.c3 |
| [033-memory-next-steps.md](033-memory-next-steps.md) | 🔄 IN PROGRESS | GC on backward jumps (item 2) done; boxed accessor pairs (item 1) done. Remaining: default-prototype elision |
| [034-async-await.md](034-async-await.md) | ✅ DONE | Async/await implemented via resumable execution on the generator save/restore path (see AGENTS.md invariants). Async generators (`async function*`) remain out of scope (B35 skip) |
| [035-enforce-strict-mode.md](035-enforce-strict-mode.md) | ✅ DONE | Made the engine strict-only as a single mode, removing `is_strict`. Superseded by [083](083-sloppy-mode.md), which restored sloppy mode as a peer |
| [036-vm-split.md](036-vm-split.md) | ✅ DONE | vm.c3 split into `src/vm/` (vm_execute, vm_calls, vm_objects, vm_property, vm_arith, …) |
| [037-esm-modules.md](037-esm-modules.md) | ✅ DONE | `boomkat -m/--module` runs ESM via `esm::resolve_module`; `test/mod_*.js` exercise it |
| [038-numeric-separators-bigint.md](038-numeric-separators-bigint.md) | ✅ DONE | Numeric separators lex (covered by `test/test_dtoa_edges.js`); BigInt implemented under plan 056 |
| [038a-register-locals.md](038a-register-locals.md) | ✅ DONE | Register-resident locals optimization; validated by the ENV_STRICT oracle (`boomkat_envstrict` target + corpus). Known gap: captured-local coherence — see plan 045 |
| [039-binary-size-dedup.md](039-binary-size-dedup.md) | 🔄 IN PROGRESS | Binary 1.23MB→1.12MB via build flags (082f193); Phase 1: dead code removal + disassembler gate; Phase 2: Map/Set/WeakMap/WeakSet dedup, error-throw helper done (8d5d034), compiler/VM dedup remaining |
| [040-test262-100-percent.md](040-test262-100-percent.md) | ✅ DONE | **Target reached**: full-suite run 2026-08-16 = 49,814 pass / 0 fail / 0 CE / 3,010 skipped (100% of the targeted subset, roadmap from session-250 baseline 71.8%) |
| [041-array-set-elem-retirement.md](041-array-set-elem-retirement.md) | ✅ DONE | Hidden-dense-write hazard retired; oracle `test/test_041_array_like_gaps.js` at 12/12 |
| [041-jump-dispatch-report.md](041-jump-dispatch-report.md) | ✅ DONE | `@jump` dispatch experiment report, 2026-07-10 |
| [042-call-callee-register-overlay.md](042-call-callee-register-overlay.md) | ✅ DONE | CALL overlaid the callee frame onto the caller's register array at `callee_reg+2`; fixed systematically by [043-call-frame-isolation.md](043-call-frame-isolation.md) |
| [042-typescript-erasable-subset.md](042-typescript-erasable-subset.md) | ✅ DONE | Erasable TypeScript syntax stripped at parse time (`src/ast/parse_ts.c3`); conformance in plans 069 and 073 |
| [043-call-frame-isolation.md](043-call-frame-isolation.md) | ✅ DONE | Systematic fix for the plan-042 overlay: `reserve_call_frame` centralizes the sliding-window CALL danger-zone reservation (replaced all 8 open-coded `next_reg` bumps; corrected two `Object.assign` sites to reserve both arg slots), `alloc_persistent_reg` documents loop-carried state. Compiler-only, VM untouched. Oracle: `test/test_call_frame_overlay.js`; the `emit_call` wrapper was skipped as non-fusible and COMPILE_VERIFY deferred as an assertion-only check |
| [044-statement-destructure-iterator.md](044-statement-destructure-iterator.md) | ✅ DONE | Statement-level array destructuring (`var/let/const [h, ...t] = x` and assignment form) rerouted through the shared iterator-protocol emitter `emit_destruct_bindings` with the `DestructStoreMode` modes; legacy index/`.slice()` emitters deleted. Oracle: `test/test_statement_destructure_iter.js` |
| [045-capture-analysis.md](045-capture-analysis.md) | ✅ DONE | Captured locals must be env-resident: token pre-scan marks captured names `is_captured` before body compile, keeping closure/eval writes coherent with register reads; per-iteration `for(let…)` fresh bindings landed via 84077872 |
| [046-architecture-review.md](046-architecture-review.md) | 📋 ROADMAP | Session-267 architecture & code review: findings register (correctness + size audits), 81.6% test262 baseline, prioritized waves toward QuickJS parity (destructuring consolidation = conformance + 40–70 KB, VM error-throw dedup, string-model decision before RegExp Unicode) |
| [047-descriptor-validation-matrix.md](047-descriptor-validation-matrix.md) | ✅ DONE | B49 wave landed: ToPropertyDescriptor + ValidateAndApplyPropertyDescriptor helpers routed through defineProperty/defineProperties/create; plan 022 remainder folded in |
| [048-destructuring-completion.md](048-destructuring-completion.md) | ✅ DONE | Destructuring completion wave landed: NamedEvaluation defaults, non-identifier keys, IteratorClose, nullish-source TypeError, member/paren targets, for-in-head patterns |
| [049-arraybuffer-typedarray-dataview.md](049-arraybuffer-typedarray-dataview.md) | ✅ DONE | ArrayBuffer + 9 TypedArrays + DataView landed with test262 phase 22; green in the 2026-08-16 full-suite run |
| [050-proxy.md](050-proxy.md) | ✅ DONE | Proxy + Reflect landed with test262 phase 23 (13 essential-internal-method traps, invariant matrix); green in the 2026-08-16 full-suite run |
| [051-async-iteration.md](051-async-iteration.md) | ✅ DONE | ES2018 async iteration landed: `for await…of`, Symbol.asyncIterator, async-from-sync adapter, async generators (plan 060), `yield*` delegation; unskipped in the runner |
| [051-test262-parallel-batch.md](051-test262-parallel-batch.md) | ✅ DONE | Session-277 fix batch at 92.9%; superseded by the zero-fail work in plans 040 and 052 |
| [052-road-to-zero.md](052-road-to-zero.md) | ✅ DONE | Route to 0 test262 failures reached: full-suite run 2026-08-16 = 0 FAIL / 0 CE:unexpected across all phases (49,814 pass) |
| [053-module-resolution.md](053-module-resolution.md) | ✅ DONE | resolve→link→evaluate pipeline wired (`src/module.c3`); ResolveExport enforced at link time, async cycle roots, `export * as ns`; module test262 groups green |
| [054-private-class-fields.md](054-private-class-fields.md) | ✅ DONE | Private fields and methods implemented (`docs/engine-scope.md`) |
| [055-preexisting-bugs.md](055-preexisting-bugs.md) | ✅ DONE | Incidental bugs from the session-287/288 agents; open items pass the test262 gate, PB2, PB5, PB13 and PB14 rechecked 2026-11-03 |
| [056-bigint.md](056-bigint.md) | ✅ DONE | Arbitrary-precision BigInt on a 32-bit limb vector (`src/hbigint.c3`) |
| [057-for-await-async-iteration.md](057-for-await-async-iteration.md) | ✅ DONE | `for await` and async iteration; see also plan 051-async-iteration |
| [058-fusion-rule-framework.md](058-fusion-rule-framework.md) | ✅ DONE | Golden-bytecode suite and declarative rules for the superinstruction fusions; follow-ups listed in the plan |
| [059-function-context-capture.md](059-function-context-capture.md) | ✅ DONE | Phase 1 + residuals landed: obj-literal eval-super, eval `super()`, nested-eval new.target; P7 public fields route through [[DefineOwnProperty]] |
| [060-async-generators.md](060-async-generators.md) | ✅ DONE | `async function*` implemented (request queue, yield-awaits-operand, drain invariant per plan 063); `*async-gen*` globs unskipped, phases green |
| [061-engine-consolidation.md](061-engine-consolidation.md) | 🔄 IN PROGRESS | B1 arrow dup/restricted-name check fixed; C1/D1 done. Open: A-series generator/async unification, B1 full ParamListPlan (~600 lines), fastint arithmetic opcodes |
| [062-core-language-coverage.md](062-core-language-coverage.md) | ✅ DONE | Orphaned test262 tests brought into the gate; two-run zero-fail across all phases |
| [063-async-gen-drain-invariant.md](063-async-gen-drain-invariant.md) | ✅ DONE | GC root separated from re-entrancy guard; drain never stalls after rejected `throw()`; pinned by `test/test_async_gen_drain_reentry.js` |
| [064-await-yield-binding-early-errors.md](064-await-yield-binding-early-errors.md) | ✅ DONE | All six listed tests pass (2026-11-03) |
| [065-typeof-arguments.md](065-typeof-arguments.md) | ✅ DONE | Strict `typeof arguments` returns `"object"` (2026-11-03) |
| [066-escaped-identifier-over-rejection.md](066-escaped-identifier-over-rejection.md) | ✅ DONE | All four listed tests pass (2026-11-03) |
| [067-optional-console.md](067-optional-console.md) | ✅ DONE | `console` behind the `CONSOLE` feature: on in the CLI targets, off in the dylib and static library; no runtime opt-in call |
| [068-multi-runtime.md](068-multi-runtime.md) | ✅ DONE | Multiple runtimes per process: `_active_heap` global deleted, `Heap*` threaded explicitly; verified by `test/capi/two_runtimes.c` + `compile_threads.c` |
| [068a-host-functions.md](068a-host-functions.md) | ✅ DONE | `jse_register_fn` + full host ABI (argc/arg/this/return/throw) in `src/capi.c3`; JS→host and host→JS both work; pinned by `test/capi/host_fn_abi.c` |
| [069-typescript-conformance.md](069-typescript-conformance.md) | ✅ DONE | TS conformance harness (`scripts/run_ts_conformance.py`, `just ts-conformance`) against the Microsoft corpus with tsc as oracle; ~189 parser gaps closed (overloads, namespaces, exports, templates, destructuring, labels); two JS bugs surfaced and fixed; full run 62 min to 43s; 0 failures |
| [070-real-world-battle-testing.md](070-real-world-battle-testing.md) | ✅ DONE | Third-party production code: B1–B21 fixed, B12 withdrawn |
| [071-memory-usage.md](071-memory-usage.md) | ✅ DONE | M1 property hash threshold, M2 pooled small blocks, M3 string header and array growth; the remaining RSS gap is not profiled |
| [072-remaining-verification-issues.md](072-remaining-verification-issues.md) | ✅ DONE | Follow-ups to plan 070; fixes landed, remaining items closed as out of scope or not reproducing |
| [073-runtime-typescript.md](073-runtime-typescript.md) | ✅ DONE | Runtime TS validation: handbook syntax corpus (`test/typescript/handbook/`, 43 files, node-captured reference output, part of test-local) + real-library sweep (`just ts-runtime`: microdiff, zustand, valtio byte-identical to node); 4 parser gaps closed (swallow ASI, keyof-object, export-type generics, inline type specifiers + exported overloads) |
| [074-embedding-c-api.md](074-embedding-c-api.md) | ✅ DONE | C embedding API (QuickJS-referenced): interrupt handler + uncatchable abort, property access/enumeration, value/object/array construction, script-name + line/col error info, host-side call; bytecode serialisation, memory limit, BigInt/Symbol values and `error.stack` are tracked separately |
| [075-test262-harness-and-remaining-gaps.md](075-test262-harness-and-remaining-gaps.md) | ✅ DONE | Official harness run and ES-core gap analysis; C3 (TLA segfault), C4 (private name in eval) and C5 (`Object.isExtensible` on primitives) no longer reproduce (2026-11-03); `$262.agent` landed with plan 109 |
| [076-embedding-c-api-2.md](076-embedding-c-api-2.md) | 📝 PLANNED | Embedding API v2 (C3-side): typed-array handle, byte buffer access, opaque user-data on objects, slot-tagged persistence, ref-cycle break on dispose, ESM resolver hook |
| [077-cross-engine-failure-closure.md](077-cross-engine-failure-closure.md) | 📝 PLANNED | Cross-engine diff vs V8/SpiderMonkey/JavaScriptCore on shared fixtures, surfacing genuine engine bugs that the targeted test262 subset does not cover |
| [078-native-addons.md](078-native-addons.md) | ✅ DONE | Build-time feature gating and the add-on ABI (`include/boomkat_addon.h`, `src/addon.c3`) |
| [080-temporal.md](080-temporal.md) | ✅ DONE | `Temporal.*` behind the `TEMPORAL` feature (on in `boomkat-full-icu`); the methods the plan listed as missing exist (2026-11-03); Temporal test262 rate not rerun at close |
| [081-object-payload-sizing.md](081-object-payload-sizing.md) | 📝 PLANNED | Size `HObjectExtra` payloads per class instead of by the largest variant — every object is charged for the biggest member (an ARRAY needs 4 bytes and pays the full union); two mechanisms (right-size the allocation tail, externalise an outlier), measured RSS trade from the one attempt, per-class tables, and the pre-existing GC bug that blocks the Temporal half |
| [082-gc-pause-reduction.md](082-gc-pause-reduction.md) | ✅ DONE | GC pause reduction: epoch-based marking and slice-budgeted collection landed with the incremental collector (095); the dictionary thresholds landed as plan 119's object-model bullet |
| [083-sloppy-mode.md](083-sloppy-mode.md) | ✅ DONE | Sloppy mode restored as a peer to strict (`FuncFlags.is_strict`, `subst_global_this` removed): sloppy-only syntax, `with` envs + `@@unscopables`, implicit globals, mapped `arguments`, Annex B.3.1–B.3.9; full suite 48,329 pass / 174 fail (99.6%), `language`/`built-ins`/`annexB` at zero failures |
| [084-skip-and-staging-closure.md](084-skip-and-staging-closure.md) | ✅ DONE | All eight items: `staging/sm`, Promise executor throw, proper tail calls, immutable ArrayBuffer, Import Text/Bytes, `using`, `Promise.allKeyed`, iterator helpers second wave |
| [085-envrecord-reclamation.md](085-envrecord-reclamation.md) | ✅ DONE | Traced environment pool reclamation: exact roots, internal ENVREF values, weak variable caches, RC contracts, block release, pressure accounting, implementation and validation gates; [2025–2026 GC research](085a-gc-research-2025-2026.md) |
| [085a-gc-research-2025-2026.md](085a-gc-research-2025-2026.md) | ✅ DONE | Collector and allocator literature survey, January 2025 to September 2026 |
| [086-es6-vm-performance.md](086-es6-vm-performance.md) | 🔄 IN PROGRESS | Bytecode/VM performance review, measured optimization experiments, validation, and remaining compiler opportunities |
| [087-nonjit-vm-optimization-ideas.md](087-nonjit-vm-optimization-ideas.md) | 📝 PLANNED | Non-JIT research: bulk iteration, compact Promise reactions, shapes, superblocks, captures, and suspension liveness |
| [088-register-const-environments.md](088-register-const-environments.md) | ✅ DONE | Experiment record: register-only const bindings, 2026-09-20 |
| [089-architecture-experiments.md](089-architecture-experiments.md) | ✅ DONE | Experiment record; resolved bindings and binding-aware liveness continue in plan 090 |
| [090-resolved-bindings.md](090-resolved-bindings.md) | 🔶 PARTIAL | Binding identities and capture classification done; reference resolution and binding-aware liveness open |
| [091-object-layout-optimization.md](091-object-layout-optimization.md) | ✅ DONE | Class-specific object layouts and pools, implemented and measured |
| [092-compiler-fixed-limits-and-vm-soundness.md](092-compiler-fixed-limits-and-vm-soundness.md) | 📝 PLANNED | Open bugs from the fixed-size table audit: loop-head environments, nested control flow, stack guard, duplicate params, nested classes, name truncation, eval function lifetime; two VM soundness issues (refcounts, cross-script global slots) |
| [093-generational-gc.md](093-generational-gc.md) | ✅ DONE | Collector superseded by plans 095 and 096; the typed store boundaries remain |
| [094-string-ownership.md](094-string-ownership.md) | 🔄 IN PROGRESS | Explicit string ownership under reference counting; plan 119 milestone 2 decides whether counting stays |
| [095-incremental-gc-design.md](095-incremental-gc-design.md) | ✅ DONE | Cooperative incremental core implemented, validated and slice-budgeted; optional concurrency is out of scope, and page batching is carried as a suggestion in plan 119. Results in benchmarks/gc-cooperative-results.md |
| [096-bounded-nursery-review.md](096-bounded-nursery-review.md) | ✅ DONE | Shared bounded nursery with conservative auxiliary roots and promotion scans; 100k scene −7.1%, ES6 −7.6%, largest measured GC slice 0.502 ms; memory tradeoffs and validation in the linked report |
| [097-engine-throughput.md](097-engine-throughput.md) | ✅ DONE | Date formatting and fixed-shape literal improvements retained; register-frame compaction rejected after measurement |
| [098-measured-interpreter-optimizations.md](098-measured-interpreter-optimizations.md) | 🔧 PARTIAL | Only GC64 applied by user decision; other prototypes remain unapplied; deeper architecture investigation follows |
| [099-engine-architecture-investigation.md](099-engine-architecture-investigation.md) | 🔧 PARTIAL | String and generator register ownership, stable native-call frames, and compact arrays applied; native callback scaling removed, 100k scene −6% time and −17% RSS; generator storage, page metadata, and semantic IR remain research |
| [100-scope-index.md](100-scope-index.md) | ✅ DONE | One scope index per unit replaces the per-block, per-function token pre-scans; landed with the flat AST (plan 101) |
| [101-flat-ast.md](101-flat-ast.md) | ✅ DONE | Flat AST merged into `main` (94ac53aa): lexer prerequisites, tree parser, resolve in compare mode, scan replacement, leaf-first codegen |
| [102-ast-optimization-investigation.md](102-ast-optimization-investigation.md) | 📝 PLANNED | Ten researched optimization candidates after the flat AST: folding, binding/value analysis, loops, numeric specialization, inlining, direct parameter defaults, scalar replacement, suspension liveness and adaptive bytecode; independent measurement and size gates |
| [103-intl-data-compaction.md](103-intl-data-compaction.md) | 🚧 IN PROGRESS | Compact Intl data in place: metazones and tzdb indices for zone names, derivation flags and rank-bitmap exception columns, offset-only tables, word-token pools; parent-inheritance matrix for future locales; golden-dump and size gates |
| [104-optimization-plan.md](104-optimization-plan.md) | 📝 PLANNED | Non-JIT optimization plan; not started |
| [105-object-shapes-and-cache-economics.md](105-object-shapes-and-cache-economics.md) | 📝 RESEARCHED | Cache density and compact records, adaptive PICs, allocation layouts, validity tokens, shape graphs and guarded fusion; metadata census, ten tentative optimizations, literature notes and validation gates |
| [106-interpreter-gap-to-ignition.md](106-interpreter-gap-to-ignition.md) | 📝 RESEARCHED | Instruction-level gap to V8's interpreter; twelve mini baselines, per-operation instruction deltas, and the paths where the gap concentrates |
| [107-jit-hot-path-coverage.md](107-jit-hot-path-coverage.md) | ✅ DONE | Completed and consolidated into plan 113; plan 119 owns the unfinished JIT scope. |
| [108-jit-correctness-and-direction.md](108-jit-correctness-and-direction.md) | ✅ DONE | Completed and consolidated into plan 113 |
| [109-multi-agent-atomics.md](109-multi-agent-atomics.md) | ✅ DONE | Multi-agent `Atomics` and `$262.agent`; `built-ins/Atomics` 389/389 with no skips (2026-11-03) |
| [110-native-jit-pipeline.md](110-native-jit-pipeline.md) | ✅ DONE | Completed and consolidated into plan 113; plan 119 owns the unfinished JIT scope. |
| [111-jit-shared-workflows.md](111-jit-shared-workflows.md) | ✅ DONE | Completed and consolidated into plan 113; plan 119 owns the unfinished JIT scope. |
| [112-jit-buffer-and-continuation-workflows.md](112-jit-buffer-and-continuation-workflows.md) | ✅ DONE | Completed and consolidated into plan 113 |
| [113-fifty-thousand-octane.md](113-fifty-thousand-octane.md) | ✅ DONE | Closed 2026-11-03 at 6,400 full Octane, 50K not reached; superseded by plan 119 |
| [114-latin1-utf16-strings.md](114-latin1-utf16-strings.md) | 📝 PLANNED | Replace CESU-8 storage with Latin-1/UTF-16 fixed widths for O(1) indexing and no regexp transcode; symbol flag off the 0xFF prefix first; Latin-1, UTF-16, borrowed-view and external-string C API |
| [115-cpp-embedding-api.md](115-cpp-embedding-api.md) | 📝 PLANNED | Header-only C++17 `bk::` layer over the C ABI, designed against Godot, Unreal, Qt, CAD, DAW, browser and edge hosts; 24 C API changes, breaking where that gives a better API (scopes, host classes, atoms, finalizers, resource control, one callback style); survey bugs fixed |
| [116-loop-ssa-repair.md](116-loop-ssa-repair.md) | ✅ DONE | Loop SSA repaired and enabled with eight regressions; Crypto +17.0%, full Octane median 5500 → 5540; general function SSA and 50K target remain open |
| [117-jit-native-body-experiments.md](117-jit-native-body-experiments.md) | ✅ DONE | Completed and consolidated into plan 113; plan 119 owns the unfinished JIT scope. |
| [118-jsc-codegen-comparison.md](118-jsc-codegen-comparison.md) | ✅ DONE | Comparison completed; structural follow-ups consolidated into plan 113 |
| [119-fifty-thousand-octane-two-tier.md](119-fifty-thousand-octane-two-tier.md) | 🔧 ACTIVE | JIT roadmap to 50K: baseline tier over every opcode on interpreter frames, string-ownership decision, optimizing tier over baseline with call, property and allocation nodes; RegExp, frontend and GC in parallel. Baseline: interpreter 5,214, JIT 6,400, JSC 6,951/23,302/78,645/124,692 by tier |
| [tiny-core-builtins.md](tiny-core-builtins.md) | ✅ DONE | TINY core-builtin prototype on the `tiny-llvm-size` branch |
| [tiny-llvm-size.md](tiny-llvm-size.md) | ✅ DONE | TINY LLVM size experiments on the `tiny-llvm-size` branch |

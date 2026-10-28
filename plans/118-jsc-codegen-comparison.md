# JSC comparison and compound function SSA

Implementation: `8bd1e565` on rat.

The 50K full-Octane objective is not achieved. This batch uses focused mini workloads, not another full Octane run. The accepted change improves DeltaBlue about 9%; Richards is neutral. Longer runs show that Boomkat remains slower even than JSC's baseline tier.

## Same workload, different tiers

ARM64 macOS, bundled JSC at `../bunc3/vendor/webkit/bin/jsc`. Baseline Boomkat is rat `de9352ce`, binary `/tmp/bk-ssa-provenance/boomkat`. Final candidate uses the compound SSA native call entry described below. Five alternating-order pairs; medians of in-script Date.now durations. No builds or sampling ran during the final timing pairs. Longer scripts change only the outer b.run count.

| Workload / iterations | Boomkat before | Boomkat after | JSC default | JSC baseline only | JSC interpreter |
|---|---:|---:|---:|---:|---:|
| Richards / 1000 | 728 ms | 726 ms | 61 ms | 413 ms | 1764 ms |
| DeltaBlue / 600 | 1105 ms | 1009 ms | 53 ms | 467 ms | 2400 ms |

JSC tier runs have three samples each, without disassembly logging. Baseline flags: `--useDFGJIT=false --useFTLJIT=false`; interpreter: `--useJIT=false`. Default uses the normal tiering policy. These are workload times, not Octane scores. Boomkat is approximately 12x/19x slower than default JSC, and 1.8x/2.2x slower than its baseline tier, respectively.

Short mini screen, before/after medians: DeltaBlue 110/101; Richards 73/72; RayTrace 157/156; Splay 106/106; Crypto 156/154; NavierStokes 188/188; EarleyBoyer 172/173 ms. Three pairs for other minis, five for Richards/DeltaBlue. The small changes on other workloads are not claimed as wins.

## Bytecode is not the principal gap

The same source functions already have similar bytecode sizes:

| Function | Boomkat bytecodes | JSC bytecodes |
|---|---:|---:|
| Richards Scheduler.schedule | 24 | 31 |
| DeltaBlue EqualityConstraint.execute | 11 | 11 |
| DeltaBlue input/output selector | 9 including a dead final RET | 11 |

Boomkat execute is LDTHIS, GETPROPC output, two register copies, CALL, LDTHIS, GETPROPC input, CALL, GETPROPC value, PUTPROPC value, RETUNDEF. JSC's bytecode expresses substantially the same work. Another AST constant-folding pass cannot explain or erase the observed order-of-magnitude native gap.

Captured JSC DFG code inlines input/output into execute and lowers property operations to checked offsets. Its generated selectors compare direction with immediate 1, rather than performing a runtime global binding lookup for Direction.FORWARD. Richards schedule includes inlined predicate code; larger enclosing functions also reach FTL. The dump options were `--useConcurrentJIT=false --dumpDFGDisassembly=true --dumpFTLDisassembly=true --dumpBytecodeAtDFGTime=true`. Dump timings are excluded from performance evidence.

## Native instructions

The archived JSC DFG execute capture has 158 ARM64 instructions (636 bytes reported by JSC, including padding), with 40 load/store instructions and 17 conditional branches. A same-process LLDB capture of Boomkat's new frameless execute region contains 392 instructions / 1568 bytes, 102 load/store instructions and 68 conditional branches. The Boomkat range excludes the earlier shared call-entry checks and the retained baseline fallback body. Both counts include cold paths; they are static instruction counts, not dynamically weighted instruction counts, and the ranges have different boundaries.

The older instrumented Boomkat function occupied approximately 7552 bytes; its retained baseline plus new entry is still larger than the isolated optimized region. Do not describe 7552 to 1568 as a whole-function code-size reduction. JSC schedule's captured DFG range was 1296 bytes versus roughly 7296 bytes for the old instrumented Boomkat function, again with instrumentation and range-boundary caveats.

Boomkat still executes binding epoch/flags/slot checks, live prototype traversal, repeated tagged-value validation, storage selection between inline and allocated properties, and spills through FunctionRun. JSC's captured code makes stronger compiled assumptions and uses direct offsets/constants. This is an IR, dependency and recovery-state problem; exposing more SLJIT opcodes alone will not remove that work.

## Implemented

- Function SSA now represents receivers, ordinary shape checks, property-storage addresses, prototype-storage paths, terminal returns and scalar selections explicitly. Internal addresses have RAW representation and cannot escape as JS values.
- Dominance CSE shares repeated receiver/layout/storage checks. Load CSE resolves aliases, and function-region liveness is rebuilt from optimized operands before register allocation, including join-edge and select operands. Existing conservative loop recovery remains intact.
- Selector callees with one forward comparison and two returns are if-converted with SLJIT select/fselect. Warmed layout feedback can describe the untaken own-field arm. Global binding snapshots retain their actual source function and deduplicate matching realm/slot dependencies.
- Whole bounded compound regions can inline those selectors and make one terminal numeric PUTPROPC. All guards precede that write. On refusal, the original argument window is authoritative.
- A frameless native call entry borrows the caller's parameters/receiver and returns directly without publishing a VM Activation. It admits exact-arity compound call/store regions of at most 32 bytecodes; it cannot allocate, call JS, collect, or hold a safepoint. The normal frame-building entry remains the fallback. Budget and result ownership checks remain explicit.
- Prototype dependencies contain shape IDs/generations along a live guarded chain, not embedded weak prototype addresses. Shape recycling validates every link and patches the existing epoch constant. Method identity guards also check realm.
- In-place SSA addresses invocation-local spills directly from the shared FunctionRun register. This frees the old state-address register, increasing value homes from two to three without widening the ABI.
- SLJIT_MAP works without SLJIT_STATS counters, and the sample parser reads the ordinary function metadata. Compile-time SSA address logs allow same-process LLDB inspection of an isolated region.

The stats build records 599466 frameless execute completions in the 60-iteration DeltaBlue mini. The embedding test explicitly changes a warmed call target so that a compiled caller must take the native call fallback; it requires the compound store counter to advance. Testing an interpreter/computed-dispatch path alone did not prove entry coverage.

## Fresh profiles

Two-second macOS samples of longer loops, address maps from the exact sampled process, SLJIT_MAP without execution counters:

- Richards: 57.84% ordinary generated body, 10.81% SSA regions, 11.07% native call entry, 14.20% call/return instructions, 3.13% entry, 0.13% exit, 2.82% runtime. Roughly 97% is generated code. Even deleting all entry/call/return overhead would give only about 1.4x; improving body work is necessary.
- DeltaBlue: 26.99% ordinary generated body, 8.93% SSA regions, 7.31% call entry, 14.89% call/return instructions, 3.75% entry, 0.45% exit, 37.67% runtime. Leading runtime helper: sljit_native_read, followed by call/return dispatch. Whole execute SSA is working, but many surrounding reads and calls still miss or use generic continuations.

These are short sampling estimates. Native inline CALL ranges can contain expanded body work, so attribution is more informative than a strict frame/body cost partition.

## Rejected or corrected

- A shape-parent walk in inline property guards regressed Richards. Moving it to cold read continuations did not give a repeatable win. Both experiments are archived, not enabled.
- A second SSA prelude at ordinary function-body entry duplicated generated code without a repeatable gain. Removed; the new whole-region path lives only at native call entry.
- Compiling a second speculative entry for every small pure function added code/guards without enough benefit. Pure leaves retain the existing inline path; new frameless admission requires inlined calls plus a terminal store.
- An intermediate comparison-range edit accidentally omitted loose equality and disabled DeltaBlue admission. It is not in the final source. The final timing and stats evidence requires the intended region to execute.
- An early native return used 1 as success, conflicting with the existing zero-success/nonzero-side-exit ABI. Fixed before acceptance. Final ARM64 and x64 embedding checks exercise the new call path.

## Next implementation levers

1. Extend function-region SSA to actual cyclic CFGs and effectful operations, with memory versions, call-effect summaries and recoverable frame states at effect boundaries. Richards schedule fits within 24 bytecodes, but its loop and intervening writes/calls cannot use the bounded single-terminal-write path. Expand across that loop and its hot run/predicate helpers; optimizing isolated leaves has limited reach.
2. Add dependency/watchpoint ownership for stable globals, prototypes and callees, including unlinking/retirement on mutation and GC. That permits hoisting or removing repeated live-chain/global checks instead of replaying them in every entry. A shape check plus a direct slot is the intended hot operation. Keep generic continuations for dependency failures.
3. Propagate guarded numeric/object facts across those larger regions, share storage bases, schedule/load common values once, and allocate registers across blocks with fewer artificial ABI reservations. The captured 102 memory instructions versus JSC's 40 are a concrete target. Keep type feedback speculative and recoverable, never semantic annotations.
4. Improve baseline continuations for DeltaBlue's repeated ordinary reads and calls while larger SSA is developed. The 190 sampled sljit_native_read self counts make this a measured cost. First establish why stable sites miss and retain a compact polymorphic fast path; broad dynamic caches and shape walks already lost in earlier experiments.

SLJIT's shared-register calls, fragments and rewriteable links are adequate building blocks for these steps. The remaining work is choosing valid assumptions, maintaining their lifetime, and constructing IR that removes repeated work. JSC's baseline-only advantage shows that baseline code quality matters alongside optimizing-region coverage.

## Validation

46 JIT/SLJIT fixtures match in interpreter, JIT and stress modes. ARM64 and x64 embedding JIT checks pass, including actual frameless store execution, method replacement, getter replay and post-GC execution. ASan passes the new fixture and Richards/DeltaBlue/Splay under JIT. The non-JIT slim fixture passes. Bundled-header binding audit: 109 constants, 39 return widths, 188 argument widths match. Differential local/Rosetta/modules match: local status 1 in both modes reflects feature-limited baseline failures; Rosetta/modules status 0. This is not a full local-suite clean pass or a new full-Octane score.

Primary architectural references: https://webkit.org/blog/10308/speculation-in-javascriptcore/ and https://docs.webkit.org/Deep%20Dive/JSC/JavaScriptCore.html . Measurements and disassembly above are from local execution, not inferred from those articles.

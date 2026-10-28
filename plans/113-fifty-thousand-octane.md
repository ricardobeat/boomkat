# 113: The 50,000 Octane target — active JIT master roadmap

Status: **ACTIVE — consolidated 2026-10-28.** Current implementation checkpoint: rat `3e837c64` (write dependencies; no new throughput milestone), previous performance checkpoint `456df4ef` (review fixes `72db32f4`, FP spills `3a34a140`). The 50K full-Octane objective and the 5–10x workload improvement objective are not achieved. This is the single active roadmap for the JIT work covered by plans 107–108, 110–112 and 116–118. Unrelated engine plans retain their own status.

## Closeout and carried scope

“Completed” on an older document closes that investigation or implementation cycle. It does not mean every proposal in its historical text shipped. The unfinished work is explicitly owned here.

| Closed plan | Delivered evidence or implementation | Unfinished scope owned here |
|---|---|---|
| 107 | Hot-path/blocker investigation and selected opcode coverage | Profitable property/call-heavy native regions |
| 108 | Correctness review followed by later fixes and gates | Recovery and ownership invariants for new optimizations |
| 110 | Shared native ABI, recoverable inlining, selected allocation continuations, patchable links | Reliable baseline coverage and general compact optimizer |
| 111 | Shared-workflow profiles and controlled experiments | Cross-workload buffer, scanner, construction and miss-path optimizations |
| 112 | Selected buffer and continuation consumers | WIDE/high-register regions, environment calls, scanner specialization |
| 116 | Bounded numeric-loop SSA repair and activation | Cyclic function SSA, effect/alias information and richer frame states |
| 117 | Measured native-body experiments and accepted small improvements | Broad guard/load elimination, useful region selection and register allocation |
| 118 | JSC bytecode/native comparison; compound frameless SSA entry | Remove the specific excess machine work exposed by that comparison |

## Latest accepted batch: parallel implementation, 2026-10-28

[Full results and cloud-review closeout](113-fifty-thousand-octane/parallel-2026-10-28/report.md): three alternating original full-Octane pairs improve median aggregate **5752 → 6355 (+10.48%)**, all assertions pass. Standard JIT targets enable a bounded standalone-loop reserve: function admission stays below 1 MiB total native code, loops may continue to 2 MiB; ending native bytes increase **1.00 → 1.21 MiB**. No eviction or eager allocation is introduced. `-U SLJIT_LOOP_RESERVE` retains the old cap; the adaptive policy is independent.

NavierStokes improves 86.6%, Mandreel 12.7%, Gameboy 10.7%, MandreelLatency 2.18x. Richards/DeltaBlue/Crypto are flat. PdfJS median is 3.5% lower with mixed pair directions and needs follow-up. Metadata/RSS, compilation CPU and GC-pause costs remain unmeasured; this does not close plan E or the 50K objective.

All eight cloud-review findings were addressed in `72db32f4`, including a negative-control test of alias operand roles and preservation of intentional tiny-callee admission. The direct FP-spill change simplifies emission and reduces generated code. Register coalescing and inherited-read experiments were removed: their tradeoffs did not justify retention. Existing shape/prototype epochs do not cover value-only writes; plan A still requires live value guards or real write dependencies.

Workstream status: **A open; B open; C partial (FP spills); D open; E partial (bounded reserve)**. Next work remains the sequence below, with PdfJS's reserve interaction added to the admission follow-up. Do not describe this batch as a general optimizing tier or a 5–10x gain. The following long-mini targets retain their explicitly named 8bd1e565 reference; the full-suite checkpoint above is newer.

## Write dependencies checkpoint, 2026-10-28

[Implementation, generated-code ranges, mini timing and validation](113-fifty-thousand-octane/write-dependencies-2026-10-28/report.md): `3e837c64` adds proper slot/layout dependencies, rooted owners, mutation invalidation and retirement outside active native frames. Compound SSA uses them for stable numeric global fields and inherited methods. The isolated uninstrumented DeltaBlue compound region shrinks **1564 → 948 bytes (391 → 237 ARM64 instruction words)**. The focused screen establishes **no throughput gain**; several minis show small costs. This is a capability checkpoint, not an accepted speed milestone. Full Octane remains at the earlier measured 6355 median.

Workstream **A is now partial**, with real write dependencies and two bounded SSA consumers implemented; broad profitable guard/load elimination and safe extension to other object classes remain open. B open, C partial, D open, E partial. Historical “A open” statements above describe the earlier batch.

## Current evidence and target

The [JSC comparison](118-jsc-codegen-comparison.md) supersedes historical descriptions below that say SSA is disabled or that all later benchmarks lack compiled code. Historical measurements remain valid for their recorded revisions only.

Five alternating long mini pairs at the checkpoint give Richards **726 ms / 1000 runs**, DeltaBlue **1009 ms / 600 runs**. JSC default medians are **61 / 53 ms**; baseline-only JSC **413 / 467 ms**. The latest DeltaBlue change improves 1105 to 1009 ms; Richards is neutral. These are workload durations, not aggregate scores. No new full-Octane result is implied.

| Checkpoint-relative target | Richards | DeltaBlue |
|---|---:|---:|
| 2x | <=363 ms | <=505 ms |
| 5x | <=145 ms | <=202 ms |
| 10x | <=73 ms | <=101 ms |

These are engineering gates, not predicted speedups. Re-establish the checkpoint controls on the same machine when measurements resume; use paired ratios if CPU frequency changes. Do not claim 50K from mini results. The last full-suite milestone in plan 117 did not establish a reliable aggregate gain over roughly 5.4K. A fresh controlled full-suite checkpoint is required at the first substantial milestone, not before every experiment.

### What must disappear from generated code

Bytecode sizes already resemble JSC: execute 11 versus 11, schedule 24 versus 31. The captured Boomkat execute region contains **392 instructions, 102 loads/stores and 68 conditional branches**; the captured JSC DFG function has **158, 40 and 17**. These static ranges include cold paths and have different boundaries. They identify concrete excess work, not dynamic speedup factors.

1. Repeated prototype traversal, class/shape checks and method identity/realm checks before already-inlined selectors.
2. Global-binding epoch/flags/slot checks and property reads for Direction.FORWARD where JSC compares an immediate 1.
3. Repeated receiver tag extraction, ordinary-object checks and shape checks despite an earlier dominating proof.
4. Repeated selection between inline and allocated property storage.
5. Spills/reloads through FunctionRun, scratch-register shuffling and redundant moves.
6. Frame/call machinery and helper lookups around larger regions that remain outside optimized SSA.

Richards samples are approximately 69% body/SSA and 28% entry/call/return machinery. Removing all transition overhead alone cannot deliver 5x. DeltaBlue has approximately 38% runtime samples, led by sljit_native_read; removing runtime alone also cannot deliver 5x. Both generated-body work and surrounding transitions/runtime must improve. The percentage partitions are short sampling estimates; inline CALL ranges can contain body work.

## Implementation sequence

### A. Remove repeated resolution in the existing compound region

First bounded deliverable: make EqualityConstraint.execute perform guarded field loads, a direction comparison and a store, without resolving the same global and methods on each invocation.

- Introduce compact dependency records for the exact global slot, prototype/property lookup and callee assumptions consumed by a plan. Reuse existing shape-generation checks, plan ownership and incoming call links; do not build a second code-retirement framework.
- Identify and cover mutation entry points before enabling constant assumptions: JS stores, define/delete, prototype changes, builtin/C-API mutations and GC shape recycling. A mutable data value requires a value-write dependency, not merely a shape dependency.
- Initially fold only observed, watched primitive constants such as FORWARD. Retain or safely revalidate object/callee dependencies; never embed unrooted movable or weak object pointers.
- Invalidate entry links before stale code can be re-entered. Keep invalidated code alive while any compiled activation can execute it. An active helper/JS mutation must force a checked continuation or deopt before dependent assumptions are reused. Pure bounded regions have no callbacks/safepoints; do not extend that guarantee to general regions.
- Encode established object/layout facts as SSA facts. Reuse them along dominated paths and kill them at effects that may change them. Hoist storage-address selection within an effect-free interval.
- Inspect actual emitted operands and eliminate scratch round trips through shared emitter helpers; do not add benchmark-specific assembly patterns.

Touchpoints: vm_sljit_ssa_field/proto/inline/opt, vm_sljit_inline/link, FunctionPlan lifecycle and relevant heap/object mutation paths.

Acceptance: no runtime global lookup or method-resolution chain on the accepted steady-state execute path; prove mutation-triggered fallback and safe retirement. Diagnostic goal: <=220 static instructions and <=60 memory instructions for the same isolated region, with dynamically executed paths recorded separately. Workload gate: seek >=15% additional DeltaBlue improvement against 8bd1e565. If assembly shrinks but the workload does not improve, reprofile before expanding this design. Counts are diagnostic targets, not sufficient acceptance.

### B. Compile the hot function loop and its effects in one SSA model

First substantial Richards deliverable: optimize Scheduler.schedule and its hot run/predicate paths across iterations, rather than adding more leaf-only paths.

- Decode instruction boundaries once, including WIDE, and build block/predecessor/successor data consumed by the SSA builder. Reuse bytecode operand/effect metadata; remove duplicate opcode-effect lists as the decoded form replaces them.
- Extend CFG construction to cyclic function regions. Implement loop headers/latches, phi construction/fixpoint representation inference and dominance valid for cycles; the present forward-DAG calculation is insufficient.
- Add explicit memory/effect versions and operation summaries: pure/read-only, known-slot store, allocation, unknown JS call and throw. Use alias classes conservatively; distinct descriptor IDs do not prove distinct objects.
- Attach recoverable frame state to effect boundaries. Deopt after a completed store/call at its continuation; never restart the region and replay effects. Represent inlined caller/callee state using the existing recovery ownership rules.
- Inline the hot predicate and selected monomorphic run bodies under dependency guards and size budgets. For polymorphic run calls, test a small feedback-driven set; retain a native generic continuation rather than expanding all targets.
- Maintain GC/interrupt budget polls at backedges and calls. Materialize roots and reload state only at real transitions that require them.

Touchpoints: SSA graph/build/emit, function-region driver, inline recovery and existing loop metadata. Keep one shared SSA optimizer/lowering pipeline, with loop and function adapters.

Acceptance: counters and address maps prove the selected cyclic region executes and completes; method/field mutations, exceptions and post-effect exits resume correctly. Inspect one complete steady-state loop path. First cumulative throughput gate: **2x on both focused workloads** relative to 8bd1e565. If Richards remains a few-percent improvement after a complete optimized hot loop is active, stop broadening coverage and identify the dominant executed instructions before proceeding.

### C. Make larger regions generate substantially less work

- Propagate guarded int32/F64/object and shape facts through joins and loops. Keep values unboxed across iterations; box at required recovery, call or externally visible storage boundaries.
- Perform alias-aware load forwarding, redundant guard elimination, dead value/store elimination where semantically valid, loop invariant code motion and induction/range reasoning for bounds checks. Unknown calls invalidate the facts their effect summary cannot preserve.
- Allocate GPR/FPR homes across blocks using actual liveness and next-use/cost information. Coalesce moves/phis and reuse dead operand homes where SLJIT operand constraints allow it. Separate VM ABI reservations from the register budget of an optimized region; use set_context/shared-register conventions only with explicit preservation rules.
- Rematerialize cheap constants instead of spilling them. Measure spills, reloads, conversions, guards and VM-slot materializations per completed region/iteration.
- Avoid a global object-layout redesign initially. Select inline/out-of-line storage once under a valid lifetime proof; pursue layout specialization only if address selection remains a measured bottleneck.

Acceptance: demonstrably fewer dynamically executed guards and memory operations on the complete Richards/DeltaBlue paths, not merely fewer cold bytes. Cumulative goal: **3–5x on both workloads**. If code-generation metrics improve without corresponding wall-time gains, attribute the remaining runtime before adding more passes.

### D. Remove remaining helper/runtime and allocation bottlenecks

- Classify DeltaBlue ordinary-read misses by exact reason: shape polymorphism, prototype dependency invalidation, unsupported ownership/type, stale feedback or code retirement. Profile the actual hottest sites rather than installing a cache at every read.
- Add bounded per-site fast paths or patchable targets only for demonstrated stable cases. Respect string ownership, accessors, proxies, realm and prototype semantics; existing generic continuations stay authoritative.
- Extend the unified effect/recovery model to the allocation, constructor, array growth, environment and string/scanner paths prioritized by fresh profiles. Helpers report not-started/completed/throw/poll outcomes and root live values; completed effects are never retried.
- Extend the successful representation/index optimizations to Crypto, NavierStokes, Mandreel and buffer/scanner consumers. Use fresh source/bytecode profiles to choose equivalent operations; no benchmark-name special cases.

Acceptance: material reduction in helper self time and transition counts, with generalizable consumers and no material regressions in the mini screen. **5x is the cumulative workload milestone; 10x is a stretch target that requires new evidence at this point.** Do not multiply independent microbenchmark speedups. If remaining time is parsing, native regex or GC, the next work must target those costs directly.

### E. Make gains survive the full suite and the code budget

- Measure useful region execution per byte, compile time, executable/metadata bytes, retirement/recompilation and GC cost. Admit/retain useful code; avoid letting early suites permanently exclude later workloads.
- Reuse safe incoming-link tracking and active-code protection from A/B. Test small starting budgets and bounded growth as explicit policies; do not default to the prior losing reclamation or blind large-cache experiments.
- At the first substantial workload milestone and at the 5x milestone, run the original full Octane suite with its warmup, assertions and latency results. Compare every result and its geometric mean.
- Keep CodeLoad/frontend and RegExp/library work separately attributable. Gains in Richards and DeltaBlue alone cannot establish 50K: two 10x results in a 17-result geometric mean improve it only about 31%.

Acceptance: at least three alternating full-suite pairs against the checkpoint/control for a broad acceptance claim, with source/build/bundle hashes and memory/compile/GC costs. The overall objective remains open until the unchanged original suite actually reaches 50K under the agreed conditions.

## Iteration rules and immediate next work

1. Start A with a minimized execute-like script and the real DeltaBlue mini. Establish actual entry use and collect an uninstrumented native path before changing code. Existing report 118 is the starting evidence; avoid repeating the whole investigation.
2. Implement one bounded dependency consumer and its invalidation/lifetime support. Measure compile-time constants and eliminated resolution on the real region. Do not enlarge general admission until the measured consumer pays off.
3. During development, compare validated benchmark outputs and focused semantics first, then run alternating performance pairs with no concurrent build/profile/test load. Use short pairs to reject losers quickly; confirm winners with at least five longer pairs and report all samples. Never retain known wrong-output results as performance wins.
4. After a promising change, run focused differential/mutation/recovery tests; broaden to embedding ARM64/x64, ASan, GC and relevant suites before committing. Broad test runs and full Octane are milestone gates, not the inner loop for every edit.
5. Screen other minis after an accepted optimization layer. Investigate repeatable regressions above roughly 3%; keep losing variants isolated or remove them. A small change may land as a scoped win; it does not close a substantial milestone.
6. Record each change against A–E with code hash, proven active path, timing ratios, native instruction/memory metrics and remaining blockers. A capability is complete only when its intended consumer runs and its semantic gates pass; a performance milestone also requires measured throughput.

Do not create another overlapping JIT roadmap. Amend this plan as evidence changes; older plans remain completed historical records with scope carried here.

---

## Historical baseline study (fa1e7f7a)

The remainder preserves the original study. Its “current,” implementation-status and policy statements refer to that historical baseline. The active roadmap and iteration protocol above take precedence for ongoing work.

The user raised the target to 50,000, alongside a reported JSC score of 70,000.
This is an active engineering target, not an achieved result or a guarantee.
Engine baseline: `fa1e7f7a`. No experimental runtime-policy changes from this
study are enabled or retained in the engine worktree.

## Comparable baseline and controlled capacity experiments

Same machine and original complete Octane bundle/settings/checks. One sequential
run per variant; the JSC adapter only supplies console.log from the shell's print.
No builds, tests or CPU sampling ran alongside these timings. These are controlled
single runs, not confidence intervals or a claim of stable improvement.

| Score | Current 1 MiB | 16 MiB | 1 MiB + cold reclamation | System JSC |
|---|---:|---:|---:|---:|
| Richards | 3993 | 3986 | 3971 | 60324 |
| DeltaBlue | 2922 | 2906 | 2909 | 104142 |
| Crypto | 3068 | 3064 | 3065 | 108332 |
| RayTrace | 3059 | 3034 | 3034 | 258404 |
| EarleyBoyer | 3064 | 3070 | 3059 | 170169 |
| RegExp | 767 | 769 | 766 | 28338 |
| Splay | 8703 | 7717 | 8157 | 109948 |
| SplayLatency | 21969 | 20872 | 21595 | 205515 |
| NavierStokes | 3948 | 7185 | 7185 | 54260 |
| PdfJS | 6047 | 7003 | 6969 | 134999 |
| Mandreel | 1919 | 2741 | 2050 | 120347 |
| MandreelLatency | 11078 | 22660 | 15245 | 199408 |
| Gameboy | 12103 | 9656 | 12506 | 230416 |
| CodeLoad | 28281 | 28686 | 26623 | 118832 |
| Box2D | 6890 | 5796 | 4432 | 203730 |
| zlib | 2884 | 2886 | 3362 | 140973 |
| Typescript | 21476 | 21473 | 10641 | 237441 |
| Score (version 9) | 5482 | 5901 | 5483 | 127586 |

System JSC scores **127,586** here. The user's 70K figure is not reproduced by
this shell comparison; browser/version/harness differences remain unverified.
50K requires **9.12×** the current aggregate of 5482 and is 39.2% of this JSC run.
The 16 MiB experiment scores **5901 (+7.6%)**; cold reclamation scores **5483**.
All full-suite assertions pass in all four runs. Neither experiment received a
full semantic release gate or is being shipped as a new default.

Capacity admits useful Navier–Stokes and Mandreel code, but also makes Gameboy,
Box2D and Splay slower. Reclamation cuts TypeScript's score roughly in half and
Box2D by 36%. Enabling more of today's generated code does not establish the
optimizing tier needed for 50K. Default code policy remains unchanged.

## Why the previous mini gains disappeared

The normal, uninstrumented build ends with 1,048,440 bytes of native code out of
1,048,576. Its 103 function plans have source lines no later than Crypto's
`pkcs1pad2` at line 3304. In the diagnostic run, compilation stops after Crypto:
22 Richards functions, 63 DeltaBlue functions, then 13 Crypto functions and eight
loops consume 1,048,504 bytes. None of the remaining twelve suites installs a
native function or loop. Their valid later CPU samples are runtime/interpreter
work. Instrumentation changes code size, so its exact byte counts are diagnostic;
the uninstrumented full-run report independently confirms arena exhaustion.

The default arena never reclaims cold compiled functions. Reclamation exists only
inside the opt-in adaptive policy. The experimental patch separates reclamation
from growth to test it at a fixed 1 MiB; a second switch tests fixed 16 MiB. Both
patches were removed from the worktree after measurement and retained as evidence.

## What the present optimizer actually does

`vm_sljit_ir.c3` is restricted representation analysis with three canonical F64
homes. `vm_sljit_flow.c3` keeps four block-local numeric values and shape/load
facts; `flow_flush` clears these at block boundaries. Named-read helper joins,
calls and branches cause frequent resets. This is not a general SSA optimizer.
Regions are normally 128 instructions and at most 512, and WIDE is rejected.

There is a separate ~3K-line numeric-loop SSA implementation in
`vm_sljit_ssa.c3`, but `SSA_ENABLED` is hardcoded false. Plans 107–108 record wrong
output for a growing-array/constant-store case. Its availability in source is
not evidence that it is production-ready or active. Reuse must start by
reproducing and fixing its known correctness failure, with long-run differential
checks and explicit evidence that generated SSA code actually ran.

## Original implementation sequence (historical)

1. Establish a correct optimizing-tier foundation: decoded instruction boundaries
   including WIDE, CFG and phi values, typed SSA, and frame-state snapshots tied to
   bytecode PCs. Audit/reuse the existing SSA implementation rather than count its
   disabled code as a finished optimizer. Preserve exact side effects on exit.
2. Lower that IR to SLJIT with representation selection and register allocation
   across blocks. Keep int32/F64 values unboxed until a real materialization
   point. Preserve shape and load facts through justified joins; use dominance
   and alias/effect information to remove repeated guards and loads.
3. Optimize loops and call graphs: invariant guards and buffer metadata, induction
   ranges, redundant bounds checks, and profitable inlining with recoverable
   caller/callee state. Integrate normal/wide calls and constructor/scanner
   continuations with the same effect and recovery model.
4. Admit code by measured usefulness and size, retire safely through incoming-link
   tracking, and define an optional throughput memory policy. The experiments
   reject both blind capacity growth and the existing reclaim policy as defaults.
5. Address runtime-heavy paths separately: allocation/GC, string scanning and
   regex execution. JS code generation alone cannot remove native regex-library
   work or frontend parsing/compilation costs.

These are required capabilities, not multiplicative speedup promises. The
benchmark suite is a geometric mean across 17 results: isolated 10× wins in two
results increase the aggregate by only about 31%. Each optimization stage must
measure the entire suite as well as its isolated kernels.

## Original acceptance and evidence (historical)

Use the original full suite with its warmup, validation and latency results.
Run at least three alternating comparisons for acceptance, report every result,
code size and compilation/GC costs, and retain correctness/ASan/embedding gates.
Do not change benchmark algorithms, suppress checks, special-case benchmark
names, or compare mini timings to a full-suite aggregate. 50K is not reached.

All raw scores, exact commands, build/source hashes and the rejected experiment
patch are alongside this report. CPU-profile timings are not used as scores.
The profiler rejects samples crossing a suite boundary; short suites cannot be
reliably attributed by a queued sample request without this check. Earlier
unvalidated phase labels were discarded and recollected.

## Phase-checked CPU samples

One one-second sample per eligible phase; samples crossing a suite boundary are
excluded. Counts describe the sampled interval, not an entire-suite CPU census.

| Phase | Generated-code share of self samples | Runtime share |
|---|---:|---:|
| Richards | 97.4% | 2.6% |
| DeltaBlue | 53.7% | 46.3% |
| Crypto | 71.2% | 28.9% |
| RayTrace | 0.0% | 100.0% |
| EarleyBoyer | 0.0% | 100.0% |
| RegExp | -0.0% | 99.9% |
| Splay | 0.0% | 100.0% |
| NavierStokes | 0.0% | 100.0% |
| Mandreel | 0.0% | 100.0% |
| CodeLoad | 0.0% | 100.0% |
| zlib | 0.0% | 100.0% |
| Typescript | 0.0% | 100.0% |

PdfJS, Gameboy and Box2D crossed a phase boundary and are omitted. Richards
has 68.4% body, 26.5% calls/returns and callee entries, 2.6% gateway entry,
and 2.6% runtime. Both body code quality and call-graph optimization matter.

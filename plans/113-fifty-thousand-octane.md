# 113: The 50,000 Octane target — active JIT master roadmap

Status: **ACTIVE — consolidated 2026-10-28; implementation sequence revised 2026-10-29.** Current implementation checkpoint: rat `86abd083` (overflow-flag integer checks; previous `66a735a0` added the size-scaled function link budget, `d75838d9` boolean ToInt32, `8c421db8` aliased loop SSA, `76e89fb6` the sparse loop register window, and `12e9346e` larger hot regions, a 2 MiB function budget and region-relative exit attribution), previous checkpoints `047d0ef0`, `68d7c01e`, `456df4ef` and `3e837c64` (review fixes `72db32f4`, FP spills `3a34a140`). The 50K full-Octane objective and the 5–10x workload improvement objective are not achieved. This is the single active roadmap for the JIT work covered by plans 107–108, 110–112 and 116–118. Unrelated engine plans retain their own status.

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

## Historical accepted batch: parallel implementation, 2026-10-28

[Full results and cloud-review closeout](113-fifty-thousand-octane/parallel-2026-10-28/report.md): three alternating original full-Octane pairs improve median aggregate **5752 → 6355 (+10.48%)**, all assertions pass. Standard JIT targets enable a bounded standalone-loop reserve: function admission stays below 1 MiB total native code, loops may continue to 2 MiB; ending native bytes increase **1.00 → 1.21 MiB**. No eviction or eager allocation is introduced. `-U SLJIT_LOOP_RESERVE` retains the old cap; the adaptive policy is independent.

NavierStokes improves 86.6%, Mandreel 12.7%, Gameboy 10.7%, MandreelLatency 2.18x. Richards/DeltaBlue/Crypto are flat. PdfJS median is 3.5% lower with mixed pair directions and needs follow-up. Metadata/RSS, compilation CPU and GC-pause costs remain unmeasured; this does not close plan E or the 50K objective.

All eight cloud-review findings were addressed in `72db32f4`, including a negative-control test of alias operand roles and preservation of intentional tiny-callee admission. The direct FP-spill change simplifies emission and reduces generated code. Register coalescing and inherited-read experiments were removed: their tradeoffs did not justify retention. Existing shape/prototype epochs do not cover value-only writes; plan A still requires live value guards or real write dependencies.

Workstream status: **A open; B open; C partial (FP spills); D open; E partial (bounded reserve)**. Next work remains the sequence below, with PdfJS's reserve interaction added to the admission follow-up. Do not describe this batch as a general optimizing tier or a 5–10x gain. The following long-mini targets retain their explicitly named 8bd1e565 reference; the full-suite checkpoint above is newer.

## Write dependencies checkpoint, 2026-10-28

[Implementation, generated-code ranges, mini timing and validation](113-fifty-thousand-octane/write-dependencies-2026-10-28/report.md): `3e837c64` adds proper slot/layout dependencies, rooted owners, mutation invalidation and retirement outside active native frames. Compound SSA uses them for stable numeric global fields and inherited methods. The isolated uninstrumented DeltaBlue compound region shrinks **1564 → 948 bytes (391 → 237 ARM64 instruction words)**. The focused screen establishes **no throughput gain**; several minis show small costs. This is a capability checkpoint, not an accepted speed milestone. Full Octane remains at the earlier measured 6355 median.

Workstream **A is now partial**, with real write dependencies and two bounded SSA consumers implemented; broad profitable guard/load elimination and safe extension to other object classes remain open. B open, C partial, D open, E partial. Historical “A open” statements above describe the earlier batch.

## Profile-guided checkpoint, 2026-10-29

[Profile, controlled experiments, full-suite pair and validation](113-fifty-thousand-octane/profiled-iteration-2026-10-29/report.md): `68d7c01e` adds bounded refresh of stale read assumptions, broader frameless SSA leaves and inherited array named-data reads. Long DeltaBlue timing improves about 9–10%; successful read-helper continuations fall 72%. Fifteen minis show a smaller Mandreel gain and mostly small changes elsewhere. One matched original full-Octane pair gives **6121 → 6257 (+2.22%)**; this is provisional single-pair evidence, not a replacement for the older multi-pair median or a 50K achievement.

Fresh profiles show the small optimized DeltaBlue execute region is only 3.63% of sampled CPU; Richards remains 97% generated code, with its hot scheduler/task bodies still using the baseline emitter. Experimental effectful prefixes and acyclic nonzero regions are archived separately. The standalone C-gateway version loses time. Earlier mismatched-feature comparisons are invalid; later matched region screens show a Richards gain against the preceding prototype and neutral DeltaBlue. These experiments have not passed broad semantic gates and are not enabled in standard targets. A/C/D remain partial or open as above; profitable large regions, cyclic CFG/effects, native continuations and broader memory traffic reduction remain required.

## Architecture and workload reset, 2026-10-29

[First-principles architecture assessment](113-fifty-thousand-octane/architecture-reset-2026-10-29.md) sets the next scope across all workload clusters. Build one compact typed/effect-aware optimizing pipeline with explicit recovery and target-derived allocation; measure numeric/buffer, object/allocation, closure/application, library and startup costs separately. Richards and DeltaBlue remain consumers, not the sole acceptance criteria. Obtain fresh suite-wide profiles before ranking further isolated changes; the old broad percentages predate recent admission improvements.

Experimental source is preserved at `8f875497` on `wip/function-ssa-regions`. It is not promoted to the validated `rat` branch. Detailed patches, mismatched-build correction and subsequent matched evidence are archived with the checkpoint.

## Coverage census and admission checkpoint, 2026-10-30

A fresh `--jit --stats` census of all fifteen minis ranked interpreted functions by executed instructions and rejection reason. The largest loss was not a slow generated body: hot functions were emitted and then discarded once the 1 MiB function budget filled (Mandreel's 308-op `sortMaxDown`, its 489-op `insertleaf`, box2d's 611-op body, TypeScript's 15-op `Verify`). The second loss was the 128-bytecode window used when only a hot header of a large function is compiled; everything past the window ran in the interpreter on every iteration.

Two bounded admission changes, `dd2e776d` and `047d0ef0`, raise the function budget to 2 MiB (loop reserve 4 MiB, two times the function cap) and the region window to 256 bytecodes. Five alternating pairs against `68d7c01e`: box2d **-9.8%**, gbemu **-3.3%**, zlib **-2.0%**, Mandreel **-0.5%**; the other eleven minis are flat, RSS is unchanged, and the differential JIT suites match. A 4 MiB budget, a 384-op window and a 512-op window each regressed, so those points are recorded as rejected, not retained.

The census also fixes the next target. zlib still executes about 835M interpreter instructions: `a1` (37,098 ops, 518 registers) is rejected as WIDE and `a8` (1,370 ops, 68 registers) runs 376M interpreter instructions because its hot loop contains operations the loop tier cannot lower. High-register/WIDE decoding with a sparse register window, and effectful loop bodies, are therefore the dominant remaining coverage work rather than further budget tuning. Constructor wrapping idioms (`this.initialize.apply(this, arguments)`, `superConstructor.call`) also keep every allocation-heavy mini on the allocation exit path; parameter-default constructors were prototyped and reverted because no hot consumer reached the native allocation helper.

## a8 investigation and plan review, 2026-10-30

`a8` is zlib's `deflate_slow`: 1,370 bytecodes, 68 registers, with loops at 103..1083 (980 ops), 109..652 (543 ops) and 796..890 (94 ops). The single installed region lands at 796 because the first hot backedge wins; the large loops exceed both `LOOP_OPS` and the region window and contain calls. Three coverage-shaped attempts were measured and all were rejected:

| Attempt | Result |
|---|---|
| Up to four function regions per function | interpreter ops 835M → 802M, but zlib +1.8%, box2d +9.3%, navier-stokes +7.3%, pdfjs +4.4% |
| Whole-function window raised to 1024 bytecodes | zlib -0.7%, box2d +7.5%, Mandreel +1.0%; 2048 exceeds C3's 64 KiB stack-object limit |
| `ToInt32` accepting booleans in bitwise lowering | geomean -0.16%, zlib +1.5% |

The 256 KiB adaptive budget policy was also re-measured: gbemu, Mandreel and TypeScript regressed, so the fixed 2 MiB cap remains.

Region-relative exit attribution (`12e9346e`, stats only) shows `a8`'s installed 796..1051 region is not failing guards: it exits 3,940 times at the loop end (pc 890) and 60 times at a call (pc 934), so its inner loop and property work already run natively. The remaining 800M interpreter instructions are the outer loop's code outside the window (103..795 and 1052..1083), where the calls to `a3`/`a6` and the unhandled tail live. A second region at the outer header was tried in the multi-region experiment and exited at the boolean `BOR` at pc 356 on every iteration; accepting booleans in bitwise lowering removed that exit but did not pay for the extra branches elsewhere. This confirms the next consumer must be a loop-with-call graph, not another region or window. The consistent conclusion is that adding native coverage to these bodies is currently slower than the threaded interpreter. The cost is inside the generated region (per-operation guards, ownership and spills) and at calls, not at the admission boundary. Coverage-window increases are therefore exhausted until generated work per operation improves; retrying them without a code-quality change is not justified.

Plan review outcome: E0 (broad attribution) is complete for the mini panel, and the A/E parts of the admission work are recorded above. The implementation order stays B1 → B2/B3 → C, but the next consumer changes: the canonical decoded view must first support a real loop with a call and exact recovery (a8's 103..1083 loop), rather than another acyclic window. Until then, C should measure and reduce executed instructions per compiled operation on the existing 256-op regions, since that is the measured reason larger regions lose.

## Capture-read caching rejection and probe gap, 2026-10-30

Resolving a capture in a function region walks the capture-ref metadata, owner class, slot and initialized guard on every `GETCAP`. In `a8`'s compiled region one capture accounts for 43 such reads (`is_value=0`, `is_cell=0`, `guard_shadow=0`). Caching the resolved value in the native run block was prototyped with and without a runtime validity mask:

| Variant | Result |
|---|---|
| Cache without validity mask | Matched timing until a resumed region entry read an uninitialized slot; TypeScript failed with a `TypeError` |
| Cache with mask reset at entry and cleared on calls/writes | Region code grew 904 bytes; zlib **+2.7%**, Mandreel **+1.2%**, NavierStokes **0.186 s → 2.409 s**, TypeScript **-0.6%** |

Both variants were reverted. The masked version also cleared on property writes and every call form, so the loss is the per-read mask test and the longer live values, not a missing invalidation. The conclusion is that capture resolution must be removed or simplified in lowering, not cached lazily in the region.

The same diagnostic run fixed the loop-tier blocker precisely. `sljit_loop_probe` returns before analysis because `a8` has 68 VM registers and `LOOP_REGS` is 64. A canonical operand-role scan, reusing the compiler's liveness table rather than treating every A/B/C field as a register, shows the inner loop `796..890` touches register 67; the outer loops at `103..1083` and `109..652` touch 67 and 65. The loop tier is therefore not being starved by threaded dispatch; it cannot represent these loops at all.

A bounded approximation was then measured: admit loops in a wide function when the loop's own operand scan stays below 64 registers and the loop spans at least 32 bytecodes. It works on a synthetic wide function (123 registers, 41-byte loop): the loop compiles and the run drops **1.94 s → 1.22 s**. No mini benefited, however: `a1`'s loops also touch registers in the 230s, so they remain rejected, and `a8`'s inner loop still needs register 67. Crypto regressed **+3%** from the changed engine code layout with identical loop admissions, so the slice was reverted rather than kept as an unused capability. The next B1 consumer is therefore still the sparse high-register window that maps only the registers a loop actually uses; a per-loop max check alone cannot reach `a1` or `a8`. Enlarging the dense loops would push the per-PC frame and mask tables past their current 64-bit bounds and memory budget.

## Sparse loop register window, 2026-10-30

`76e89fb6` lets a loop in a function wider than 64 registers use the loop tier. The compiler's operand-role table identifies the high registers the loop actually touches, the loop tier aliases each to a free low slot, and the bytecode is remapped only during analysis and native emission. `LoopPlan.slot_reg` maps every dirty slot back to its original VM register at exit, so the interpreter frame is preserved.

Measured on five alternating pairs against the pre-change binary:

| Workload | Change |
|---|---:|
| zlib | **-6.9%** (4146 → 3861 ms), `a8`'s inner `796..890` loop now compiles |
| box2d | -0.5% |
| typescript | -0.5% |
| raytrace | -0.6% |
| richards | -1.3% |
| mandreel | +1.0% |
| earley-boyer | +1.3% |
| other nine minis | within ±1% |

The differential JIT suites, local suite (688 pass, 27 expected Intl/Temporal failures in the default build) and module/rosetta suites match the interpreter. `test/test_sljit_highreg_loop.js` covers both a wide function whose loop stays low and one whose counter/inputs are aliased from high registers.

Aliased loops deliberately used the straight-line emitter at this checkpoint: the shared SSA frame appeared to index VM registers directly. SSA aliasing followed immediately, and the dense `LOOP_REGS` increase and per-loop max-only admission remain rejected.

## Aliased loop SSA, 2026-10-30

`8c421db8` removes the refusal that kept aliased loops on the straight-line emitter. The suspicion behind that refusal was wrong: because the sparse window remaps the bytecode into low slots before analysis, the shared SSA frames are already slot-relative and needed no rewriting. Only the explicit guard stood in the way.

The real hazard was the rebuild path. When an SSA loop guard exits inside the body, the tier frees the native body and re-emits it, either wider after an integer overflow or through the straight-line emitter. Those rebuilds read `cf.code`, which `loop_highreg_compile` restores to the interpreter's copy on return, so an aliased plan would have been re-emitted for the wrong registers. A new `loop_reemit` re-installs the plan's own slot mapping for the duration of each rebuild. The mapping is derived from `LoopPlan.slot_reg`, so no rescan is needed.

Five alternating pairs against the pre-change binary:

| Workload | Change |
|---|---:|
| earley-boyer | **-2.5%** (159 → 155 ms) |
| box2d | -0.9% |
| mandreel | -0.8% |
| typescript | -0.6% |
| zlib, gbemu, navier-stokes, raytrace | +0.2% to +0.6%, within noise |
| other seven minis | 0.0% |

Earley-Boyer recovers the small regression the sparse window introduced; zlib is unchanged because `a8`'s inner loop needs 117 spills and 23 phis, above the 128-entry SSA spill budget. Raising that budget to 192 admits the loop (SSA body 21,552 bytes against 9,140 straight-line) but zlib regressed **+3%**, so the budget stayed at 128 and the loop keeps the straight-line tier. The local suite's 27 failures, the differential JIT suites and the module/rosetta suites are unchanged. `test/test_sljit_highreg_loop.js` now also drives the wide-count path, which overflows, widens and finally falls back to the straight-line tier.

The next B1 consumer proposed at `76e89fb6` was `a8`'s `103..1083` call loop, on the theory that `bytecode_remap_registers` refusing call/argument windows was what blocked it. That premise does not hold. `LOOP_OPS` is 128, and `sljit_loop_probe` rejects a span of 128 or more before the remap is ever consulted, so `a8`'s 980-op and 543-op loops are out of reach for the loop tier regardless of call windows. A census over all fifteen minis (a stats build printing every `loop_highreg_compile` refusal) recorded **no refusals at all**: every wide loop that reached the sparse window could be mapped. Remapping call windows would need contiguity-preserving block allocation for the whole argument range, and has no measured consumer, so it is not implemented.

## Boolean ToInt32, 2026-10-30

`d75838d9` teaches the native ToInt32 conversion that a boolean is a number. Emscripten output combines comparisons with bitwise operators (`(a|0)!=-1&(b|0)!=-1`), so a boolean operand is common. The conversion guard accepted fastints and narrow doubles only, and a boolean exited, running the rest of the body in the interpreter. In zlib's 429-op `a6`, one such BAND site accounted for 749,214 exits; after the change the same function's native entries fall from 1,193,525 to 446,410 and the site disappears from the exit table.

The implementation is one mask. `TAG_BOOLEAN` is `TAG_FASTINT`'s neighbour: `0xFFF5` against `0xFFF1`, one bit apart, so `tag & ~4` folds both onto the existing fastint tail, where a boolean's payload is already its 0 or 1. Null masks down to an unused tag below `TAG_FASTINT` and undefined stays above it, so the existing magnitude guard still rejects both, along with heap values and out-of-range doubles. A branch-based version that tested both tags separately was measured and rejected: it adds a compare on the double path and cost Earley-Boyer 2.6%.

| Workload | Change |
|---|---:|
| zlib | **-1.5%** |
| Mandreel | **-2.0%** |
| gbemu | -0.4% |
| typescript | **+0.8%** |
| Earley-Boyer, regexp | +0.3% to +0.6% |
| other eight minis | within ±0.3% |

Aggregate across the fifteen minis is about **-0.8%**. The differential JIT suites, the local suite's 27 pre-existing failures and the module/rosetta suites are unchanged. `test/test_sljit_boolean_bitwise.js` covers `&`, `|`, `^` and `~` on booleans and the wide values that still leave native code.

## Native coverage measurement, 2026-10-30

A stats build now answers where the remaining work is. Summing the per-function interpreter counters (`threaded` plus `switch`, both counted in bytecodes) and the native bytecodes consumed (function `charged_edges` plus loop `iterations`) gives the split below. Both sides count bytecodes, so they are directly comparable; the interpreter counters include a function's executions before it was compiled, which biases slightly toward the interpreter on short runs.

| Workload | Interpreted | Native | Interpreted share |
|---|---:|---:|---:|
| typescript | 188.7M | 1.2M | **99.4%** |
| raytrace | 17.1M | 0.07M | **99.6%** |
| regexp | 18.3M | 0.01M | **100%** |
| earley-boyer | 26.8M | 0.46M | **98.3%** |
| box2d | 34.9M | 0.38M | **98.9%** |
| zlib | 840.9M | 30.7M | **96.5%** |
| pdfjs | 38.9M | 1.4M | **96.5%** |
| gbemu | 53.3M | 2.2M | **96.0%** |
| splay | 11.7M | 0.7M | **94.1%** |
| mandreel | 126.8M | 17.3M | 88.0% |
| crypto | 13.5M | 4.9M | 73.3% |
| deltablue | 2.0M | 2.6M | 43.2% |
| navier-stokes | 3.7M | 8.8M | 29.4% |
| richards | 0.06M | 2.5M | **2.3%** |

Generated code still covers a small minority of executed bytecodes on eleven of the fifteen minis. Per-operation cost therefore governs only Richards, Navier-Stokes, DeltaBlue and partly Mandreel and Crypto; for everything else the first-order question remains which hot bytecodes never enter native code at all. Measured code density for the baseline function tier is 66 to 130 ARM64 words per bytecode op (zlib's `a6` 73, mandreel's `sortMaxDown` 130, deltablue's 39-op body 110), which is consistent with the earlier JSC comparison but is not itself the limiter while coverage is this low.

## Link-budget admission attempt, 2026-10-30

The coverage census named one concrete admission blocker: box2d has three hot functions (408, 382 and 350 bytecodes) rejected as `guard/link capacity`, together about 8.1M interpreted bytecodes. `function_link_limit` returns 8192 fixups only for typed-heavy bodies and 2048 otherwise, and these bodies need more than 2048. Raising the generic limit to 4096 removed the rejections and gave **box2d -2.8%** and **Navier-Stokes -8.9%**, but also **gbemu +8.2%** and **zlib +2.6%**; aggregate over fifteen minis was **+1.2% worse**, so it was reverted.

Two refinements did not isolate the gain. Allowing 4096 only for bodies without a backedge kept gbemu's regression and lost box2d's gain, as did restricting it to bodies with no loop candidate under `LOOP_OPS`. Under 4096 gbemu compiles exactly the same 177 functions with the same hit count and code bytes as before, so its loss is not an admission change at all but a whole-binary layout sensitivity: a control rebuild of the unchanged source measured gbemu within 1.1%. That makes sub-3% single-workload results across *different* builds unreliable, which is worth remembering when reading the tables above.

The concrete item remained: those box2d bodies need a larger link budget than 2048 but do not qualify for the typed reserve.

## Size-scaled link budget, 2026-10-30

`66a735a0` replaces the fixed generic limit with eight fixups per bytecode, floored at 2048 and capped at `LOOP_LINK_LIMIT`. The old constant already implied that density for a 256-op body, so shorter bodies keep exactly their previous budget and only longer ones grow. Five box2d bodies were being rejected at the 2048 cap; with their natural requirement measured at 2082-2826 fixups they now compile, and `guard/link capacity` disappears from the workload.

| Workload | Change |
|---|---:|
| box2d | **-2.4%** (209 → 204 ms) |
| typescript | -0.8% |
| splay | -0.9% |
| Earley-Boyer, Navier-Stokes, regexp | -0.3% to -0.6% |
| gbemu, pdfjs | +0.5% to +0.7% |
| other six minis | 0.0% |

The differential JIT suites and the local suite's 27 pre-existing failures are unchanged. Unlike the earlier global increase, this one leaves every body shorter than 256 ops at its previous budget, which is why gbemu stays within the layout noise a control rebuild already measured.

## Machine-code comparison with JavaScriptCore, 2026-10-30

Worked backwards from the goal instead of from our code. JavaScriptCore's bundled `jsc` dumps its optimizing tier (`JSC_dumpDFGDisassembly=true`), and a temporary engine dump wrote our generated bytes to stderr for `llvm-mc` to disassemble. Both were run on the same eight-bytecode function, `function sum(n){var s=0;for(var i=0;i<n;i++)s=(s+i)|0;return s;}`.

The comparison found the loop body is not where we lose. JSC's DFG loop is about 15 instructions (`ldur`/`add`/`stur`, `adds`/`b.vs` for the increment, a load of `n`, `cmp`, `b.lt`) plus a tier-up check and an operation-count update. Ours was about 30: the same arithmetic, but each int32 operation compared its result against INT32_MIN and INT32_MAX (two compares, two branches and two constant loads per operation), plus redundant `sxtw`/`orr` copies. `86abd083` replaces the range compares with the arithmetic overflow flag; the body is now 15 instructions and matches the DFG shape instruction for instruction.

That parity produced **no measurable suite gain**. Even a pure 100M-iteration integer loop is unchanged, because these workloads spend their loop bodies in property and element access, not arithmetic. Code size per operation was never the limiter; the limiter is what runs and what does not.

### Where the interpreted work actually is

Summing the interpreter counters of every function by its rejection reason across the fifteen minis:

| Reason | Share of 1,365M interpreted bytecodes |
|---|---:|
| `WIDE` bytecode | **24.7%** |
| `code budget` | **11.3%** |
| everything else | 64.0% |

`WIDE` is almost entirely zlib: `a1` is 37,098 bytecodes, 518 registers, and **40.3% of zlib's own interpreted work**. A register at or above 256 needs a `WIDE` prefix word, and every JIT analysis pass and emitter reads the 8-bit `Instruction` fields directly, so `function_analyze` refuses the whole body. The loop tier refuses it too: `bytecode_remap_registers` rejects any `WIDE` inside the loop, and that is the real reason `a1`'s loops stay interpreted. The earlier note that call/argument windows blocked it was measured on the wrong call site; the refusal is `WIDE`.

`code budget` is TypeScript (54.4% of its interpreted work) and Mandreel (39.4%). Three attempts to admit those functions were measured and all were rejected:

| Attempt | Result |
|---|---|
| Function budget 2 MiB → 4 MiB | typescript **+5.2%**, mandreel +1.7%, box2d +1.5% |
| 512 KiB reserve for bodies ≤ 4 KiB | typescript +1.1%, mandreel flat |
| Continue after a call through a native call instead of exiting | zlib +0.2%, typescript +0.9%, crypto +0.7%, mandreel +0.5% |

The budget is not the disease. A 15-op TypeScript function with 14M interpreted bytecodes was measured exiting native code 613 times at a single `GETPROPC`: such a body pays a native entry and leaves at the first property access, so compiling it is a loss whether or not it fits. Native calls are not the answer either: the call entry publishes a VM activation, which costs more than the small callee it saves.

A related aliasing bug was found and left unfixed on purpose. Loop rejection was a 64-bit mask keyed by the backedge offset, so in `a1` the cold backedge at 35,988 sets the same bit as the hot one at 31,044 and blocks it permanently. Widening the mask to 256 bits was implemented and measured: it admits two more box2d loops and one more pdfjs function, changes no workload beyond layout noise, and is inert until `WIDE` lets those loops compile. It is recorded here rather than kept.

### The two builds that can double throughput

1. **A `WIDE`-aware JIT.** Decode the prefix into 16-bit operands for analysis, remapping and emission instead of refusing it. This is the single largest coverage item (24.7% of interpreted work, 40% of zlib) and it is bounded, mechanical work: an operand view over `pc`/`pc-1` replacing direct `ins.a`/`ins.b`/`ins.c` reads in the loop and function tiers, plus a remap that re-encodes a widened operand into an 8-bit field and drops the prefix when it lands in a low slot.
2. **Native property access that does not bail.** Object-heavy workloads are at 93-100% interpreted not because they cannot compile but because a compiled body leaves at the first uncached `GETPROPC`/`GETPROP` and never re-enters. A polymorphic inline cache (two to four shapes) plus a call into the interpreter's megamorphic path, with the body continuing afterwards, is what addresses the remaining 64%.

## Current status and acceptance model

The architecture reset governs the implementation order below. A–E remain stable workstream names, not a requirement to finish every item in A before starting B. Older checkpoint paragraphs above record status at their own revisions.

| Workstream | Status | Next responsibility |
|---|---|---|
| A — Feedback, assumptions and dependencies | PARTIAL | Reuse delivered watches; represent facts and their invalidation in the shared graph |
| B — CFG/SSA, effects and recovery | PARTIAL | Sparse window and aliased loop SSA landed; cyclic regions and effect information remain; the loop body now matches JSC's DFG shape |
| C — Optimization and allocation | PARTIAL | Boolean ToInt32 and the overflow-flag checks landed; measured loop bodies are at JSC parity, so remaining cost is in property and element access |
| D — Runtime and compiled continuations | PARTIAL | Native calls publish an activation and do not pay for small callees; the open item is a native property path that continues instead of exiting |
| E — Coverage, measurement and budgets | PARTIAL | 24.7% of interpreted bytecodes are `WIDE`-refused and 11.3% are budget-blocked; a `WIDE`-aware tier is the next coverage step, and the budget increase itself was measured as a loss |

Validated source is `rat` at `86abd083`. Experimental `8f875497` is a source of reusable pieces, not a branch to merge wholesale. In particular, entry-only global snapshots after intervening effects need guaranteed dependency ownership or effect-aware reloads; failed registration must refuse specialization. Broad recovery, ownership, mutation and GC validation remains open.

The latest matched full-suite pair is **6121 → 6257 (+2.22%)**, provisional. The earlier **5752 → 6355 (+10.48%)** result uses three pairs in a different timing window. Neither establishes 50K, and these absolute scores must not be compared across windows as a regression or gain. From roughly 6.3K, 50K requires roughly 8x aggregate improvement.

The JSC comparison found similar bytecode sizes but excess checks, resolution, storage selection and frame traffic in Boomkat. Its historical isolated ranges (392/102/68 instructions, memory operations and conditional branches versus JSC 158/40/17) include cold code and different boundaries. Later dependencies reduced a Boomkat range to 237 instruction words without a throughput win. These are diagnostic observations, not current dynamic counts or speedup predictions. See [plan 118](118-jsc-codegen-comparison.md) for the exact revisions and evidence.

Performance acceptance is based on matched throughput and executed work across workload clusters. Richards and DeltaBlue remain regression consumers; their historical 2x/5x/10x mini targets no longer determine implementation order or completion. No optimizer pass is assigned an assumed multiplicative speedup.

## Engine target and design constraints

Use one compact speculative optimizing pipeline over the existing baseline:

`decoded bytecode + feedback → typed cyclic CFG/SSA + effects/frame states → optimization → representations/register allocation → SLJIT + exits/root maps`

- Extend existing loop/function graph infrastructure. Share operand/use enumeration, liveness, recovery and lowering; remove superseded paths as consumers migrate. Avoid another pattern-specific optimizer or handwritten metadata table.
- Treat numeric types/ranges, shapes/shape sets, callees and array/storage kinds as guarded runtime facts. Type hints seed speculation; they never change JavaScript semantics. Reuse watch ownership, rooted assumptions and safe code retirement.
- Keep hot values unboxed and in registers across useful loops/calls. VM slots are recovery/storage locations, not mandatory destinations for every temporary. Root publication at safepoints must still obey string ownership, GC and helper contracts.
- Model calls, stores, allocation and exceptions explicitly. Distinct descriptor IDs do not establish nonaliasing. Unknown operations conservatively invalidate facts and have an explicit continuation or exit; do not silently assume purity.
- SLJIT supplies emission, register conventions, fragments and patchable linking. Select its context from actual allocation and clobber needs. Preserve incoming-link safety and active-code protection. Do not add bindings without a concrete consumer.
- Keep compilation and memory bounded. Replace structural fixed-array/bitmask limitations with budgeted representations where measured consumers require it; simply raising all constants multiplies graph/frame memory. Use C3 stdlib containers/allocators where appropriate. No global object-layout or GC rewrite without evidence.
- Keep parser/frontend and native library optimization separately attributable. Flat-AST folding can simplify bytecode and compilation, but cannot replace native loop, memory and call optimization.

## Implementation sequence

### E0. Establish broad attribution and select structural consumers

Make one fresh diagnostic census of the unchanged original suite on the current build, with source/configuration/bundle hashes and maps from the sampled process. Separate interpreter, baseline, optimized body, helper, GC and frontend CPU. Record admission/rejection/exit reasons, compilation CPU, code/metadata bytes and phase order. Distinguish missing generated code from unmapped generated addresses; reject phase-crossing samples. This is a milestone measurement, not a full-Octane run for every edit.

Choose short reproducible kernels from the following groups based on the census. Reuse existing fixtures/runners and save exact commands; these are workload categories, never benchmark-name compiler special cases.

| Group | Initial candidates | Structural questions |
|---|---|---|
| Integer/buffer | Crypto, Mandreel, Gameboy, zlib | Cycles/nested loops, WIDE/high registers, shifts, typed accesses, captured bindings |
| Floating-point | NavierStokes, RayTrace, Box2D | Unboxed doubles, invariant bases/lengths, numeric inlining, spills |
| Object/allocation | Splay, RayTrace, Box2D | Field stores, constructor/allocation continuations, barriers and GC |
| Application/closures | EarleyBoyer, TypeScript, PdfJS | Environment access, JS calls, shapes, strings and arrays |
| Native library/startup | RegExp, CodeLoad | Regexp kernel versus surrounding JS; parser/compiler/metadata costs |

Compare equivalent hot kernels against JSC baseline-only and default tiers where useful. Match source semantics, warmup, tier configuration and disassembly boundaries; exclude diagnostic logging from timing. Static counts explain emitted work, while mapped samples, activation/completion counters and elapsed time establish relevance. Do not carry old broad runtime percentages forward as current measurements.

Deliverable: a ranked blocker/CPU-share table and a small iteration panel containing at least an integer/buffer kernel, a floating-point kernel and an object/closure kernel. Include Richards/DeltaBlue as regression checks, not the whole panel. Select one real consumer blocked by each structural change before implementing it.

### B1. Shared decoded CFG, canonical uses and cyclic SSA

1. Audit/reuse the current bytecode decoder and compiler liveness before introducing infrastructure. Decode WIDE and branch boundaries into one indexed view retaining original bytecode PCs. Use canonical register read/write roles; constant-pool operands must never become register uses. Decode target/fallthrough and exception boundaries explicitly.
2. Build predecessor/successor edges and traversal order once. Generalize forward-only function joins to natural loops, headers/latches, multiple backedges and nested loops. Use cycle-valid dominance and phi construction/repair; representation inference converges to a fixed point. Unsupported irreducible/exception cases initially use explicit baseline exits with a recorded reason.
3. Replace duplicated SSA operand walks with one canonical enumeration, including phi edge operands and recovery uses. Separate computational liveness from values required only for exits. Preserve definitions that are observable after a region even if unused in its body.
4. Keep existing specialized loop behavior until shared lowering has proven parity, then remove duplicate analysis. Budget graph nodes, edges and snapshots independently of source register count. Handle WIDE/high-register mappings without blindly expanding dense per-PC frame matrices.

Touchpoints: bytecode operand/decode utilities, compiler liveness, `vm_sljit_ssa_graph/build`, region/loop adapters and SSA use/allocation code.

Acceptance: prove an actual cyclic function region executes across repeated iterations, not merely an acyclic prefix at a loop header. Use minimized diamond/backedge/nested-loop and exit-only-live-value cases, including WIDE decoding where introduced. Demonstrate activation and equivalent results on selected integer and floating-point consumers. Record compile/memory costs and the precise remaining unsupported operations. This stage need not claim a throughput win by itself; it must unlock an identified blocked consumer and avoid material regressions.

### B2/A. Effects, memory facts and exact recovery

1. Give operations explicit effect summaries: pure, heap read, known-location write, allocation, unknown call, throw/poll. Track memory/fact versions through joins and backedges. Begin with conservative kills; refine disjointness using proven receiver identity/location, not descriptor inequality.
2. Attach sparse frame states at observable boundaries. A failed check before a store resumes before it; a later exit resumes after a completed store/call. Never replay effects. Include inline caller/callee state, exception destinations, live references and ownership. Recovery liveness participates in allocation.
3. Reuse rooted watches and invalidation/retirement. Revalidate after operations that may mutate assumptions; avoid stale entry snapshots. Watch registration/metadata allocation failure declines specialization safely.
4. Implement known-slot stores followed by further native computation and a guard. First consumers must include an object/allocation or closure workload beyond the two property/call benchmarks.

Acceptance: counters prove continuation after an effect. Minimized tests force aliasing, disjoint writes, branch writes and late getter/method/global mutation; observe exactly-once effects. Audit strings, barriers, active-code lifetime and exits before broadening. Measure whether fewer repeated loads/checks improve the real selected kernel; do not expand a nonpaying specialization solely because its assembly is smaller.

### B3/D. Calls, safepoints and runtime continuations

1. Add graph-level calls with argument/result locations, clobbers, effect summaries and recovery states. Inline profitable monomorphic callees under rooted dependencies and budgets; keep remaining calls explicit. One generic call must not disqualify the entire function from optimization.
2. Define helper completion/exception/poll outcomes for allocation, object initialization, array growth and environment operations. Publish or describe roots, reload movable stack pointers after helpers, and resume at the correct compiled continuation. Arbitrary JS calls invalidate conservative heap facts; checked continuations handle invalidation of currently active code.
3. Keep GC/interrupt polls on loops/calls, plus safe native entry/link/retirement ownership. Establish general root maps or precise root publication before keeping heap references live across collection. Use SLJIT context/fragments/linking only under the same ABI and lifetime contracts.

Acceptance: a hot loop remains compiled across a non-inlined call, and a separate allocation/closure consumer resumes natively after a completing helper. Test collection, stack growth, exceptions, mutation and code retirement on those actual paths. Known incompleteness causes a supported exit, not silently incorrect code.

### C. Optimize the connected computation

Apply shared passes to the graphs enabled above: type/shape/range propagation, profitable inlining, constant propagation, alias-aware load elimination/store forwarding, redundant guards, dead computations, invariant hoisting and proven bounds-check elimination. Preserve integer overflow, signed/unsigned shifts, negative zero, NaN, holes, getters and coercion semantics. Keep integer/double/object values in useful representations across blocks; rematerialize cheap values instead of spilling.

Allocate GPR/FPR homes across blocks using live ranges, call clobbers and target availability; coalesce copies/phis and reuse dead operands. Select ABI context after allocation. Defer escape analysis/scalar replacement until effects, roots and recovery can describe eliminated objects correctly.

Acceptance: show fewer executed checks/loads/stores/conversions or spills together with repeatable throughput improvement on relevant kernels. Require consumers in multiple clusters for a claim of general optimizer benefit. Treat static code size as supporting evidence. A pass that reduces compile/code complexity can justify a measured modest tradeoff, documented explicitly; avoid accumulating extra paths for noise-sized gains.

### D/E. Runtime costs, budgets and full-suite acceptance

Profile remaining allocation/GC, strings, environments, regexp and frontend work directly. Optimize the dominant runtime kernels where JS compilation cannot remove them. Measure code usefulness per byte, metadata/RSS, compile CPU, retirement/recompilation and GC costs. Test a 256 KiB starting budget with bounded growth as an experiment once usefulness signals exist; do not change the current default or revive losing eviction policies without matched evidence.

Run original full Octane at substantial capability/performance milestones, with assertions and latency results intact. Broad acceptance needs at least three alternating pairs, all workload results and the geometric mean, matched hashes and memory/compilation costs. Two 10x results among 17 geometric-mean components yield only about 31% aggregate gain. The 50K objective stays open until actually measured under agreed conditions.

## Immediate implementation slices and iteration protocol

1. **Attribution and blocker inventory (E0): DONE 2026-10-30.** The mini panel and ranked rejections are recorded above. Keep profiling separate from timing; refresh the census after structural changes rather than adding a framework.
2. **Canonical instruction/use view (B1):** consolidate decoding/operand roles and distinguish recovery from execution liveness. First reviewable change should remove duplicate metadata/analysis or demonstrably enable the next graph step; do not merely raise caps. Record consumers, source files and before/after rejection reasons.
3. **One real cyclic graph (B1):** implement phi/dominance/fixpoint support and entry/exit lowering on the shared path. Choose its kernel from E0; include numeric/buffer consumers. Verify actual loop completion before adding more optimizations.
4. **Post-effect continuation (B2):** integrate reusable pieces of `8f875497` selectively, fixing its ownership/global-watch limitations. Exercise a store, later guard and exact recovery on an object/closure consumer. Do not merge the prototype wholesale or substitute DAG prefixes for cyclic SSA.
5. **Calls/helpers and optimization (B3/C/D):** preserve the graph around a generic call, then a completing allocation/helper; add load/guard and representation optimization against the exposed costs. Start with C on the existing 256-op regions: the a8 measurements show per-operation guard/ownership/spill work, not missing coverage, is what makes larger windows lose. Keep the broad mini panel as the performance gate.

For each slice, capture a control and candidate with matched features/hashes, prove the intended generated path executes, check the benchmark result, and run short uninstrumented alternating timings without concurrent builds/profiling/tests. Reject losses quickly; confirm promising wins with longer pairs (normally five). Never count known wrong-output runs as wins. Infrastructure slices may land without speed claims only with a concrete enabled consumer and bounded cost.

Use minimized recovery/mutation cases during development; after a promising change, complete appropriate interpreter/JIT/stress, embedding ARM64/x64, ASan/GC and differential gates before promotion. Full Octane is a milestone gate, not the edit loop. Investigate repeatable mini regressions above roughly 3%; document explicit simplicity/performance tradeoffs rather than hiding them.

Record each slice under A–E with commit/configuration, activation/completion proof, performance samples, executed-work diagnostics, compilation/memory costs and remaining blockers. Maintain one canonical current status here; older plans remain completed evidence. No additional overlapping JIT roadmap.

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

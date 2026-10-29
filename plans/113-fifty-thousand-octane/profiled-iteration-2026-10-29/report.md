# Profile-guided native read and call improvements

Implementation: rat **68d7c01e**, baseline **3e837c64**. Partial delivery under active plan 113; the 50K and 5–10x objectives remain open. This report records the validated main-worktree batch. Effectful SSA region experiments are isolated and are not claimed as delivered optimizations here.

## What the profile established

Same-process SLJIT_MAP-only binaries, 3-second macOS sample at 1ms intervals after .5s startup, unchanged mini algorithms with only outer run counts increased. No concurrent builds/tests/profiles overlapped samples or timing windows.

- DeltaBlue: runtime **38.94%**, baseline body **27.25%**, CALL/RET **16.47%**, call entry **8.61%**, ordinary entry **3.95%**, SSA leaves **4.34%**, exit **0.43%**. The compound EqualityConstraint.execute SSA region alone is **92/2532 = 3.63%** of samples. Making that isolated static range 39% smaller cannot establish an overall speedup.
- Richards: runtime **2.64%**, baseline body **58.29%**, CALL/RET **13.44%**, call entry **12.16%**, ordinary entry **3.34%**, SSA leaves **10.14%**. Scheduler.schedule and TCB.run use baseline bodies, not whole-function SSA. Their null branches, multiple stores, polymorphic calls and scheduler backedge need a richer optimizing region and recovery state.

## Delivered changes

- A four-entry bounded per-plan miss sampler detects stable ordinary-object data reads. After 64 matching successful misses, it requests an interpreter IC update before publishing the triggering read. The outer native gateway waits until that exact shape/generation is in the IC, unlinks and retires the old code only after all native frames unwind, and recompiles on the next eligible call. Two attempts per CompiledFunction and 32 pending gateway checks cap churn. It records no object pointers. Policy lives in vm_sljit_feedback.c3.
- Existing pure and one-terminal-numeric-store SSA leaves use the existing frameless call ABI. VM activation/local-stack capacity checks run only on the fallback that actually publishes a frame. Arity, realm, epochs, budget, depth, environments, this, result ownership and pure-body restrictions remain guarded.
- Inherited array named-data reads can execute using a guarded one-link snapshot when the cached owner is ARRAY. This excludes length/index/hidden keys and validates receiver/owner classes, flags, shapes, prototype identity and allocated property storage. It loads the current slot value, so replacement stays observable. OBJECT-owner sites receive no extra array branch.
- The existing dominance CSE pass handles identical constants/conversions/comparisons in direct in-place graphs and runs after load aliases become visible. A larger independent scalar optimizer/unboxed-predicate pass was reduced to this small shared implementation.

Successful DeltaBlue native read-helper continuations: **1,297,014 → 357,249 (72.46% fewer)** in matched stats runs. Ending instrumented native bytes: **389,876 → 411,372**. The new frameless leaf calls add approximately 147K completed calls beyond the prior compound region. An isolated array fixture records 4,905 native executions and no read-helper continuations before mutation. Embedding tests require actual refresh/retirement/recompile, then fewer than eight helper misses over 80 native reads of the later shape.

## Focused performance

Long, unchanged-algorithm DeltaBlue runs (1200 outer calls), three alternating pairs: main batch predecessor comparison **2023 → 1832ms (9.44% less time)**. Richards is neutral in stable pairs; later control outliers are retained in raw data and are not called gains. The earlier ablation compared old 456df4ef, tracking without the consumers, 3e837c64, the larger scalar candidate and the rejected flow variant; its raw results distinguish infrastructure costs from the tiny optimized region.

Fifteen unchanged short minis, three alternating pairs, no overlapping build/test/profile. Time change is positive when slower:

| Mini | Before ms | After ms | Time change |
|---|---:|---:|---:|
| deltablue | 105 | 95 | -9.52% |
| richards | 74 | 75 | +1.35% |
| crypto | 162 | 164 | +1.23% |
| navier-stokes | 190 | 190 | +0.00% |
| raytrace | 165 | 167 | +1.21% |
| earley-boyer | 180 | 178 | -1.11% |
| splay | 115 | 114 | -0.87% |
| pdfjs | 369 | 368 | -0.27% |
| typescript | 1250 | 1274 | +1.92% |
| code-load | 163 | 162 | -0.61% |
| regexp | 341 | 344 | +0.88% |
| box2d | 233 | 235 | +0.86% |
| mandreel | 693 | 670 | -3.32% |
| gbemu | 297 | 299 | +0.67% |
| zlib | 4322 | 4375 | +1.23% |

The minis support the DeltaBlue gain and a smaller Mandreel gain. Most others are within about 1–2%; TypeScript and some other small slowdowns need monitoring. No aggregate score is inferred from these times.

## Original full Octane

One matched sequential pair on the unchanged original bundle (SHA256 `ef4c74d25100e6308436fb19b14eaefd5b4b690f30a799b60bc9bccbcefdce8e`), standard O2 ARM64 macOS build, C3 0.8.5, --macos-min-version 27.0, --jit --stats. No SLJIT_STATS instrumentation, concurrent builds or other agent runs. All original assertions pass in both runs. **6121 → 6257 (+2.22%)** is a **single-pair provisional result**, not a multi-pair median. Do not compare this absolute score to the earlier 6355 median taken in another timing window.

| Result | Before | After | Score change |
|---|---:|---:|---:|
| Richards | 4314 | 4356 | +0.97% |
| DeltaBlue | 2922 | 3283 | +12.35% |
| Crypto | 4901 | 5109 | +4.24% |
| RayTrace | 3028 | 2989 | -1.29% |
| EarleyBoyer | 2796 | 3008 | +7.58% |
| RegExp | 725 | 753 | +3.86% |
| Splay | 7978 | 8263 | +3.57% |
| SplayLatency | 19739 | 21261 | +7.71% |
| NavierStokes | 7257 | 7164 | -1.28% |
| PdfJS | 7310 | 7337 | +0.37% |
| Mandreel | 2119 | 2146 | +1.27% |
| MandreelLatency | 22660 | 24083 | +6.28% |
| Gameboy | 13378 | 13311 | -0.50% |
| CodeLoad | 29166 | 28369 | -2.73% |
| Box2D | 6269 | 6116 | -2.44% |
| zlib | 2931 | 2903 | -0.96% |
| Typescript | 21770 | 21848 | +0.36% |

Ending native code bytes **1,273,504 → 1,263,528**, active functions **103 → 112**, loops **93 → 92**, evictions **0 → 0**. This does not measure total metadata, executable allocator overhead, RSS, compilation CPU or GC pauses.

## Validation

- All **51** JIT/SLJIT fixtures match in interpreter, normal JIT and stress modes.
- ARM64 embedding, ARM64 ASan embedding and x64 Rosetta adaptive embedding all pass.
- Full-ICU local, Rosetta and module differential suites all match with status 0, avoiding the omitted-Intl/Temporal failures of the standard target.
- Non-JIT slim compiles. SLJIT audit: 109 constants, 39 return widths, 188 argument widths match bundled header.
- New regressions cover changing read receiver shape, value/layout/accessor/GC changes, and array method data/shadow/prototype/proxy semantics. The embedding test checks a real request and replacement, populated later-shape IC and reduced misses.

## Rejected or unready experiments

- Preserve all baseline flow facts across named reads with interpreter side exits: DeltaBlue roughly **+18%**, Richards roughly **+20%** time. Reverted.
- Checked this-shape continuation stubs: DeltaBlue roughly **+14%** versus the winning combination; no worthwhile Richards gain. Reverted.
- FUNCTION named-read arm in the ordinary path: DeltaBlue neutral, Richards roughly **+2.4%**; flow materialization and the extra ordinary-path branch outweighed saved helper calls. Reverted.
- Standalone effectful SSA prefix: focused correctness eventually passes, but C-gateway/frame-publication costs produce large losses. Isolated, unmerged.
- In-parent effectful prefix plus exact pruned recovery state: cuts C transitions, but early screens remain flat for Richards and about **+9%** for DeltaBlue. Further register/context/continuation work is required before retention. It is not a completed optimizer milestone.

The next architectural work is profitable effectful regions with exact recoverable frame states, ABI-aware register allocation and native slow continuations. Whole scheduler-loop SSA additionally needs cyclic CFG/phi support, effects/aliasing and calls. The current profile does not support an isolated tiny SSA cleanup as a path to 5–10x by itself.

# Scalar register-cache investigation, 2026-10-31

**Outcome: rejected runtime optimization.** The candidate failed the full-suite
performance gate and was removed. Only a compile-time auxiliary-arena invariant
and a scalar recovery fixture are retained in the engine checkpoint. No throughput
improvement is claimed for the retained changes.

Baseline: rat `fa11ea2d`. Work stayed in the rat worktree; main was not changed.
This is a bounded scalar-code refinement, not the optimizing-tier completion or
the 50K target. The full comparison is recorded in `full-results.json`.

## Candidate

The baseline function tier already caches four numeric values in F64 lanes.
This experiment adds three boxed GPR homes (R4..R6), shared with no other emitter:
only a whitelist of scalar instructions may use them. All other operations,
control-flow entries, calls, property/helper joins and inline SSA are barriers.
Values are selected by a bounded next-use scan and mapped to three deterministic
homes. Clean definitions avoid subsequent frame loads. An inert replacement of
an already inert value can delay publication. Eviction, barriers and guard exits
publish its actual tagged bits. Exit deduplication includes the boxed frame state.
String ownership remains with the existing store path.

The same scalar sequences propagate proven fastint facts through definitions,
copies and successful integer guards, removing repeated ToInt32/type checks.
Definitions and barriers invalidate facts. The cache does not change function
admission budgets, WIDE support, benchmark algorithms or execution modes.

The extra exit-state word increases LoopLink size. Blocks must fit SLJIT's
128-byte auxiliary allocation limit on 64-bit hosts (64 bytes on 32-bit hosts).
The initial block size silently prevented native compilation; it was corrected,
a static assertion was added, and affected performance samples were discarded.

## Measurements

Five alternating mini pairs against a fresh control build, before the final
conservative fact-scope/snapshot-canonicalization cleanup:

| Mini | Control median ms | Candidate median ms |
|---|---:|---:|
| Crypto | 172 | 172 |
| Mandreel | 570 | 561 |
| Gameboy | 275 | 276 |
| PdfJS | 364 | 363 |
| TypeScript | 1249 | 1232 |
| zlib | 3720 | 3728 |

These results are small or neutral, not evidence of massive gains. See raw
`mini-pairs.json`; use medians, not the unusually slow individual control samples.
The initial write-through-only screen was also essentially neutral.

The final focused fixture's scalar function compiles from 3972 to 3580 bytes;
its recovery function compiles from 2932 to 2812 bytes. The helper-containing
function slightly grows, 2464 to 2472 bytes. Native plans are present under
`--jit --jit-stress --stats`; outputs match the interpreter. This is generated
code-size evidence, not an instruction-retirement or RSS measurement.

## Rejected extension

A more aggressive variant tried to guard an old slot against strings and delay
the first inert store too. It failed Crypto's output validation and timed out in
zlib. It was removed, and no performance result from it is accepted. Merely
passing the existing focused fixtures was insufficient to establish correctness.
Do not restore it without minimizing and fixing its recovery/ownership fault.

## Validation

- 51 preexisting jit*/sljit* fixtures agree in interpreter/JIT/stress modes.
- New `test/jit_scalar_recovery.js` checks scalar eviction, coercion exits, primitive
  type changes, single execution of valueOf, and helper/return publication.
- Local/Rosetta/modules differential outputs and statuses match. Local status 1
  is the preexisting feature-limited baseline; Rosetta and modules return 0.
- ARM64 and x64 embedding JIT checks pass. Cross-compiled C sources require
  `--cflags '-arch x86_64'`; otherwise the compiler builds them for ARM64.
- Address-sanitized embedding JIT passes with `--sanitize=address -O1`.
  The exploratory O0 threaded build exhausted the stack; it is not a passing
  ASan result and is not used as a memory-corruption diagnosis.
- Bundled SLJIT header audit: 109 constants, 39 return widths, 188 argument widths.

Compilation CPU, RSS and GC costs have not been measured. The added compile-time
flow arrays and larger temporary fixups are bounded; native arena limits are
unchanged. Larger cyclic regions, effect-aware facts, compact property lowering,
register allocation across helpers and WIDE function-tier support remain open.

## Interpretation and next slice

This rejects the specific three-home, direct-mapped scalar whitelist experiment;
it does not prove that register allocation across larger effect-aware regions
cannot help. Property accesses and calls are cache barriers here, so the object-
and buffer-heavy consumers still reload most operands and replay most guards.
Smaller scalar fragments and their micro code-size reductions did not establish
full-suite profitability. Avoid blindly promoting this design or raising admission
caps around it. A useful next cache must survive the real hot operations with
precise recovery state and be measured together with admission/code-size effects.
The existing plan's canonical decode/effect/CFG work remains necessary.

No massive non-JIT engine win was identified or implemented in this slice.
The 50K target remains unmet. Do not replace the accepted throughput baseline
with these rejected candidate scores.

## Full Octane: three alternating pairs

All six runs return status 0 and pass the original benchmark checks.

| Result | Control median | Candidate median | Score change |
|---|---:|---:|---:|
| Richards | 4639 | 4632 | -0.15% |
| DeltaBlue | 3329 | 3339 | +0.30% |
| Crypto | 4663 | 4577 | -1.84% |
| RayTrace | 3108 | 3074 | -1.09% |
| EarleyBoyer | 3062 | 3040 | -0.72% |
| RegExp | 769 | 772 | +0.39% |
| Splay | 8483 | 8328 | -1.83% |
| SplayLatency | 21759 | 21182 | -2.65% |
| NavierStokes | 7272 | 7109 | -2.24% |
| PdfJS | 6374 | 6955 | +9.12% |
| Mandreel | 2186 | 2120 | -3.02% |
| MandreelLatency | 24926 | 24200 | -2.91% |
| Gameboy | 13090 | 12724 | -2.80% |
| CodeLoad | 28557 | 27958 | -2.10% |
| Box2D | 6884 | 5819 | -15.47% |
| zlib | 3353 | 3210 | -4.26% |
| Typescript | 20855 | 20817 | -0.18% |
| Score (version 9) | 6309 | 6219 | -1.43% |

Aggregate controls: 6364, 6309, 6201. Candidates: 6219, 6011, 6308.
Median aggregate **6309 → 6219 (-1.43%)**. Box2D median loses 15.47%;
PdfJS improves, but the cross-workload tradeoff is unacceptable. The third
pair reverses the aggregate direction; the result is a rejection for lack of
a reliable broad benefit, not a precise universal slowdown estimate.
Native code at the end of pair 0: control 2377436 bytes, candidate 2378004;
functions 173 → 172; loops 102 → 99. Three-pair capacity effects are part of
the measured behavior, not grounds to discard inconvenient full results.
Final source hashes, original bundle hash and experimental binary hashes
are in manifest.json. Performance runs were sequential; builds and substantial
validation completed before the comparison. A short focused native-size check
also ran during the first control and is a limitation of that pair; the broad
Box2D loss repeats in pairs 1 and 2.

## Retained checkpoint

Rat `4228a786` retains only the auxiliary-arena size assertion and the new scalar
recovery regression. The final rebuilt release executable is **byte-for-byte
identical** to the fresh fa11ea2d control (SHA-256
`7ac7219b82c2b05ef454f1dd8222dd86e56f0a9d96279058739e9a465b07bf0b`).
All 52 jit*/sljit* fixtures agree in interpreter/JIT/stress modes after removal
of the experiment. `final-fixtures.txt` records this final check. The full-suite
control scores therefore describe the retained runtime; there is no shipped
throughput change. Main remains untouched.

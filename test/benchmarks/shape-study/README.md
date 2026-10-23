# Shape and cache speed experiments

This continues plan 105's original R0–R6 work. It does not complete the whole
plan: packed cache addressing, deeper operation fusion, and the triggered
T-series proposals remain unimplemented.

## Retained change

Seal and freeze now flatten an object's layout once and update its descriptor
flags directly in that private layout. Previously each property update could
clone the private layout again. Freeze applies non-configurability and data
non-writability in one pass. Accessors, array length and mapped arguments retain
their respective rules. A failed flatten cannot enter the new direct-edit path.

The focused immutable-record workload allocates six- and sixteen-field records,
checks an unfrozen peer, seals/freezes records, and retains their values. The
standalone change reduced CPU time **60.04%** against the integration baseline
in five alternating pairs; Richards **+0.09%** and TypeScript **+0.15%** were
near baseline. This is an operation-specific gain, not a 60% engine speedup.
The final retained executable has the same file size, **3,165,224 bytes**;
its machine-code section grows **120 bytes** (2,417,568 → 2,417,688).
Final five-pair confirmation: immutable records **-60.02%**, Richards **-0.62%**,
DeltaBlue **-0.18%**, TypeScript **-0.15%**, PdfJS **+0.19%**, scene churn
**-0.04%**. General throughput is approximately unchanged; the gain is specific
to integrity operations. Raw samples are in `results/retained.json`.

## Controls and method

Coding agents wrote isolated candidates without builds or validation. One
reviewer inspected the source, built snapshots and ran the checks and timing
experiments. Initial experiments use `9f087b30`; unrelated work reached
`056f24f8` during the experiment, so final integration uses a fresh binary of
that revision. Both controls remain locally available:

- `out/shape-study/baseline-9f087b30`
- `out/shape-study/baseline-056f24f8`

All CLI timing binaries use the default `boomkat` target: C3 0.8.5, LLVM 23.1.3,
macOS ARM64, O3, no size optimization, single module, relaxed floating point.
Binary hashes, revisions and actual code-section sizes are under `results/`.
Builds ran separately from timing. The existing allocation-study harness runs
one excluded warm pair, then alternates A/B and B/A order sequentially. Screens
use three pairs, confirmations five to nine; batched scene confirmation uses
three processes per side per pair. CPU time is primary; wall time, output and
peak RSS are retained. Fresh five-pair A/A controls varied about 0.3–0.4% CPU.
These short local experiments do not establish statistical significance for
small differences, and CPU frequency/load still varies between batches.

## Decisions

Percentages below refer to CPU time. Negative means less time. Screens are
retained even when their apparent gains disappeared on confirmation.

| Candidate | Evidence and decision |
|---|---|
| R1 variable-record packing | 120 → 104 bytes; TypeScript +0.44%, Richards +0.94%, DeltaBlue -1.11%. No convincing speed gain; reject for this speed-focused batch |
| R1 optional property-chain payload | Common record 88 → 40 bytes plus 48 bytes only at chain sites; about 4 MB lower TypeScript RSS, time -0.09%; reject for throughput |
| R1 per-function cache families | Conservatively classify final bytecode and omit unneeded arrays; screened slower, including TypeScript +2.37%; reject |
| R2 second own-read shape | Reuse unused chain storage, no larger record; mixed-shape kernel +0.24%, Richards +1.71%; reject |
| R3 eight inline slots for known five-to-eight-field objects | One allocation instead of header plus property block; nine-pair batched scene CPU -2.24%, about 1.5 MB less RSS. On newer baseline alone: scene -1.81%, Richards +0.66%, TypeScript -0.53%. Reject integration: combined with the retained update, Richards +2.98%, TypeScript +1.26% |
| R3 grouped compact/wide header free | Principled attempt to remove the added generic-free branch; combined Richards still +2.72%; reject |
| R4 preserve shape generation on storage growth | Index-based property entries survive relocation; variable raw-slot invalidation stays. Confirmation scene -0.15%, DeltaBlue +0.08%; reject as neutral |
| R4 heap epoch instead of per-shape generation | Removes dependent shape-table reads but broadens invalidation; Richards +0.98%, TypeScript +1.27%; reject |
| R4 epoch plus obsolete metadata removal | Smaller shape header; Richards -0.96%, TypeScript +1.23%, scene -0.32%; reject |
| R5 share existing descriptor transitions during seal | Much lower immutable-record RSS, but CPU +43.70%; reject |
| R5 bulk private descriptor update | Immutable-record CPU -60.04%, general workloads near baseline; **keep** |
| R6 consume one inert copy after a property read | Richards +3.03%, TypeScript +2.13%; reject |
| R6 consume guarded object/string copy | Initial Richards -7.12% and TypeScript -10.33% did not repeat: confirming Richards +0.87%, TypeScript +0.31%, PdfJS -0.27%; reject |
| R6 inert/object-only copy | Five-pair Richards +0.99%, TypeScript +0.48%; reject |

The cache reductions remain useful memory tradeoffs on their isolated branches;
they are absent from the retained runtime change. No padding or alignment hacks
were used to chase the mixed integration results. A failed initial bulk build
copied a stale executable; its measurements were discarded and are excluded
from these results. The corrected candidate was rebuilt successfully and rerun.

## Opportunity profile and validation

The existing opt-in opcode profiler showed 13.35 million GETTHISC executions in
Richards, 7.97 million in DeltaBlue, and 28.50 million cached property reads in
TypeScript. Scene churn executed about 446,000 shaped allocations. This motivated
cache/allocation and bounded continuation experiments. Pair counts can cross
frames and do not prove that a compiler fusion is legal. The raw profile is
retained in `results/opprofile.json`; it is not release timing evidence. This is
a partial R0 profile, not the full sampled site/miss-cause census.

Focused checks cover shared peers, accessors and symbols, strict writes, dense
arrays and holes, array length, mapped arguments, descriptor changes, and value
lifetime. Both value representations and a freshly rebuilt ASAN worker are
checked, including 23 ASAN worker inputs (two execution variants per input)
with reset between inputs; the exact retained validation record is in `results/validation.json`.
No full conformance sweep was run. The wider combined candidate also passed
29 worker inputs with reset between inputs before being rejected for speed.

## Reproduction

From the repository root, after building matching control and candidate binaries:

```sh
python3 test/benchmarks/allocation-study/measure.py \
  out/shape-study/baseline-056f24f8 out/shape-study/retained \
  test/benchmarks/shape-study/immutable-records.js \
  bench/mini/richards.js bench/mini/deltablue.js \
  bench/mini/typescript.js bench/mini/pdfjs.js \
  --pairs 5 --out /tmp/retained.json
```

Use build commands that stop on failure before copying executables. Rejected
implementations remain on isolated experiment branches; only the bulk update
is retained in the engine.

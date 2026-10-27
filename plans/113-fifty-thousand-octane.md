# 113: The 50,000 Octane target

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

## Implementation sequence for the new target

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

## Acceptance and evidence

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

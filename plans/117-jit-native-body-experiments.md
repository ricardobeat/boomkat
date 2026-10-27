# Native-body optimization experiments

Target remains 10x improvement / approximately 50K full Octane. No full-suite result in this batch establishes progress to that target; iteration used interleaved mini timings.

## Landed

- e02b58f5 prefers existing memory SSA kernels over generic function backedges. Crypto mini 213 to 162 ms; Richards and DeltaBlue neutral.
- d63dc1c3 separates conservative register may-write effects from the compiler's narrower liveness-kill metadata. Calls, destructive operands and unknown opcodes cannot silently preserve numeric homes.
- 6e728827 fixes own-polymorphic admission and this-receiver reloads. DeltaBlue 120 to 117 ms; recorded GETTHISC exits 144635 to 72981. Focused, embedding and targeted ASan checks passed.

## Rejected experiments

Clean GPR read caching, widening numeric IR to 512 bytecodes, eager local numeric homes, whole-function read-feedback refresh, and adaptive per-read data caches did not produce broad gains. Local-home variants either disrupted native calls/inlining or selected no new homes in the measured workloads. Refresh helped DeltaBlue but regressed Crypto/RayTrace. Dynamic caches on all reads regressed heavily; moving them to miss continuations still failed to improve the minis. Saved patches are experiments, not accepted code.

## Fresh CPU samples

Same-process SLJIT_MAP attribution of five-second macOS samples, current committed code plus a longer mini iteration count:

- Richards: 4201 self samples, body 67.01%, call/return 15.42%, call entry 9.85%, entry 2.93%, runtime 4.78%. GETTHISC 681, GETPROPC_CACHED 465, LDREG 342 samples. No unmapped category. Runtime includes process-start costs.
- DeltaBlue: 4254 self samples, body 34.09%, call/return 17.25%, call entry 8.72%, entry 3.74%, runtime 35.87%, exits 0.33%. sljit_native_read is the largest named runtime helper at 398 samples.

## Landed dcdaf730: guarded property-result ownership hints

Threaded warmup samples at most 16 results. Four non-string observations allow a generated non-string guard and uncounted store, preserving string fallback. First pairs: Richards 88 to 85 ms; confirmation 89 to 85. Other minis mostly neutral; initial RayTrace gain did not repeat. Focused three-mode tests, embedding and targeted ASan pass. Broader differential validation: local status 1 matches in both modes; Rosetta/modules match at status 0. Local failures in this feature-limited build are not a clean suite pass. Committed as dcdaf730.

Full Octane should be run for a meaningful validated candidate, not each experiment. Retired-plan exit counters must not be compared as aggregate totals when evaluating refresh.

## Landed 72a3e3de: named-read producer retargeting

Fused named property reads now use the existing producer-retarget liveness proof, removing a redundant copy without introducing a new pass. Duplicate fused-load classification was removed. Tests cover getters, throwing assignments, receiver aliasing, branches and this reads. Two five-pair mini runs showed small gains; confirmation: Richards 84→82, DeltaBlue 118→116, Crypto 160→158, Splay 115→112, RayTrace 164→160, EarleyBoyer 176→174 ms. Focused three-mode, baseline/candidate interpreter comparisons, embedding and targeted interpreter/JIT ASan checks passed. Broader differential results match (local status 1, Rosetta/modules 0). Full-suite milestone comparison is in progress; mini timings are not an aggregate score.

## Full-suite milestone, 72a3e3de versus f5bb66df

Two sequential alternating pairs using unchanged bundle SHA256 ef4c74d25100e6308436fb19b14eaefd5b4b690f30a799b60bc9bccbcefdce8e, no overlapping builds/tests. All four runs pass. Baseline scores 5365, 5468; current 5483, 5446. Median 5416.5→5464.5 (+0.89%). Pair changes disagree in sign; this does not establish a reliable aggregate speedup. Richards and Crypto improve, but later-suite variation and regressions dilute them. Only two pairs were collected, below the three-pair acceptance protocol from plan 113; no broad performance acceptance claimed. 50K remains unachieved. Raw per-suite scores and the runner are archived alongside this report.

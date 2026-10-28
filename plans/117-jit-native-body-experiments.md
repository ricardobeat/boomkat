# Native-body optimization experiments

Status: **COMPLETED — consolidated into [plan 113](113-fifty-thousand-octane.md), 2026-10-28.**

The recorded experiment cycle is complete: accepted commits and rejected approaches remain evidence. It did not establish a 5–10x gain. Unfinished general function-SSA and native-body optimization work is carried into plan 113. Completion closes this document as a separate workstream; it does not assert that the broader optimizing tier or performance target has been achieved.

The original implementation notes, measurements and status statements below are historical evidence. Plan 113 owns the current priorities and acceptance criteria.

---

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

## Splay isolation and cold result feedback (9ba74af8)

Restored Octane's original measurement loop in the standalone Splay harness, without changing the workload. Three alternating pairs: old SSA baseline versus 72a3e3de yields JIT Splay 7994→8638 (+8.1%), but interpreter-only 8059→7905 (−1.9%). The full-suite decline therefore does not reproduce with a fresh JIT arena.

Moved named-result sampling from every threaded publication to cache fills/shared-cache misses, retaining a guarded hint after the first cold observation. Against 72a3e3de, three interpreter-only pairs yield Splay 8337→9160 (+9.9%) and latency 21337→22244. JIT minis: Richards83→83, DeltaBlue115→116, Crypto158→158, Splay115→111, RayTrace161→160. Focused/embedding/targeted ASan checks pass; broad differential matches (local status 1, Rosetta/modules 0). No full-suite acceptance claimed yet.


## SSA binding snapshots and recovery inputs (6e4741bb)

Rejection tracing found every sampled Navier numeric loop blocked on GETCAP.
SSA now reuses the validated binding snapshots already prepared by the loop tier.
Recovery-only header inputs remain boxed: requiring overwritten temporaries to be
numeric caused immediate SSA retirement. Integer inference now uses shared
register may-write effects instead of two incomplete opcode lists.

Five alternating mini pairs against 9ba74af8: Navier 207→201 ms, Crypto 158→159,
Richards 83→82, DeltaBlue 118→115. An earlier run regressed DeltaBlue; the latest
run did not reproduce it. These are modest mini gains, not evidence of a large
aggregate improvement. No full Octane rerun. Focused three-mode fixtures,
embedding tests, binding/Navier ASan checks pass; broader differential matches
(local status 1, Rosetta/modules 0). Stats show millions of lin_solve SSA
iterations after fixing recovery-only entry guards. Indexed-load guards and
unsupported operations still limit coverage.

The preceding optional 256 KiB SSA reserve experiment admitted no Mandreel loops
and only about 2 KiB additional code in the pressure harness. Removed rather than
claiming its timing changes demonstrated the intended benefit.


## Mixed numeric loads and recovery allocation experiments

Mixed dense-number conversion removed all reported Navier SSA fallbacks, but
five-pair medians versus 6e4741bb were Navier 200→202, Crypto 158→161,
DeltaBlue 115→116, Richards 82→82 ms. Removed. The stale double-read proof flag
was independently corrected in 2c310e0e, reusing the address-invalidated numeric
proof; focused three-mode tests passed under ASan.

Forcing recovery-only phis into spills: Navier 202→206, Crypto 160→158,
Richards 82→82, DeltaBlue 115→115. Shortening their allocation intervals instead:
Navier 203→203, Crypto 159→159, Richards 83→84, DeltaBlue 117→115. Both pass
focused three-mode checks but establish no overall performance improvement;
both removed. Comparisons use the 6e4741bb release binary, so candidates also
include the later ownership-guard correction. Raw data and patches preserved.


## Native property miss tracing after 5130a280

Fresh same-process samples at 2c310e0e show Richards body62.55%, calls15.18%,
call entry10.60%, runtime8.73%; named read opcodes1093/4112 samples. DeltaBlue
runtime36.24%, body33.99%, calls17.47%, call entry8.15%; native_read371/4269.
555a140f adds missing boolean ownership facts for EQ/NEQ (neutral minis).
5130a280 hoists receiver/shape reloads out of polymorphic own-arm chains:
Richards83→82, DeltaBlue116→114, RayTrace160→160, Splay111→109; focused tests pass.

Temporary direction-read tracing found62/80 early misses with cached polymorphic
own data feedback (receiver287, primary278, chain254),18 with the same primary
shape287. Reusing ic_poly_slot inside native_read passed tests but gave
DeltaBlue115→115, Richards82→82, RayTrace160→160, Splay108→109. Removed. Existing
feedback availability is established; a generated fallback may avoid the helper
call, while a helper-only lookup change did not improve these workloads.


## Live polymorphic generated fallback (removed)

Implemented direct reads from existing ICPolySet data on generated misses,
ordinary-object guards, common value-store continuation, no cache ownership
changes. Focused three-mode checks pass. Stats counted190644 successful reads
in DeltaBlue mini. First shared-continuation variant: all four paired medians
unchanged (DeltaBlue115, Richards82, RayTrace160, Splay109 ms), code385652→502676
bytes. Restricting emission to own-data feedback yields DeltaBlue117→116,
Richards83→84, RayTrace163→162, Splay111→111; code461548 bytes. No persuasive
speedup for the extra code; removed. Inlined property misses still reconstruct
interpreter frames and are not covered by this prototype.


## Inline ordinary-read continuation (removed)

Factored ordinary data-slot lookup from native_read and reused it against
borrowed inline windows, with non-string results only and no allocation or
observable calls. Added continuation labels and flow-reset boundaries. Focused
three-mode checks pass. Stats against the older current-profile binary at
2c310e0e: DeltaBlue inline recoveries75472→2338, inlined4877650→4962648.
This large recovery reduction only gives a small timing change: paired release
medians versus5130a280 DeltaBlue115→113, Richards83→85, RayTrace162→160,
Splay113→112, Crypto159→158. Restricting continuation boundaries to polymorphic
feedback yields DeltaBlue115→115, Richards82→82, RayTrace161→164,
Splay114→110, Crypto159→158. Removed rather than claim a broad win.
The preserved patch is the selective version; remove the feedback restriction
to reproduce the broader version. Profiling evidence favors eliminating
successful generated-code work over further transition-only changes.


## Integer equality and SLJIT audit after b2be46d3

Performance-first seed for Richards' predicate region. Explicit block-local
integer-result facts did not improve Richards (84→85 ms); removed before broad
correctness work. Direct tagged-integer equality avoids F64 conversions.
Branch-result variant: Richards83→82, DeltaBlue118→117, Crypto162→160,
RayTrace165→164. Condition-flags materialization variant: Richards84→83,
DeltaBlue119→120, Crypto168→167, RayTrace168→169. Short-run differences are small.
Three alternating extended Richards pairs (12000 workload iterations):
23777→14849, 22658→20642, 14194→9975 ms. All favor the candidate but absolute
variance is large; do not report the median ratio as a reliable broad speedup.
Focused three-mode equality/JIT checks, generated-code ABI checks and targeted
ASan equality/Richards/DeltaBlue pass. Broad differential matches (local status1, Rosetta/modules0). Equality landed196e4028.

SLJIT audit committed6fe17d05: five status returns corrected from64 to32bits;
condition materialization exposed and executed in the ABI suite. New checker
validates70 constants,23 return widths,106 parameter widths and arity against
the bundled header. Architecture documentation inventories missing capabilities
and constraints; existing shared-register calls/fragments/patching distinguished
from missing indexed-operand helpers/selects/flag setters/constants/SIMD APIs.


## Shared function-region SSA and capability consumers

9d84537e exposes selects, flag-only arithmetic, masked shifts/rotates, patchable
constants, paired memory, SIMD movement and feature/register queries. Header
checker validates109 constants,39 return widths,188 argument widths. Executable
ABI tests exercise indexed loads, selects, masked shifts, rotates, constant
patching, paired transfers and vector stores on ARM64 and x86-64 (cross C sources
need --cflags '-arch x86_64').

810cf7f6 adds single-pass regions to the existing SSA graph/allocator/emitter,
shared publication and an opt-in SLJIT_FUNCTION_SSA scalar adapter. Admission
remains restricted; no 5–10x mini-Octane gain is claimed. Five-pair minimal long
arithmetic case: baseline29→region24ms; live-input initialization24→20ms, with
identical output on all runs. The continuation must clear baseline temporary
FP assumptions: broad diff caught captured global sum300 instead of1500, fixed
by an explicit continuation block boundary. A branch at pc0 also needed an
unambiguous no-branch sentinel; a direct region test covers both arms.

CPU register queries revealed the old SSA request (9 saved/8 scratch) exceeds
x86-64's6 saved/13 total registers. Allocation now uses actual counts and only
pins memory descriptors when a complete saved-register pair is available.
ARM allocation is unchanged. Targeted generated-region/ABI tests pass on both
architectures. Focused three-mode suites under ASan pass, including scalar type
changes/coercion and function_scope_capacity. Broad differential matches:
local status1 in both modes, Rosetta/modules0.

52a60313 uses masked 32-bit shifts in function bitwise lowering. Five-pair
minis vs196e4028: Crypto165→164, Mandreel722→716 (4/5 pairs faster),
Navier209→210, Richards83→83, DeltaBlue118→118. Small effect only.

Rejected: indexed memory operands in existing loop SSA (Crypto158→158,
Navier200→202, Mandreel697→704); scalar value numbering (no loop or minimal
region gain); read-only region descriptor preparation (Vector.dot admitted,
25525 calls, but RayTrace268→271 and Crypto control258→263 with substantial
run-time variation). Descriptor preparation per short call is unproven; restored
scalar-only admission. Next: direct generated function-region entry for memory
reads, wider CFG/return selection, and measured select/patch/SIMD consumers.

Function-region shared-context continuation (2026-10-28)
------------------------------------------------------

Added opt-in direct SSA entries for call-free functions with no captured
bindings. They retain S0/S1/S2, allocate values in S3/S4 and use run-owned
scratch via S5. Original VM slots are untouched until successful publication
of the return value; guard failures restart the compiled baseline body at PC0.
No helpers/allocations/writes occur in these regions. String results and
replacement of a string-owned return slot use baseline ownership handling.
Captured bindings keep the C adapter/exact snapshot path.

Ordinary, non-dictionary own FIELD reads now have generated entry preparation.
One receiver/shape guard supplies all its slot addresses. An epoch constant is
patched through SLJIT's API before native execution. A once-per-heap-epoch scan
refreshes linked callees too; invalid shape generations patch a value outside
the runtime uint epoch range, permanently refusing the stale region.

Five alternating pairs against scalar live-input SSA: RayTrace168→166ms,
Richards83→83, DeltaBlue118→118, Crypto165→165, Navier208→208. Long arithmetic
micro20–21→18ms, output98173796.02306579 unchanged. RayTrace Vector.dot:
25525 entries,25131 completed,394 baseline refusals,4 epoch updates; guard
sharing reduced region904→632 bytes. These are small gains and neutral minis,
not evidence of the requested5–10x improvement. Keep feature opt-in.

Checks:43 focused fixtures in interpreter/JIT/stress, embedding JIT success on
ARM64 and x86-64, default embedding build, ASan scalar/field fixtures and
Richards/DeltaBlue/RayTrace. Embedding tests execute the shared-context entry
explicitly, assert unchanged input slots, and force epoch refresh/invalidation.
Broad differential before the epoch-refresh follow-up: local outputs/status1
match, Rosetta/modules outputs/status0 match. No full Octane run this iteration.

A smaller admission threshold admitted extra tiny functions but showed no
reliable benefit; restored eight-instruction minimum. An actual-used-register
context experiment was neutral/slightly worse for loop SSA, so existing loop
context sizes remain unchanged; only single-pass region contexts are trimmed.
Next coverage barriers remain calls/allocations and multiple returns. Existing
binding capabilities do not remove these semantic barriers by themselves.


## SSA leaves and call-containing loops, de9352ce

The function and loop tiers now consume the same scalar lowering for arithmetic,
comparisons and bitwise operations. Fused CALL_GLOBAL/CALL_VAR expand guarded
scalar callees into the caller graph. Binding snapshots and dominated function
checks share SSA values; effect-only nodes no longer consume register homes.
Comparison values and IF_TRUE/IF_FALSE latches admit call-containing loops whose
bytecode cannot use a fused numeric backedge. Recovery publishes the latch
temporary as well as loop-carried values. Call-containing SSA kernels are enabled
by default; whole-function SSA regions remain opt-in.

Small warmed own-field callees emit SSA directly into baseline code, including
nested virtual callers. They borrow bounded, compact private scratch in deeper
FunctionRun windows and use R4/R5 plus FP3..6; no new C call or native frame is
introduced. Observed int32 fields stay unboxed, numeric globals are folded behind
live binding/bit guards, immediate operands avoid constant homes, and repeated
field loads are coalesced. One terminal numeric PUTTHISC is admitted only before
RETUNDEF, with receiver/prototype, value, old-slot and result-ownership guards
before the write. Dictionary layouts, accessors and unsupported effects retain
interpreter recovery. Unknown boxed stores are declined at graph construction.

Fixed a provenance error in feedback-only field analysis: a field destination
must lose its previous origin. Otherwise a chained access can guard an unrelated
entry input and always refuse. The nested leaf fixture now records 438 completed
chain-read SSA executions and 438 terminal-write completions. This coverage fix
has neutral mini timings; it is not claimed as another performance win.

Three alternating screening pairs, leaves disabled versus enabled (same source
before call-loop default enablement): Richards83→77ms, DeltaBlue118→118,
Crypto163→164, RayTrace166→166, Navier208→207, Splay114→113,
Earley181→178. Default call-loop expansion separately gives numeric call-loop
micro15→5ms; actual mini changes remain small. Five longer Richards pairs,
500 workload repetitions: disabled408,408,408,408,407 versus
candidate379,379,380,380,378; medians408→379ms (-7.1%). Earley confirmation
181,181,181,181,182 versus180,180,180,180,180. These are ablations, not a
full-Octane score or evidence of 10x gains. Raw rows:117-ssa-focused-results.json.
The final provenance correction is neutral: Delta118→118, Richards77→77;
RayTrace165→166 in five short pairs.

Rejected: short copy-region SSA (neutral); a direct empty-array named-method
path removed212k DeltaBlue property-helper calls but produced no reliable wall
clock gain; a generated baseline expansion after every refused SSA leaf added
code without a speedup and was removed. No full Octane run in this iteration.

Fresh same-process address maps now name SSA leaf ranges, including virtual
caller depth, separately from ordinary CALL ranges. Corrected native range ends
to exclude separately allocated whole-function SSA code. Richards2323 self CPU
samples: body55.96%, SSA leaf10.98%, call/return13.65%, call entry12.70%,
entry3.40%, runtime3.27%, exit0.04%. DeltaBlue2316 samples: body33.29%,
call/return17.27%, call entry8.46%, entry4.06%, runtime36.57%, exit0.35%.
These are process CPU attribution, not timing measurements. Prior disassembly
matched hot Richards PCs to648 loads among1182 sampled instructions in
Scheduler.schedule and TaskControlBlock.run. DeltaBlue miss telemetry finds
stable receiver shapes repeatedly taking sljit_native_read: Plan.execute118861,
Binary.isSatisfied66499, Binary.output54492/53777 calls in the short trace.
The next larger levers remain cross-call guard/load reuse and useful cold
property specialization; adding more coverage without reducing repeated work
has repeatedly been neutral.

Validation after measuring:45 focused fixtures in interpreter/JIT/stress modes;
C embedding checks assert actual SSA execution, shared binding snapshots, kernel
call expansion and shape-epoch refresh/refusal; ARM64 and x86-64 embedding tests;
ASan leaf/call fixtures and Richards/DeltaBlue/Splay; non-JIT slim build.
Broad differential agrees: local status1 in both modes (existing feature-limited
failures), Rosetta/modules status0. SLJIT binding checker still validates
109 constants,39 return widths,188 argument widths.

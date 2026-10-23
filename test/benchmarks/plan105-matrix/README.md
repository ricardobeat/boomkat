# Plan 105: complete mini-suite experiment matrix

This ongoing study tests isolated candidates against retained release baseline
`51e0e10e`, using the fifteen unchanged classic-script benchmarks from the Octane
worktree. Agents write isolated source; the parent alone builds and validates it.
`out/plan105-matrix/` holds binaries and original local evidence. This checkpoint
is not a claim that the plan is finished or that small screen gains are winners.

Three alternating A/B pairs and one unrecorded warmup pair are used for screening.
Positive changes mean slower. Runtime is the geometric mean of each benchmark's
median emitted elapsed time. Process CPU includes compilation and teardown.
Potential winners require longer independent confirmation and size review.

| Attempt | Runtime | Process CPU | Status |
|---|---:|---:|---|
| `constructor-8` | -0.21% | -0.12% | Pending targeted evaluation or confirmation |
| `ctor-last` | -0.10% | -0.20% | Pending targeted evaluation or confirmation |
| `ctor-highwater` | +0.51% | +0.47% | Pending targeted evaluation or confirmation |
| `flat-literals` | -0.81% | -0.75% | Pending targeted evaluation or confirmation |
| `property-predicate` | +0.70% | +0.70% | Pending targeted evaluation or confirmation |
| `property-pair` | +0.69% | +0.71% | Pending targeted evaluation or confirmation |
| `initializer-pair` | +0.76% | +0.69% | Pending targeted evaluation or confirmation |
| `prefix-clear` | -0.54% | -0.57% | Pending targeted evaluation or confirmation |
| `selective-clear` | -0.55% | -0.46% | Pending targeted evaluation or confirmation |
| `computed-dict` | -0.21% | -0.16% | Pending targeted evaluation or confirmation |
| `packed` | +2.79% | +2.55% | Reject for throughput |
| `compact-records` | -0.43% | -0.40% | Pending targeted evaluation or confirmation |
| `packed-compact` | +2.03% | +1.91% | Reject for throughput |
| `packed-dense` | +2.24% | +2.03% | Reject for throughput |
| `negative-read` | -0.08% | +0.00% | Pending targeted evaluation or confirmation |
| `proto-epoch` | -0.33% | -0.28% | Pending targeted evaluation or confirmation |
| `proto-watch` | +0.30% | +0.24% | Pending targeted evaluation or confirmation |
| `pic-four` | -0.26% | -0.13% | Pending targeted evaluation or confirmation |
| `pic-shared-action` | +0.07% | +0.17% | Pending targeted evaluation or confirmation |
| `enum-json` | -0.22% | -0.29% | Pending targeted evaluation or confirmation |
| `enum-full` | -0.61% | -0.55% | Pending targeted evaluation or confirmation |
| `numeric-scan` | -0.49% | -0.51% | Pending targeted evaluation or confirmation |
| `numeric-template` | +0.16% | +0.21% | Pending targeted evaluation or confirmation |
| `intrinsic-flat` | -1.01% | -0.90% | Pending targeted evaluation or confirmation |
| `cache-budget` | +45.38% | +40.91% | Reject for throughput |
| `sized-objects` | -0.42% | -0.55% | Pending targeted evaluation or confirmation |
| `lazy-prototypes` | +0.57% | +0.65% | Pending targeted evaluation or confirmation |
| `fresh-key-dict` | +0.59% | +0.50% | Pending targeted evaluation or confirmation |

The global dictionary threshold 64→32 was evaluated separately with seven pairs
on all fifteen mini benchmarks: runtime **+1.34%**, process CPU **+1.25%**,
TypeScript **+8.93%**, GBEmu **+6.08%**. Reject it; retain threshold 64.
Binary file size was unchanged. The synthetic unique-key dictionary gain is
workload-specific and does not justify the broad regression.

Focused fixtures check prototype/missing-read mutation, reflection order and
freshness, constructor behavior, numeric promotion and lazy function prototype
semantics. The native idle-trim probe checks rejection during native callbacks,
idle release and successful rewarming of retained functions across four phases;
it released 64,468,768 requested cache bytes. Its timing is still pending.
No new engine implementation from this matrix has been merged at this checkpoint.

Further evidence and final decisions will be appended before accepting changes.

## Targeted follow-up checkpoint

These remain three-pair screens, not retention decisions:

| Candidate | Workload | Process CPU change |
|---|---|---:|
| Simple constructor replay through eight stores | Six-field construction | -27.18% |
| Exact-last capacity feedback | Six-field construction | -19.70% |
| High-water capacity feedback | Six-field construction | -21.00% |
| Exact five-to-eight-slot pools | Six-field construction / scene | -2.22% / -0.80% |
| Flat literal layouts | Scene / mixed literal and constructor reads | -9.00% / +3.57% |
| Existing JSON key-plan reuse | Repeated enumeration | -12.33% |
| Complete own-key plan | Repeated enumeration | -40.13% |
| Negative read cache | Missing fields through depth zero to four | -37.76% |
| Computed-key dictionary hint | Unique runtime keys | -19.83% |
| Fresh non-interned key dictionary hint | Unique runtime keys | -20.31% |
| Two / four / shared-action own-read cache | Polymorphic reads | +3.88% / -1.41% / +1.29% |
| Lazy ordinary function prototypes | Retained closures | -3.61% |

The dictionary hints reduce peak RSS from approximately 126 MB to 61 MB in
that synthetic workload. Exact pools did not reduce peak RSS in the scene
screen. Lazy prototypes reduce closure RSS about 21 MB but increase actual
machine code by 3,712 bytes and regress the mini suite by 0.57%.

The integer payload comparison uses the expanded tagged numeric-template
control rather than the original compiler: runtime +0.18%, process CPU +0.15%.
Its active payload is narrower but allocated capacity stays unchanged, so this
is not evidence of reduced allocation bytes.

Idle cache trimming completed seven paired four-phase native runs: CPU +0.11%,
peak RSS approximately 349.3→352.6 MB. The probe's successful release of 64.5 MB
of requested cache allocations does not establish lower resident memory.

A source-capable build with image support passed Script and Module semantics,
including direct eval and function-source retention. Same-binary source versus
image screening on all fifteen minis reduced whole-process CPU by 4.58%.
PdfJS was -26.92%, Mandreel -13.32%, while DeltaBlue was +2.04%. Serialized
images totaled 37,334,664 bytes versus 10,759,352 source bytes. These results
exclude image generation and any Python cache-helper overhead. Source maps,
function source slices and eval metadata are retained. A leftover module-only
reader check was found during review and fixed before any image timing.

Seven-pair complete mini-suite confirmations, preceded by an identical-binary
A/A calibration, are running sequentially. Targeted gains, binary cost and
semantic behavior will be considered alongside the full-suite confirmation;
no implementation from this batch has been merged yet.

The fresh seven-pair identical-binary calibration measured runtime -0.08% and
process CPU +0.02%, providing the noise control for confirmations.

# Measured interpreter optimizations

Status: four experiments and combined confirmation complete; only 64-unit GC
work batches are applied. Other prototypes remain unapplied by user decision.
Further optimization work follows [plan 099](099-engine-architecture-investigation.md).

The experiment sources are patches against the revision recorded in
[`manifest.json`](../benchmarks/engine-throughput/four-experiments/manifest.json).
The engine uses the GC64 candidate only. Measurements, validation output,
reproduction commands, and the combined result live in the
[experiment report](../benchmarks/engine-throughput/four-experiments/README.md).

## Experimental findings

1. **Small array literals give the largest independent throughput gain.** The prototype reduces
   100k-node scene wall time by 11.4% and peak RSS by 16.3%. Destructuring
   improves by 7.4%. It preallocates storage for literals of 1–256 positions,
   encodes constant element indices directly, and threads uncomplicated
   element stores. Empty, large, spread, and explicit-undefined cases retain
   appropriate generic paths. Prefix elements before a spread can still use
   the constant-index opcode.
2. **Keep fixed-slot initialization as a small conditional candidate.**
   Scene wall time improves by 1.9%; the large retained-object benchmark
   improves by 5.2%. The seven-run class follow-up is 1.2% slower for slots
   and 2.9% slower for the combined candidate. Resolve the combined regression
   before adopting the bundle.
3. **Evaluate 64-unit GC work batches separately.** Scene wall time improves
   by 7.4%, with lower p99 and maximum frame times and stable scene RSS.
   Mixed iteration RSS rises about 5%. This is a scheduling change: reducing
   clock polling alone, while preserving 32-unit work batches, is 1.1%
   slower in the control comparison.
4. **Reject the current multiplication prototype.** It increases scene wall
   time by 0.6%. Opcode frequency does not establish that another threaded
   handler pays for itself.
5. **Reject 128-unit GC work batches.** Scene RSS nearly doubles and the
   ASAN/GC_VERIFY allocation-progress test fails its live-object bound.
   The throughput gain is insufficient evidence for adoption.

The seven-run combined confirmation gives **19.5% lower wall time** for the
100k scene (1.6203 to 1.3041 seconds), **29.3% lower frame p99** (1.301 to
0.920 ms), and **16.3% lower peak RSS** (197.4 to 165.1 MiB). QuickJS takes
0.8584 seconds with 0.278 ms frame p99 and 72.6 MiB peak RSS in that run.
These gains do not close the gap to QuickJS or settle the class/RSS tradeoffs.

## Gates for any future adoption of the remaining prototypes

### 1. Array literals

- Introduce the constant-index element opcode and known-capacity allocation
  as a single independently measurable change.
- Preserve string retains/releases and both incremental and generational
  barriers. The threaded handler must check every fallback condition before
  mutating a slot.
- Preserve own properties containing `undefined`, holes, evaluation order,
  abrupt completions, and inherited non-writable indices. The dense storage
  representation uses `undefined` as a hole sentinel.
- Review bytecode metadata, fusion, register liveness, wide operands,
  disassembly, generators, and async snapshots. The prototype updates fusion
  and move elimination; the async optimization allow-list conservatively
  selects a full snapshot for the new opcode.
- Run narrow test262 array-initializer coverage using a freshly built runner,
  plus spread, generator/async suspension, and 255/256/257-position boundary
  repros. Re-run the existing GC verification target with threaded dispatch.
- Compare normal uninstrumented CLI builds as well as the temporary clock
  builds. Keep the optimization only if the scene gain and memory reduction
  reproduce without a material correctness or throughput regression.

### 2. Fixed-slot initialization

- Add the leaf fast path independently of array construction.
- Fall back when publication needs marking, an old owner needs remembering,
  or a string needs pin handling or final-reference cleanup.
- Retain initializer-temporary cleanup; removing it breaks bounded string
  ownership.
- Inspect the class hot paths and generated code: the seven-run follow-up
  retains a small class regression. This workload contains no hot array or
  object literals, so investigate code layout and shared dispatch before
  attributing the effect to literal stores. Evaluate the marginal gain on
  top of the array change before retaining a second handler.

### 3. GC work batching

- Treat 64 as a candidate work-batch size, with the existing 512-unit call
  allowance and 500 microsecond slice budget.
- Measure collection progress, peak live objects, peak RSS, and frame tails
  on retained scenes, mixed iteration, allocation-only loops, large
  containers, and native reentry. A frame measurement is not a direct
  measurement of the maximum collector slice.
- Instrument actual slice duration before accepting a cadence change:
  checking the clock less often can overshoot the nominal time budget.
- If a global batch size harms memory, investigate separate mark/sweep
  work allowances before expanding collector state or architecture.
- Do not substitute the rejected 128-unit batch or the slower polling-only
  patch for the measured 64-unit candidate.

### 4. Combined acceptance and subsequent profiling

- Retest candidates together; independent improvements are not additive.
- Keep `just bench-vdom` at its existing 10k/100k workloads and short runtime.
  Longer repeated experiments use the separate scripts in the report.
- Repair opcode profiling before selecting fused instructions. The current
  counter runs after a threaded burst and records switch-dispatched
  operations only; its pairs are not necessarily adjacent bytecodes.
- Split class construction/method calls and mixed iteration into separately
  timed phases. These experiments leave substantial gaps to QuickJS there.
- Compare throughput, frame p95/p99, median run maximum, absolute observed
  maximum, and peak RSS against both current Boomkat and QuickJS.

## Validation limits

These are isolated performance prototypes, not production-ready changes.
The existing Rosetta suite, targeted semantic/string-ownership checks, and
ASAN/GC verification provide useful gates; full test262 was not run.
The temporary high-resolution clock hook changes the one-argument behavior
of `Date.now` in experiment binaries only and must not enter the engine.

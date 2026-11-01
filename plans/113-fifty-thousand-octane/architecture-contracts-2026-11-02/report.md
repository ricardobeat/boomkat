# Shared SSA architecture acceptance

Engine checkpoint: `b5ca8c66` on `rat`. Final documentation/regression checkpoint:
`fec58fc1` (identical engine sources). Compiler flags and binary hashes are in
[metadata.json](metadata.json); platform configurations are in
[platforms.json](validation/platforms.json). No throughput claim is made.

## Contracts now exercised by native consumers

- Decoded cyclic CFG and semantic roles, WIDE/high registers, dynamic graph and
  invocation storage, sparse immutable frames, and bounded compilation work.
  The large native gateway test executes 714 bytecode words with 310 registers;
  a separate 605-word consumer completes 128 helper continuations. The closure
  startup regression exceeds the old 64-register window and verifies the
  CLOSURE result reaches both native continuation and prototype initialization.
- Generic call/allocation continuations preserve typed homes and precise boxed
  roots, reload movable VM state and distinguish before/after outcomes.
  Shared deoptimization freezes locations once and materializes logical frame
  chains at exact PCs. Executable owners stay pinned through publication.
- Native dense arrays, eight typed-array classes and own fields consume current
  SSA receivers, live layout generations and current storage. Callback/storage
  movement, aliasing and post-store recovery have real native consumers.
- Effectful inline prefixes execute child stores directly and recover inside
  the child on a later guard or unsupported operation.
- Real preheaders and external-import blocks enable total-operation LICM;
  fixed-point scalar facts feed overflow/range reasoning and bounds removal.
  Cyclic allocation includes phi edges and recovery-only uses. Numeric constants
  have no physical home and are reconstructed at operands and recovery.

## Bytecode and machine-code inspection

**Inlining:** [independent review](inline/review-report.txt),
[successful body](inline/native-005-4416.asm),
[logical-frame events](inline/runtime-events.json). At `c93c0cff`, the child store
is a native `str` at +0x668, before the late guard at +0x744. The complete BL set
contains only callee resolution, activation reservation and the shared
publication bridge; successful child execution has no ordinary function call.
Late recovery selects child ADD PC4. Callback recovery selects child CALL PC5,
with parent CALL_GLOBAL PC2. Fixture assertions verify effects are not replayed.

**LICM:** [bytecode](licm/bytecode.txt), [native body](licm/native-001-1596.asm),
[manifest](licm/manifest.json). At `f638ac8f`, the native loop starts at +0x474;
its +0x4f0 backedge returns there. Shared preheader +0x4f8 contains FMULs at
+0x500/+0x50c and FADD at +0x510, then jumps into the loop at +0x534. Native
backedges bypass the moved computation. Import paths execute it before entry.

**Bounds:** [independent review](bounds/review-report.txt),
[positive body](bounds/positive-native.asm),
[callback body](bounds/callback-native.asm). At `c93c0cff`, a dominating successful
index7 access proves a subsequent masked index in [0,7]. Both second-access
length comparisons disappear; tag, class and storage guards remain. The callback
case retains both comparisons after the helper. A supplementary
[live-register capture](bounds/callback-shrink/post-callback-bounds-events.json)
observes index7, capacity8, then logical length2 after the callback shrinks the
array: the retained native length guard exits correctly.

**Rematerialization:** [review](rematerialization/review-report.txt), [native body](rematerialization/native-000-33460.asm),
[manifest](rematerialization/manifest.json). The native embedding consumer keeps 141 distinct numeric
constants across an unknown callback and exercises late coercion and exceptions.
It records 24 native entries, 23 helper calls and two native continuations.
A separate special-value fixture preserves -0, NaN and both infinities through
callbacks, phi edges and post-store recovery. Frozen recovery uses constant
bits, while boxed references retain normal rooted ownership. At `f3316b22`,
the only helper saved-bits store is the boxed callee at +0x573c. After the
+0x70a8 helper call, integer constants are recreated from immediates and F64
constants from raw bits plus FMOV. Numeric constants have no helper saves or
restores. The downstream JOIN values still use spills: external interpreter
entries require those merges, and this change does not remove their storage.

Native captures are tied to their exact component source revisions, rather than
being presented as captures of later builds. The final combined engine below
validates their integration.

## Combined validation

- ARM64 full embedding with ASan: [PASS](validation/arm64-asan.out).
- x64 full embedding, with actual native entry assertions: [PASS](validation/x64.out).
- Local regressions, Rosetta and modules, interpreter versus stressed JIT:
  [all match, status0](validation/differential.txt).
- 80 JIT/SLJIT scripts in interpreter, normal JIT and stressed JIT:
  [80/80 match](validation/jit-panel.json). Elapsed milliseconds are normalized
  as in the repository differential runner; raw output is retained.
- Nine focused fixtures in both JIT modes with ASan, GC_STRESS, GC_VERIFY and
  POOL_BYPASS: [18/18 pass](validation/gc-stress.json).
- Additional special constant regression in three ordinary modes and both
  ASan/GC modes: [5/5 pass](validation/special-constants.json).
- NONANBOX build plus seven semantic smokes; no-JIT build plus five semantic
  smokes: [all pass](validation/platform-smoke.json). NONANBOX intentionally
  does not expose the NaN-boxed JIT.

## Deliberate limits and next phase

Effectful inlining currently expands straight-line prefixes. Branches, loops,
captures and unsupported child operations materialize the callee rather than
continuing inside a virtual activation. LICM requires a dominating shared
preheader and declines rotated-loop side entries that bypass it. Bounds proofs
stop at potentially mutating helpers. Scalar replacement still requires virtual
object reconstruction and remains deferred by the plan.

These are explicit coverage limits on the shared architecture, not evidence of
50K performance. Admission, code size, compilation cost and runtime usefulness
must next be profiled across original full Octane. Plan milestones1/5 and the
50,000 score remain open. No timing sweeps or policy-budget increases were used
to close architecture acceptance. Main was not modified by this work; plans and
evidence stay exclusively on `plans/archive`.

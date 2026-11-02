# Recoverable cyclic SSA checkpoint

Revision: **rat `3ae23aa2`**, refining architecture checkpoint `1a50864f`,
following main merge `46ddf102`, shared CFG
`91474a9c`, real-checksum mini correction `ef90365d` and loop-retirement
fix `4c74782e`. Main was neither modified nor advanced. Plans remain solely
on `plans/archive`.

This establishes bounded effectful cyclic function optimization. It does **not**
complete plan 113 or establish a 50,000 full-Octane score.

## Architecture delivered

- Canonical decoded CFG with instruction/payload/next PCs, positive control-flow
  eligibility, semantic operand roles and call windows. Continuation analysis and
  recoverable function SSA share its liveness. In particular, constant property
  keys and literal call counts no longer become false register reads.
- Published-frame whole-function SSA, with native segments before and after
  generic calls and fresh entry at loop headers. Calls, guards and polls publish
  the exact next unperformed bytecode. Native proofs do not cross an interpreted
  call. VM slots own references while native segments execute without allocation.
- Explicit effects and fixed-point availability on cyclic graphs. Scalar CSE,
  repeated loads/guards and exact own-slot forwarding are legal only while their
  reaching definitions survive every path. All stores conservatively kill memory
  facts; descriptor identity is not an alias proof. No store deletion/code motion.
- CFG liveness/interference allocation including JOIN edge operands, synthetic
  entries, recovery frames and the implicit outer latch. Spill slots and edge
  interference remain conservative. Target-derived extra function scratch homes
  remain opt-in because the separate timing panel did not establish a benefit.
- Recovery snapshots and ordinary joins retain semantic live inputs from the
  shared CFG. VM-slot ownership, descriptor preparation, argument imports and
  pinned baseline reloads remain unchanged.
- Representation widening converges before emission. Cyclic joins preserve
  fractional values and signed zero, and parallel copies stage overlapping inputs
  before committing destinations. Packed frameless storage uses explicitly
  bounded dense temporary slots.

The function lowering still has 128-word/64-register/16-block bounds and rejects
WIDE. Sparse scalable graph/frame storage, broader native calls/inlining,
allocation continuations, LICM, range/bounds proofs, general DCE, rematerialization
and allocation-derived contexts remain open. SLJIT was retained; this checkpoint
addresses frontend IR/recovery/allocation limitations rather than replacing it.

## Correctness findings and validation

The merged baseline could replay completed nested-loop stores when an SSA budget
exit caused kernel retirement. `4c74782e` preserves publication, charged work and
the exact resume PC even when replacement compilation fails. The original Navier
check occurs at frame 15; the former ten-frame mini never reached it. The mini now
runs sixteen frames, and its generator enforces that minimum.

Precise operand roles then admitted an `advect` graph formerly rejected during
emission. A cyclic phi inferred INT32 from comparison use and truncated a 16.5
bound to 16. This changed a later clamp and corrupted simulation values. Widening
to a fixed point fixes the cause; exact phi conversions also reject lossy values.
Independent review exposed a pure cyclic swap that sequential edge copies could
corrupt even with interference allocation. Bounded parallel-copy staging fixes it.

Validation at the final checkpoint:

- Local, Rosetta and module interpreter/JIT-stress suites match. Local exits 1 on
  both paths due to the selected build's feature limitations; the other suites
  exit 0. This is differential agreement, not a claim every local test passes.
- Embedding JIT checks pass, including normal/WIDE decoded roles and TONUMERIC
  with distinct source/destination registers.
- Sixteen final ASAN + GC_STRESS + GC_VERIFY + POOL_BYPASS runs pass, normal and
  stress JIT, covering effects, calls, recovery, captures, fractional/signed-zero
  bounds, nested-store budgets and original Navier16.
- Final x64 release passes allocation, effects, retirement and integer/F64 pure
  swaps in both JIT modes, plus original Navier16. ARM64 release is the timed build.
- Two Navier frames, six arrays, **202,800 values** compare exactly with the
  interpreter: zero differences. The real sixteen-frame checksum passes too.
- Pure swap statistics show 3,905 integer and 3,925 floating-point frameless
  completions. Real Navier `advect` records 868 SSA entries, 48 completions and
  791,742 charged native edges; this is active optimized execution, not fallback.

See final-suite-diff.txt, final-embedding.txt, final-asan-gc.json, final-x64.json
and pure-swap-validation.json for retained records.

## Bytecode and native evidence

The architecture checkpoint `advect` capture has 79 bytecodes, 39 VM registers, 201 SSA values,
8 joins, 98 spills and 16,552 native bytes. `advect-disassembly.txt` follows both
fractional bounds from bytecode producers through floating-point phi slots to
native comparisons. Their paths contain no float-to-integer narrowing. Nearby
`fcvtzs` operations implement explicit JavaScript `x | 0` / `y | 0` bytecodes.
The bytecode listing and native assembly are retained alongside the report.

The final recovery-liveness refinement reduces that capture to 199 values,
77 spill slots and 12,704 native bytes, with identical activation/edge counts.
On the selected successful unclamped inner path, spill accesses fall **123→84**
and scalar instructions **470→431**. Array traffic remains seven loads/one store
and descriptor/state traffic twelve loads. Cold recovery stubs separately shrink
11,540→8,084 bytes, accounting for 89.8% of the code-size saving. These are
distinct effects; the smaller exit stubs alone do not establish faster hot code.
See recovery-liveness-disassembly.txt and its path counts.

Five alternating mini pairs versus `1a50864f`: Navier −3.8% wall time, with
Richards, DeltaBlue, crypto, Box2D, mandreel, gbemu and TypeScript within about 1%.
Nine pairs versus the corrected merged baseline: sixteen-frame Navier −31.4%.
The original full suite exercises a different warmed execution regime; these
mini results are not substituted for full-suite evidence.

After the refinement, broad differential suites still match, all 202,800
inspected simulation values still agree exactly, nine refreshed ASAN/GC runs
pass and x64 recovery/fractional/allocation/retirement tests pass in both modes.
The recovery-liveness-* validation records supersede the earlier checkpoint
records where source-dependent.

Earlier allocator diagnostics on real Navier `lin_solve` reduced spills 25→20
and inner-loop memory instructions 58→47. These captures precede the final
multi-entry/phi fixes; they demonstrate the allocator mechanism, not final-suite
speed or exact final code size. Likewise, extra ARM64 scratch reduced one crypto
body's loads/stores but grew its enclosing frame/code and did not win the matched
mini panel. It remains opt-in.

`pre-retirement-mini-pairs.json` used the invalid merged Navier baseline and the
old ten-frame mini. It is a rejected diagnostic checkpoint and MUST NOT be used
as acceptance evidence or a speed claim.

## Full Octane measurement

Final alternating-pair results are pending. The driver runs unmodified original
suite algorithms, validation, warmup, deterministic settings and latency results;
only shell `load` assembly and the unused zlib `read` shim adapt the shell.
`full-octane-inputs.json` records every input hash and the assembled bundle hash.
`full-octane-pairs.py` records each result, binary hashes, process CPU, wall time
and peak RSS. No builds, tests or profiling run during the measurements.

Baseline is the merged/shared-CFG revision with only the independently validated
retirement correction applied, equivalent engine code to `4c74782e`. Candidate
is `3ae23aa2`; `revision.json` records its source and binary hashes. Both pass the
original complete suite's validations. Earlier score 6,563 is historical and is
not substituted for a current matched baseline.

The first architecture checkpoint was measured separately in
full-octane-1a50864f/: baseline scores 5,578 / 6,471 / 6,633, candidate
5,744 / 6,473 / 6,525. Median scores were 6,471→6,473 and geometric paired
score change +0.44%: essentially neutral, not a demonstrated overall win.
Navier regressed across those full pairs, motivating the recovery refinement.
All raw runs remain available; no failed checksum or obsolete ten-frame result
is counted as an accepted full-suite score.

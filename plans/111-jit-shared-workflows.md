# 111: Shared JIT opportunities beyond Richards and DeltaBlue

Status: investigation complete, 2026-10-27. Baseline `rat` at `bd44daea`.
Diagnostics committed as `d569b9ed`; performance experiments remain isolated.

The strongest common targets are complete buffer-processing kernels,
construction followed by initialization and calls, and scanners whose state
crosses small helpers. Captured/global state and recurring property misses
connect these workloads. Coverage must be assessed alongside generated-code
quality: admitting more code improved Mandreel and zlib but made Gameboy and
Navier–Stokes slower in the capacity experiment below.

## Evidence and scope

All 13 other `bench/mini` programs were run with and without JIT using
`SLJIT_STATS + OP_PROFILE`. The table's bytecode counts cover the whole mini,
including setup. They count executed interpreter bytecodes, including fused
operations, not native instructions or time.

For CPU attribution, each benchmark's existing setup/teardown and checks were
retained, and its timed run loop was extended to at least seven seconds. Each
phase was sampled for three seconds, starting 0.6 seconds after its run marker.
This produced 16 profiles of roughly 2,200–2,330 self samples. The binary used
`SLJIT_STATS + SLJIT_MAP`, **without OP_PROFILE**. Same-process address maps now
include the loop tier. Generated percentages include body, entry, exit and
call code, as well as loop code. The profiles represent warmed execution after
setup, not the original mini's timing interval. They are diagnostic samples,
not estimates of uninstrumented speedups. Unknown generated addresses remain
separate; the largest unknown share was Gameboy's 1.62%.

Builds, benchmarks and CPU sampling were not run concurrently. Timings below
use separate normal O2 arm64 builds without counter/map instrumentation,
fresh processes, and alternating pair order. No full Octane aggregate was
remeasured here; plan 110 contains the preceding full-suite measurements.

| Benchmark | Interpreter bytecodes, JIT off → on, millions | Generated CPU samples | Main remaining workflow |
|---|---:|---:|---|
| Box2D | 66.35 → 52.67 | 10.9% | Solver loops, vector fields and small methods |
| CodeLoad | 0.31 → 0.30 | ~0% | Parsing and bytecode compilation |
| Crypto | 163.23 → 10.27 | 68.7–70.3% | Limb-array multiply, shift, carry and reduction loops |
| Earley–Boyer | 35.74 → 27.56 | 3.0–6.2% | Recursive pair/tree construction, binding writes and calls |
| Gameboy | 102.27 → 54.26 | 10.4% | Audio/pixel buffers, state-object fields and dispatch helpers |
| Mandreel | 656.84 → 511.33 | 5.2% | Typed-heap loads/stores, integer indices and tiny global calls |
| Navier–Stokes | 178.61 → 4.58 | 89.6% | Native numerical stencil loops |
| PdfJS | 55.86 → 40.82 | 4.6% | Byte decoding, string scanning, token construction and collection |
| RayTrace | 34.01 → 17.99 | 18.0% | Vector/color constructors, argument forwarding and field access |
| RegExp | 17.44 → 16.89 | 0.2% | Native regex execution and its runtime |
| Splay | 25.18 → 22.01 | 5.5% | Recursive literals, string fields, tree reads/writes and collection |
| TypeScript | 226.34 → 198.30 | 4.4% | Scanner helpers, character access, AST construction and traversal |
| zlib | 2,295.39 → 1,599.25 | 17.3% | Typed-heap kernels, captured buffers and WIDE bytecode |

Sources: [counter census](111-jit-shared-workflows/census-summary.json),
[CPU profiles](111-jit-shared-workflows/samples-categorized.json),
[compiler diagnostics](111-jit-shared-workflows/diagnostic-summary.json).

## Shared workflows to cover

### 1. Load buffer → compute integer index → read/update → repeat

Primary beneficiaries: Mandreel, zlib and Gameboy; also Crypto, Navier–Stokes
and PdfJS. This crosses ordinary dense arrays and typed-array heaps, so the
optimizer needs distinct representations with a common loop/control-flow IR.

The residual Mandreel stream contains 94.2M `GETGLOBAL`, 67.2M `SHRI`, 60.6M
`GETPROP`, and 32.4M `PUTPROP` operations. Its common sequence is global heap
load, index addition, shift, indexed read/write. zlib has 144.2M `GETCAP` and
123.7M `GETPROP` operations left, plus 256.0M WIDE dispatches. These are
concrete repeated memory kernels, not a need for an unrelated opcode list.

The two hottest Mandreel functions, `sortMinDown` and `sortMaxDown`, account
for 72.9% of its residual threaded entries. Both fail at the emitter's
guard/link capacity. zlib's `a6` accounts for 38.5% and hits the same limit;
`a1` accounts for another 19.0% and is rejected at WIDE. That function has
37,098 bytecode words and 518 registers. A native-region decoder must normalize
WIDE and preserve original PC boundaries; increasing a small-function limit
does not solve this.

Implement connected hot-loop regions, int32/uint32 arithmetic and conversions,
bounds/index checks, and stable buffer/environment loads. Keep values and
data pointers live across blocks. Revalidate pointers and binding assumptions
after calls or other operations that can invalidate them. Preserve detached
buffer, bounds, prototype/hole, signed-shift and numeric-conversion semantics.
Use the existing small-loop SSA path as a quality reference.

Crypto and Navier–Stokes already remove 93.7% and 97.4% of interpreter
bytecodes. Crypto's samples concentrate in `am3` multiply/bitwise/indexed work;
Navier's `lin_solve` loop alone accounts for 73.5% of all sampled CPU. Those
need fewer native instructions and memory accesses. More baseline coverage
alone has little reach into their dominant work.

### 2. Construct → initialize fields → call methods → return an object

Beneficiaries: Splay, RayTrace, Earley–Boyer, Box2D and TypeScript; also parts
of PdfJS. Allocation continuations are only the first operation in this chain.

Splay's `GeneratePayloadTree` accounts for 61.7% of residual threaded entries.
Its literal workflow is `NEWOBJ_SHAPE → NEWARR_CONST → INIT_SLOT`, followed by
string concatenation or recursive calls and another `INIT_SLOT`. The whole
mini executes 2.016M interpreted `INIT_SLOT` operations. The JIT allocation
helper succeeds, but this unsupported initialization stops the continuation;
the entry retires after short runs. Only 16 recorded exits at that site do
**not** mean it is unimportant. The function retains eight other entries but
its native entry no longer covers the common construction sequence.

Add fixed-layout slot initialization with correct value ownership and write
barriers, then connect recursive calls and string-producing helpers to their
compiled continuations. `th_init_slot` already specifies the empty-slot
contract; reuse its semantics. String concatenation and reference-counted
slot replacement need explicit ownership and completion status, not raw stores.
Splay's warmed CPU profile also has 17.4% in identified GC routines: native
construction cannot eliminate collection cost by itself.

RayTrace's constructor factory returns a wrapper that invokes
`this.initialize.apply(this, arguments)`. The wrapper is rejected for mapped
arguments. The mini records 530,782 `NEW_OBJ` exits, and samples show work in
`th_apply_args`, `th_new_obj`, `th_putthisc` and return handlers. Extend the
native constructor/call pipeline to safe argument forwarding and initializer
continuations. Mapped-argument aliases, constructor return values, stack
growth and exceptions must remain recoverable. This also creates the basis
for later escape analysis of short-lived vectors and pairs; allocation
elimination is not yet demonstrated.

### 3. Read scanner state → inspect a character → classify → advance/build token

Primary beneficiaries: TypeScript and PdfJS. TypeScript's `innerScan` and
`peekChar` each contribute about 8.6% of residual threaded entries. `peekChar`
is a 17-op method that reads `pos`, `len`, `src`, then calls `charCodeAt`.
The loop tier has a guarded character-access intrinsic, but the function tier
does not provide the same general continuation. Compiling a prefix of the
1,182-op `innerScan` does not connect this helper chain.

Extend string character intrinsics and short-string comparisons to function
regions, specialize the builtin identity, and inline/retain scanner state
across small helpers. Preserve UTF-16 indexing, out-of-range results and
overridden methods. Token-producing substring/concatenation/allocation paths
need rooted resumable helpers. PdfJS's `Type1Parser_extractFontProgram`
contributes 17.6% of residual threaded entries and repeatedly combines indexed
string access, separator tests, captured cursor updates and token creation.
Its CPU profile has 23.1% in identified GC routines, so reducing temporary
strings/closures can matter alongside continuation coverage.

### 4. Read/write shared state → call a small helper → resume the caller

This connects the buffer, scanner and recursive-object workflows. Beneficiaries
include Earley–Boyer, Mandreel, zlib, PdfJS and the deterministic RNG used by
Splay/RegExp.

Earley–Boyer records 342,115 `RESOLVEVAR` exits, concentrated in the two Boyer
rewrite/unification functions. The interpreter already has a guarded cached
assignment-target path. Extend native binding access to the complete
resolve/read/write sequence, retaining scope-head, shape/recycle, shadowing,
TDZ and mutability checks. The current writable-capture prologue supports one
fastint capture; that is not general shared state.

The shared-register native ABI accepts explicit-window `CALL` and
`CALL_UNDEF_THIS`. Fused `CALL_GLOBAL`/`CALL_VAR` can take existing inline paths,
but do not have the equivalent general native-call path. Mandreel has 12.9M
interpreted `CALL_GLOBAL` operations. Lower these into the same guarded callee
and argument-window representation, then use the existing call-entry/linking
machinery. Keep the caller native after the callee and any recoverable helper;
a call that immediately exits again is a poor use of code budget.

### 5. Repeated property misses should establish a cheaper subsequent path

Gameboy spends 464/2,280 self samples (20.4%) in `sljit_native_read` alone.
That helper walks prototype owners and searches their shape-property chains
on every use. It resumes compiled code, but does not install a new fast read
target. This is a concrete next use of patchable IC targets or compact data
arms, applicable to state-object methods in Gameboy, Box2D, TypeScript and
RayTrace. The earlier DeltaBlue profile also found material read-helper cost.

Start with a bounded data-property cache keyed by receiver/owner shape
generation and prototype epoch, and update it at the miss continuation.
Trace embedded owners/shapes and invalidate or unlink before retirement.
Once a stable path exists, the optimizer can eliminate repeated field loads
and guards within regions. Adding more calls to the current shape-search
helper merely preserves native continuity while keeping the repeated work.

## Two controlled experiments

### Executable budget alone: 1 MiB → 16 MiB

Three interleaved pairs for every other mini, with no eviction-policy change.
Most median changes were within about 2%; TypeScript increased 3.9%. No broad
gain was established. The larger diagnostic build really admitted more code:
Box2D grew from about 1.0 to 2.3 MiB, Gameboy to 1.9 MiB, and TypeScript to
7.7 MiB. These byte counts include diagnostic instrumentation and are not RSS.

This does not invalidate a small initial budget with useful growth. It shows
that admission should reward executed useful work and connected hot loops,
not just available bytes. A full-suite shared heap can have additional order
effects; these fresh-process minis do not measure those.
[All timing pairs](111-jit-shared-workflows/budget-pairs.json).

### Guard/link table: 2,048 → 8,192 entries

The diagnostic change distinguishes this limit from generic emission failure.
It occurs in Mandreel's 290/308-op sorting kernels, zlib's 429-op `a6`,
Navier's 200-op `set_bnd`, and Gameboy's 505-op background renderer.

For a counterfactual, both variants used the same fixed 16 MiB code budget.
The experiment enlarged both `LoopEmitter.links` and the matching exit-fixup
table, with no opcode coverage change. Five alternating pairs were run for
the first four rows; three for Box2D/TypeScript.

| Mini | 2,048 entries | 8,192 entries | Time change |
|---|---:|---:|---:|
| Mandreel | 796 ms | 615 ms | −22.7% |
| zlib | 4,795 ms | 4,326 ms | −9.8% |
| Navier–Stokes | 203 ms | 210 ms | +3.4% |
| Gameboy | 312 ms | 325 ms | +4.2% |
| Box2D | 222 ms | 222 ms | neutral |
| TypeScript | 1,276 ms | 1,276 ms | neutral |

Mandreel's residual threaded entries fall from 503.5M to 101.2M; zlib's from
1,584.0M to 829.3M. These include retries and are not a CPU-time fraction.
Diagnostic emitted code grows from 2.0 to 5.6 MiB in Mandreel and from 0.59
to 1.17 MiB in zlib. Removing most interpreter dispatches does not remove
the cost of generic generated operations, guards and slot traffic.

The static 8,192-entry emitter exceeds C3's normal 64 KiB stack-object limit;
the experiment explicitly used `--max-stack-object-size 262144`. It is not a
shipping design for a small-memory engine. Use bounded compiler scratch
storage, compact guard/fixup records and shared exits, and reduce duplicated
guards through type/shape propagation. Preserve the better loop tier when a
generic function region would displace it. Reprofile the chosen tier rather
than assuming that more admitted bytecodes are faster.

[Timing pairs](111-jit-shared-workflows/guards-pairs.json),
[coverage/code-size comparison](111-jit-shared-workflows/capacity-comparison.json),
[experimental patch](111-jit-shared-workflows/capacity-experiment.patch).

## Implementation order and success criteria

1. Fix bounded guard/fixup storage and hot-region selection together with
   repeated-guard elimination. Use Mandreel/zlib as initial coverage gates,
   and Crypto/Navier/Gameboy as code-quality gates. Keep executable memory
   admission separate from temporary compilation memory. Add canonical WIDE
   decoding and original-PC recovery maps before admitting zlib's large body.
2. Make recurring property misses learn a bounded fast path. Gameboy's read
   helper is the clearest CPU target; retain shape-generation/prototype-epoch
   invalidation and incoming-link retirement rules.
3. Complete construction continuations: fixed-slot initialization, owned
   string results, constructor/argument forwarding, and connected recursive
   calls. Measure Splay, RayTrace and Earley–Boyer together; include GC time
   and allocation volume rather than counting only removed exits.
4. Connect scanner/helper chains and captured/global calls. Unify the call
   lowering with the existing shared-register ABI, extend character intrinsics
   into function regions, and propagate scanner types/shapes across blocks.
   Measure TypeScript and PdfJS, with Mandreel and closure-heavy workloads as
   additional call/binding tests.

Across these steps, optimize useful work per byte and per instruction: unboxed
integer/FP values, reusable data pointers and fields, fewer guards, and live
register allocation across blocks. SLJIT already supplies calls, contexts,
fragments and patchable targets; Boomkat must select regions, establish
invariants and maintain recoverable state. The experiments demonstrate two
meaningful opportunities, not a 10× gain or a new full Octane score.

CodeLoad and RegExp should have separate goals. CodeLoad's profiles spend
60–78% in identified lexer/parser/compiler/AST routines, with only 1–2% in
identified interpreter routines. RegExp spends about 59% in regex-library
routines alone. Better JS wrappers may help, but those costs primarily need
frontend and regex/runtime work.

## Validation and retained artifacts

- 26 interpreter/JIT counter runs and 13 diagnostic mini runs passed.
- All 16 sampled phases completed successfully, retaining original benchmark
  checks. Initial sampling attempts blocked on buffered output; they were
  discarded and all phases were recollected with continuous output draining.
- 22 existing JIT fixtures passed in interpreter, JIT and JIT-stress modes
  (66 comparisons; the small-function fixture's elapsed milliseconds were
  normalized, its result retained). Four focused fixtures also passed with
  the final normal build.
- Final diagnostics explicitly confirmed guard-table exhaustion in all four
  targeted workloads. Both counterfactual timing runs completed their checks.
  These prototypes were not given a full semantic/ASan release gate and are
  not committed to the engine.
- Normal and statistics/map builds succeeded; `git diff --check` passed.
  Engine changes only improve reporting and loop address attribution.

The evidence directory includes raw compressed counter logs, same-process
CPU samples/maps, diagnostic logs, parsed summaries, all timing pairs,
validation results, exact collection drivers and a build/binary manifest.
The drivers retain their original local paths under `/tmp/boomkat-jit-common`.
To recreate long sample inputs, replace only the final harness's
`for (var i = 0; i < N; i++) b.run();` with a `PROFILE_RUN` marker and a
`do { b.run(); } while (Date.now() - profileStart < 7000);` loop. Do not
include `OP_PROFILE` in CPU or timing builds.

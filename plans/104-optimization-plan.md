# Non-JIT optimization plan

Status: planned; implementation has not started.

This plan covers the eight targets in `/tmp/opt.txt` and the implementation
costs measured in the guarded bytecode inliner. Work starts only after an
explicit instruction to proceed. Writing this plan does not start the work.

## 1. Objectives and completion criteria

Improve interpreter execution and compilation costs while preserving the
engine's supported JavaScript semantics, low memory use, and portability.
Each optimization needs an independently reviewable commit, a focused semantic
check, and a measurement against its own baseline.

An individual target is complete when:

1. Its measured hot path has an implemented fast path, or measurements establish
   that the proposed path has no useful opportunity and document why.
2. Guard refusal preserves evaluation order, already evaluated operands,
   exceptions, register ownership, and GC roots.
3. Relevant focused tests and narrow test262 runs pass.
4. Unprofiled release measurements demonstrate the result. A change without a
   repeatable performance benefit stays experimental or is omitted from the
   integration branch.
5. Code size, peak RSS, bytecode growth, and persistent cache metadata are
   recorded where the change can affect them.

Do not change test262 exclusions to accommodate an optimization. Preserve the
strict/sloppy distinction and existing feature gates. Keep diagnostics,
portable bytecode, and the non-NaN-boxed representation working.

## 2. Starting state and evidence

Relevant commits:

- `7976a3d3`: opt-in guarded bytecode leaf inlining.
- `2ccbb7ef`: corrected opcode profiling on the inlining branch.
- `aab1fea3`: the profiler fix cherry-picked onto `main`.

Recheck these commits and the current branches before implementation; do not
assume the checkouts remain at these revisions.

The profiler counts completed threaded instructions, switch instructions, and
additional bytecodes consumed by fused handlers. Its counters distinguish
`total_dispatches`, `executed_bytecodes`, `threaded_dispatches`,
`switch_dispatches`, and `fused_bytecodes`. `just test-opprofile` checks opcode
and pair counts against a switch-only reference.

The inlining measurements use the same release binary with expansion disabled
and enabled. Timings come from processes without opcode or inline profiling.
Opcode counts come from separate profiling runs.

| Metric | Richards | DeltaBlue |
|---|---:|---:|
| Executed bytecodes, baseline | 80,649,519 | 67,319,910 |
| Executed bytecodes, inline | 96,544,819 | 98,097,615 |
| Additional bytecodes | 15,895,300 | 30,777,705 |
| Additional `LDUNDEF` | 7,469,700 | 12,877,380 |
| Additional `LDREG` | 2,134,200 | 4,469,580 |
| Switch dispatches, baseline | 9,471,436 | 4,786,820 |
| Switch dispatches, inline | 19,971,566 | 20,674,482 |
| Calls avoided | 1,067,100 | 2,739,600 |
| Identity misses | 0 | 804,660 |
| Later guard misses | 0 | 240 |
| Latest five-run median slowdown | approximately 18.6% | approximately 30.9% |

Interpretation:

- Initialization accounts for approximately 47% and 42% of the net increase in
  executed bytecodes. The ordinary call path performs initialization in native
  loops; the inliner emits separate interpreted initialization instructions.
- Richards' inlined predicate has seven registers. Every register it reads is
  assigned before use, and two registers are unused. Its seven emitted scratch
  initializations are unnecessary.
- The inliner executes approximately 10.50 million `INLINE_*` instructions in
  Richards and 16.68 million in DeltaBlue. These instructions have switch
  implementations but no threaded handlers.
- Richards regresses with no identity misses. Candidate misses are a secondary
  problem, rather than the explanation for the whole regression.
- Counts identify added work; they do not establish exact CPU-time attribution
  or predict the speedup of a proposed fix.

The Octane study also identifies costs outside the inliner: typed-array access
in zlib/PdfJS, captured bindings in Navier-Stokes, eager variable-cache clearing
in CodeLoad Closure, compiler work in CodeLoad jQuery, string access in
TypeScript/PdfJS, and forwarding constructors in RayTrace. Reconfirm those
opportunities against the current baseline before implementing them.

### Octane work to reconcile before implementation

The Octane worktree contains relevant committed work that must be reviewed
before implementing overlapping targets:

| Commit | Existing work | Plan intersection |
|---|---|---|
| `39045285` | Threaded scope reads and declarations across activations | T2 cache hits and rearming |
| `5018a7ea` | Quadratic name scans and redundant liveness sweeps | T7 compiler-pass work |
| `cc61949d` | Lean constructor entry and re-dispatched calls | T8 constructor/call transport |
| `3fc8b606` | Indexed-property lookup consolidation and block element moves | T5 lookup/fusion groundwork |

Audit their applicability and dependencies, then reuse accepted work. Do not
implement a second version solely because the integration baseline lacks it.

Two additional experiments are uncommitted in that worktree:

- A compiler proof that an identifier is global, allowing function bodies to
  emit `GETGLOBAL`. It adds atom lookup and retains the atom slot table through
  compilation. This complements T2; it does not optimize captured names.
- A GC root-rescan policy intended to permit removal of threaded register
  publication checks. This is a separate GC-policy experiment, subject to G1
  below, rather than an accepted handler simplification.

The inspected snapshot has both experiments disabled by temporary early
returns/flag values, while the threaded publication checks are restored. Its
existing binary is not a valid baseline. Preserve the saved patch and clean
copies; reconstruct experiments in isolated checkouts instead of treating that
binary as evidence about a particular source configuration.

The combined experiment reports approximately 57% more retired instructions
and 63% more cycles in Navier-Stokes. The reported hot reads are captured
`GETVAR` references to `FluidField` bindings. These observations strengthen T2's
priority but do not attribute the regression to either experiment. Retired
instructions and cycle counts must include counter configuration and repeated
samples; cycles still respond to CPU/cache conditions.

### G1 — Validate the GC policy before removing publication checks

Ownership: integration review with Runtime. Keep this experiment independent
of T1–T8 commits and measurements. Unrelated optimization work can proceed
under the existing GC policy.

The proposed one-time rescan sets `gc_stack_rescanned` before scanning activation
roots. That scan can enqueue new marking work, and budgeted marking can yield
before sweeping. Establish what protects root updates after that yield; a flag
that merely records an earlier rescan is not a proof that current roots are
covered. This is an unresolved invariant, not a demonstrated failure.

Validation requirements:

1. Write down the marking invariant, the exact mark-to-sweep transition, and
   every point at which mutator execution can resume. Account for activation
   creation, returns, register copies, environment references, and native roots.
2. Establish how roots published after a rescan remain protected if the rescan
   discovers work and marking resumes incrementally. Preserve heap-edge
   barriers and root-span tracking; publication checks are not ownership checks.
3. Add a deterministic test that forces a rescan to discover work, exhausts the
   marking slice, resumes the mutator, and moves another reachable value into
   an already-scanned frame before the next mark-to-sweep transition. The
   existing allocation-churn test does not deliberately force this sequence.
4. Cover major/minor collection, tiny slice budgets, cross-frame arguments and
   returns, environment-reference values, and collections entered from native
   code. Rebuild and run the relevant GC_VERIFY, GC stress, and sanitizer checks.
5. Compare four freshly built configurations from the same source baseline:
   baseline, proven-global specialization alone, rescan plus publication-check
   removal alone, and both together. Include a control retaining the compiler
   scaffolding with global emission disabled if the regression remains.
6. Resolve the Navier-Stokes regression and report rescan work, cache misses,
   invalidation/rearming, instructions, cycles, and release timings separately.

Acceptance: the root-publication invariant is demonstrated across yields,
deterministic tests pass, and the policy's independent performance/memory result
is acceptable. Until then, retain the existing publication checks in new
threaded paths. Identity, accessor/proxy, and coercion guards remain necessary
for JavaScript semantics regardless of the GC-policy result.

## 3. Worktrees and parallel ownership

Use three parallel implementation lanes and a separate integration worktree.
The paths and branch names below are proposed names. Check that they are free;
never overwrite an existing worktree, branch, or uncommitted change.

| Lane | Proposed worktree | Proposed branch | Targets |
|---|---|---|---|
| Runtime | `.worktrees/opt-runtime` | `opt/runtime-fastpaths` | T1, T6, T8 |
| Bindings | `.worktrees/opt-bindings` | `opt/bindings-and-invalidation` | T2, T3 |
| Compiler | `.worktrees/opt-compiler` | `opt/compiler-and-inlining` | T4, T5, T7 |
| Integration | `.worktrees/opt-integration` | `opt/non-jit-integration` | Review, merge, combined measurements |

At the start:

1. Record repository status and identify unrelated edits.
2. Create the integration branch from the current `main`, including the profiler
   fix exactly once.
3. Bring in the inlining implementation commit `7976a3d3` if it is absent.
   Resolve recipe conflicts without duplicating the profiler fix. Keep inlining
   disabled by default.
4. Audit the overlapping Octane commits and reconstruct any selected experiment
   without its temporary hacks. Keep GC-policy validation separate.
5. Build and establish the shared baseline before branching the three lanes.
6. Build every output in its worktree's persistent `out/build/<target>/`
   directory. Do not share mutable build directories between worktrees.

### Shared-file boundaries

- Runtime owns typed-array, string, and constructor fast-path implementations.
- Bindings owns environment invalidation, capture validity, `VarICEntry`
  changes, and the common cache hit/fill/rearm rules.
- Compiler owns inline expansion, register/dataflow modeling, fusion rules,
  optimization-pass interfaces, and `INLINE_*` handlers.
- Both Runtime and Compiler edit `vm_execute_threaded.c3`. Keep changes to
  separate helpers and handler-table entries, and integrate them explicitly.
  Do not replace a shared file with another lane's complete copy.
- Runtime coordinates constructor-recognition hooks with Compiler before
  changing `CompilerContext.finish()` or persistent function metadata.
- Bindings publishes its cache-validity interface before Compiler adopts it
  for inline free-variable reads. Inline reads must use the callee's scope.
- Coordinate every opcode or persistent metadata addition across encoding,
  disassembly, dataflow analysis, feature checks, serialization, and tests.
  Prefer existing bytecodes and existing runtime representations.

## 4. Measurement protocol

### Baseline and artifacts

Record commit IDs, compiler version, build flags, platform, benchmark source
checksums, repetition counts, and the command used. Keep baseline and candidate
binaries separately identifiable.

Benchmark sources are currently available under
`.worktrees/octane/bench/mini/`. A reusable measurement script must accept an
explicit corpus directory and report missing sources. It must not silently
skip unavailable benchmarks or depend exclusively on that worktree path.

Use `test/benchmarks/non-jit/<target>/` for reviewable measurement artifacts:

- `results.json`: individual timing samples, medians, ratios, and build data.
- `profiles.json`: instruction counts and relevant allocation/cache counters.
- `README.md`: commands, source checksums, conclusions, and limitations.

Preserve benchmark licensing when retaining source excerpts or fixtures.

### Timing and profiling

1. Warm up each configuration in a separate process.
2. Run at least seven unprofiled samples per configuration, alternating order.
3. Record both process wall time and the benchmark's internal elapsed time when
   available. CodeLoad must distinguish parsing/compilation from execution.
4. Repeat an apparent benefit in a second batch before enabling it by default.
5. Run timing batches without concurrent builds or other benchmark batches.
   Parallel implementation does not imply parallel performance measurement.
6. Collect opcode, call, allocation, and cache diagnostics in separate runs.
   Never use profiling-build elapsed time as release performance evidence.
7. Attribute instruction reductions separately from time reductions. Use a
   sampling profile when counts cannot explain the result.
8. Investigate repeatable cross-benchmark regressions above 2%; treat effects
   within baseline variation as inconclusive rather than a win.

### Focused correctness checks

Use local repros, the relevant narrow test262 directories or canonical single
tests, and `just rosetta` at integration checkpoints. Do not run the full
test262 corpus as part of each optimization's debug loop.

Run `just test-opprofile` after adding threaded handlers, fused execution, or
new dispatch paths. Extend its focused cases when a new handler consumes
multiple bytecodes or can partially complete before returning to the switch.

## 5. T1 — Threaded typed-array reads and writes

Lane: Runtime. Primary benchmarks: `zlib.js`, `pdfjs.js`.

### Inspect and measure

- Inspect indexed `GETPROP`, `GETPROP_CACHE`, and `PUTPROP` handling in
  `src/vm/vm_execute_threaded.c3` and `src/vm/vm_execute.c3`.
- Reuse the conversion and memory rules in `src/builtins/typedarray.c3`,
  especially `ta_read_element_checked`, `ta_load_element`, `ta_coerce_element`,
  and `ta_store_scalar`.
- Use buffer/view checks from `src/builtins/arraybuffer.c3` and the existing
  view representation. Measure access types before choosing initial classes.
- Count typed-array access refusals separately from ordinary-array misses.

### Implementation sequence

1. Add threaded reads for the Number-backed element classes present in the
   measured loops, using nonnegative integer indices and current view bounds.
2. Add writes for numeric values whose conversion cannot invoke JavaScript.
   Share existing integer wrapping, float conversion, and clamping semantics.
3. Check the current backing buffer and view state before every direct access.
   Do not retain a raw backing pointer across a call, detach, resize, or other
   operation that can invalidate it.
4. Leave proxies, coercing keys/values, unsupported classes, and uncertain
   buffer states on the ordinary path before making an observable change.
5. Consider additional classes only after the first read/write result is
   measured. BigInt element reads can allocate; they need a separate ownership
   and safepoint design rather than being treated as Number loads.

### Checks and acceptance

Cover signed/unsigned values, wrapping, clamping ties, NaN, infinities, negative
zero, byte offsets, bounds, detached buffers, fixed and length-tracking views,
and coercions that detach or resize a buffer. Check negative zero and
noncanonical numeric property keys through the normal fallback.

Start with existing `test/typedarray_elems.js`,
`test/typedarray_elements_are_own_properties.js`, and targeted tests under
`built-ins/TypedArray`. Select class-specific cases according to the classes
implemented. Verify store strict/sloppy behavior and single evaluation of keys
and values.

Acceptance: the measured numeric accesses remain threaded, semantic checks
pass, and zlib/PdfJS show a repeatable benefit without persistent buffer-pointer
or per-element metadata growth.

## 6. T2 — Captured-variable and outer-binding access

Lane: Bindings. Primary benchmark: `navier-stokes.js`. Secondary:
Richards/DeltaBlue inline binding reads.

### Inspect and measure

Audit `src/compiler/captures.c3`, `capture_slots.c3`, `cells.c3`,
`src/vm/vm_captures.c3`, closure creation in `vm_control.c3`, and the GETVAR /
GETCAP / GETCELL handlers.

The engine already has capture vectors, snapshot values, and mutable capture
cells. Identify which Navier-Stokes references still walk environments and why;
do not add another capture representation without demonstrating a gap.

Separate proven-global classification from captured-binding acceleration.
Inspect the Octane `is_free_global_name` proof and its atom-table lifetime
requirements. Classify Navier-Stokes' captured reads independently, and measure
why cache hit/rearm behavior differs in the regressing configuration before
changing that behavior again.

### Implementation sequence

1. Classify hot reads as immutable captured values, mutable cells, stable
   environment slots, shadow-guarded slots, or dynamic lookups.
2. Repair missed compiler classification where the existing capture machinery
   can represent the binding correctly.
3. For remaining stable slots, validate ownership, shape/storage changes,
   shadowing, and TDZ before using a cached location.
4. Keep mutable bindings live: do not replace a mutable capture with a value
   snapshot. Re-read storage that can move instead of retaining an invalid
   raw slot pointer.
5. Expose a reusable validity path for the inliner's callee-scoped reads.
   Preserve `with`, `@@unscopables`, eval shadowing, and live module bindings.
6. Review proven-global emission as a separate commit, including strict/sloppy
   reads and stores, lexical TDZ, enclosing eval/with scopes, and module code.
   Keep atom lookup storage alive until its final compiler consumer and account
   for the resulting peak compilation memory.
7. Check every store selected by the global classification. The reported global
   accessor setter bug is a prerequisite: fix it or keep affected stores on a
   correct path. Avoiding setter cases in the optimization test is insufficient
   when the optimization makes those paths newly reachable inside functions.

### Checks and acceptance

Use existing capture and closure fixtures, including
`test/test_capture_analysis.js`, `test/test_lexical_closure_capture.js`,
`test/loop_capture_storage.js`, and `test/closure_uncaptured_loop_var.js`.
Add focused cases for two closures sharing a template but different captures,
mutation after closure creation, per-iteration captures, environment storage
growth, TDZ, eval shadowing, and GC between creation and invocation.

Acceptance: hot references use existing capture/cell or validated slot paths;
environment-walk counts fall; Navier-Stokes improves; closure retention and
metadata growth remain bounded.

## 7. T3 — Lazy variable-cache invalidation

Lane: Bindings. Primary benchmark: the Closure workload in `code-load.js`.

### Current mechanism

`env_declare_var` and `env_declare_global_func` call
`Heap.invalidate_var_ic_entries()` when eval introduces a binding. That method
walks compiled functions and clears their variable caches. `var_ic_filled`
avoids redundant sweeps until a cache is filled again.

Relevant files: `src/env.c3`, `src/heap.c3`, `src/hobject.c3`,
`src/vm/vm_execute.c3`, `vm_execute_threaded.c3`, and `vm_calls.c3`.

### Implementation sequence

1. Inventory every variable-cache reader, including fused calls, writes,
   typeof, rearming, and any new inline-binding cache.
2. Add a binding-resolution generation distinct from the shape-recycle epoch.
   Eval-created shadowing and shape/storage lifetime are different validity
   conditions.
3. Advance the generation at the existing invalidation triggers. Stamp a cache
   at successful fill/rearm and reject stale entries before dereferencing
   cached environment, owner, or slot data.
4. Update every hit path in one commit; a partial rollout can make one opcode
   observe stale bindings while another resolves correctly.
5. Preserve GC pruning of weak cache references. Lazy semantic invalidation
   does not replace lifetime validation or weak-cache cleanup.
6. Define wraparound and heap-reset behavior explicitly. Use a rare complete
   clear if needed on generation wrap; avoid returning an old generation to a
   still-valid cache.

### Checks and acceptance

Exercise direct and indirect eval, new `var` and function declarations,
repeated declarations, deletion/redeclaration, lexical collisions, sloppy
implicit globals, `with`, GETVAR/TYPEOFIDENT, and CALL_VAR fallbacks. Include
heap-reset reuse through the canonical test262 worker.

Measure invalidation invocations, caches scanned, stale hits rejected, and
cache rewarming. Acceptance: ordinary eval binding introduction performs no
compiled-function/cache sweep, every reader rejects stale resolution, and the
target CodeLoad workload improves without a repeatable hot-loop regression.

## 8. T4 — Make guarded tiny-method inlining economical

Lane: Compiler. Primary benchmarks: `richards.js`, `deltablue.js`.

Relevant files on the inlining branch: `src/compiler/inline.c3`,
`src/compiler/entry.c3`, `src/vm/vm_inline.c3`, `vm_execute.c3`,
`vm_execute_threaded.c3`, `src/inline_stats.c3`, and `src/bytecode.c3`.

Retain and modify the inliner. Its identity-guarded expansion, ordinary-call
fallback, register remapping, and source-location handling remain useful.
Proven-global specialization and inlining address different costs; improving
global access does not remove the potential benefit of avoiding call frames.

Keep the current one-level expansion and caller growth budget during this
work. Larger scope is not a substitute for making existing sites profitable.

### I1. Correct scratch initialization

- Replace the branch-triggered `uint::max` initialization mask with a
  control-flow analysis of registers read before definite assignment.
- Initialize missing formals when needed. Initialize locals only on paths
  that need their JavaScript default value.
- Do not initialize unused register numbers merely because they fall below a
  register high-water mark.
- Preserve valid tracked values in reused caller scratch slots; use ordinary
  ownership-aware stores when overwriting them.
- For Richards' measured predicate, confirm that all seven per-call scratch
  `LDUNDEF` instructions disappear.

### I2. Remove unused setup and diagnostic instructions

- Omit `INLINE_COMMIT` when inline profiling is disabled. Count successful
  inline returns only when requested; loaded profiling bytecode must still
  execute correctly.
- Materialize `this` only when the copied body needs it. Map method receivers
  directly where safe, and preserve arrow lexical `this`, strict undefined
  `this`, and sloppy substitution/boxing fallback.
- Copy only parameters the body needs. Alias read-only inputs only when later
  writes cannot corrupt the operands retained for fallback.

### I3. Thread retained inline operations

- Add threaded handlers for retained identity, receiver, type, binding, and
  profiling operations, or replace them with fewer fused instructions.
- A successful guard must continue inside the threaded burst. A refusal must
  reach the ordinary call with the original callee, receiver, and arguments.
- Keep heap publication, reference release, GC tracking, realm checks, and
  derived-constructor TDZ behavior intact.
- Retain existing register publication checks unless G1 validates and integrates
  a replacement policy. Do not make inlining performance depend on adopting the
  unvalidated GC experiment.
- Add profiler parity cases for success, identity refusal, later refusal,
  successful completion, and partial fused completion.

### I4. Fuse guarded reads and retain lookup caches

- Combine the pure-data-property check and the actual read. Use the existing
  property cache validity rules instead of searching the same property twice.
- Refuse accessors, proxies, and observable key coercion before invoking them.
  Their normal call path must retain the callee frame and its observable caller.
- Reuse T2/T3 validity machinery for free-binding reads, keyed by the callee's
  lexical/variable environment, not the enclosing caller's environment.
- Preserve a callee's proven-global classification. The current expansion
  lowers both `GETVAR` and `GETGLOBAL` to `INLINE_GETFREE`, losing the global
  specialization and walking environments again. Use an explicitly global
  lookup/cache for proven globals, with realm and global lexical-binding
  validity checks. Do not let caller-local shadowing retarget the lookup.
- Validate capture cells and live slots with the existing capture reader.

### I5. Integrate optimization after expansion

- Model each new instruction's explicit and implicit register uses, writes,
  guard-success/failure edges, and terminal behavior.
- Preserve original call operands until the final possible refusal. Treat
  exception regions and borrowed values according to existing ownership rules.
- Move expansion before the appropriate optimization stage, or expose a common
  post-expansion pipeline. Run liveness, move elimination, constant/copy
  propagation, guard elimination, and compaction with correct relocation.
- Recompute analysis after mutations according to T7; do not run existing
  passes blindly over instructions whose effects they do not understand.
- Propagate numeric facts from constants and arithmetic results so a guard is
  emitted only where a coercion-capable operation still needs one.

### I6. Limit branch bridges and improve site profitability

- Widen only branches whose remapped offsets overflow. Preserve short branches
  that still fit; preserve negative-comparison and NaN behavior.
- Record per-site attempts, successful returns, identity misses, and later
  misses only in diagnostic builds/runs.
- Replace the size-only admission rule with a conservative cost estimate:
  emitted setup, live copies, guards, expected refusal cost, branch bridges,
  bytecode growth, and scratch-register pressure.
- Leave ambiguous or repeatedly unprofitable sites on the ordinary call path.
  Keep static identity/realm guards even at sites with a high measured hit rate.

### Checks and acceptance

Run `scripts/test_guarded_inline.py` against expansion on/off, and extend it
for dead initialization on conditional paths, missing formals, input aliasing,
getter/proxy/coercion refusal, closure mutation, arrow `this`, exception
handlers, and source positions. Check portable-image round trips when changing
opcodes or persistent references. Exercise the non-NaN-boxed representation
after changing value-copying or handler code.

Add a cross-optimization fixture: a callee with a proven-global reference is
inlined into a caller with a same-named local. Check reads, global accessors,
mutation, deletion, TDZ, and multiple closures/realms through appropriate
ordinary-call fallbacks. Compare ordinary and inline lookup/cache counts.

Measure each I-step independently. Acceptance: the demonstrated dead setup is
gone, retained inline operations have threaded paths, lookup duplication is
removed, fallback tests pass, and both target workloads show repeatable gains
before considering default enablement.

Use a bounded performance trial: measure I1/I2, then I3/I4, then the
post-expansion optimization/profitability result in separate commit groups.
Repeat the final Richards/DeltaBlue comparison in two timing batches. If only
some sites benefit, narrow eligibility to those sites. If the leaner design
still provides no repeatable benefit, recommend omitting or shelving the
inliner rather than extending scope indefinitely. Keep independently useful
global-access and binding-cache improvements regardless of that decision.

## 9. T5 — Fuse common interpreter operations

Lane: Compiler, with Runtime supplying typed-array and string fast-path
interfaces. Primary candidates: field-load/predicate sequences in
Richards/DeltaBlue and indexed-load/arithmetic/store sequences in zlib/PdfJS.

### Implementation sequence

1. Rank dynamic opcode pairs/sequences with the corrected profiler after the
   simpler fast paths and inline setup fixes land. Compilation-frequency
   histograms do not establish execution benefit.
2. Start with a measured field-load/predicate or guarded-read sequence. Preserve
   numeric checks, missing-property behavior, NaN, and the original order of
   potentially observable operations.
3. Add indexed load/arithmetic/store fusion only after T1's element access rules
   are available. Reuse those guards and conversions rather than duplicating
   typed-array semantics in a second implementation.
4. Respect branch targets into the middle of a sequence. Retain an ordinary
   continuation where a fused operation can complete partially.
5. Add opcode metadata, disassembly, feature checks, liveness/alias rules,
   serialization compatibility, and profiler accounting together.

Checks: mixed numeric representations, overflow, negative zero, exceptions,
destination aliasing, refcounted destinations, branch entry, and a refusal after
the first operation completes. Use `test/fused_add_results.js`, threaded
numeric fixtures, targeted new repros, and `just test-golden-bytecode` when
compiler output changes. Update golden output only after inspecting the diff.

Acceptance: fewer executed dispatches and repeated checks in measured hot
sequences, correct partial-completion behavior, and a repeatable release win.

## 10. T6 — Guarded ASCII string intrinsics

Lane: Runtime. Primary benchmarks: `typescript.js`, `pdfjs.js`.

Inspect `src/builtins/string.c3`, `src/hstring.c3`, and the call/property handlers.
The engine already has ASCII builtin paths, cached ASCII character strings, and
a threaded ASCII string iterator. Measure the remaining call/lookup/decoding
cost rather than reimplementing those existing paths.

Implementation sequence:

1. Identify the most frequent intrinsic, receiver representation, and index
   shape. Begin with `charCodeAt` if the current profile confirms it.
2. Guard the evaluated method identity, primitive string representation,
   verified ASCII property, and integer index before direct byte access.
3. Preserve UTF-16 indexing. A non-ASCII string, surrogate sequence, coercing
   receiver/index, replaced method, or unsupported representation uses the
   ordinary call with already evaluated operands.
4. Handle negative and out-of-range indices with the intrinsic's correct
   result, or refuse before performing observable work.
5. Consider scanning/checksum helpers only when a measured sequence justifies
   them. Preserve bounds, interrupt responsiveness, and exact numeric results.

Checks: empty strings, NUL, ASCII boundaries, non-ASCII BMP characters, lone
surrogates, supplementary characters, sliced/concatenated strings, coercing
indices, and method replacement during argument evaluation. Use narrow tests
under `built-ins/String/prototype/charCodeAt` and corresponding directories
for any additional intrinsic.

Acceptance: the measured ASCII path avoids generic call/decoding overhead,
Unicode and replacement cases retain correct fallback, and the relevant
TypeScript/PdfJS workload improves.

## 11. T7 — Reduce compiler-pass work

Lane: Compiler. Primary benchmark: the jQuery workload in `code-load.js`.

Relevant files: `src/compiler/context.c3`, `fusion.c3`, `moveelim.c3`,
`binding_analysis.c3`, `regalloc.c3`, `patches.c3`, and source-map/bytecode
relocation helpers.

Implementation sequence:

1. Measure allocations, time, and invocation counts for jump-target building,
   try-region discovery, liveness, scratch-buffer allocation, and compaction.
   Separate these costs from parsing, lexing, and execution.
2. Reuse per-function scratch arenas where their size and lifetime are bounded.
   Do not retain compilation scratch on every finished function.
3. Define which mutations invalidate each analysis: instruction count/layout,
   control-flow edges, register uses/definitions, and exception coverage.
4. Share jump-target/try-region information only across passes whose mutations
   preserve it. Recompute it at explicit boundaries.
5. Reuse a liveness result only when preceding changes preserve its graph and
   transfer functions. Otherwise reuse allocation, not stale analysis values.
6. Expose a common analysis/optimization interface for T4 expansion so the
   inliner does not grow an independent optimizer or relocation implementation.

Checks: golden bytecode, `--no-optimize`, wide operands, far branches,
try/catch/finally, direct eval PCs, async saved-register metadata, and source
maps. Existing semantic assertions remain the oracle; an expected bytecode
file alone does not establish correctness.

Acceptance: measured analysis/allocation work falls, compile time improves,
peak compiler memory remains bounded, and runtime bytecode is unchanged except
for separately reviewed intended optimization differences.

## 12. T8 — Forwarding constructors and argument transport

Lane: Runtime, coordinating recognition hooks with Compiler. Primary
benchmark: `raytrace.js`.

Inspect `src/builtins/function.c3` (`apply_call` and
`builtin_function_proto_apply`), `src/vm/vm_calls.c3`, `vm_objects.c3`,
`src/compiler/class.c3`, parameter/default/rest lowering, and `FWD_ARGS`.
Default derived constructors already use `FWD_ARGS`; simple field-store
constructors already have a separate shortcut.

Implementation sequence:

1. Measure the actual forwarding forms in RayTrace: wrapper calls, `apply`,
   rest/spread transport, arguments-object creation, and constructor frames.
2. Identify wrappers whose arguments are used only for forwarding and cannot
   escape through supported observable behavior.
3. Guard the evaluated forwarding intrinsic and target before selecting direct
   argument-window transport. Reuse `FWD_ARGS` or the ordinary call layout when
   semantics match.
4. Preserve receiver coercion, argument order/count, mapped arguments, defaults,
   rest behavior, bound/proxy targets, and overlapping register windows.
5. Preserve the distinction between `Base.apply(this, arguments)` and
   constructing `Base`. Keep `new.target`, derived `super()` initialization,
   and constructor object-return behavior correct.
6. Refuse unsupported/observable cases before omitting arguments materialization
   or changing the original call machinery.

Checks: zero/missing/surplus arguments, mapped aliases, escaping arguments,
replaced `.apply`, bound and proxy targets, throwing getters, return-object
overrides, derived constructors, and value-stack growth during argument
evaluation. Reuse `test/apply_redispatch_refcount.js`, class constructor
fixtures, and narrow Function `apply` / class constructor test262 cases.

Acceptance: the measured eligible wrapper avoids arguments materialization
and generic apply transport, all refusal cases preserve behavior, and RayTrace
shows a repeatable benefit with reduced allocation pressure.

## 13. Execution waves and dependencies

### Wave 0 — Shared baseline

Verify branch state, profiler parity, corpus availability, timing variability,
and the inlining baseline. Create the integration and lane worktrees only after
the instruction to start.

Audit overlapping Octane commits first. Reconstruct the free-global and GC
experiments from known sources, establish the four-way comparison, and identify
the Navier-Stokes regression without using the hacked binary as a baseline.
Record G1 as pending until its correctness and performance gates pass.

### Wave 1 — Independent first changes

- Runtime: T1 numeric typed-array reads, then writes.
- Bindings: isolate the Navier-Stokes regression, review proven-global
  classification, and complete the T3 cache-reader audit before changing cache
  validity rules.
- Compiler: I1/I2 dead initialization and unused setup, plus T7 pass-cost
  inventory and analysis-interface design.

Each lane submits its first focused commit and measurements before broadening
scope. Integrate and measure these changes individually.

### Wave 2 — Shared fast-path foundations

- Runtime: T6 ASCII intrinsic; audit T8 forwarding forms.
- Bindings: T3 invalidation generation, then T2 missed capture classifications
  and stable-slot access, reusing accepted Octane work.
- Compiler: I3 threaded inline execution; I4 guarded property reads. Adopt
  binding validity support after the Bindings commits are integrated.

### Wave 3 — Compiler integration and remaining targets

- Runtime: T8 forwarding transport and constructor checks.
- Bindings: validate cross-lane cache users and heap-reset behavior.
- Compiler: I5 post-expansion optimization, T7 measured scratch/analysis reuse,
  I6 branch/profitability work, and T5 profile-selected fusion.

Keep T5 array-load/arithmetic/store work behind T1's finalized access semantics.
Keep inline binding-cache changes behind T2/T3 validity rules. Rebase dependent
work on integrated commits; avoid duplicate implementations.

Treat G1 as a separate acceptance decision. An unsuccessful or inconclusive GC
experiment does not block optimizations that retain the existing barriers.

### Wave 4 — Combined result

1. Integrate one reviewed commit group at a time.
2. Rebuild all binaries used for validation; do not trust stale profiler,
   conformance, non-NaN-boxed, or sanitizer outputs.
3. Run the focused checks for the merged areas, `just test-opprofile`, and
   `just rosetta`. Use narrow test262 runs for changed semantics.
4. Run the named Octane workloads serially and compare with the shared baseline.
5. Record feature interactions, code size, RSS, bytecode growth, and compile time.
6. Enable a fast path by default only when its semantic and performance gates
   pass. Keep the inliner opt-in if either Richards or DeltaBlue still regresses.

## 14. Commit and review requirements

Each commit description should state the concrete trigger, resulting behavior,
guard/refusal rule, focused validation, and measured effect. Keep unrelated
cleanup separate. Update `docs/architecture.md` when a design claim changes.

For each target, retain:

- The exact before/after commits and build flags.
- A minimized semantic fixture for the non-obvious fast-path invariant.
- Raw timing samples and the separate diagnostic profile.
- A list of supported cases and cases deliberately left on fallback.
- Memory/code-size effects and any unresolved regression.

Review shared handler-table edits, cache validity checks, register aliasing,
partial-completion paths, and serialization changes explicitly. Commit and
publish only within the authorization in effect when execution starts.

## 15. Final deliverables

- Separate reviewed commits for all accepted optimizations.
- An integration branch with recorded merge order.
- A status table for T1–T8 and I1–I6: implemented, measured no-benefit, or
  blocked with a concrete reason.
- A separate G1 validation result and an explicit decision about retaining or
  replacing register-publication checks.
- Focused test and narrow-conformance results.
- Per-target and combined benchmark records.
- A recommendation for default enablement based on measured performance and
  memory use, including any optimization that should remain experimental.

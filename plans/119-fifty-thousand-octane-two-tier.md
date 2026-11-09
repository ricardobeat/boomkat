# 119: 50K Octane on a two-tier JIT

Status: **ACTIVE, 2026-11-03, on branch `jit`.** Supersedes the first Octane JIT plan.
Full original Octane at rat `bcb55ef9` scores 6,400 in one process. The target is 50,000.

## Objective

Reach 50,000 on the original Octane 2.0 suite, run as one process with all 17
results, on the Apple M3 used for the measurements below. Keep sloppy, strict and
module semantics, the embedding API, bounded compilation memory, and a small
default code footprint for embedded hosts.

The JIT becomes two tiers that share the interpreter's frame layout:

1. a baseline tier that compiles every opcode and leaves generated code only to throw;
2. a speculative optimizing tier that deoptimizes into those frames.

The baseline tier comes first. Runtime work outside the JIT (regexp, frontend,
allocation) runs in parallel, because several benchmarks are bounded by it.

## Measurements, 2026-11-03

Apple M3, 8 cores, macOS 27.0 (26A5425a), load average about 3. Boomkat rat
`bcb55ef9`, release `boomkat` target. JSC is the system framework, version
22625.1.29.11.26. The Octane 2.0 sources are those in
`boomkat-jit-experiments/octane-study-20261021/octane`; `make_bundles.sh`
concatenates them into one script with a `read` stub that zlib's shell detection
needs. Hashes are in `manifest.json`. Each configuration ran once, so
per-benchmark differences under about 5% are noise.

JSC configurations: `--useJIT=false` (LLInt; this also disables the RegExp JIT),
`--useDFGJIT=false` (LLInt and the baseline JIT, RegExp JIT on),
`--useFTLJIT=false` (adds DFG), and the default.

| Benchmark | bk interp | bk JIT, one process | bk JIT, fresh process | JSC LLInt | JSC baseline | JSC DFG | JSC full |
|---|---:|---:|---:|---:|---:|---:|---:|
| Richards | 1,522 | 4,579 | 4,861 | 2,263 | 8,402 | 31,150 | 57,998 |
| DeltaBlue | 1,480 | 3,190 | 4,300 | 2,039 | 8,966 | 40,153 | 101,359 |
| Crypto | 2,611 | 4,556 | 4,431 | 2,335 | 9,630 | 55,796 | 105,624 |
| RayTrace | 2,948 | 2,891 | 4,552 | 5,506 | 15,022 | 78,291 | 251,226 |
| EarleyBoyer | 3,575 | 3,386 | 4,108 | 7,527 | 32,351 | 91,971 | 148,671 |
| RegExp | 1,141 | 1,127 | 1,207 | 1,126 | 15,001 | 24,184 | 28,058 |
| Splay | 8,019 | 8,076 | 7,856 | 12,240 | 36,793 | 72,600 | 106,509 |
| SplayLatency | 21,981 | 21,935 | 20,793 | 41,978 | 112,506 | 200,257 | 249,273 |
| NavierStokes | 4,348 | 4,868 | 23,229 | 3,406 | 5,383 | 32,648 | 52,281 |
| PdfJS | 6,058 | 6,168 | 5,830 | 14,904 | 49,681 | 112,723 | 134,527 |
| Mandreel | 2,043 | 2,253 | 3,026 | 1,746 | 7,331 | 54,032 | 120,948 |
| MandreelLatency | 11,984 | 25,965 | 26,947 | 9,550 | 34,145 | 113,300 | 216,748 |
| Gameboy | 13,493 | 14,159 | 12,389 | 11,440 | 42,725 | 158,615 | 222,340 |
| CodeLoad | 28,651 | 28,645 | 25,843 | 104,987 | 118,169 | 115,334 | 107,136 |
| Box2D | 7,413 | 7,244 | 8,216 | 9,199 | 21,924 | 128,214 | 179,282 |
| zlib | 3,133 | 3,571 | 4,354 | 2,978 | 11,757 | 95,929 | 142,154 |
| Typescript | 21,564 | 21,159 | 20,827 | 28,711 | 92,329 | 188,061 | 220,217 |
| **Score** | **5,214** | **6,400** | **7,580** | **6,951** | **23,302** | **78,645** | **124,692** |

"Fresh process" runs each benchmark alone with `base.js` and the original driver;
its score row is the geometric mean of those runs.

- 50K sits between JSC's baseline configuration (23,302) and its DFG
  configuration (78,645): about 64% of DFG and 2.1x the baseline. From boomkat's
  best result, 7,580, it is 6.6x. A baseline tier alone does not reach it; JSC's
  baseline configuration, with its RegExp JIT and runtime, is at 23K.
- The JIT adds 1.23x over the interpreter in one process. The gains are Richards
  3.0x, DeltaBlue 2.2x, MandreelLatency 2.2x and Crypto 1.7x; the other
  benchmarks are within 0.95–1.14x.
- The interpreter is 0.75x of LLInt. It matches or beats LLInt on numeric and
  typed-array code (Crypto 1.12x, NavierStokes 1.28x, Mandreel 1.17x, Gameboy
  1.18x, zlib 1.05x) and trails on allocation, strings, closures and parsing
  (Splay 0.66x, RayTrace 0.54x, EarleyBoyer 0.47x, PdfJS 0.41x, CodeLoad 0.27x).
  With the JIT on, boomkat is still below LLInt on RayTrace, EarleyBoyer, Splay,
  SplayLatency, PdfJS, CodeLoad, Box2D and TypeScript.

### Code budget and suite order

- NavierStokes scores 23,229 alone, 4,868 inside the suite and 21,179 when its
  source moves to the front of the bundle. The suite ends with 2,379,920 bytes of
  generated code. Function compilation stops at 2 MiB (`JIT_MAX_CODE_LIMIT`,
  `src/vm/vm_sljit_budget.c3:8`); loops may continue into a reserve up to 4 MiB.
  The default build evicts nothing.
- Generated code per benchmark when run alone: NavierStokes 504 KB, Richards
  234 KB for 22 functions, RayTrace 475 KB for 42, PdfJS 2.09 MB for 116,
  Mandreel 2.11 MB for 43, Box2D 2.10 MB for 132. Three benchmarks fill the
  function budget by themselves.
- With `JIT_MAX_CODE_LIMIT` at 64 MiB (`64mib-code-limit.patch`, no other change)
  the suite compiles 1,666 functions into 36.4 MB and scores 6,307. NavierStokes
  recovers to 23,058, PdfJS reaches 7,226, zlib 4,229 and Mandreel 2,789.
  TypeScript falls to 7,195 against 21,564 on the interpreter, Gameboy to 10,053,
  Box2D to 5,417 and CodeLoad to 21,464. TypeScript alone drops from 20,827 to
  15,948; its profile at 64 MiB is 49% interpreter, 21% generated code and 15%
  JIT runtime, of which about 5% is compilation.

Once the current function tier may compile freely, it is slower than the
interpreter on large polymorphic programs; the 2 MiB cap limits that loss. More
budget pays only when compiled code stops falling back to the interpreter.

The mini screen and `scripts/octane_score.py` do not show either effect: each
mini runs in a fresh process, and the score is a projection from a historical
full run.

### Profiles

macOS `sample`, each benchmark alone with `--jit`, about 4 s each. Percentages are
of all main-thread samples. `sample` lists only symbols with at least five
samples; the unlisted remainder is counted as generated code, which overstates
that column by the small C tail (2–6% in interpreter-only profiles). A dash means
no listed symbol fell into that column.

| Benchmark | Samples | Generated code | Interpreter | JIT runtime | GC | Largest entries |
|---|---:|---:|---:|---:|---:|---|
| Richards | 1,059 | 98% | – | 2% | – | `sljit_native_read` 2.4% |
| DeltaBlue | 1,216 | 73% | 11% | 11% | 2% | `sljit_native_read` 5.8%, `sljit_function_entry` 2.9% |
| RayTrace | 1,223 | 22% | 61% | 12% | 3% | `sljit_function_entry` 8.0%, `th_putthisc` 7.8%, `th_apply_args` 7.8% |
| Box2D | 415 | 46% | 46% | 9% | – | `th_getpropc_cached` 16.4%, `sljit_function_entry` 5.1% |
| EarleyBoyer | 3,391 | 9% | 53% | 9% | 15% | `th_try_fast_return` 7.1%, `sljit_function_entry` 5.3% |
| Splay | 1,272 | 32% | 25% | 10% | 21% | `gc_sweep_objects_step` 9.3%, `sljit_native_operation` 4.7% |
| PdfJS | 670 | 35% | 26% | 2% | 22% | strings 7% |
| TypeScript | 3,398 | 12% | 72% | 4% | 3% | `th_call` 11.3%, `th_getpropc_cached` 10.9% |
| CodeLoad | 1,175 | 29% | – | 10% | 0% | frontend 49%, `sljit_function_ssa_refresh` 10.1%, `build_line_table` 9.4% |

Richards and DeltaBlue are bound by the quality of generated code and calls.
RayTrace, Box2D, EarleyBoyer and TypeScript run mostly in the interpreter with the
JIT on. EarleyBoyer, Splay and PdfJS spend 15–22% in the collector. CodeLoad is
the frontend.

## Findings

### The function tier does not cover functions

The JIT began as workload-specific compilers: template-rendering loops, numeric
array loops and hot callback segments, followed the same week by SSA for numeric
loops. The function tier in `src/vm/vm_sljit_function.c3` is the nearest thing to
a baseline, and it grew optimizer features (shape guards baked into code, small
callee inlining, numeric register homes, read refresh) without ever covering
every opcode.

`function_op` (`src/vm/vm_sljit_function.c3:143`) admits 97 of the 239 opcodes;
calls, Math intrinsics and a few others have separate paths. A native run ends at:

- an opcode without a native path, or a property-cache state the generated
  guards and `sljit_native_read` do not answer;
- a call that is not an exact-arity `CALL` or `CALL_UNDEF_THIS` to a callee with
  a native entry; `CALL_VAR` and `CALL_GLOBAL` have no native call path unless the
  callee is inlined;
- native call depth 64 (`src/vm/vm_sljit_native.c3:173`) or an exhausted
  progress budget;
- a string left in a callee local or scratch slot at call entry
  (`src/vm/vm_sljit_native.c3:231`); at return, a string result or a string in
  any register or in the caller's result slot (`src/vm/vm_sljit_function.c3:867`).

Then every machine frame unwinds and the interpreter continues until it reaches
a point where it checks for re-entry: function entry, a backedge, a return into a
caller whose plan has an entry at the return PC, or the start of a threaded
burst. Each re-entry runs the C gateway `sljit_function_entry`, which takes
3–8% of DeltaBlue, Box2D, RayTrace, EarleyBoyer and Splay. How much of each
function runs natively is then decided by stall counters, helper-per-entry
demotion, rebuild limits and read refresh.

The SSA tier was built without a complete tier underneath it. Its exits and
helpers return to the interpreter through frame publication, root maps and the
single-step `vm_dispatch` bridge, which is where much of its helper cost and
complexity comes from.

### Code density

The archived SSA throughput report
(`113-fifty-thousand-octane/ssa-throughput-2026-11-02/report.md`) measured
220–700 bytes per bytecode op, about 3.2 KB per computed `GETPROP` site and about
110 bytes per register store with the reference-count path inline. Moving the
counted store out of line cut body bytes by 5% and admitted nine more plans, and
did not change time. Size limits how much fits in the budget; on its own it did
not slow the code.

Shape IDs and prototype pointers are compile-time immediates
(`src/vm/vm_sljit_property.c3:143`, `:166`), and a plan tracks at most 32 shapes
(`FunctionPlan.shapes`). A cache that changes after compilation is answered by
`sljit_native_read`, a read refresh or a recompile.

### Calls

A JIT-to-JIT call entry (`FunctionEmitter.emit_call_entry`,
`src/vm/vm_sljit_native.c3:131`) runs up to fourteen guards, checks each callee
local and scratch slot for a string, makes about 33 stores into the activation,
VM, context and run records, and stores `undefined` into each local and scratch
slot. Return (`FunctionEmitter.native_return`,
`src/vm/vm_sljit_function.c3:831`) checks the result, every register and the
result slot for strings, clears every register, restores the caller's VM and
context fields and recomputes `ic_bias` and `var_ic_bias` from the caller's
function. An interpreter call into compiled code runs `sljit_function_entry`,
which checks the GC phase, pending interrupts, the plan's shape clock and epoch
and the progress budget, retires invalid plans, refreshes SSA liveness and pins
the code artifact. In the SSA tier a generic call is a helper that publishes the
frame and roots and calls `call_fn`, a nested VM run (`ssa_helper_execute`,
`src/vm/vm_sljit_ssa_continuation.c3:425`).

### String reference counting

Only strings are counted, and the count reaches every JIT path: two tag checks
and an inline increment/decrement sequence per register store (`function_store`,
`src/vm/vm_sljit_function.c3:270`), the string refusals at call entry and return,
the `unowned`/`inert` flow facts, and the increment/decrement passes in SSA
publication and root updates. The out-of-line store did not change time (see
Code density), so the cost is in the refusals and the bookkeeping around frames
and helpers rather than in store size. Tracing strings like objects removes all
of these, and also removes prompt reclamation, which matters on small devices.
String ownership under reference counting records the current boundaries.

### The SSA tier

The recoverable SSA tier works for numeric kernels: NavierStokes reaches 23,229
alone, 0.71x of JSC's DFG configuration. Its IR has arithmetic, guards, field and
element access, branches, `EXIT` and `HELPER`. A helper executes one interpreter
instruction through `vm_dispatch` (`ssa_vm_step`, `src/vm/vm_sljit_vmstep.c3`)
after root maps, publication and rebinding, and may run `loop_prepare` after it.
For a recoverable plan, each entry from C initializes an execution record,
copies every register up to `LOOP_REGS` and runs `loop_prepare`
(`sljit_function_ssa_run`, `src/vm/vm_sljit_function_ssa.c3:196`). Whole bodies
above 320 ops (`SSA_BODY_OPS`, `src/vm/vm_sljit_loop.c3:29`) are not attempted,
which excludes, for example, the
large emscripten-generated functions in Mandreel and zlib. Calls, cached property
access and allocation are not IR operations, so inlining, a large part of what an
optimizing tier gains on call-heavy code, cannot act on them. JSC's DFG
configuration is 3.4x its baseline configuration on this machine.

### Tier and policy count

Tiers: the loop tier (straight-line and SSA), function regions, recoverable SSA
for functions, loops, leaves and call entries, effectful inline prefixes, and the
template-rendering tier. Inliners: four, with their own eligibility rules
(`src/vm/vm_sljit_inline.c3:110` up to 17 ops, `:539` up to 48 ops, the SSA leaf
and selector inliners, and `vm_sljit_ssa_inline_effect.c3`). Configuration: 22
`SLJIT*` build features and dozens of tuning constants. Many recent commits on
rat adjust admission and demotion policy, for example `1de6c8dd` (demote
helper-saturated SSA plans one call earlier), `acb8d3bb` (stop repeated native
compilation) and `845e3650` (refuse bodies whose reads cannot be lowered before
building them).

### Defects

1. `sljit_function_ssa_refresh` (`src/vm/vm_sljit_function_ssa.c3:179`) runs on
   every gateway entry (`src/vm/vm_sljit_function_runtime.c3:355`). After a
   shape-recycle epoch change it walks every compiled function in the heap. It is
   10.1% of CodeLoad, and the 64 MiB suite run had 1,666 compiled functions.
   `sljit_retire_invalid_dependencies` (`vm_sljit_function_runtime.c3:223`) walks
   the same registry while `jit_dependencies_dirty` is set. Both should iterate
   only the plans that need them.
2. `sljit_function_compile` returns the result of `ssa_function_wrap` directly
   (`vm_sljit_function_runtime.c3:105`). When the wrap fails the baseline region
   is not tried, and the caller has already set `sljit_function_calls =
   uint::max` (`:302`). Unless the failure set `sljit_budget_wait`, the function
   stays interpreted.
3. `function_inline_site` (`src/vm/vm_sljit_inline.c3:15`) finds the callee's
   producer by walking back through `LDREG` copies to the nearest earlier write
   in code order, ignoring branches. The callee is checked at run time, so this
   is safe, but where different paths reach the call with different producers it
   can choose the wrong one or give up. `function_inline_property` uses the same
   scan.

About 25 commit subjects on rat appear twice: parallel branches carried the same
patches and were then merged. Bisecting across that history is harder than on a
linear one.

### Limits outside the JIT

- RegExp: 1,207 alone on libregexp's interpreter. JSC is at 1,126 without its
  RegExp JIT and 15,001 with it. RegExp at 15,001 alone would raise the
  fresh-process score from 7,580 to 8,791. SLJIT is also the backend of PCRE2's
  JIT.
- CodeLoad: 26–29K against 105–118K in every JSC configuration, so this is
  frontend throughput. `build_line_table` (`src/ast/parser.c3:339`) is 9.4% of
  it. A single scope index and a flat AST cover the lexer and resolver costs.
- Allocation and GC: 15–22% of EarleyBoyer, PdfJS and Splay. RayTrace,
  EarleyBoyer and Box2D also need allocation inline in generated code.
- Object model: an object on a shape no other object has reached moves to a
  dictionary shape at 64 properties (`SHAPE_SOLITARY_MIN_PROPS`,
  `src/heap.c3:1945`). Gameboy's `GameBoyCore` is such an object.
- `Function.prototype.apply` with `arguments`: `th_apply_args` is 7.8% of
  RayTrace.

## Design

The interpreter, the baseline tier and optimized code use one frame layout: the VM
register window and `Activation`. Moving between the interpreter and baseline
code needs no translation, and deoptimization writes ordinary frames.

JSC (LLInt, baseline JIT, DFG, FTL) and V8 (Ignition, Sparkplug, Maglev,
TurboFan) both have this structure. Sparkplug is the model for the first
baseline: it compiles every bytecode into code that calls the interpreter's own
operations and cache handlers, shares the interpreter's frames and compiles in
one pass. JSC's baseline inlines more property-cache fast paths, at a higher
compile and memory cost; boomkat adds those only where profiles show they pay.
Maglev is the model for the optimizing tier: it builds an SSA control-flow graph
in one pass from bytecode and feedback, records the interpreter frame state at
each bytecode for deoptimization, and represents calls, property access and
allocation as graph nodes.

### Baseline tier

- Whole functions, with no region windows. Entry at function start, and from the
  interpreter at loop headers.
- Every opcode is emitted. Cheap operations get inline fast paths; everything else
  calls an operation function that performs the instruction against the register
  window and returns a status, and generated code continues at the next
  instruction. A throw unwinds through the existing handler machinery; resuming
  the interpreter at the catch handler is acceptable at first.
- Operation functions are factored out of the interpreter handlers, so the switch
  dispatcher, the threaded dispatcher and generated code share one implementation
  of each instruction's semantics. The threaded `th_*` handlers tail-dispatch to
  the next instruction and cannot be called this way, and the single-step bridge
  is too slow to use per instruction.
- Generators and async functions may stay interpreted in the first version; that
  exclusion is listed explicitly.
- Property access, calls and `new` use caches that read the site's `ICEntry` at
  run time through shared handler stubs. Polymorphic sites need no recompilation,
  and misses update the same IC the interpreter uses.
- Calls between generated frames cost the same whatever the callee's register
  count: the entry writes what the callee and unwinding need, and the
  `Activation` record is complete whenever the runtime can observe it (throw, GC
  root walk, stack trace, interrupt, deoptimization, interpreter resume). Arity
  adaptation happens in the entry stub. Locals are cleared only where liveness
  requires it.
- The baseline records the feedback the optimizing tier needs: receiver shapes,
  value kinds and call targets, in the existing IC entries where possible.
- Slow paths are out of line and shared. Bytes per op are recorded per benchmark;
  the first prototype sets the target.
- Code budget: a small default cap for embedded hosts, a larger cap for
  throughput configurations such as the CLI, and reclamation of code that has not
  run recently.

### String ownership

Prototype strings traced by the collector, with increment and decrement compiled
out, and measure time and RSS on the suite, the minis and
`scripts/run_memory_bench.sh`. If counting stays, every counted store in
generated code calls an out-of-line stub, and no frame transition refuses strings.

### Optimizing tier

- Input: baseline frames and their feedback.
- IR: the existing SSA graph, dominance, liveness, ranges, LICM, CSE, DCE and
  logical frame states, extended with:
  - calls, direct or polymorphic with target guards;
  - property get and put by shape, with polymorphic variants;
  - allocation with a known shape;
  - calls to operation functions with declared clobbers and root maps, instead of
    frame publication.
- Inlining guided by call-target feedback, with nested frame states.
- Deoptimization writes interpreter-layout frames for every inlined frame and
  resumes in baseline code at the exit PC.
- int32 induction and unboxed f64 across loops. The earlier JSC comparison found
  lost integer induction and repeated binding validation in NavierStokes.
- A compile-work budget instead of the 320-op body bound.
- Later: allocation sinking for RayTrace, EarleyBoyer and Box2D.

## Branch

The work is on `jit`, branched from `main` on 2026-11-03, not on `rat`. `main`
has no JIT; `rat` is 251 commits and about 20K lines of tier code over it, and
its interpreter hooks (`sljit_function_backedge`, the `sljit_loop_ready` mask,
template and function dispatch, `sljit_function_resumes`) are shaped around the
five tiers the baseline replaces. Rebasing them across the 35 `main` commits that
touch the same compiler and VM files would have been done mostly to delete the
result. The 5,214 to 6,400 that rat's tiers gave is given up until the baseline
tier passes it.

Ported from `rat` as the first commit: `vendor/sljit`, `src/jit/` (the shim and
the C3 bindings), the `SLJIT` build token and targets, `Heap.set_jit` and
`set_jit_stress`, the `--jit` and `--jit-stress` switches in the CLI and the
test262 runner, `bk_set_jit` and `JsRuntime.set_jit`, the SLJIT ABI test and
the C API switch test, `scripts/run_jit_diff.sh`, `scripts/octane_score.py` and
the `bench_interleaved.py` JIT flags. Left on `rat`, to be ported or rewritten
when a milestone needs them: the prototype-arm ICs in `hobject.c3`, write
dependencies, `bytecode_cfg.c3`, the moveelim liveness work, the regexp
required-substring filter in `re_wrapper.c`, and the `gen.c3` dead-jump
elimination. `rat` stays as reference for the NaN-box guards, the deopt layout
and the call entry sequence.

## Milestones

### 0. Measurement gate

Add a script that runs the full suite in one process, prints all 17 results and
the composite, and records generated code bytes, compiled function count, peak
RSS and binary hashes. Gate changes on at least three alternating runs against
the previous gate binary, with no concurrent builds or profiling. Fresh-process
runs and `sample` profiles are for diagnosis. `scripts/octane_score.py` remains a
quick screen, not a gate.

Add a native-coverage measure per benchmark: interpreter dispatches with the JIT
on, divided by dispatches with it off.

Acceptance: the script reproduces the measurements above within noise, and
records the `main` interpreter score the `jit` branch starts from.

### 1. Defects

Dropped: defects 1 and 2 are in rat code that is not carried to `jit`.

### 2. String ownership decision

Prototype and measure as described under Design.

Acceptance: a recorded decision with time and RSS numbers, made before the
baseline's store path is written.

### 3. Operation functions

Factor each opcode's interpreter semantics into a callable operation shared by
both dispatchers.

Acceptance: interpreter scores unchanged within noise on the suite and the minis;
test262 and the local suites pass in both script modes and as modules.

### 4. Baseline tier

Write a new emitter for the baseline tier, taking the arithmetic,
compare-and-branch and shape-check fast paths from rat's function tier
(`src/vm/vm_sljit_function.c3`, `vm_sljit_property.c3`, `vm_sljit_typed.c3`
on `rat`) where they fit. The function tier's contract (leave on anything
unhandled, cache state baked into code) is the opposite of the baseline's, so
it is not retrofitted.

Acceptance:

- every opcode outside the listed exclusions compiles;
- with the code cap at 64 MiB, no Octane benchmark scores below the interpreter;
- native coverage of at least 95% on every benchmark except RegExp and CodeLoad;
- `scripts/run_jit_diff.sh` with `--jit-stress`, its test262 mode, and the
  embedding JIT suites pass, including the ASan build.

Planning estimate, to be replaced by measurement: with RegExp held at its
interpreter score, JSC's baseline configuration would be about 2.9x its
interpreter configuration. Applied to boomkat's interpreter that is roughly 15K;
boomkat's slower collector, strings and frontend will keep it below that.

### 5. Optimizing tier

Build the SSA tier on baseline frames as described under Design, reusing rat's
graph, dominance, liveness, range and LICM code (`src/vm/vm_sljit_ssa_*.c3`
on `rat`) where it fits the new frame contract.

Acceptance: per-benchmark gains in the full suite; deoptimization, inlining and
call nodes covered by the differential and embedding suites; bounded compile time
and memory.

### 6. Runtime, in parallel

- RegExp: compile regexps to native code with SLJIT. Reference: 15,001 in JSC's
  baseline configuration.
- Frontend: build line tables lazily or during lexing, carry out the frontend migration to a single scope
  index and a flat AST, and compile function bodies lazily. Reference: 105–118K for CodeLoad in
  JSC.
- Allocation: bump allocation callable from generated code, and the collector
  work: pause reduction, a sticky-mark nursery, and incremental
  collection.
- Object model: revisit the 64-property dictionary threshold for singleton objects
  and the deep-shape dictionary cap.
- `Function.prototype.apply(this, arguments)` without materializing `arguments`.

## Rules carried over from the earlier Octane JIT plan

- No replay of completed stores, exact recovery, roots held across helpers, no
  non-aliasing inferred from descriptor IDs, no entry snapshots reused after
  effects.
- Differential testing with `--jit-stress`, the embedding JIT suites and their
  ASan target, on ARM64 and x64.
- Interleaved timing runs on a calm machine, and investigation of repeatable
  regressions above about 3%.
- Performance work on `jit` keeps a linear history so regressions can be bisected.

## Evidence

`119-fifty-thousand-octane-two-tier/baseline-2026-11-03/`:

- `logs/`: the four JSC configurations (`jsc-*.log`, `*.time`), boomkat
  interpreter and JIT suite runs (`bk-interp.log`, `bk-jit.log`), fresh-process
  runs (`single.out`, `single-*.jit.log`), the suite with `--stats`, the
  NavierStokes-first bundle and per-benchmark code totals (`probe.out`), the
  64 MiB suite run (`bk-64mb-suite.log`) and TypeScript alone at 64 MiB
  (`ts64.log`).
- `profiles/`: raw `sample` output (gzip) and `profiles.txt` from
  `profile_summary.py`.
- `scripts/`: `make_bundles.sh`, `run_tiers.sh`, `run_single.sh`, `probe.sh`,
  `sample_bench.sh`, `classify.py`, `profile_summary.py`. They expect the layout
  they ran in: the bundles from `make_bundles.sh` in a directory `octane/`, the
  per-benchmark bundles in `octane/single/`, and the release binary at `bk-rat`
  next to `octane/`.
- `64mib-code-limit.patch`: the only source change in the 64 MiB build.
- `manifest.json`: commit, binary, JSC and Octane source hashes.

## Milestone 5 status, 2026-11-08

The optimizing tier is in place on branch `jit` and both tiers are on by
`--opt`. What it covers: int32 and double arithmetic in registers, typed loads,
field reads and writes through shape guards (polymorphic up to the five shapes
the baseline cache records), element access, calls with a callee guard and a
branch per target, inlined callees spliced into the caller to three levels and
200 bytecode words, allocation sinking inside inlined constructors, and typed
array fast paths. Everything else is a GENERIC node running the baseline
emitter's code on the window.

### Acceptance, as measured

One process, full Octane suite, Apple M3, load average about 2. Each
configuration ran once, so differences under about 5% are noise.

| Benchmark | interpreter | `--jit` | `--opt` |
|---|---:|---:|---:|
| Richards | 1,702 | 2,849 | 4,134 |
| DeltaBlue | 1,595 | 2,096 | 3,465 |
| Crypto | 2,866 | 6,074 | 8,723 |
| RayTrace | 5,027 | 4,914 | 7,237 |
| EarleyBoyer | 4,192 | 5,399 | 5,224 |
| RegExp | 2,481 | 2,476 | 2,476 |
| Splay | 9,192 | 11,547 | 9,810 |
| SplayLatency | 23,419 | 24,184 | 23,880 |
| NavierStokes | 4,462 | 6,766 | 12,489 |
| PdfJS | 6,680 | 7,431 | 7,613 |
| Mandreel | 2,192 | 2,881 | 4,261 |
| MandreelLatency | 13,809 | 21,304 | 24,679 |
| Gameboy | 14,134 | 17,849 | 17,182 |
| CodeLoad | 32,998 | 33,986 | 33,241 |
| Box2D | 8,464 | 8,796 | 12,120 |
| zlib | 3,595 | 7,387 | 12,568 |
| Typescript | 25,748 | 26,872 | 27,432 |
| **Score** | **6,191** | **7,984** | **9,753** |

- The baseline tier is 1.29x the interpreter, the optimizing tier 1.58x, and
  `--opt` is 1.22x `--jit`. Against the 50,000 target that is 20%.
- RegExp does not move: the score comes from libregexp, which has no native
  compilation of its own. The suite's regexp work is
  inside the interpreter loop, so neither tier reaches it.
- Two benchmarks come in below `--jit` in that run: Splay (9,810 against
  11,547) and Gameboy (17,182 against 17,849). Interleaved repeats put them at
  about 3% and 2% behind, so most of the gap in a single run is noise, but both
  are real: each discards a large share of the bodies it compiles (Splay 8 of
  20 after exits at int32 overflow) and pays for the rebuild.
- The tier's cost is bounded and reported. Over one suite run with
  `--opt --jit-stats`: 485 ms of compilation across both tiers, the longest
  single compile 21 ms (a 37,006-word baseline compile), 2,089 optimizing
  compiles for 610 discards and 97 refusals, 2.4 MB of optimized code after 20
  sweeps of the 4 MiB cap, and 63.4 MB of generated code live at exit (65.2 MB
  peak) against the baseline's 64 MiB cap. Peak RSS for the suite is 2.0 GiB in
  all three configurations, so the tier does not move it.
- Coverage: deoptimization (every exit reason forced by `opt_exit_check.sh`, and
  the discard, ban and generic-lowering paths), inlining (nested sites, inlined
  calls, forwarding `apply`, inlined allocations), and call nodes (a guard per
  target, indirect and variable calls) run in the local differential, the
  test262 differential and the embedding suites, the last under ASan.

### Testing as of this status

- `scripts/jit_check.sh`: 765 fixtures through the interpreter, `--jit`,
  `--jit --opt`, `--jit --opt --opt-always`, `--jit --opt --jit-stress`, and
  `scripts/opt_exit_check.sh` with every exit reason forced under both the
  normal and the forced-optimizing settings: no output differences.
- `scripts/run_jit_diff.sh` for the local suites, Rosetta, the module fixtures
  and test262 (`language/expressions`, `language/statements`,
  `built-ins/Array`) with `--jit --jit-stress` and with
  `--opt --opt-always --jit-stress`: match.
- The same differential under AddressSanitizer: match, and it found a read past
  a shared shape's hash table during an append, fixed on the branch.

### What remains for this milestone

- The largest exit and refusal groups are property sites with no cache yet
  (TypeScript: 25,416 `no cache` skips per run), calls the inliner declines
  because the callee holds a call it cannot inline (1,229 on TypeScript), and
  `TYPEOF`, `NEWARR` and `INIT_SLOT` inside callees. Call nodes, `TYPEOF` and
  the allocations inside inlined bodies are the next three.
- The optimizing tier's control flow graph budget is 4,096 words, so the
  multi-thousand-word decoders a compiler emits (zlib's is 37,006) stay in the
  baseline tier. Raising the budget alone was measured at -0.6% on the suite:
  the win needs region-based compilation of a hot loop inside a large function,
  not a bigger whole-function graph.

## Milestone 6 status, 2026-11-08

The runtime work was scheduled in parallel with the tiers. Per bullet, as of
this status:

- **RegExp**: the native matcher is built, wired in and validated. `src/re/`
  holds the decoder, subject cursor, class predicates and the backtracking
  walk; it declines only lookarounds and back references, and falls back to
  `lre_exec` for those and for any program that fails its bounds check. A
  differential suite (`make test-native-regexp`) compares verdict, span and
  every capture against the interpreter over every start offset and both
  subject forms, and the full test262 suite gives identical results with the
  native path on and off. The path is off by default: on `bench/mini/regexp.js`
  the walk measures 122 ms against the interpreter's 109 ms, so turning it on
  would cost the benchmark. `BOOMKAT_RE_NATIVE=1` opts in. Closing that gap is
  what remains of this bullet.
- **Frontend**: line tables are built once per compilation unit and shared by
  every body parsed under it (`build_line_table` in `src/ast/parser.c3` is
  guarded by `shared_line_starts.len == 0`), and function bodies are compiled
  lazily (`src/compiler/lazy.c3`). The flat-AST frontend migration is done: it
  merged into `main` (`94ac53aa`), and its resolve pass carries the one scope
  index per unit that finally replaces the per-block token re-scans.
- **Allocation**: the bounded nursery and the slice-budgeted
  cooperative incremental collector are in place, and the epoch-based
  marking plus the dictionary thresholds have landed.
  Allocation from generated code goes through the runtime helper with the
  object adopted as a temporary root; a bump path inlined into generated code
  is still open. The page-batching idea (release old pages in chunks at
  safepoints instead of per node) is carried here as a suggestion for later.
- **Object model**: the dictionary thresholds are already split by shape kind,
  `SHAPE_SOLITARY_MIN_PROPS` (64) for a shape no other object uses and
  `SHAPE_COMPUTED_MIN_PROPS` (32) when property names are computed, which is
  what the bullet asked to revisit.
- **`apply(this, arguments)`**: done. A function whose only use of `arguments`
  is to forward it keeps the arguments in its frame registers
  (`CallFlags.forward_args`) behind `APPLY_ARGS`, and the optimizing tier
  inlines through it, so no arguments object is built.

So every milestone-6 bullet is done in the part the tier needed; the
milestone's last whole projects, the one-scope-index-per-unit and
flat-AST work, have both merged into `main`. None of them is a two-tier milestone item:
the tiers' own acceptance is recorded above.

### Native regexp compilation, 2026-11-08

The matcher lives in `src/re/` under `boomkat::re_native @feat(!NO_REGEXP)`,
so it builds without the `SLJIT` feature and is compiled out under
`NO_REGEXP`:

- `prog.c3` decodes libregexp's bytecode once into indexed instructions:
  resolved branch targets, unpacked class pairs, quantifier registers, and the
  header's flags and capture and register counts. It models every opcode except
  lookarounds and back references, and `ReProgram.executable()` bounds-checks
  slots, registers, pairs and targets before the walk indexes them.
- `input.c3` is the subject cursor over Latin-1 bytes and UTF-16 units, with
  the surrogate rules of unicode mode. Its helpers take the subject fields as
  arguments so the walk keeps them in registers.
- `class.c3` tests a code point against a class's range pairs and answers the
  line start, line end and word boundary assertions.
- `exec.c3` walks the program with a backtracking frame stack and an undo
  stack of capture and register writes. Quantified single-character atoms run
  in a tight loop that switches on the opcode once, mirroring libregexp's
  `lre_run_char_op`. A program that opens with the position loop uses the
  compile-time first-unit filter to skip candidate starts.

`src/re_wrapper.c` keeps an opaque handle on the compiled regexp, prepares it
once on the first run that reaches the end of the prefix and required-literal
fast paths, and falls through to `lre_exec_ex` on a declined program, a
matcher error or a timeout. `re_set_native()` forces either matcher, which is
how the differential suites compare the two; `re_first_set()` exposes the
compile-time filter to the walk. `src/re_bindings.c3` declares both hooks.

Testing: `make test-native-regexp` runs the decoder, cursor, class and
differential suites (24,000+ comparisons covering all 95 Octane patterns plus
targeted counted-repeat, unicode, sticky, assertion and empty-match cases).
`BOOMKAT_RE_NATIVE=1` runs the same matcher over the whole 53,380-test
test262 suite; the on/off logs diff to zero lines. `scripts/jit_check.sh` and
`scripts/run_jit_diff.sh` cover the tiers, and `make test-jit-api-asan`
covers the C API under AddressSanitizer.

That left the walk at 122 ms against the interpreter's 109 ms on
`bench/mini/regexp.js`, with the body of every pattern still decoded on the way
through it. Both levers named there are now taken.

### Native regexp compilation, 2026-11-09

The matcher has two tiers in `src/re/`. `exec.c3` is the walk, kept as the
reference and as the matcher for a build without `SLJIT`. `jit.c3` compiles the
decoded program into machine code with SLJIT under `@feat(SLJIT)`:

- the program becomes blocks joined by direct jumps, so an opcode is chosen
  once, at compile time;
- a run of literal characters is one bounds check, one base pointer and a
  compare per character, with the ignore-case form folded to a bit test where
  the pattern is ASCII letters;
- a class is a membership bitmap for a Latin-1 subject, and the walk's own pair
  test above it; the bitmap is keyed by subject unit, so the ignore-case form
  needs no canonicalization in generated code;
- a frame carries the address to resume at, so a failure unwinds what the
  attempt wrote and jumps straight to where matching continues, and a greedy
  run hands back one code point per visit from a stub of its own;
- capture writes record their undo inline, and both unwinds are inline loops;
- two bodies are compiled per pattern, one per subject form, since a Latin-1
  subject never holds a surrogate pair.

Only lookarounds and back references are declined. That set is the walk's
decoder set, and a program outside it stays on `lre_exec` exactly as before.

Measured on the Apple M3, interleaved runs:

| Workload | libregexp | compiled matcher |
|---|---:|---:|
| matcher-bound loop (`/(\w+)\s+(\w+)\s+(\d+)/g` over a 60-unit subject, 1.5M runs) | 4.6 s | 3.35 s |
| the six-pattern matcher micro (`bench`-style literal, class, alternation, capture, ignore-case and anchored cases) | 788 ms | 590 ms |
| `bench/mini/regexp.js` | 108 ms | 107 ms |

So the compiled matcher runs matcher-bound work about 1.3–1.35x faster than the
interpreter, and the Octane RegExp benchmark, which spends most of its time in
the engine's object, string and property work rather than in the matcher, is
unchanged. It is on by default; `BOOMKAT_RE_NATIVE=0` opts out, and
`re_set_native()` forces either answer.

Testing: `make test-native-regexp` runs the differential suite (31,162
comparisons over the Octane patterns, targeted instructions and subjects long
enough to force both stacks past their initial capacities), and
`make test-native-regexp-asan` runs it under AddressSanitizer, which is what
caught the last two emitted-store faults. The whole 53,380-test test262 suite
returns identical verdicts with the compiled matcher on and off.

What is left: the Octane RegExp score does not move while the engine's own
regexp path costs more than the matcher does, so the next lever there is the
runtime around it rather than the matcher. Inside the matcher, a quantified
class or `.` run could skip whole runs of a known first byte (`charpos`-style
scanning), and a wide subject's class test above Latin-1 could be inline
instead of a call.

## Milestone 5 status, 2026-11-09: the items named as next

The three exit and refusal groups the milestone listed, measured on branch
`jit` at `49ead542` and after each change. One process, full suite, all 17
results, `--jit --opt`; each figure is one run, so ±5%.

| Change | Score |
|---|---:|
| as found | 9,386 |
| `TYPEOF` lowered in an inlined body | 9,669 |
| object and array literals built in an inlined body | 9,775 |
| functions that build closures, regexps and cells optimized | 9,835 |

- **`TYPEOF` inside a callee.** A callee holding a `typeof` could not be
  inlined at all. `OptOp.TYPEOF` reads the operand's tag, stores the interned
  name, and takes the baseline thunk's path for the cases the tag does not
  answer; a numeric operand is the constant `number`, with no test, which is
  the `typeof x === "number"` guard TypeScript-shaped code is full of. The
  names stored are the heap's own builtin strings, which no collection
  reclaims, so a destination slot beyond the caller's frame is sound. On the
  TypeScript mini the inliner's `opcode TYPEOF` rejections go from 17 to 0.
- **Object and array literals inside a callee.** `OptOp.ALLOC` builds the
  object inline exactly as the baseline emitter does and stores it to the
  callee's slot; the allocator adopts it as a temporary root and the only
  points that can collect are exits, which publish the frames covering the
  slot. `OptOp.INIT_SLOT` fills an object literal's slots with no shape guard,
  since the object was just built on that shape. The same node makes a
  function whose own body fills a literal's slots optimizable, which was a
  whole-body refusal before (`opt refused opcode INIT_SLOT`).
- **Closures, regexp literals and cells.** The largest of the three, and not
  on the list: a function was refused **as a whole** when its bytecode held an
  instruction the control flow graph did not take. Those are the instructions
  that build the objects the compiler makes for itself: `NEWREGEXP`,
  `CLOSURE`, `NEWCELLS`, `GETCELL`, `SETCELL` and `INITELEM`. They only
  allocate or store and fall through, and the roles already leave A a use and
  no def, so `bytecode_cfg_build` now takes them behind a flag that only the
  optimizing tier passes. TypeScript goes from 9 CFG refusals to 2 (both
  `INITFOR`), pdfjs from 14 to 9 (`TAILCALL_CALL`, `RETEST`, `INITFOR`), and
  the Octane RegExp benchmark's `runBlockN` functions, which each held one
  `NEWREGEXP`, now compile at all. `MOVECELL` is deliberately left out: with
  it admitted, `EarleyBoyer` returns a `TypeError`, and refusing only the
  functions that hold it makes the failure go away, so the fault is in
  compiling a function that holds a `MOVECELL` (its A register, which the move
  clears, is untracked somewhere) rather than in the graph.

### The "no cache" group is a counting artifact

The milestone named property sites with no cache (25,416 skips on TypeScript)
as the largest refusal group. They are counted once per build attempt, and
every one of them has an unfilled entry (`ic.key == null`), that is, the
instruction has never run: 10,819 attempts over 2,504 distinct sites on the
TypeScript mini, all `GETPROPC`, `GETTHISC`, `PUTPROPC` and `PUTTHISC`. A site
that has run has its cache filled by the interpreter or the baseline, so
there is nothing to speculate on and nothing to lower. They are correct as
`GENERIC` nodes on paths that do not run, and no work belongs here.

### Where the RegExp benchmark's time goes

Sampled on a loop of `re.exec` over one of the benchmark's patterns, inside a
function so that top-level `var` stores do not dominate: `regexp_run` (the
matcher, `re_wrapper.c` and the builtin's entry) 26%, property dispatch 9%,
building the match result array 9%, the JIT relay and thunks 8%,
`find_prop_idx` 4%, sweeping the result arrays 4%, capture `str_slice` 4%.
That matches the earlier conclusion from the other side: the matcher is a
quarter of this loop and less of Octane's mix, so the two matcher levers above
are worth a few percent at most. The lever that pays is compiling the
`re.exec(s)` call itself in the optimizing tier, which is the same call-node
work as a builtin call with a guard and a deoptimization contract.

### What remains for this milestone

- `MOVECELL` in a function the tier compiles, per the caveat above.
- Region compilation of a hot loop inside a function larger than the CFG
  budget. Nothing of it exists yet; the budget and the "raising it alone is
  -0.6%" measurement above still stand.
- Calls to builtin methods (the `re.exec` case) as graph nodes.

## Element reads, 2026-11-09: measured, not kept

The end of the section above named compiling a builtin method call as the
lever for RegExp. The first step of it was measured and dropped.

`OptBuild.get_elem` lowers a computed-key `GETPROP` (`a[k]`) into an
`OptOp.LOAD_ELEM` only inside an inlined body; the function's own body ran the
baseline's code there. Two changes were built and run: the same node for the
function's own body, and (needed with it, since the benchmark's arrays hold
`undefined` for unmatched captures) a `LOAD_ELEM` of rep NONE publishing
`undefined` for a hole instead of exiting.

The premise was wrong. `--jit-count-ops` shows the baseline already completes
computed element reads natively: 99.0–99.4% inline on pdfjs and TypeScript,
100% on Gameboy, with 13.5k thunk calls in 2.5M reads. There was no relay cost
to remove. Both changes measured inside the run-to-run spread: 9,785 and 9,892
with them, 9,507 and 9,559 with the hole relaxation alone, 9,778, 9,835 and
9,835 as committed, all on a machine at load average 3.2 where the composite's
spread is about 4%. Neither is kept: nothing here is repeatable, and the
element path already exits on receivers, indexes past the end and holes, so a
change there needs a calm machine and interleaved runs to judge.

The rest of the `re.exec` cost is the same in both tiers: the builtin call
machinery (`vm::jit_call_builtin_native` per call), the match result array
(9%), the sweep of those arrays (4%) and the capture substrings (4%). Compiling
the call as a graph node would have to replace that machinery rather than the
relay, and the loop that needs it most (`run(n)` called once, looping over
`re.exec`) is not credited to the optimizing tier at all: with `--opt` it stays
in the baseline's loop tier, and only `--opt-always` compiles it (0.21 s to
0.19 s on 300k iterations). A function that is entered once and loops is the
case region compilation is for, not call nodes.

## Region compilation: design, 2026-11-09

Started, and stopped at the design, because the change is a hundred lines
across five files with four invariants that only measurement can settle, and
this session's machine could not settle them (load average 3.2, composite
spread about 4%).

### What the refusals actually are

`--jit-stats` over the minis shows **no** `graph size` refusal at all: the tier
never reaches `OPT_STATE_MAX` or `OPT_BLOCK_MAX`. Every refusal is at the
control flow graph, and the large ones are decode failures over the whole
`code_count`:

| Function | Words | Registers | Reason |
|---|---:|---:|---|
| zlib `a1` | 37,006 | 518 | decode (`DEFAULT_CFG_BUDGET.max_words` is 4,096) |
| mandreel `initPhysics` | 11,203 | 58 | decode |
| typescript `:9881` | 2,786 | 65 | `MOVECELL` (the caveat above) |
| pdfjs `Stream_getChar` | 18 | 11 | `TAILCALL_CALL` |

So the region work that pays is not "pick a span out of an existing graph": it
is a **bytecode slice**, because for the functions that need it the graph
builder never decodes a first instruction.

### The pieces

1. **The region finder** (`opt.c3`, beside `opt_osr`). `opt_osr` is already
   called at the backward branch the baseline takes, with `ds.curr_pc` set to
   the loop header. From that pc: scan forward with `bytecode::decode_bytecode`
   to the first branch whose target is that pc (the back edge, within
   `OPT_REGION_WORDS_MAX`); then widen the span until every branch target of an
   instruction in it lies inside it, refusing if one lies before the header. The
   result is a closed slice `[start, count)` that `bytecode_cfg_build` accepts
   as it stands, since it validates that every target is in range.
2. **`pc_base` on the graph.** The slice's `DecodedCfg` keeps relative pcs
   (`cfg.nodes[i].view.pc`), while everything the emitter reads must be
   absolute: `OptNode.pc`, `OptBlock.pc`, exits, `bc.entries[]`, the dispatch's
   comparison against `ds.curr_pc`, `Asm.decode`, `ic_entries[next_pc - 1]`.
   Set `self.pc`/`self.next_pc` in `OptBuild.context` to
   `node.view.pc + (own ? pc_base : 0)`, where `own` is `fl_site[i] == 0`:
   an inlined body's instructions keep their callee's pcs, which `use_fn` and
   `decode` already resolve against the callee's own code array.
3. **The entry.** `begin_block` skips the merge and the phis for position 0, so
   a region whose header is position 0 would have no loop-carried registers in
   machine form, which is most of the point. A region build must take the merge
   path at position 0: with every forward predecessor dead the speculation is
   `INT32` for each register live at the header, and `repair` then overrides
   from the back edge exactly as it does for a header reached from a preheader.
   The header then has `blk.osr` set from `osr_target[0]`, which the emitter
   already turns into the entry that reloads those nodes from the window with
   `NOT_INT32`/`NOT_NUMBER` guards.
4. **Leaving the region.** A slice that ends at the back edge has one block
   whose fallthrough leaves it: the CFG gives the last instruction no
   successor, and `end_block` then emits nothing, so the code would run into
   whatever block is emitted next. That block needs an unconditional
   `OptOp.EXIT` at its `next_pc`, which is the same node `cold_field` and
   `throw_exit` already emit. Branch targets never leave the region, by (1).
5. **The two entry points the whole-function build owns.** In `opt_emit`, a
   region must not set `bc.entries[0]` to `labels[0]` (pc 0 is the function's
   entry, not the region's) and must not emit `call_entry` (a direct native
   call cannot enter a loop). `call_entry` is already skipped when
   `g.blocks[0].osr`, which the region header sets; `bc.entries[0]` needs a
   region flag, as does `bc.entries[pc] = to_base` staying as it is for every
   pc outside the region.
6. **Policy.** Retry with a region only after the whole-function build refuses,
   and only with `no_inline` set: inlining splices callee bodies into the
   graph, mixing pc spaces for no gain in a loop whose calls are `GENERIC`
   anyway. `opt_try_compile` already has a no-inline retry to model the second
   attempt on.

### What to measure

`bench/mini/zlib.js`, `mandreel.js` and `pdfjs.js` with `--opt`, interleaved
against the previous binary on a calm machine, plus `--jit-stats` to confirm
`opt: compiled` rises and the refusals fall. Acceptance is the plan's own:
per-benchmark gains in the full suite, and the differential suites unchanged
(`scripts/jit_check.sh`, `scripts/run_jit_diff.sh`, and its `--test262` mode
under `--jit --opt --opt-always`).

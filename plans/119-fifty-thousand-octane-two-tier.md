# 119: 50K Octane on a two-tier JIT

Status: **ACTIVE, 2026-11-03, on branch `jit`.** Supersedes [plan 113](113-fifty-thousand-octane.md).
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

Plan 113's SSA throughput report
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
Plan 094 records the current ownership boundaries.

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
  it. Plans 100 (scope index) and 101 (flat AST) cover lexer and resolver costs.
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
- int32 induction and unboxed f64 across loops. The plan 113 JSC comparison found
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
- Frontend: build line tables lazily or during lexing, carry out plans 100 and
  101, and compile function bodies lazily. Reference: 105–118K for CodeLoad in
  JSC.
- Allocation: bump allocation callable from generated code, and the collector
  work in plans 082 (pause reduction, sticky-mark nursery) and 095 (incremental
  collection).
- Object model: revisit the 64-property dictionary threshold for singleton objects
  and the per-plan shape limit.
- `Function.prototype.apply(this, arguments)` without materializing `arguments`.

## Rules carried over from plan 113

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
  compilation of its own (plan 113's RegExp JIT). The suite's regexp work is
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

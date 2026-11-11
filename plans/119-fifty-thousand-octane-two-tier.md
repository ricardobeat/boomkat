# 119: 50K Octane on a two-tier JIT

Status: **ACTIVE** on branch `jit` (worktree `.worktrees/jit`), last revised 2026-11-11 at `370ba16d`.
The composite is about 10,000. The target is 50,000.

This file holds the current state and the work ahead. The history of how the
tiers were built (status reports, dropped experiments, the rat-branch findings)
is in this file's git log on `plans/archive` up to `43ab0734`, and in the
commit messages on `jit`.

## Objective

Reach 50,000 on the original Octane 2.0 suite, run as one process with all 17
results, on the Apple M3 used for every measurement here. Keep sloppy, strict
and module semantics, the embedding API, bounded compilation memory, and a
small default code footprint for embedded hosts.

## Where it stands

Gate r15 (`716b8d37`, three alternating runs) is the last clean gate. JSC
columns are the system framework measured on 2026-11-03 (`--useDFGJIT=false`
for baseline, `--useFTLJIT=false` for DFG).

| Benchmark | `--jit --opt` | JSC baseline | JSC DFG | DFG / ours |
|---|---:|---:|---:|---:|
| Richards | 4,106 | 8,402 | 31,150 | 7.6 |
| DeltaBlue | 3,745 | 8,966 | 40,153 | 10.7 |
| Crypto | 8,636 | 9,630 | 55,796 | 6.5 |
| RayTrace | 6,875 | 15,022 | 78,291 | 11.4 |
| EarleyBoyer | 5,183 | 32,351 | 91,971 | 17.7 |
| RegExp | 2,428 | 15,001 | 24,184 | 10.0 |
| Splay | 10,760 | 36,793 | 72,600 | 6.7 |
| NavierStokes | 12,796 | 5,383 | 32,648 | 2.6 |
| PdfJS | 8,114 | 49,681 | 112,723 | 13.9 |
| Mandreel | 4,930 | 7,331 | 54,032 | 11.0 |
| Gameboy | 17,542 | 42,725 | 158,615 | 9.0 |
| CodeLoad | 32,593 | 118,169 | 115,334 | 3.5 |
| Box2D | 12,495 | 21,924 | 128,214 | 10.3 |
| zlib | 14,380 | 11,757 | 95,929 | 6.7 |
| Typescript | 27,350 | 92,329 | 188,061 | 6.9 |
| **Composite** | **10,064** | **23,302** | **78,645** | **7.8** |

SplayLatency and MandreelLatency (about 22,700 and 27,700) are in the
composite and left out of the table. The same binary scores 7,830 under
`--jit` alone and 6,106 in the interpreter; under `--jit`, RayTrace is still
below the interpreter (4,812 against 4,933).

- 50,000 is 5.0x the current composite and 64% of JSC's DFG configuration.
- The baseline tier is 1.28x the interpreter. JSC's is 3.35x its interpreter,
  and its baseline configuration is 2.3x our two tiers together. A large part
  of that gap is runtime (regexp, collector, strings, frontend, builtin calls),
  which no amount of optimizing-tier work recovers.
- Seven benchmarks gain 3% or less from `--opt`: EarleyBoyer, RegExp, Splay,
  PdfJS, Gameboy, CodeLoad, TypeScript.

Since r15, eleven commits (`1b5ad136`..`370ba16d`) are measured in instructions
retired only: TypeScript about -10%, EarleyBoyer -9%, Splay -6%, the RegExp loop
-15.7%. Gate r16 ran on a loaded machine (load average 3 to 8) and decides
nothing; its one calm pair read 10,132 against 9,841. **It has to be rerun.**

## What exists

Both tiers run the interpreter's frames: the register window and `Activation`.
Moving between interpreter, baseline and optimized code needs no translation.
`--jit` enables the baseline, `--opt` adds the optimizing tier. About 16,400
lines in `src/jit/` and `src/vm/vm_jit_*.c3`.

**Baseline tier** (`src/jit/baseline*.c3`, helpers in `src/vm/vm_jit_*.c3`).
One native function per `CompiledFunction`, compiled after 32 entries. Every
opcode is emitted: an inline path that mirrors the threaded handler's cache
hit, and a thunk into the handler for the rest. Inline: integer and number
arithmetic, compare and branch, property, global, variable and capture caches
read from the site's `ICEntry` at run time, element access, `typeof`,
`instanceof`, object and array literals by bump allocation, `new` of a simple
constructor. Calls between generated frames go through a call entry that
publishes the callee's `Activation` in generated code and returns inline,
including constructor frames, frames holding strings and any argument count.
It records the feedback the optimizing tier reads (shapes, value kinds, call
targets, builtin targets). Cap: 64 MiB of code, no eviction.

**Optimizing tier** (`src/jit/opt*.c3`). Built after 1,000 entries (loops
credit 250) from the bytecode CFG in one pass. A JS register is either *Window*
(in the register window, type unknown) or a node of rep `INT32`, `FLOAT64` or
`OBJECT` in a machine register. Everything else is a `GENERIC` node: the
baseline emitter's code for that instruction, between a store of the dirty
registers and a reload. Lowered: int32 and double arithmetic, typed and dense
element access, field reads and writes by shape (up to five shapes), `length`,
captures, globals and variables in inlined bodies, `Math.*`, `Array.push`,
literals and `typeof` in inlined bodies. Inlining: callee guard, a branch per
target at polymorphic sites, three levels deep, 64 words per callee and 200 per
tree, `apply(this, arguments)` and `.call` forwarding, inlined constructors
with allocation sinking. Functions over the 4,096-word CFG budget compile one
loop as a region at OSR. An exit writes machine registers back to the window
and continues in baseline code at the exit pc; eight exits discard the body,
two rebuilds are allowed, banned sites stay generic. Cap: 4 MiB,
second-chance eviction.

**Runtime done under this plan.** Native regexp matcher (`src/re/`, SLJIT,
declines lookarounds and back references), regexp fast paths (replace,
match-result shape, pristine guard, `lastIndex` slot), bounded nursery and
incremental collector, lazy function bodies, shared line tables, flat AST,
`apply` forwarding without an arguments object.

**Not there.** No rep for booleans, strings or `undefined`. A call that is not
inlined is a `GENERIC` node. No inlining of callees that contain a call the
inliner cannot also take, or a loop. No guard elimination or hoisting across
`GENERIC` nodes. No baseline code eviction. x86-64 is untested since the
optimizing tier landed.

## Working rules

- **Validation per change:** `scripts/jit_check.sh` (782 fixtures in six
  modes plus `opt_exit_check.sh`, about 70 s). Every fix gets a fixture in
  `test/jit/`.
- **Validation per layer** (a finished group of changes): `run_jit_diff.sh`
  in default, `--opt --opt-always --jit-stress` and region modes; the same
  under an ASan JIT build (temporary `boomkat_jitasan` target: `boomkat` with
  `sanitize: address` and `POOL_BYPASS`, C sources uninstrumented); test262
  `built-ins/{Math,String,Array,RegExp}`, `language/{expressions,statements}`;
  slim, tiny and no-NaN-box builds; binary size.
- **Measurement per change:** instructions retired (`/usr/bin/time -l`) on the
  loops in `boomkat-jit-experiments/p119/*_loop.js`. Load does not move them;
  Box2D's vary ±1.5%.
- **Gate:** `scripts/octane_gate.py`, three alternating runs against the
  previous gate binary, on a machine with load average under about 2 and
  nothing else running. Binaries and gate scripts live in
  `boomkat-jit-experiments/` (`gate_r16.sh` is the pattern).
- **Profiles:** `scripts/jit_profile.py` (needs the sandbox off). Optimized
  code is attributed to its function's `RET` ops. For a census of why
  something leaves a fast path, count in the helper behind an environment
  variable and remove the counter before committing.
- History on `jit` stays linear. Engine bugs found on the way are fixed, with
  a fixture, not deferred.
- No replay of completed stores, exact recovery at exits, roots held across
  helpers, no entry snapshot reused after an effect.

## Next steps

In order. Each item names what was measured; anything without a number is a
hypothesis until its first step, which is to measure it.

### 0. Close the open ends

1. Rerun gate r16 on a calm machine (`--jit --opt` against r15, then `--jit`).
2. Layer validation for `1b5ad136`..`370ba16d` (list above).
3. Bug, all modes: in a sloppy script, `acc = 42` where `acc` is an accessor
   on the global object does not call the setter.
4. Remove merged worktrees (`jit-alloc`, `jit-cp`, `jit-elems`, `jit-gbemu`,
   `jit-md`, `jit-newobj`, `jit-ops`, `jit-pl`, `jit-props`, `jit-puts`,
   `jit-strings`, `jit-vars`, `jit-regexp`) after checking each one's status.

### 1. Calls in the baseline tier

Counts are per mini run, from the census of what still reaches the C helpers.

1. `new` of a non-simple constructor always calls the helper: TypeScript 5.7M;
   RayTrace's constructors take the same path. Give `NEW_OBJ` the call entry, with the object allocated at the
   site.
2. Callees that need a scope object (`needs_env` with `env_call_ok`): PdfJS
   2.4M, TypeScript 476K, EarleyBoyer 121K. Create the scope in the call entry.
3. Smaller leaks: string results (TypeScript 2M), `CALL_VAR` (PdfJS 1.3M),
   `APPLY_ARGS` (Box2D 592K, RayTrace 225K), returns while marking (TypeScript
   850K), trivial callees still called through C (TypeScript 2M).
4. The protocol itself: a plain call costs about 220 instructions over an
   empty loop, a method call about 450. The `Dispatch` view is rewritten on
   entry and on return. Trace one call, then cut; the target is under 100.
   Richards, DeltaBlue and RayTrace are bound by this.

### 2. Collector and allocation

1. `gc_sweep_objects_step` walks a linked list of every object header: 11% of
   EarleyBoyer, and 10 to 20% of Splay in earlier profiles. Sweep by page, and let nursery
   survivors be the only objects a minor collection touches.
2. Constructor initialisation: `init_simple_constructor` 3.6% and
   `jit_new_simple` 2.1% of EarleyBoyer; a declined simple constructor wastes
   one allocation.
3. Allocation while marking takes the helper in both tiers.
4. Peak RSS for the suite is 2.0 to 2.3 GiB. Not investigated.

### 3. Values in the optimizing tier

Richards spends 99% of its time in optimized code and is still 7.6x behind
DFG; its profile is flat. The cost is the window: every `GENERIC` node stores
and reloads around itself and forgets every guard.

1. A boxed-value rep, so strings, booleans and `undefined` stay in machine
   registers across compares, branches, moves and field stores.
2. Calls as nodes: a call that is not inlined places its arguments and enters
   the callee's call entry without the baseline site's generic preamble, and
   declares what it clobbers, so shape facts survive it.
3. Inlining past the current limits: callees that hold calls or loops, and
   the 64/200-word limits re-measured once (2) exists.
4. Guard elimination and hoisting of shape checks, lengths and capture loads
   out of loops, on top of (2).
5. Exit policy: Splay discards 8 of 20 bodies after int32 overflow exits and
   pays for the rebuilds. Feed the exit reason into the rebuild instead of
   counting to eight.

### 4. Builtins and strings

1. A generic builtin call is about 530 instructions (125 at the site, 411 in
   five C functions), about 9% of PdfJS and of RegExp. Give builtins a direct
   native signature the site can call without building an argument frame.
2. Nodes for the hot ones: `Function.prototype.call` (TypeScript 1.5%),
   `Array.prototype.pop` (DeltaBlue 1.3%), `re.exec` and `re.test`,
   `charCodeAt`, `indexOf`, `substring`.
3. PdfJS: `concat_frame_holds_elsewhere` scans the whole frame span on every
   concatenation (4.8%), `note_feedback` 4.5%, `move_dense` 4.2%.
4. Property misses: `find_prop_idx` is 2.5 to 3% of PdfJS and DeltaBlue. Find
   which sites miss before changing anything.

### 5. RegExp and CodeLoad

One benchmark each, and the two furthest below JSC's baseline configuration.

1. RegExp (2,428 against 15,001): the matcher is a quarter of the time. The
   rest is the builtin call, the match result array, capture substrings and
   their sweep. Items 2.1 and 4.1 apply first; then intern or defer capture
   strings and cut `re_native_run`'s entry cost.
2. CodeLoad (32,593 against 118,169): frontend throughput. Not profiled since
   the flat AST merged; profile it before planning anything.

### 6. Before the branch can merge

- x86-64: build, differential suites, and phi spilling in the register
  allocator.
- Baseline code budget: a small default cap for embedded hosts and eviction of
  code that has not run recently. The suite ends at the 64 MiB cap.
- Documentation of the tiers in `docs/architecture.md`.

## Evidence

`119-fifty-thousand-octane-two-tier/baseline-2026-11-03/` holds the JSC and
rat-branch measurements the JSC columns come from (logs, profiles, scripts,
`manifest.json`). Gate outputs since then are in
`boomkat-jit-experiments/g*_*/`.

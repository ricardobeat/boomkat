# 119: 50K Octane on a two-tier JIT

Status: **ACTIVE** on branch `jit` (worktree `.worktrees/jit`), last revised 2026-11-12 at `43f259c4`.
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

Gate r17 (`127b4c61`, 2026-11-11, calm machine, three alternating runs
against r15): `--jit --opt` **10,654** against 10,175 (+4.7%), `--jit` 8,349
(r15: 7,830). Gains: Gameboy +30%, RegExp +20%, PdfJS +16%, DeltaBlue +16%,
Splay +12%, RayTrace +8%, EarleyBoyer +6%, TypeScript +5%. RayTrace under
`--jit` is now above the interpreter (5,045). Peak RSS rose from 1,997 to
2,362 MiB over the bundle; not yet explained.

Gate r22 (`0c06bb31`, five runs against r18, one disturbed): **10,551**
against 10,472. Box2D 13,238 (the epoch fix `d5efe152`), TypeScript +4%,
DeltaBlue +3%, RayTrace +3%; PdfJS, Splay and CodeLoad read 5% lower in this
gate with fewer instructions executed (collector timing; recheck in the next
gate). Peak RSS 2,013 MiB.

Since r22, ungated (steady instructions per iteration, `scripts/mini_steady.py`,
`b2df5d27` to `ff15b34f`): Richards 26.1M to 18.1M, DeltaBlue 38.2M to 32.4M,
RayTrace 148.6M to 139.2M, EarleyBoyer 661M to 633M (`1aa1e94e`: Richards
18.0M, DeltaBlue 32.3M). JSC FTL: 1.13M, 1.76M, 6.48M, 39.6M. Commits: `83caf60e` (constant field store), `e9db9974` (cached
add under the prototype epoch), `d90793c1` (minis time steady runs),
`881b2048` (store into an old owner), `579086cc` (room for inlined frames
tested once per entry), `4e05a8e7` (inlined method proven by its function
object), `5d54f18c` (shape facts across joins), `c41cf2b9`, `ae019c27`,
`ff15b34f`, `1aa1e94e` (step 3.0). Then `f5e641b8` (booleans and joined objects in
registers), `0353b45c` (an inherited megamorphic hit fills an epoch entry),
`96dd6a13` (an inherited read proves its receiver's shape), `f74b3dfd` (no
callee note in optimized code): Richards 17.2M, DeltaBlue 27.5M.

**Box2D is unstable under `--opt` and that comes first** (step 0). Inside the
full bundle it scores 8,000 to 12,700 from run to run (gate median 9,759, r15
13,026 and stable); the mini (`box2d_loop.js`) never shows it. r16 already had
it, less often.

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

In order. Each item says what is measured, what to build and where, what must
hold, and how to tell it worked. A number without a source in this file is from
the call census or a profile of 2026-11-10/11. "Verify" marks an assumption
that has to be checked in the code before building on it.

### 0. Close the open ends

1. **Box2D's slow mode: explained, two causes fixed, one left to step 2.**
   Box2D in the bundle scores about 12,700 or about 8,500 from run to run.
   - Fixed (`f49f90f3`): `ic_fill_read_heap` marked every receiver observed
     when any object on its chain was a dictionary, so Crypto's instances
     moved `prototype_epoch` 28,000 times a run. Only a dictionary receiver
     is observed now; 31,700 moves per bundle run became 179.
   - Fixed (`d5efe152`): freeing an observed object moved the epoch, once per
     object. A major sweep that freed fourteen (dictionary objects CodeLoad
     left behind) voided every inherited-read cache fourteen times. One move
     per sweep now; shape exits in an affected Box2D run 180 to about 70.
   - Left: the slow runs are exactly the runs in which a major collection
     starts inside Box2D's timed window (`GCSTART`/`GCEND` stamps: one major
     cycle of 260 to 290 ms wall in each slow run, no collection at all in
     each fast one, 6 of 6 runs). That cycle costs Box2D a quarter of its
     score. Which benchmark pays for a major cycle depends on allocation
     volume, which depends on how many iterations the timed benchmarks before
     it ran. This is the collector's cost (step 2), not a JIT defect.
   - Gate r18 (`f49f90f3`, 5 runs, against r17): composite 10,554 against
     10,587; Box2D per run 12796, 12721, 11050, 12708 (and 8522 in a run the
     machine disturbed) against 11308, 12561, 9569, 9569, 12721.
2. Layer validation of `1b5ad136`..`91dd8227` done so far: `jit_check`
   (789 files, 6 modes), `test-local`, `test-jit`, `test-jit-diff`,
   `test262-jit-diff`, slim, tiny, no-NaN-box build. Still owed: ASan JIT
   build, GC-stress, the full test262 gate.
3. Merged worktrees removed (branches kept). `jit-strings` stays: it holds
   eight `STRING_TRACE` prototype commits that are not in `jit`.

Done since r16: optimized code kept through the mark phase (`c03a4ffd`),
inline string-content equality (`06ada748`), inherited reads cached through a
settled dictionary receiver (`1ab1b419`, Gameboy), inline global step
(`d6baf093`) and bitwise not (`338d581d`), call-path trims (`127b4c61`), the
global accessor store bug (`91dd8227`), the two epoch fixes above.

### 1. Calls in the baseline tier

Today a call site (`Asm.emit_direct_call`, `emit_call_body` in
`src/jit/baseline_call.c3`) loads the callee's `CompiledFunction`, calls its
call entry (`emit_call_entry`) with `(ds, bottom, retval, packed)`, and on
`JIT_CALL_SLOW` falls to `vm::jit_call`, which re-classifies the call in C
(`jit_call_enter`, `src/vm/vm_jit_call.c3:82`) and publishes the frame through
`th_publish_lean`. Every item here moves one class of call from the C path to
the entry.

**1.1 `NEW_OBJ` through the call entry.** TypeScript 5.7M per run, and every
RayTrace constructor. Now: `jit_new_simple` for flagged simple constructors,
otherwise `jit_new_lean` (`vm_jit_call.c3:287`), which validates the site's
`prototype` cache, allocates and publishes in C.

- Add a construct bit to `packed` beside the existing receiver bits. The site
  does what `jit_new_lean` does before the publish: guard the constructor is a
  compiled, constructable, non-arrow, non-derived function with no brand or
  field initialiser (static per target: bake the answer into the callee's
  `BaselineCode` as a second entry label, `construct_entry`, emitted only for
  functions that pass); check the site cache (`key == prototype`, shape id and
  generation of the constructor, data slot) and load the prototype.
- Allocate at the site with `ALLOC_SUB` (`baseline_alloc.c3`), the same
  subroutine `NEWOBJ` uses, writing the header with the prototype from the
  cache. Capacity above `INLINE_PROPS` (`constructor_capacity`) goes to the
  helper at first; count how often before inlining `reserve_props`.
- `construct_entry` differs from `call_entry` in three stores: `this_binding`
  is the new object, `flags` has `ACT_FLAG_CONSTRUCT`, `new_target` is the
  function. The inline return already handles construct frames (`d7027402`).
- Call `ic_note_constructor` only on the slow path; the opt tier needs the
  target once, not per call. Verify the opt tier reads nothing else from it.
- Must hold: the object is reachable from the moment it exists (it is in the
  callee's `this_binding` before any instruction that can collect; `ALLOC_SUB`
  already refuses while marking). `Reflect.construct` with another
  `new.target` stays on the C path.
- Measure: census counter for `NEW_OBJ` reaching `jit_call` goes to near zero
  on TypeScript and RayTrace; `raytrace_loop.js` and the TypeScript mini in
  instructions.

**1.2 Callees with their own scope object.** PdfJS 2.4M, TypeScript 476K,
EarleyBoyer 121K: all `needs_env` with `env_call_ok`, entered today through
`jit_enter_redispatched` after C builds the scope.

- In `emit_call_entry`, after the frame is published and before the body,
  call one helper `jit_entry_env(ds)` that does what the interpreter's entry
  does for such a function (allocate the declarative environment, link it to
  the closure's captured scope, store it in `act.lex_env`/`var_env`, re-arm the
  variable caches). On failure it returns a status and the entry unwinds the
  publish and returns `JIT_CALL_SLOW`. Verify what `env_call_ok` already
  guarantees so the helper has no decline of its own beyond allocation.
- That is a C call per call, but it replaces the unwind of native frames
  (`RESTART`) and a full re-dispatch. The second step, only if the helper still
  shows in PdfJS's profile, is allocating the scope inline with `ALLOC_SUB`
  for a scope of static size.
- The inline return must accept a frame whose `lex_env` is its own scope:
  nothing to release (scopes are traced), so only the guard in
  `emit_return_body` changes. Verify no path there assumes `lex_env == cap`.
- `var_ic_rearm` per new scope was 1 to 2% of EarleyBoyer; if it shows again,
  key the variable cache by scope shape instead of scope identity so a fresh
  scope of the same function hits.

**1.3 The smaller leaks**, each a separate small change:

- *String results* (TypeScript 2M, PdfJS 421K, EarleyBoyer 229K):
  `emit_result_window` sends a string result to `jit_ret` because the caller's
  result slot may be tracked (counted). Inline the same store the baseline's
  string register move uses: if the destination slot is not tracked, store and
  go; only a tracked destination calls the helper.
- *`CALL_VAR`* (PdfJS 1.3M): resolve the callee through the site's variable
  cache inline, as `load_global_callee` does for `CALL_GLOBAL`, then fall into
  the same direct call. Verify which of the 1.3M are cache misses (those stay
  slow) before writing it.
- *`APPLY_ARGS`* and the `NEW_OBJ` before it. Calls that still enter through
  `jit_call` (C), by opcode, per mini (`--jit`, 2026-11-11): RayTrace
  `NEW_OBJ` 995K and `APPLY_ARGS` 994K (the class wrapper
  `function() { this.initialize.apply(this, arguments) }`: one construction
  is both), Box2D 322K and 485K, TypeScript `NEW_OBJ` 3.7M, `CALL` 921K,
  `CALL_VAR` 387K, PdfJS `CALL` 2.2M, `CALL_VAR` 1.3M, EarleyBoyer
  `CALL_UNDEF_THIS` 204K. Three parts, in order:
  (a) done (`504534d7`): a call entry for a `forward_args` function. RayTrace
  under `--jit` 4.03G to 3.81G instructions, `jit_call` entries 2.0M to 1.0M;
  0.6% under `--opt`, 0.3% of Box2D.
  (b) `APPLY_ARGS` inline: when the register holds a count, the callee slot
  is `%Function.prototype.apply%` and the collector is not marking, do the
  window shuffle `jit_apply_lean` does and raise `heap_reg_count` to cover
  it; the state is then exactly the one `CALL_S` expects.
  (c) `CALL_S` as a direct-call site with its count read from the register
  (the call subroutine already takes the count in a register).
  Worth about 250 instructions per call saved: 11% of RayTrace under `--jit`,
  about 4% under `--opt` (which inlines most of these), 2% of Box2D.
- *Returns while marking* (TypeScript 850K): the inline return bails when the
  collector is marking because the result store needs shading. Emit the shade
  as a call to `jit_opt_shade` on that path instead of leaving through
  `jit_ret`.
- *Trivial callees through C* (TypeScript 2M `DONE` results): a callee whose
  body is a constant or field return is completed inside `jit_call_enter` by
  `@lean_call_*`. Give those functions a call entry like any other; the frame
  is cheap now and the C classification is not.

**1.4 The frame model.** Measured 2026-11-11 at `f74b3dfd` with
`scripts/call_cost.py` (instructions one call and return add, beyond the work
of the callee's body):

| | plain | method | fib |
|---|---:|---:|---:|
| `--jit` | 329 | 395 | 355 |
| `--jit --opt --opt-no-inline` | 342 | 404 | 367 |
| JSC baseline (`--useDFGJIT=false`) | 61 | 84 | 90 |
| JSC FTL (`noInline`) | 37 | 52 | 53 |

Richards spends 37% of its steady instructions in this protocol. Where a call
goes (lldb trace of Richards' scheduler): call subroutine before the call 53,
call entry 129 (prologue saving 14 registers 13, tests 16, `Activation`
stores about 50, view block 12, pinned registers and constants 12), return
subroutine 92, epilogue 11, call subroutine after the call 33. Each frame is
written three times: the 17-word `Activation`, the 8-word code view in the
`Dispatch`, and a native frame. **Target: under 20 instructions for a call
from optimized code to a proven callee, under 35 from a baseline call site.**

The model, in four rules:

1. **One native frame per entry from C.** C enters generated code through a
   trampoline (`jit_enter`, emitted once per heap) that saves the callee-saved
   registers, sets the pinned ones (`ds`, `heap`, `thunks`) and fast-calls the
   target. Every generated body is compiled with `sljit_set_context` on the
   trampoline's exact context (the optimizing tier's register pools, which are
   a per-platform constant, and a fixed local area), so it has no prologue.
   Calls between generated frames are `SLJIT_FAST_CALL` (one `bl`); the callee
   stores the return address in its `Activation` (`native_ret`) and returns
   with `SLJIT_FAST_RETURN`. Any status that leaves generated code is the
   body's existing `sljit_emit_return`: it unwinds the shared frame straight
   to the trampoline's C caller, abandoning every generated frame in between
   for free. That is the existing contract ("each abandoned caller resumes
   later through the entry table at its saved `curr_pc`"), so the status
   protocol does not change. `jit_floor`, `jit_depth`, the C-stack depth cap
   for these calls, the callee-saved register saves and the native locals
   that survive a call (`CALL_FLOOR_OFF`, `CALL_RESUME_OFF`) all go. The local
   area is scratch: valid between a store and a load with no generated call
   in between (verify every `reg_sp()` use; `cap_slot` in `opt_emit` lives
   across the body and moves to the `Activation` or a register).
2. **The `Activation` is written by its frame only where nothing can derive
   it.** A frame pushed by generated code writes `func`, `bottom`,
   `native_ret` and a constant `flags` word: two pair stores. A `SYNCED` flag
   bit, clear in that constant, marks a record whose other fields are not yet
   written. Before generated code calls into C (a thunk, a helper that can
   collect, throw or read frames) it runs `jit_sync` when `ds.act` is not its
   record: from the top down to the first synced record, `jit_sync` writes
   `parent`, `var_env`/`lex_env` (from the function object at `bottom[-2]`),
   `cat`, `forin`, `new_target`, the async fields, `serial`, `tv_func`,
   `this_binding` (from `bottom[-1]` and the function's call flags),
   `caller_valstack_top`, `retval` (from the caller's call instruction) and
   the parent's `curr_pc` (from this record's `native_ret`, through the
   caller code's return-address map), and sets `SYNCED`. Synced records form
   a prefix of the stack: a push writes a fresh record with the bit clear, and
   a pop never unsyncs what is below. Each record is synced at most once per
   push, so the cost is paid only by frames that reach C.
3. **VM-wide frame state is a cache of the top record.** `ds.act`,
   `vm.activation_count`, `vm.current_func`, `vm.valstack_top`/`bottom`,
   `ds.regs_base`, `ds.capture_refs` and the 8-word code view are written by
   `jit_sync`, not by calls and returns. Generated code holds the current
   record in a pinned register (`la`); `vm.activation_count` is derived from
   it. The collector, the unwinder, stack traces and every thunk run after a
   sync, so none of them sees the stale cache.
4. **Results travel in a register.** The callee returns the value in `R1`
   and status 0 in `R0`; the caller stores the value (a generated caller) or
   the trampoline returns it to C, which writes it where the interpreter
   wants it. The return path no longer needs `retval`, the result-window
   check, the result kind test (strings included: generated frames hold no
   counts), the "a native site waits" test or the caller's view reload.

A direct call from optimized code to a lean callee, in instructions:
caller: advance `regs` by the window offset, `bl`, test status, restore
`regs` (4); callee entry: return address and record (`add la`, two `stp`
with the function constant from a literal: 4), one room test against
`vm.valstack_end` with the activation array sized so that value-stack room
implies record room (verify the sizes: `MAX_CALLS` against the stack size
and the minimum frame) (3), the collector and interrupt poll (2); return:
reload the return address, `sub la`, `ret` (3). About 16. A baseline site
adds the callee test against its call cache (about 6) and the entry adds the
argument-count fill only for callees that need it.

Must hold, each checked before its stage lands:

- The window is the frame's truth at every safepoint. Registers past the
  formals are cleared at entry today (`clear_slots`) and again at return
  (`th_clear_tracked_regs`); keep only one (the collector scans each frame's
  span, `activation_span_end`, so clearing at entry is the one that must
  stay unless pops clear).
- Stores of heap values into the window while the collector marks shade them
  (`Asm.publish`); a result stored by the caller goes through the same rule.
- Generators, async functions, frames with `try` or for-in, derived
  constructors, `arguments` objects and tail calls keep today's entry and
  pops. A function is fast-entered only when its generated code reads no
  record field that `jit_sync` derives (verify per opcode: `LDTHIS` reads
  `act.this_binding`, `TRY` writes `act.cat`).
- The code eviction sweep (`opt_make_room`, `baseline_reap`) must not free
  code a suspended frame returns into: walk `native_ret` of live records.

Stages, one commit each, each measured with `call_cost.py`, the minis and
`jit_check`:

1. **Trampoline and shared native frame.** Bodies on the trampoline's
   context; call subroutine fast-calls the call entry; the return subroutine
   fast-returns; exits unchanged. `Activation` and VM state still written
   eagerly. Expect about 60 fewer instructions per call (prologue,
   epilogue, floor and depth, native save area).
2. **Lazy VM state** (rule 3): sync before C, view and `current_func` and
   counts no longer written per call. Expect about 50 fewer.
3. **Lazy record fields** (rule 2) with the return-address map. Expect about
   60 fewer.
4. **Results in a register** (rule 4) and static return tests (`cat`,
   `forin` only in functions with `TRY`/`INITFOR`). Expect about 40 fewer.
5. **Direct calls from optimized code** (`OptOp.CALL`, step 3.2) to the
   checked entry, skipping the tests the builder proved. Then measure what is
   left against the 20-instruction target and cut it.

**Progress (2026-11-11, `79332700`).** `call_cost.py` (plain/method/fib):

| stage | commit | `--jit` | `--opt --opt-no-inline` |
|---|---|---:|---:|
| before | `c2ee8c2d` | 328/396/355 | 346/410/370 |
| 1 trampoline | `cd7fc64e` | 305/366/325 | 312/373/337 |
| 2 lazy VM state | `25eff28e` | 245/306/265 | 252/313/277 |
| 3 lazy record fields | `46027126` | 218/286/238 | 228/293/251 |
| 4 results in a register | `f5ac3a54` | 194/256/211 | 201/268/226 |
| 5 fewer entry stores | `f1445652`, `79332700` | 165/227/182 | 174/236/192 |

Richards' steady instructions, stage against stage: 1 -5.8%, 2 -12.7%, 4
-6.0%, `f1445652` -3.6%. Stage 5 so far: the entry leaves `func`, `tv_func` and `caller_valstack_top` to
`jit_fill` (it reads the function from `bottom[-2]`), sets neither the value
stack's top nor `ds.curr_pc` (every call into C is handed its resume point),
writes flags and `heap_reg_count` as one word, and takes the result slot in a
register. The scope tests moved to the call subroutine (`emit_scope_test`,
shared with `CHECK_CALLEE`). `ACT_FLAG_JIT_CALLED` now implies a live
`native_ret` (`Activation.forget_return`, and the trampoline prologue clears
it), so the return tests the flags alone.

Findings that change the stage 5 plan:

- `call_cost.py`'s opt row does not measure optimized-to-optimized calls for
  plain and method: `run` is called twice and stays baseline code (no OSR
  into a loop that only calls), so that row is a baseline call plus the
  callee's tier-up counter. Only fib runs optimized code on both sides. Add
  an opt shape whose caller is hot by calls before measuring 5a.
- Value-stack room does not imply record room: the value stack grows past
  any multiple of `MAX_CALLS`, so the entry keeps both tests.
- A JIT GC-stress run of the whole list is clean (after `c8177a9b`, a
  `yield*` uncaught-throw bug the normal build had too), with the
  interpreter under `ulimit -s 65520`.

Where a plain baseline call's 165 instructions go now (lldb trace):

- Call subroutine, 47: the callee tests 26 (tag 3, header mask 6 with two
  materialized constants, builtin 3, scope 7, `comp_func` 2, code and entry
  lookups 4, the construct bit 2), the callee feedback 10 (re-deriving the
  cache from `curr_pc` with a multiply and a 64-bit constant), saves 2.
- Call entry, 36: gates 4 (realm, collector), record room and `retval` 6,
  value-stack room 4, argument count 3, `native_ret` 2, flags 4, `curr_pc`
  and `bottom` and `this` 2, clearing 6 slots 4, registers 2, jump 1; a
  baseline entry adds its tier-up counter (5).
- Return, 25: subroutine call and return 6, flags 4, result kind 3, `ds.act`
  test 3, pop 2, status 2, the body's fast return 3.
- Site, about 20: the callee read (a variable cache, 12 for a global), the
  undefined receiver, argument moves with heap tests, the four call
  registers; after the call 4.

Next cuts, in order:

- 5a. **Direct calls with a proven callee** (optimized code). When the
  builder names the callee object (`method_constant`; for a global or
  closure variable, the binding's current value, made `prototype_observed`
  so its death moves the epoch like a method's), the site guards with the
  object compare and the epoch (5 instructions) and fast-calls a `direct`
  label in front of the callee's entry, which stores its return address at
  `SUB_RET_OFF` and skips what the site proved statically (realm, argument
  count, receiver kind). Skips the whole call subroutine: about 35 fewer.
  A miss takes the existing subroutine path, so a polymorphic site costs
  the compare and no exit.
- 5b. **Lean-callable bit** in the function object's header, set at closure
  creation when `var_env` is set and `lex_env` is not a `with` scope, folded
  into the header mask test: the scope test's 7 go. First verify that
  neither field changes after creation.
- 5c. **The site hands over its cache address** with its resume point: the
  feedback check is 4 instructions instead of 10.
- 5d. **Inline the return** in functions with one or two `RET`s: about 6.

Those reach about 110 baseline and 70 optimized. The 20 and 35 targets need
the optimized tier's own convention, the one JSC's numbers reflect: an
optimized-to-optimized call passes the window in machine registers and
pushes no `Activation`, publishing the frame only when it exits or calls C,
the way an inlined body's frame is published today ("an exit from the body
publishes its frame and those of the calls around it"). A non-inlined
callee then costs the inlined guard plus a `bl`, a stack adjust and a
`ret`. That is the design to write next, reusing the inliner's
frame-publication machinery rather than the call entry.

**Stage 6: register calls between optimized functions** (the convention the
targets need; started 2026-11-12 after `43f259c4`, which made proven calls
from optimized code direct: a constant guard and a `bl` into the callee's
`direct` entry label, skipping the call subroutine).

What a direct call still pays, traced at `43f259c4` (plain, optimized `run`
calling `f`): the caller boxes every live value into its window and reloads
and unboxes them after (about 30), reads the callee's variable (12), the
callee entry pushes and fills an `Activation`, tests record and value-stack
room and clears the callee's registers (33), the callee unboxes its
arguments from the window, and the return pops through flag and result
tests (25). None of it is the call itself. JSC's 37 to 53 has none of it.

The convention, for a call from optimized code to a proven callee whose
optimized code is a *register leaf* (every node native, no call into C but
its exits and its back-edge polls' slow paths):

1. **Register entry.** Such a function gets a second entry, `reg_entry`, and
   a signature in its `OptCode`: the rep of each formal (from the build's
   own CHECK_I32/CHECK_NUM of the formal, else OBJECT-or-boxed) and of the
   result. Formals arrive in fixed argument registers in those reps; the
   result leaves in R1 in its rep. The entry saves the pool registers the
   body allocates into its own native frame below the shared one (`sub sp`,
   `stp` per pair) and restores them before `ret`: the caller's live nodes
   survive in registers, so the caller spills and reloads nothing.
2. **No `Activation`.** The callee's frame is virtual, as an inlined body's is.
   Its window lies in the caller's frame: the caller reserves it like an
   inlined body's (`room_slots`, `frame_regs`, so the collector scans it as
   part of the caller's span), and the callee writes it only where an exit
   needs it. A native stack-depth test (`sp` against a limit in the
   `Dispatch`, 2 instructions) replaces the record and value-stack room
   tests; a deep recursion takes the existing call entry.
3. **Exits in two phases.** A register leaf's exit cannot publish its frame
   while its caller's live values sit in saved registers the collector does
   not see. Its exit stub stores its own live values into its window (inside
   the caller's span), restores the caller's registers and returns to the
   call site with status `CALLEE_EXIT` and the exit's descriptor in R1. The
   site takes its own exit (its snapshot stores the caller's values and
   publishes the caller's frame at the resume point after the call), then a
   helper pushes the callee's `Activation` from the descriptor (function,
   window, resume pc, `retval` the call's result slot) and the interpreter
   or baseline code continues in the callee, returning into the caller
   through the ordinary path. A back-edge poll's slow path is such an exit.
4. **Caller node.** `OptOp.CALL_REG`: the guard (constant compare and epoch,
   or the callee test), argument nodes moved into the argument registers in
   the signature's reps (a rep mismatch converts or falls back to the direct
   call), `bl` to the callee's `reg_entry` loaded through `cf.opt_code`
   (null or a different signature: the direct call path), the result node
   defined from R1. The builder emits it when `direct_callee` holds and the
   callee's current optimized code is a register leaf with a matching
   signature; it does not kill the caller's registers.
5. **Code lifetime.** A register leaf's code may be retired while a native
   frame runs in it: the retirement already waits for no native code
   running (`opt_reap`); verify the sweep also never frees code a register
   call returns into (the caller's code is live while it runs).

Expected per call: guard 3, argument moves 0 to 2, `bl`, save and restore of
the registers used (1 to 3 pairs each way), stack test 2, `ret`, status test
1: about 15 plus the body. Steps, each measured with `call_cost.py`'s
opt-opt row (which needs callees that tier up by feedback, not
`--opt-always`, which compiles before the call feedback exists):

**Stage 6 progress** (2026-11-12, `35e7aa60` to `2c416f85`). Built, in a
different shape from the design above where the code showed better:

- Register mode is optimized code entered with no record: `reg_entry`
  (FAST_ENTER, the window in R1 and in `regs`, a native frame of
  `REG_FRAME_BYTES` = 512 of its own below the shared one, moved by
  `sljit_shim_adjust_sp`, a two-instruction `op_custom` for arm64 and
  x86-64, with the return address at `JitFrame.link_off`). Each frame has
  its own local area, so callers spill to theirs and nothing is shared; no
  per-register save/restore. `jit_enter` sets `Dispatch.reg_floor`
  `vm::JIT_REG_DEPTH` (`MAX_CALLS / 16`) frames below each entry from C;
  the entry declines past it or without value-stack room (`REG_DECLINE`,
  `OptExit.DEEP`, transient). Mode test where code must know it (returns,
  exits): `la.bottom == regs`.
- What may run in register mode is `OptGraph.reg_blocker`: no GENERIC but
  `RET`, no allocation, no loop, no scoped read of the running record;
  stores, exits, inlined bodies and `CALL_REG` are fine.
- Exits in two phases as designed: the exiting body stores its window,
  records `(oc, reason, pc or inline site)` in the `Dispatch` and returns
  `REG_EXIT`; each register-mode caller unwinds through `opt_reg_unwind`
  (its call appended to `vm.reg_calls`), and the first caller with a record
  publishes the whole chain (`vm::jit_publish_reg_calls`, sharing
  `jit_publish_call` with inline exits), counts the exit on the exiting
  code and continues it in its baseline code. A frame that starts register
  calls reserves `JIT_REG_DEPTH + 1` records at its entry.
- `CALL_REG` (`OptCg.emit_call_reg`): stores the snapshot, saves live
  pool registers in its own frame's area, loads `cf.jit_code.reg_entry`
  at run time (none: `OptExit.DECLINED`, which bans no site), `bl`,
  `regs -= window`, result from R1.
- Recursion: self-calls lowered as `CALL_REG` on the guess that the function
  is register-capable, rebuilt without when not (`OptBuild.self_reg_calls`).
  Root window moves become `COPY_WINDOW` only when they are all that blocks
  register mode (`window_moves`; as a default they doubled code size).
  A build compiles the callees it proves first (`opt_compile_callee`),
  keeping a feedback-less callee only if it can run in register mode.
- Tooling: `scripts/jit_report.py` (per-function builds, exits, call
  lowering, what keeps a body framed); `--jit-stats` counts register exits.

Measured: `call_cost.py` opt row plain/method/fib 165/186/188 to 90/175/141.
A recursive `fib` call is 112 instructions (traced): argument boxed into the
window and checked again as int32 by the callee (about 25), the callee guard
through the global's cache (25), result boxed and reloaded (15), entry
(floor, room, clearing the window: 20). Minis against r23 (`e7e0c034`):
Richards -2.5%, Splay -3.7%, the rest within 0.6%. Richards' hot methods
stay framed: `jit_report.py` shows them blocked by GENERIC `PUTTHISC` and
`GETPROP`, by calls of framed functions, and by loops.

Next, in order:

- 6.4 **Promotion.** A register-mode body that reaches something needing a
  record (a GENERIC, a call of framed code, a back-edge poll's slow path)
  pushes its own record in place first: `jit_publish_call` on its window
  from its caller's call (the caller's values are already in the window by
  the call's snapshot; the chain above must publish too, so promotion is
  the unwind path minus the exit), then continues in the same code as a
  framed body, and returns to its register-mode caller by popping the
  record and `REG_RETURN`. Then GENERICs, framed calls and loops leave
  `reg_blocker`, and register mode covers every proven call.
- 6.5 **Typed signature.** Formals and result in machine registers in the
  reps the callee checks (`CHECK_I32`/`CHECK_NUM` of a formal, the `RET`
  node's rep): no boxing into the window, no recheck. Exits rebox from the
  registers into the window before publishing.
- 6.6 **Guards.** A self-call needs no callee guard beyond the variable's
  epoch; a constant callee's guard is one compare. Entry: clear only
  the registers an exit can publish before their first write.
- Zlib lost 3% when root moves went back to GENERICs: the baseline `LDREG`
  is slower than `COPY_WINDOW`; look at its emission.

### 2. Collector and allocation

**2.1 Sweep.** `Heap.gc_sweep_objects_step` (`src/gc/gc_incremental.c3:102`)
pops every header off `gc_sweep_old`/`gc_sweep_young`, tests the reachable
bit, clears it and pushes the header back on `objects_old`/`objects_young`.
Every live object costs two list operations and a cache miss per cycle. 11% of
EarleyBoyer.

- Stage A, small: do not unlink survivors. Flip the meaning of the mark by
  epoch (the heap already marks by epoch, per the incremental collector work;
  verify the reachable bit can be compared against a cycle parity instead of
  being cleared), so a sweep only unlinks dead objects and survivors are read
  once, not rewritten. Promotion of young survivors becomes a splice of the
  surviving young list onto the old list at the end of the sweep.
- Stage B: objects of the pooled size classes live in pages
  (`ALLOC_SUB` already pops from page pools). Keep a mark bitmap per page; the
  sweep walks pages, frees unmarked blocks into the page's free list, and
  releases empty pages. No header list at all for pooled objects; the lists
  remain for large and exotic objects. This is what makes a minor collection
  proportional to the nursery.
- Stage C, only after B: bump allocation in the nursery region with survivors
  marked in place (sticky mark bits), so `ALLOC_SUB`'s free-list pop becomes a
  pointer bump and a limit check.
- Must hold: finalisation order and `hobject_free_step`'s incremental budget
  (large objects are torn down in slices); the remembered set (`remember`) for
  promoted objects; host edges. Each stage runs the GC-stress build
  (`make out/boomkat_gc_stress`) over `test/` once, since this is the one area
  where a missed root is the likely bug.
- Measure: `earley_loop.js`, `splay_loop.js` instructions and the
  `gc_sweep_objects_step` share; peak RSS must not grow (`run_memory_bench.sh`).

**2.2 Constructor initialisation.** `init_simple_constructor` 3.6% and
`jit_new_simple` 2.1% of EarleyBoyer. With 1.1 in place, a simple constructor
(`this.a = a; this.b = b`) is just a constructor whose body the baseline
already compiles with absent-property puts. Then: allocate the object directly
on the constructor's final shape (the shape `record_constructor_capacity`
has seen it end on, cached on the function with the shape generation), so each
`PUTTHISC` in the body is an overwrite of a pre-sized slot rather than a
transition. Guard: the body must store every slot before the object can
escape or the slot must start as `undefined` and be observable as absent; the
safe version keeps the transitions and only pre-sizes the storage, which is
what to build first. Remove `jit_new_simple` once the general path is as fast
on `earley_loop.js`.

**2.3 Allocation while marking.** Both tiers leave the inline allocator when
the collector is marking, because a new object must be shaded. Allocate black:
write the header with the current mark epoch set (one more constant in the
header word `ALLOC_SUB` writes). Verify the collector's invariant for objects
born during marking is allocate-black and not allocate-grey.

**2.4 Peak RSS** is 2.0 to 2.3 GiB for the suite. Record where it goes
(`--stats` at the high-water mark: object pools, strings, code, AST and
bytecode retained by lazy compilation) before deciding anything.

**2.5 Pauses.** Measured over the bundle (`--jit --opt`, every `gc_step`
call timed, 2026-11-11): 1.47 million slices, all under 250 microseconds
(99.8% under 50), 3.0 s of collector work in a 45 s run. No blocking loop
(`while (gc_phase != IDLE) gc_step(uint::max, ...)`) ran. Two kinds of slice
exceed 1 ms, each once or twice a run, both in a major sweep:

- `sweep_shapes` (sweep stage 2) runs whole: 4 to 6 ms in the one cycle where
  `trans_count` reaches `shape_sweep_at`. Its cost is `mark_object_shapes`,
  a walk of every live object. Design, not built: mark each survivor's shape
  chain into the bitmap as the object sweep visits it (stage 0 touches every
  survivor anyway), so stage 2 keeps only the passes over shapes and the
  transition table. What that needs, and why it was not done in passing:
  objects that change shape or are born after the sweep passed them. Advance
  `shape_recycle_epoch` when the bitmap is created (every cached shape id is
  either checked against that epoch or pinned, which is today's invariant),
  mark at every C store of `HObject.shape_id` (12 sites), clear a recycled
  slot's bit in `alloc_shape_slot` (`mark_shape_chain` stops at a set bit, so
  a stale one would hide the new shape's parent), grow the bitmap for ids
  past its size, and require `native_frame_depth == 0` at creation. The hole
  to close first: a cache filled during the sweep from the current shape of
  an object the sweep has not reached (`NewSite`, the baseline allocation
  template, the regexp result shape, opt `NEW_OBJECT`) can hand that shape to
  new objects in generated code after the source object has left it; mark at
  those fills, or walk `objects_young` at stage 2. A wrong enumeration frees
  a shape in use, so this wants its own pass with the GC-stress build.
- One or two slices of 2 to 8 ms in sweep stage 0, on a different ordinary
  object each run (two properties, no array). Not reproducible per object;
  the suspects are the scheduler taking the thread and `PagePool.dealloc`
  returning a page. Unverified: time the slice with thread CPU time.
- Prefetching headers ahead of the sweep cursor measured nothing (3M-object
  live heap with churn, 6.3 to 6.9G cycles either way): objects are swept in
  allocation order, which the hardware prefetcher already follows.

### 3. Values in the optimizing tier

The tier keeps a JS register in a machine register only as `INT32`, `FLOAT64`
or `OBJECT` (`OptRep`, `src/jit/opt_ir.c3:66`). Anything else forces a
`GENERIC` node, and a `GENERIC` node stores every dirty register it may read,
runs baseline code, reloads, and kills every fact (`OptBuild` facts are
cleared per `GENERIC`). Richards is 99% optimized code, flat, 7.6x behind DFG.

**3.0 Where the instructions go.** Richards' scheduler loop
(`while (this.currentTcb != null) { if (this.currentTcb.isHeldOrSuspended()) this.currentTcb = this.currentTcb.link; else ... }`),
single-stepped, ran 443 instructions at `b2df5d27` for an iteration that
makes no call and runs 314 at `1aa1e94e` (JSC's FTL runs the whole benchmark
in 1/16 of our instructions). Per node, as measured at `5d54f18c` (383):

| Node | Now | Floor in this object model |
|---|---:|---:|
| `this.field` read, shape not yet proven (tag 5, proxy 3, shape cell 6, storage 2, load 1) plus the object result test (inert 3, tag 5, mark phase 3) | 31 | 3 to 6 |
| inherited method read, constant path (`4e05a8e7`) | 42 | 17 |
| callee guard, constant path (`4e05a8e7`), with receiver test | 18 | 0 (folded into the read) |
| field read of an OBJECT node as INT32 (receiver 14, storage 3, int conversion 12) | 29 | 7 |
| global constant as INT32 (cache epoch 8, slot 3, TDZ 6, int conversion 12) | 33 | 9 |
| compare to a boolean in the window, reloaded and tested twice | 22 | 2 |
| `!= null` on a window value | 16 | 3 |
| field store of an object (receiver 19, old value 11, new value 11, barrier 6) | 50 | 9 |
| loop poll | 9 | 3 |

The floor column sums to about 80. No single node is the problem: each of
about 25 nodes costs 10 to 30 instructions where 1 to 7 would do, because
every emitter re-proves its operands from boxed values (tag, proxy, shape
through a memory cell), publishes results to the window and reads them back,
and reuses the baseline's sequences. Work the table top-down by mass, one
node kind per commit, re-tracing the loop each time (`tracerun.sh`,
`iter.py`). Done: the constant method (`4e05a8e7`, 443 to 401); shape facts
across joins (`5d54f18c`, to 383); the fastint tested first and the TDZ test
folded into the numeric test of a global (`c41cf2b9`); shared shapes pinned
and compared as immediates (`ae019c27`); the object tag tested first in
OBJECT loads and stores (`ff15b34f`, to 322); the receiver test dropped
where the method's read proved it (`1aa1e94e`, to 314).

Next, by mass in the loop as it stands:

- Compare and branch: the boolean of `(a & K) != 0 || b == K2` is boxed,
  stored to the window, copied to the caller's slot and tested twice (22),
  and `!= null` on a window value is 16. A `BOOL` rep (or branch threading
  through the inlined body's return) makes both 2 to 3.
- The inherited method read is still 38 (class 6, first prototype 6, epoch
  2, slot address 3, load, object result 8) plus 11 for the guard. A write
  watch on the owner's slot (a `GcBits` bit that every store path honours
  by moving the epoch) removes the load, the compare and the object result;
  shape implying prototype would remove the prototype compare. Without
  those the floor is about 25.
- Global constants are 22 each. A baked slot address saves 3; a write watch
  on the binding folds the load to a constant.
- Receiver tests on an OBJECT node: tag 5, proxy 3, shape 3. The proxy test
  goes if a proxy's shape can be shown never to equal a cached one (proxies
  keep target and handler outside their properties; not yet audited). The
  tag test goes when the node is known to be an object (a `KNOWN_OBJECT`
  flag set by the load that passed its shape guard, kept across blocks like
  the shape facts).
- The mark-phase test after each object load (3) exists because an OBJECT
  node is not a root: shade at the store to the window instead, where
  `store_object` already tests the phase.
- `this` is reloaded from the activation at every use (2) and re-proven
  after each call; an entry node in a register makes each use free (3.1).
- The field store is about 35: receiver 11, old value 3, new value 3,
  barrier 6, storage 3.

The same accounting for calls is in 1.4: a non-inlined call is about 313
instructions of protocol against JSC's 56 to 74, and 29% of Richards' steady
state. Inlining removes it only where the callee holds no call of its own
(`TaskControlBlock.run` is rejected for "opcode CALL", its `this.task.run` for
"polymorphic call"): nested calls from inlined frames and polymorphic inlining
(3.2) are worth about 240 instructions per call each.

**3.1 A boxed rep.** Add `OptRep.VALUE`: a boxed `TVal` in a machine register,
type unknown or partly known.

- Nodes: `LOAD_WINDOW` (the register's current value, no guard), and `VALUE`
  results for `LOAD_FIELD`, `LOAD_ELEM`, `LOAD_CAP`, `LOAD_GLOBAL` instead of
  the present choice between "number or exit" and "write to the window".
  Consumers that take a `VALUE`: `STORE_FIELD`, `ADD_FIELD`, `INIT_SLOT`,
  `STORE_ELEM`, call arguments, `RET`, `BRANCH_TRUTH`, and the equality
  compares (`BRANCH_WINDOW`, `COMPARE_WINDOW` become node forms).
- Known-type facts on a `VALUE` node: a small lattice (boolean, undefined,
  null, string, object-of-shape) set by guards and constants, so
  `typeof x === "string"`, `x === undefined` and `if (flag)` fold or become
  one tag compare. This replaces most uses of `STORE_CONST`, `TYPEOF`, `LNOT`
  writing to the window.
- Strings: registers hold no counts (the invariant `4534a792` relies on), so
  a string in a machine register is as sound as one in a window register,
  provided an exit writes it back before anything that can collect or flush
  zero-count strings. Every `VALUE` live across a node that can call into the
  runtime is either stored first (dirty-store, as now) or recorded in that
  node's root map. Start with store-first; root maps are an optimisation.
- Barriers: a `VALUE` stored into an old object while marking exits today
  (`SLOW_PATH`); call `jit_opt_shade` inline instead.
- Regalloc: `VALUE` uses the general-register pool like `OBJECT`; a spilled
  `VALUE` lives in its home window slot, which is exactly the present
  behaviour, so spilling needs no new mechanism.
- Build order: rep and `LOAD_WINDOW`/`STORE` plumbing with no consumer (must be
  perf neutral and pass `jit_check`), then field loads and stores, then
  compares and branches, then call arguments. Measure `richards_loop.js` and
  `deltablue_loop.js` after each; count `GENERIC` nodes per hot function with
  `--opt-dump` before and after (Richards' scheduler loop was 48 `GENERIC`
  against 27 `LOAD_FIELD`).

*Progress (2026-11-13, `jit` at `fbff012a`; last gate g33 = 15,119, ungated
since).* Built: the rep, renamed from `OBJECT` (`05a61708`); strings read
from counted holders (`df86688a`, `OptNode.counted`); field, element, global
and capture reads as `VALUE` by default, a numeric use asking the next round
for a typed load (`fdad95f5`, `ask_number`); truth tests and `!` on any
`VALUE` in its register (`c7577776`); `COMPARE_WINDOW` and `BRANCH_WINDOW` as
node forms (`a65b6e8e`); the mark-phase test moved from every load to the
stores into the window, through a register-keeping `Trampoline.shade`
(`1aaab5d8`); a plain-object fact per register that survives calls, so a
receiver proven plain once is tested only for its shape after (`9ae11798`);
a sloppy function's `this` as a `THIS` node read from the record where it is
used, which removes LDTHIS's publish (`fbff012a`). Call arguments reach
`CALL_REG` as `VALUE` nodes through the dirty stores; `STORE_FIELD` and
`ADD_FIELD` take them; stores into old objects while marking go through
`jit_opt_store_slot` rather than exiting. Two older builder bugs surfaced and
were fixed: an inlined body's case test read the flattened graph's table
(`9a2ce946`, an infinite loop) and a base constructor's adds through a copy of
the object were missed (`9cfdc661`, TypeScript lost `tokenId`; the mini
suite caught it, `jit_check` did not). Steady instructions per iteration,
`a65b6e8e`'s predecessor to `fbff012a`: Richards 9.91M to 9.29M, DeltaBlue
21.5M to 19.0M, Box2D 513M to 481M, TypeScript about -5%. Left: the type
folds (`typeof`, `=== undefined`), which no hot profile shows yet; RET and
`STORE_ELEM` taking a `VALUE` (RET's cost is the return protocol, 1.4).
Where Richards' optimized code goes now: `LOAD_FIELD` 32%, `STORE_FIELD` 13%,
`CHECK_CALLEE` and `GUARD_BINDING` 6% each, `CALL_REG` 4%; inherited method
reads are about 60% of DeltaBlue's `LOAD_FIELD` samples (shape, class, epoch
and prototype tests, then `CHECK_CALLEE` again: 3.0's table), and the inline
rejections are callees holding a call or a NEW_OBJ (3.3).

**3.2 Calls as nodes.** A call that is not inlined is `GENERIC`: the baseline
site with its feedback recording, generic guards and view reload.

- `OptOp.CALL`: target `CompiledFunction*` from feedback, guarded by
  `CHECK_CALLEE` (already exists for inlining). Arguments are nodes; the
  emitter stores them straight into the call window, then calls the target's
  call entry. With 1.4(b) the entry is the post-guard body label.
- Declared effects: a call clobbers the heap (fields, elements, globals,
  captures written by others) but not the caller's registers. So numeric and
  `VALUE` nodes that are not dirty stay in callee-saved machine registers
  across it (SLJIT saved registers; the baseline body uses five scratch
  registers, verify which saveds are free), and facts about a register's
  *type* survive while facts about an object's *shape* are dropped only for
  objects that may have been reached by the callee. First version: drop all
  shape facts, keep all type facts.
- Exits: the call's frame state is the state after the call with the result in
  its register. A throw unwinds through the published frame as now. If the
  callee's code is discarded and rebuilt while the caller is on the stack, the
  caller returns into valid code because the call entry is reached through
  `f.jit_code` at call time; verify the eviction sweep (`opt_make_room`) does
  not free a caller that is on the native stack (it records entries for this).
- Polymorphic sites: up to `OPT_POLY_MAX` targets as a `BRANCH_CALLEE` chain,
  each a direct `CALL`, with the `GENERIC` call as the tail.

**3.3 Wider inlining.** Limits now: 64 words per callee, 200 per tree, depth
3, no callee with a loop, no callee holding a call the inliner cannot also
inline.

- With 3.2, a call inside an inlined body is an `OptOp.CALL` whose frame state
  names two frames. The exit machinery already materialises inlined frames
  (`jit_inline_materialize`, `OptInlineExit`); what is new is a *call* made
  while logically inside an inlined frame, which needs the inlined callee's
  activation to exist for the duration of the call (stack traces, `arguments`,
  a throw through it). Materialise before such a call and treat the rest of
  the inlined body as running in a real frame; or, simpler and the first
  version, inline only when every call in the callee is on a path that has
  never run (already an `EXIT`), and otherwise use 3.2's direct call.
- Loops in callees: the flattening (`bytecode_cfg_finish`) already produces a
  CFG; the restriction is that the callee's back edge needs an interrupt
  check and an OSR-free loop header. Admit loops whose header has no OSR
  entry; the interrupt check exits with the materialised frame.
- Re-measure the 64/200 limits on the suite once 3.2 exists; inlining stops
  being the only way to make a call cheap, so the right limit may go down for
  cold-ish sites and up for hot ones. Use call-site counts from feedback
  rather than a single size threshold.

**3.4 Guard elimination and hoisting.** With 3.1 and 3.2 there are stretches
without `GENERIC` nodes for facts to live across.

- Give every node an effect class (none, writes field of shape S, writes
  element, calls). Shape facts die only on a call or on a store that can
  transition the object; a `STORE_FIELD` overwrite kills nothing.
- Loop-invariant hoisting for `CHECK_*` shape guards, `LOAD_LENGTH`, typed
  array base/length, `LOAD_CAP` of an immutable capture: hoist to the
  preheader when the loop body has no effect that kills them. The hoisted
  guard's exit resumes at the loop's entry pc with the pre-loop state, which
  the builder has (the preheader state the header's phis are built from).
- Bounds checks: an induction variable with a known range against a hoisted
  length removes the per-iteration `BOUNDS` exit (NavierStokes, Crypto, zlib,
  Mandreel). Int32 overflow checks on `i++` bounded by a compare against an
  int32 go the same way.

**3.5 Exit policy.** Eight exits of any kind discard the body
(`OPT_EXIT_MAX`), two rebuilds (`OPT_REOPT_MAX`), then it stays baseline. Splay
discards 8 of 20 bodies after int32 overflow exits.

- An exit records its reason and pc in the site's feedback before leaving (the
  `UNPROFILED` exit already does this for typed arrays). The rebuild reads it:
  `OVERFLOW` at a site makes that node `FLOAT64`; `NOT_INT32` widens the
  check to number; `SHAPE` adds the shape if the cache now has it, else makes
  the site `GENERIC`; `HOLE`/`BOUNDS` make the access `GENERIC`.
- With per-site adaptation, a rebuild fixes its cause, so trigger it on the
  first exit from a site that has feedback to add (as `UNPROFILED` does)
  rather than after eight, and stop counting rebuilds that changed the graph
  against `OPT_REOPT_MAX`.
- Measure: `--jit-stats` discards and rebuilds per suite run (2,089 compiles
  for 610 discards at the last count), Splay and Gameboy against `--jit`.

### 4. Builtins and strings

**4.1 The builtin call.** Done so far (2026-11-11): `CALL_GLOBAL` of a
builtin completes in the call subroutine (`ff9f30f4`); the wrapper chain is
one function (`ee86985c`); `jit_builtin_leaf` (`6b19cb02`) answers `charAt`,
`fromCharCode`, `push`, `parseInt` of a number and the Math functions without
a `BuiltinContext`, reusing `opt_array_push` and `opt_math_fn`, behind a
kind table by builtin number (a miss costs 7 instructions): PdfJS loop -3.0%,
Box2D -5.1% under `--jit`. A site of `Function.prototype.call` keeps its
callee feedback (`0c06bb31`); before, the builtin note made every such site
polymorphic and the optimizer never inlined through `f.call(...)`. Still
open: `indexOf`, `substring`, `pop`, `splice` (PdfJS 296K), and calling the
leaf from the site without the helper's preamble. The original analysis:
about 530 instructions: 125 at the site, 411 across
`jit_call_builtin_native` → `jit_call_builtin` → `th_call_native` → the
builtin's dispatch → the builtin (`vm_jit_call.c3:847`). The C side
re-classifies the callee, binds cache biases, goes through the threaded
handler with a stop table, and checks a handoff enum afterwards.

- Add a fast-call table: for builtins that neither re-enter JS nor need a
  frame (most of `String.prototype`, `Math`, `Array.prototype.push/pop`,
  `charCodeAt`, `indexOf`, `substring`, `fromCharCode`, `RegExp.prototype.exec`
  on a pristine regexp), a function `fn TVal(Heap*, TVal this, TVal* argv,
  uint argc)` that returns a sentinel for "take the general path". Generate
  the table next to the `Builtin` enum so a builtin opts in by having the
  function.
- The baseline site, when its feedback holds `IC_BUILTIN_TARGET | index` and
  the table has an entry: guard the callee is that builtin function object
  (pointer compare against the realm's builtin, loaded once), call the fast
  function with a pointer into the window, store the result. No frame, no
  handoff. Errors: the fast function returns the sentinel before any effect
  and the general path throws.
- Must hold: a fast function never allocates in a way that can collect while
  holding unrooted values other than its arguments (which are in the window).
  Results that are fresh strings are stored to the window by the site before
  anything else runs.
- Target: under 150 instructions for `charCodeAt`-class builtins. Measure
  PdfJS, RegExp and TypeScript loops.

**4.2 Builtin nodes in the opt tier.** Same table, called from an
`OptOp.BUILTIN` node after `CHECK_BUILTIN` (exists). Inline nodes only where
the builtin is a few instructions: `charCodeAt` on a Latin-1 string (bounds,
byte load), `Array.prototype.pop` (mirror `ARRAY_PUSH`), `Function.prototype
.call` (rewrite to a 3.2 `CALL` with shifted arguments; TypeScript 1.5%).
`re.exec`/`re.test` go through the table, not an inline node.

**4.3 Strings in PdfJS.**

- `concat_frame_holds_elsewhere` (`src/vm/vm_execute.c3:354`, 4.8%) scans the
  frame's whole register span on every accumulating `s += x` to prove no other
  register aliases the accumulator. Replace the scan with a proof kept at
  birth: when the concat path creates the accumulator it is in exactly one
  register; mark the string (a header bit, cleared by any register-to-register
  move of a string, by a call argument copy, and by a capture or property
  store). The moves are in the interpreter's `LDREG`/argument paths and in
  the baseline's string register move, so the bit is cleared in few places.
  Verify the complete list of places a string value is copied between window
  slots before relying on it; if the list is not short, fall back to scanning
  only `heap_reg_count` slots rather than the span.
- `note_feedback` (`src/vm/vm_ops.c3:171`, 4.5%) is called from `jit_add_concat`
  and `jit_mod` on every execution. Feedback is sticky bits; test in generated
  code whether the bits to be set are already set (one load, one mask) and
  call only when they are not.
- `move_dense` (4.2%): find the caller first; it is likely array growth by
  `push` or a `shift`/`splice`. Growth should double; a `shift` loop wants an
  offset-start dense array. Do not design this before the caller is known.

**4.4 Property misses.** `find_prop_idx` is 2.5 to 3% of PdfJS and DeltaBlue.
Use the call-graph parser from the RegExp work (`jit-regexp/scratch/paths.py`,
copy it to `scripts/` if it earns its keep) on a `sample` of each to split
callers. Expected classes, each with a different fix: megamorphic reads (more
than `IC_POLY_MAX` shapes: a per-site secondary hash keyed by shape),
dictionary-mode receivers (no cache at all today for inherited reads), and
`jit_put_absent` misses on objects past their reserved capacity.

### 5. RegExp and CodeLoad

**5.1 RegExp** (2,428 against JSC's 15,001 with its regexp JIT). After the
2026-11-10/11 work the loop is the builtin call, the result array, capture
strings, and the matcher at about a quarter.

- 4.1 removes the call overhead for `exec`, `test`, `replace`, `match`,
  `split`, `search` with a pristine regexp.
- Result array: allocate on the cached match-result shape with dense storage
  sized to the capture count in one allocation. Captures as slices: a capture
  substring that shares the subject's storage (offset and length, keeping the
  subject alive) instead of a copy plus intern. Verify whether the string
  representation has a slice form; if not, this is a string-representation
  project and belongs with 4.3, not here.
- Unused results: `re.exec(s)` whose result is only tested for truthiness, and
  `replace` with a string pattern, need no array at all. In the opt tier a
  `BUILTIN` node whose result feeds only `BRANCH_TRUTH` calls the `test` fast
  function.
- `re_native_run` entry cost: per call it re-reads flags, sizes the capture
  buffer and selects the Latin-1 or UTF-16 body. Cache the selected entry and
  capture count on the regexp object after the first run.
- Matcher: first-character scanning for an unanchored pattern (`memchr`-style
  skip to a byte that can start a match) and inline class tests above Latin-1.
  Last, since the matcher is the smaller part.

**5.2 CodeLoad** (32,593 against 118,169; JSC is at that level in every
configuration, so this is parse and compile throughput). No profile since the
flat AST merged. Profile first, then expect the work to be: skipping function
bodies without building AST (a pre-parser that only finds the closing brace
and records free variable uses), since lazy compilation today still parses;
verify that. The JIT plays no part in this benchmark.

### 6. Before the branch can merge

- **x86-64.** Build and run the differential suites on x64 Linux (podman, per
  the local validation notes). The register allocator's pool is much smaller
  there; phis are never spilled, which will fail to allocate in functions with
  many loop-carried values. Spill a phi to its home window slot like any other
  value, with the move resolved at the predecessor's edge.
- **Baseline code budget.** The suite ends at the 64 MiB cap with nothing
  evicted. Reuse the optimizing tier's second-chance sweep (`opt_make_room`):
  a per-function "entered since last sweep" bit set by the entry, code freed
  when clear and the function not on the native stack, `f.jit_code` reset so
  the interpreter runs it until it is hot again. Default cap small (a few
  MiB) for embedded hosts, raised by the CLI.
- **Docs.** The tiers, the frame contract, exits and the feedback format in
  `docs/architecture.md`.

## Evidence

`119-fifty-thousand-octane-two-tier/baseline-2026-11-03/` holds the JSC and
rat-branch measurements the JSC columns come from (logs, profiles, scripts,
`manifest.json`). Gate outputs since then are in
`boomkat-jit-experiments/g*_*/`.

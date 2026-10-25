# 106: Closing the interpreter gap to Ignition

Status: research complete, no implementation started.

Research baseline: `742fef58` on `main`, measured on 2026-10-25 on Apple
silicon (macOS, arm64) with the default `boomkat` target (O2, threaded
dispatch, NaN-boxing). Source references are to that commit. Recheck them, and
the overlapping items in plans 104 and 105, before implementing anything.

The comparison engine is V8's interpreter run with `node --jitless`
(Node 24.13.0). It is a register-based bytecode interpreter with inline caches
and no compiler tier, so it is the closest reference design. QuickJS-ng 0.17.0
(`qjs`) is listed where useful. Full V8 is not a target.

## 1. Where Boomkat stands

Benchmark-reported milliseconds from `.worktrees/octane/bench/mini`, one run
each, summed over each mini's printed results:

| mini | boomkat | qjs | Ignition | boomkat / Ignition |
|---|---|---|---|---|
| richards | 230 | 298 | 161 | 1.43 |
| deltablue | 266 | 294 | 164 | 1.62 |
| raytrace | 193 | 270 | 114 | 1.69 |
| splay | 127 | 138 | 64 | 1.98 |
| earley-boyer | 205 | 238 | 101 | 2.03 |
| typescript | 1215 | 1195 | 719 | 1.69 |
| regexp | 360 | 555 | 64 | 5.6 |
| box2d | 275 | 286 | 220 | 1.25 |
| navier-stokes | 570 | 615 | 509 | 1.12 |
| crypto | 292 | 610 | 380 | 0.77 |
| mandreel | 840 | 1535 | 911 | 0.92 |
| gbemu | 237 | 328 | 239 | 0.99 |

zlib, pdfjs and code-load do not run under node (they probe `read` and
`require`).

Numeric code already matches or beats Ignition. Object-heavy and call-heavy
code is 1.4 to 2 times slower, and regexp is 5.6 times slower.

With the earley-boyer loop raised to 100 iterations, Earley takes 838 ms
against Ignition's 162 (5.2x) and Boyer 5811 against 2961 (2.0x). Earley is
the outlier inside that mini.

## 2. What is not the problem

These were measured and can be ruled out as primary causes.

- Boomkat is instruction-bound. `/usr/bin/time -l` on the microbenchmarks
  reports 7.3 to 7.8 instructions per cycle for boomkat and 5.4 to 6.4 for
  Ignition. Run time follows retired instructions almost linearly, so
  instruction counts are the metric to optimize and to report.
- Arithmetic and dispatch are cheaper than Ignition's. `th_bori` is 22
  machine instructions on its fast path, `th_incdec` 21, the fastint `th_add`
  about 30. The loop `s = (s + i) | 0` with a global bound retires 132
  instructions per iteration against Ignition's 253.
- A plain call and return costs about the same as in Ignition: 195 retired
  instructions against 210. A method call and return costs 289 against 294.
- Isolated monomorphic loops are faster than Ignition in almost every case:
  global function call 16.4 against 18.8 ns, method call 24.8 against 27.7,
  three property reads 15.9 against 18.9, `this` read-modify-write 12.4
  against 17.5, three-shape polymorphic read 10.5 against 17.6.

The gap therefore comes from specific paths that real programs reach and
simple loops do not. Sections 3 to 11 list them in suggested order.

## 3. Measurement method

Two microbenchmark sets are in `plans/106-interpreter-gap-to-ignition/micro/`,
run by `run.sh <boomkat-binary>`:

- `m_*.js` print nanoseconds per iteration through `head.js`'s `bench()`
  helper, which warms the function up with 1000 iterations first.
- `d_*.js` are run under `/usr/bin/time -l`. Subtract `d_base.js`'s retired
  instruction count and divide by N = 20,000,000 for the cost of the extra
  operation each one adds.

Per-operation instruction deltas, boomkat against Ignition:

| case | boomkat | Ignition |
|---|---|---|
| call and return (`e(i)`) | 195 | 210 |
| method call and return (`o.e(i)`) | 289 | 294 |
| `this.v` read | 63 | 43 |
| `o.v` read | 62 | 43 |
| object literal `{x: i}` plus one read | 708 | 257 |
| method returning an object, plus one read | 770 | 372 |

Profiles used `sample <pid>` on long-running copies of the minis with the
iteration count raised. The threaded handlers tail-call each other, so
`sample` call graphs are flat; read the "Sort by top of stack" section.
`boomkat_gcprofile` is the O2 target with full debug info and threaded
dispatch, and gives source lines. It, like `boomkat_opprofile`, takes the
script path without `--script`. `boomkat_debug` and `boomkat_opprofile`
define `TRACE_VM`, which disables lazy function compilation
(the deferral test in `CompilerContext.gen_compile_function`,
`src/compiler/gen.c3`), so their
bytecode can differ from the release build's in eval code.

## 4. Mapped `arguments` reads scan the whole stack

Evidence. `m_args.js` reads `arguments[i]` from a sloppy function with no
formals, called at different stack depths:

| depth | boomkat | qjs | Ignition |
|---|---|---|---|
| 0 | 368 ns | 164 | 73 |
| 50 | 555 | 163 | 73 |
| 200 | 1146 | 163 | 73 |

Earley's hot helpers `sc_list` and `sc_append` are this shape, and its parser
recurses deeply. The Earley profile's two hottest source lines inside
`dispatch_property` are the `mapped_args_read` calls in the switch `GETPROP`
and `GETPROPC` paths (`src/vm/vm_property.c3`), with `HObject.find_prop_idx`
next.

Mechanism. `mapped_args_read` (`src/vm/vm_calls.c3:250`) first calls
`mapped_args_owner` (`src/vm/vm_calls.c3:98`). That loops over every
activation from the bottom of the stack and, for each frame whose function
maps its formals, fetches the frame's `arguments` binding
(`frame_arguments_object`), which for an environment-resident binding is a
by-name lookup. Only after finding the owner does `mapped_args_read` check
`idx < cf.num_args` and `args_is_mapped(args_obj, idx)`. For a function with
no formals no index is ever mapped, so the whole scan is wasted on every read.
`mapped_args_write` and `mapped_args_sync_all` (`src/vm/vm_calls.c3:172`)
call the same search.

Proposal.

1. Test `args_is_mapped(args_obj, idx)` before searching for the owner, in
   `mapped_args_read`, `mapped_args_write` and every other caller. An
   arguments object with no mapped bits then costs one load.
2. Replace the search with a recorded owner. The arguments object can hold
   the owning activation's index, or a pointer that the frame's pop clears.
   Check how generator and async frames are saved and restored, and how
   `bind_env_arguments` and `bind_register_arguments` create the object,
   before choosing the representation. The current identification by the
   frame's own `arguments` binding exists so a frame that merely receives
   the object as an argument is not taken for its owner; the recorded owner
   must keep that property.
3. Find why these reads reach the switch at all. An unmapped dense index on
   an arguments object should be a threaded read. Check `th_getprop_array`
   and its siblings for the `ARGUMENTS` class.

Checks. test262 `built-ins/Arguments`, `language/arguments-object`, and
`language/expressions/call`, plus strict/sloppy variants of a local repro that
writes a formal and reads `arguments[i]` (and the reverse) from a nested call,
after a `delete arguments[i]`, after `Object.freeze(arguments)`, and from a
generator. Acceptance: `m_args.js` flat across depth and within 2x of
Ignition; Earley's time measured before and after.

## 5. Returning an object leaves the leaf return path

Evidence. `d_retobj.js` calls a method that returns `this.n` and reads `.v`
from the result: 770 instructions per iteration against 289 for the call
plus 62 for the read, and 372 in Ignition. `th_return_general` is 10% of
deltablue's samples, 9% of raytrace's, 7% of richards' and 4% of
typescript's, and `th_resume_caller` adds 4% to 8%.

Mechanism. The callee is `GETTHISC r1; RET r1`. `GETTHISC` puts an object in
a register, which raises the frame's tracked-register watermark
(`heap_reg_count`). `th_try_fast_return` (`src/vm/vm_execute_threaded.c3`)
takes its leaf path only for a primitive result. Since `742fef58` it accepts
tracked registers that hold only objects, but an object result still goes
through `th_return_slow` to `th_return_general`, which is `@noinline` with a
full register-saving frame. There it checks the construct case, tests
`th_can_publish`, runs `sweep_callee_regs` (a decref-and-clear loop over the
tracked registers), stores the result, calls `track_heap_store` on the
caller's frame, releases `this`, and tail-calls `th_resume_caller`.

`th_resume_caller` itself saves eight callee-saved registers (four
`stp`/`ldp` pairs) on every return because the rare call to
`Heap.switch_realm` (`heap.enter_realm`) is inlined into it.

In the caller, `LDREG r3 = r4` copies the returned object and calls
`track_heap_store` again.

Proposal.

1. Give `th_try_fast_return` a leaf path for an object result: the frame
   passes `th_frame_is_replaceable`, every tracked register is uncounted (the
   `th_tracked_regs_uncounted` test from `742fef58`), the caller's result
   register is inside the caller's window, and `th_can_publish` holds for
   the value. The pop is then plain stores plus the caller's watermark
   update.
2. Move the realm switch in `th_resume_caller` into a separate `@noinline`
   function reached by a tail call, so the common return is a leaf. Confirm
   with `objdump -d --disassemble-symbols=_boomkat.vm.th_resume_caller` that
   the prologue no longer saves registers.
3. Measure whether `LDREG` of an object needs `track_heap_store` when the
   source register is already tracked and the destination is below the
   watermark.

Checks. `just test-local`, `just modules`, `just rosetta`, test262
`language/expressions/call`, `language/statements/class`,
`language/expressions/new`, `language/statements/return`, plus a run of the
minis under `boomkat_gc_stress` or `test262_runner_verify` (HEAP_VERIFY) to
catch a missed sweep or a stale register. Acceptance: `d_retobj.js` within
1.3x of Ignition's instruction count, deltablue and richards measured.

## 6. Allocation and freeing cost 2.75 times Ignition's

Evidence. `d_lit.js` (`var o = {x: i}` plus one read) costs 708 instructions
per iteration against Ignition's 257. In `m_lit.js` (two fields) the time is
39.8 ns against 18.2, `m_arrlit.js` 46 against 26.6, `m_new.js` 50.8 against
32.8, and `m_retobj.js` (a method that returns `new V(...)`) 82.7 against
59.7. The `m_lit.js` profile splits about evenly between allocation
(`hobject_alloc`, `Heap.alloc_shaped_object`, `Heap.alloc_object`,
`PagePool.alloc_prefix`, `memset`, `th_newobj`, `th_init_slot`: about 40%)
and freeing (`hobject_free_step`, `hobject_free_impl`,
`Heap.gc_sweep_objects_step`: about 22%). Allocation and collection
together are 15% to 25% of the raytrace, earley-boyer and splay profiles.

Mechanism. One literal goes through these layers:

1. `th_newobj` calls `Heap.alloc_shaped_object` (`src/heap.c3:3247`), which
   reads the shape, picks a capacity, and calls `Heap.alloc_object`.
2. `Heap.alloc_object` (`src/heap.c3:3203`) calls `hobject_alloc`, then
   `register_allocation` (a `List` push onto `objects_young` and
   `shade_new_header`), sets the temproot flag, and updates
   `live_obj_count`, `peak_live_obj_count`, `gc_trigger_counter`,
   `gc_alloc_since_begin`, `mem_check_budget` and the GC profile counter.
3. `hobject_alloc` (`src/hobject.c3:2765`) branches on the class several
   times, takes a block from a `PagePool` through `alloc_prefix`, which
   clears the header with a `memset` call, and initializes the header
   fields one at a time.
4. `Heap.init_object_shape` (`src/heap.c3:3259`) reads the shape again and
   fills every slot with undefined.
5. Each field is a separate `INIT_SLOT` dispatch, and `th_init_slot` checks
   that the slot is still undefined before storing.

Freeing walks `objects_young` in the sweep, then `hobject_free_step` and
`hobject_free_impl`, whose class `switch` reaches the pool `dealloc`.

Proposal. A plain-object fast path for sites whose shape and capacity the
compiler already knows (`NEWOBJ_SHAPE`, see plan 105 section 2.2):

1. One inline allocation in the handler: pool freelist or bump pointer,
   header written from a per-shape template with one block copy instead of
   field-by-field stores and a `memset`, accounting counters folded into
   one budget decremented per allocation.
2. Have the literal's initial values written by the allocating instruction,
   or have `INIT_SLOT` skip the undefined test when it follows the
   allocation directly, so the undefined fill of slots that are about to be
   written disappears.
3. A sweep fast path for an ordinary object with inline storage only, which
   skips the class `switch` in `hobject_free_impl`.

Plan 105's R3 covers storage layouts for these objects; implement this
section against its measurements and keep its memory accounting.

Checks. GC stress and HEAP_VERIFY runs of the minis, `just test-local`,
`check_temproot_rss.py`, test262 `built-ins/Object` and
`language/expressions/object`. Acceptance: `d_lit.js` under 400
instructions, RSS of the minis unchanged.

## 7. Property-cache hits are longer than they need to be

Evidence. A monomorphic own-property read costs 62 instructions against
Ignition's 43 (`d_objrd.js`, `d_thisrd.js`). `th_getthisc` plus
`th_getpropc_cached` are 20% to 30% of the richards, deltablue and
typescript profiles. Disassembly of `th_getthisc`'s own-data hit runs about
50 instructions with four dependent load chains.

Mechanism. `th_get_cached` (`src/vm/vm_execute_threaded.c3`):

1. compares `ic.shape_id` with the object's shape id, then compares
   `ic.shape_gen` with `heap.shapes[shape_id].generation`
   (`HObject.live_shape_generation`), a chain of three dependent loads on
   every hit;
2. `hobject::ic_resolve_value` decides per object between inline and
   out-of-line storage (`prop_alloc` null test) and computes the inline base
   through a class lookup table;
3. `th_publish_read` tests the destination register's refcount and, for an
   object value, loads the GC phase through `cold.vm.heap` before
   `track_heap_store`.

Proposal.

1. Remove the generation load from the hit path. The generation exists
   because shape ids are recycled (`## epoch bumps: shape_reuse=...` in the
   opprofile output). Alternatives: invalidate the caches that name a shape
   id when the id is recycled, or never hand out an id that a live cache
   entry may still name. Measure how often ids are recycled in the minis
   first.
2. Store a resolved slot locator in the entry when the shape fixes the
   storage choice, so a hit is one compare and one load from a known offset.
   Plan 105 section 2.1 notes that a shape is a logical layout, not a
   physical one; any offset cached this way needs a storage guard that is
   cheaper than the current test.
3. Keep `cold.heap`'s phase in `ColdCtx`, or fold "marking in progress" into
   a value the handler already loads.

Plan 105's R1 (compact cache records) and R4 (separate validity conditions)
cover the same entries. Coordinate the entry layout with them.

Checks. test262 `built-ins/Object/defineProperty`, `language/expressions/delete`,
`built-ins/Object/setPrototypeOf`, local regressions that reshape objects
between reads. Acceptance: `d_objrd.js` within 1.15x of Ignition.

## 8. `f.apply(this, arguments)` runs on the switch

Evidence. raytrace's classes come from prototype.js's `Class.create`, whose
constructor is `this.initialize.apply(this, arguments)`. The raytrace
opprofile shows 665,942 switch executions each of `APPLY_ARGS` and `CALL_S`
per run, and `vm_dispatch` is 9% of its samples. `m_apply.js`: constructing
through this wrapper costs 131 ns against 50.7 for a direct constructor, an
80 ns overhead; Ignition's overhead is 27 ns (60.1 against 32.7).

Mechanism. `APPLY_ARGS` has no threaded handler, so every construction
leaves the burst for the switch, builds or reads the arguments object, and
spreads it into a new call frame.

Proposal. A threaded path for the case where `apply`'s target is the
unmodified `Function.prototype.apply`, the argument is the current frame's
own unmapped or unmodified arguments object, and the callee is a lean
compiled function. The arguments are the caller's incoming argument
registers, so the call copies them into the callee window without
materializing the object. When the function never otherwise reads
`arguments`, the compiler could emit a dedicated forwarding opcode and skip
creating the object at all.

Checks. test262 `built-ins/Function/prototype/apply`,
`language/arguments-object`, and repros that overwrite
`Function.prototype.apply`, pass a modified arguments object, or forward
from a strict function. Acceptance: raytrace measured, `m_apply.js` overhead
under 40 ns.

## 9. Name resolution is more conservative than the language requires

### 9.1 One direct eval turns every global read in the file into GETVAR

Evidence. Five minis contain a direct `eval` call: earley-boyer, mandreel,
pdfjs, typescript and zlib. Their opprofile `GETVAR` counts are mandreel
127.8M plus 13.0M `CALL_VAR` (21% of its dispatches), zlib 17.3M, typescript
12.5M, earley-boyer 3.8M and pdfjs 2.5M. A three-line repro shows it: with
`function E(s) { return eval(s); }` anywhere in the script, `A`'s read of the
global `B` is `GETVAR`; without it, `GETGLOBAL`.

Mechanism. The eval pass at the end of `Resolver.resolve_refs`
(`src/ast/resolve.c3:793`) sets
`SCOPE_CAPTURE_ALL` on the eval's function and every enclosing function up to
the program. `is_free_global_name` (`src/compiler/emit.c3:126`) rejects a name
if the current function has `capture_all` set, or if any scope on its chain
has `SCOPE_HAS_EVAL` or `SCOPE_CAPTURE_ALL`. The program scope always has
`SCOPE_CAPTURE_ALL` once any function in the file contains an eval.

A sloppy direct eval can add `var` and function bindings only to the
variable environment of the function that contains it, which is where the
resolver puts `SCOPE_HAS_EVAL` (`self.var_scope()`, `src/ast/resolve.c3:274`).
A strict direct eval adds no outer bindings at all. Eval in a parameter list
sets `SCOPE_EVAL_PARAMS`.

Proposal. In `is_free_global_name`, reject on `WITH` scopes,
`SCOPE_HAS_EVAL` and `SCOPE_EVAL_PARAMS` on the chain, and on the function's
own `has_direct_eval`, `has_with_stmt` and `outer_with`. Do not reject on
`capture_all` or `SCOPE_CAPTURE_ALL`, which describe whether this function's
own bindings may be read by an eval and say nothing about which bindings can
shadow a global. A prototype of exactly this change measured:

| mini | before (ms) | after (ms) |
|---|---|---|
| mandreel | 861 | 803 |
| earley-boyer | 208 | 204 |
| pdfjs | 368 | 363 |
| typescript | 1239 | 1226 |
| zlib | 5587 | 5566 |

The prototype was not run against test262 and was reverted.

Checks. test262 `language/eval-code` (direct and indirect), `annexB`
eval-code tests, `language/statements/with`, and repros where an eval in an
enclosing function declares the name a nested function reads, in both
strict and sloppy code.

### 9.2 A function declared before a `var` reads it by name

Evidence. In

```js
function F() {
  function before() { return w + 1; }
  var w = 1;
  function after() { return w + 2; }
  var g = function () { return w + 3; };
  ...
}
```

`before` reads `w` with `GETVAR`, `after` and `g` with `GETCAP`.
navier-stokes' `FluidField` has this shape: its inner functions are declared
before `var width; var height; var rowSize; ...`, and the opprofile shows
10.9M `GETVAR` with no eval in the file. typescript has 12.5M `GETVAR` and
2.9M `GETCAP`.

Mechanism. `resolve_capture_candidates` (`src/compiler/capture_slots.c3`)
resolves a child's free names against the parent's `scope_stack` at the point
the closure is emitted. Hoisted function declarations are emitted at the top
of the parent, before the later `var` declarations are pushed.

Proposal. Resolve captures from the flat AST's resolver result, which records
each reference's binding regardless of source order, instead of from the
compiler's scope stack at emission time. Plan 104's T2 covers captured and
outer-binding access; fold this into it if T2 is still open.

Checks. test262 `language/statements/function`, `language/function-code`,
`annexB/language/function-code` (block-level function hoisting), and repros
with TDZ `let` captured by an earlier-declared function.

## 10. Caches that never fill or keep missing

### 10.1 Dictionary-mode prototypes are never cached

Evidence. A temporary counter in the switch `GETPROPC` path found 835,955 of
typescript's switch reads at sites whose cache entry had never been filled,
and 825,459 fill attempts refused because a prototype on the chain was in
dictionary mode. `m_dictproto.js`: a method on a prototype with 20 methods
costs 22.2 ns per call, on one with 80 methods 41.2 ns. Ignition is 27.2 and
26.6, qjs 31.1 and 32.4.

Mechanism. An object with `SHAPE_SOLITARY_MIN_PROPS` (64,
`src/heap.c3:1775`) or more unshared properties takes a private dictionary
shape. `ic_fill_read` (`src/vm/vm_property.c3:84`) returns false when any
prototype it walks is in dictionary mode, so such sites never leave the
switch path.

The epoch chain that `ic_fill_read` already builds for plain prototypes
depends on structural changes to an observed prototype bumping
`prototype_epoch`. `put_prop_new`, deletes, `layout_moved`, flag changes and
`Heap.set_prototype` all do so when `gc.prototype_observed` is set, and a
dictionary's property indexes do not move.

Proposal. Accept dictionary-mode prototypes in an epoch chain. The receiver
itself must still not be in dictionary mode, since it can gain a shadowing
key without changing shape and is not marked observed. Before relying on the
epoch, audit every path that adds, removes or reconfigures a property of a
dictionary-mode object for the `prototype_observed` bump. Plan 105's T4
(adaptive dictionary policies) is the alternative: return prototypes to
shared shapes.

Checks. test262 `built-ins/Object/defineProperty`,
`built-ins/Object/prototype`, `language/expressions/delete`, and a repro that
adds, deletes and redefines a method on an 80-method prototype between
cached calls.

### 10.2 Every read site caches one shape

Evidence. The same counter found 151,013 switch reads in typescript, 81,001
in deltablue and 25,267 in box2d where the entry held a different shape than
the receiver's. deltablue's constraint hierarchy and typescript's AST node
types reach the same call and read sites with several shapes.

Proposal. Plan 105's R2 (two- or four-entry own-property polymorphic caches)
is this item. Use these counts as its opportunity measurement.

## 11. Smaller call-path trims

Calls already cost what Ignition's do (section 3), so these come last.

- `th_call` is not a leaf. Its prologue saves four registers and spills
  `pc` and `cold` to the stack. Find which inlined call forces the frame
  (`th_trivial_call`, or `bind_register_arguments` inside `th_enter_lean`)
  and move it behind a tail call.
- `th_lean_target` follows callee value, function object, `extra_ptr`,
  `comp_func` and `call_flags` before deciding, then checks realm, IC
  arrays, `var_env`, a `with` scope, activation capacity and value-stack
  room. Precomputing a "lean and ready" bit on the function object at
  closure creation would replace most of that chain with one load and one
  test.
- `th_call_gate` reads several heap flags through `gc_safepoint_due` and
  separately increments `cold.call_burst`. One countdown that triggers the
  full check when it reaches zero would cover both.
- Removing the five null stores in `th_enter_lean` measured about 1% on the
  recursion benchmarks during the earlier session and is not worth doing on
  its own.

Acceptance for each: a measured reduction in `d_callu.js` and `d_meth.js`
instruction counts with no binary growth.

## 12. Regexp

`lre_exec` is 61% of the regexp mini's samples. It is QuickJS's backtracking
interpreter (`vendor`), which QuickJS itself runs slower than Boomkat (555
against 360 ms). Ignition's 64 ms comes from irregexp's interpreter and its
search optimizations. This needs its own plan: profile which patterns
dominate the mini, then consider a literal-prefix scan with `memchr` or
`memmem`, first-character sets, and anchoring checks before entering the
matcher.

## 13. Suggested order and protocol

1. Section 4: a contained fix with the largest single payoff (Earley).
2. Sections 5 and 6: the broadest gap, reached by every object-heavy mini.
3. Sections 8 and 9.
4. Sections 10 and 7, coordinated with plan 105.
5. Section 11.

For each change: report retired instructions for the relevant `d_*.js`
files, the minis' benchmark-reported times interleaved against the previous
binary (best of five), and `__text` size from `size -m out/boomkat`. Run
`just test-local`, `just modules`, `just rosetta` and the test262
directories named in the section, then full test262 before merging. Commit
each accepted step separately; record rejected attempts and their
measurements in this plan.

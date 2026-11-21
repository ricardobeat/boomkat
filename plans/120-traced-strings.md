# 120: Trace strings with the collector

Status: **PROPOSED** 2026-11-21, written against `jit` at `c920e574`.

## Objective

Make strings collector-owned, like objects, and delete the reference
counts, the zero-count table (ZCT), deferred register counts and the
borrowed/owned distinction. Give small builds a simpler stop-the-world
collector. Keep sloppy, strict and module semantics, the embedding API, and
the low-memory goal for small devices.

## Where it stands

Three ownership schemes share the heap:

| Scheme | Owns | Rule |
|---|---|---|
| Tracing collector | objects, environments, buffers, BigInts | Incremental and generational marking, 64 KiB pool pages with live, mark and teardown bitmaps, a write barrier, allocation pins and `ObjectRoot`/`ValueRoot` for native code. |
| Reference counts | strings | Every holder counts: object slots, bindings, shapes, caches, constants, host handles. The collector never marks a string. It sweeps zero-count entries of the intern table and the large-string registry, and an object it frees drops its strings' counts. |
| Deferred counts (`jit` only) | strings in registers | Slots of the current register segment hold no count. A string at its table level is queued on the ZCT; `zct_flush` scans every activation's slots and frees what nothing holds. A suspended async segment takes counts for its live spans. |

Cost, measured on `jit` at `c920e574`:

- **Spread.** About 800 count-handling call sites in 62 of 281 source files
  (`tval_copy_ref` 332, `decref_tval` 170, `decref` 152, `incref` 88), plus
  251 `set_string_borrowed` sites, each an ownership decision.
- **Bugs.** Since 2026-08-01, of 2,474 commits: 63 mention ownership, 28
  refcounts, 22 lifetime, 14 use-after-free. `test/` holds 27 string-lifetime
  regressions.
- **Seams.** The four bugs fixed on 2026-11-21 (`3c3e1ee3` to `94cb3afd`) were
  all between schemes. A host `bk_gc(BK_GC_FULL)` never reached `zct_flush`.
  `bk_weak_get` revived a queued symbol. Tests assumed `main`'s eager frees.
  `reset` drift sat in fields both systems touch.
- **Promptness is mostly gone already.** A string held by a dead object is
  freed when the sweep frees the object. On `jit` a temporary waits for a
  flush. Eager reclamation remains only for strings that never reach the
  heap, and only on `main`.
- **Divergence.** `main` frees at zero and `jit` defers. Shared code behaves
  differently on the two branches, and cherry-picks need adapting.
- **`jit` already scans for strings.** `zct_flush` walks every frame slot to
  decide what may be freed. That is the root scan of a tracing collector,
  done for strings alone.

## Design

### Marking

A string has no references to other strings or objects. `HString`
(`src/hstring.c3:150`) holds flags, refcount, capacity, registry slot, hash
and length; external strings point at host bytes, not at an `HString`. So
marking a string sets one bit and pushes nothing gray.

- The `refcount` word becomes the `GcBits` half of the `HeapHeader` union,
  as for every other node.
- `TVal.is_traced` (`src/types.c3:423`) takes the string tag, and
  `is_refcounted` goes away.
- `Heap.mark_tval` (`src/heap.c3:4835`) gains a string case. Today it only
  calls `verify_string_owner` under `GC_VERIFY`.
- Pooled strings live in `PagePool` pages (`small_pools`), which have no
  bitmaps. They move into `ObjectPool` size classes, which already have live,
  mark and teardown bitmaps, page sweep and bump allocation. The class sizes
  need checking against string length distributions, since strings vary in
  size more than objects. Strings above 8 KiB stay outside the pools and
  carry a header mark, like unpooled objects.

### Barrier

`write_barrier` (`src/heap.c3:4628`) already takes the stored `TVal`. During
marking it shades strings too. A shaded string is set black at once, since
it has no children. Between cycles it remembers an old owner of a young
string. `root_store_tval` stops skipping strings (`src/heap.c3:4668`). The
`needs_teardown` call for counted values goes away, since a string no longer
needs its holder's teardown.

### Holders the marker must reach

Inventory taken 2026-11-21. The groups matter more than the exact lines.

**Walked today, marking objects only.** A string case in `mark_tval` covers
these:

- object property values and array parts
- Map and Set entries
- primitive wrappers, `HObjectError.captured_stack`, promise results and reactions
- getter/setter pairs, captures, bound-function fields, iterator helpers
- environment bindings, which are objects
- `Runtime.slots`, `host_vals`, `addon_handles`, `host_exotic_hold`
- generator saved registers and state values, catchers, async-generator requests
- the microtask queue, unhandled rejections, `value_roots`
- module synthetic values and evaluation errors
- `RealmState` string fields, through `mark_intrinsics`
- `CompiledFunction.constants`, through `gc_scan_compiled_slot` and `mark_roots`

**Not walked today. The marker needs new code for each of these:**

| Holder | Where |
|---|---|
| `ShapeProperty.key` | `src/hobject.c3:664`. Shape liveness runs separately (`mark_object_shapes`, `sweep_shapes`), and `sweep_shapes` runs only when `gc_collects_strings()`. |
| `TransitionEntry.key` in `Heap.trans_table` | `src/heap.c3:2025` |
| `JsonShapePlan` entries, `OwnKeyShapePlan.keys`, `JsonEntry.key`, `JsonSerializeCtx.prop_keys` | `src/hobject.c3:3454, 3486`; `src/builtins/json.c3:42, 653` |
| `ICEntry.key`; `mega_cache` and `absent_cache` keys | `src/hobject.c3:3810, 4389, 4128` |
| `CompiledFunction` names: `closure_name`, `regexp_cache[].source`, `brand_name_hstr`, `super_binding_name`, `static_super_binding_name`, `home_object_binding_name` (the last four are raw `void*`) | `src/bytecode.c3:2050-2176` |
| `HObjectRegExp.pattern_str`: `gc_scan_object_fields` has no `ObjClass.REGEXP` case | `src/hobject.c3:749` |
| String iterator and RegExp string iterator `string`; `HObjectTemporal.identifier` | `src/hobject.c3:824, 832, 1049` |
| `IntlSegmentState.input`, a raw `HString*` in an opaque host payload with no mark callback | `src/builtins/intl_segment.c3:12` |
| `Heap.concat_cache`, symbol registry, the 15 well-known symbol fields on `Heap` | `src/heap.c3:936, 1169, 1313` |
| `CheckpointEntry.key`; `ForInState.keys`, including a generator's for-in chain | `src/heap.c3:288, 293` |
| `HostClassEntry.name`, `HostFnEntry.name` | `src/heap.c3:525, 565` |
| `Runtime.atoms` keys, which are raw and kept alive by `refs` | `src/embed.c3:219` |
| `Vm.threaded_throw`, `LongjmpState` values | `src/vm/vm_types.c3:470`; `src/heap.c3:209` |

**Weak.** These are cleared at sweep for unmarked strings: `str_table`,
`large_strings`, `RealmState.slice_cache`, `accum_births`, and `WeakEntry`
targets that are symbols. `weak_condemn` (`src/gc/gc_weak.c3:121`) stops
skipping strings, so a symbol dies through the same path as an object.

**Pinned.** These are marked by root arrays or treated as always marked:
`Heap.strs`, `small_int_strs`, `unit_strs`, well-known symbols.

**JIT.** Baseline and opt code embed string and key pointers as
immediates. These include `OptSinkSite`, `OptNode`, `OptAvail`,
`Asm.length_key` and `Heap.jit_site_key`. All are borrowed and kept alive by
`CompiledFunction.constants` or `ICEntry.key`, so marking those two covers
generated code. Compiled functions are enumerated through
`Heap.compiled_funcs[]`. A minor cycle reaches new constants through
`root_store_tval`.

### Native code

A fresh string takes an allocation pin, as an object does today, which a
quiescent safepoint clears. A native frame that holds a string across a
call into the VM uses `ValueRoot`. With that rule a blocking collection can
collect strings too, so the `gc_collects_strings` policy goes away. Today it
skips strings in blocking cycles because native locals may hold uncounted
pointers.

### In-place append

`vm_concat_accumulate` (`src/vm/vm_execute.c3:395`) appends in place only
when the string is held by its register alone (count 0 under deferral), or
by one binding that `concat_binding_owns` proves (count 1). Without counts it
needs another proof of a single owner.

The candidate is an `escaped` flag on the string. Any store other than into
the accumulator's own register sets it: the object and environment store
barriers, captures, host handles and constants. Register copies are already
checked by `concat_frame_holds_elsewhere`. The flag never clears, so a string
that escapes once stops appending in place; the count test also gives up past
one owner.

The binding-owned case needs its own rule, because storing into the binding
would set the flag. This overlaps task #46 (PdfJS accumulator ownership).
Settle both together.

### External strings and shapes

An external string's release hook runs when the sweep frees it. A shape
keeps its key strings alive by being marked, and `sweep_shapes` drops dead
shapes in every major cycle, not only in cycles that collect strings.

## Small-device collector

Add a `GC_SIMPLE` feature for the tiny and slim targets. It is a
stop-the-world, non-incremental, non-generational mark and sweep:

- Mark with `mark_roots` and `drain_gray`, which is what the `GC_VERIFY`
  oracle (`verify_incremental_mark`, `src/gc/gc_verify.c3`) already runs.
- Sweep pages with the existing bitmaps.

`GC_SIMPLE` drops the incremental slice machinery (`gc_scan_roots_step`
stages, pacing), the nursery, the remembered set and `gc_alloc_bitmap`.
The write barrier reduces to the teardown bit.

A collection starts once the bytes allocated since the last one reach
`max(live × factor, floor)`, or when the heap limit asks for one. Pause time
grows with the live heap, which is small on these devices.

Building `GC_SIMPLE` first gives traced strings a smaller first target,
without barrier or young-generation interplay. The incremental and
generational collector then gains string marking separately.

## Phases

Each phase lands as reviewable commits with the suites green.

0. **Measure. No behavior change.**
   - A `COUNT_PROFILE` feature counting increments, decrements, ZCT pushes,
     flushes and slots scanned per flush, on `main` (eager) and `jit`
     (deferred).
   - Instructions retired per Octane suite with the fixed-iteration harness:
     each suite sliced from the bundle with
     `BenchmarkSuite.config.doDeterministic = true`.
   - Peak RSS for the Octane suites and for string-churn scripts on the
     default, slim and tiny builds.
   - Collector share and pause distribution (`GC_PROFILE`).
   - Size of the collector code in the tiny binary.
1. **`GC_SIMPLE` on tiny and slim.**
   - Tests: test-local, test-api and a `GC_STRESS` variant.
   - Gate: tiny no larger; peak memory and pauses recorded against phase 0.
2. **Mark strings alongside counts.**
   - Add the string case to `mark_tval`, the holders listed above, and the
     missing `ObjClass.REGEXP` case.
   - At the end of a major mark, `GC_VERIFY` walks the string pools, the
     intern table and the large-string registry, and fails on any string
     above its table count that is unmarked. This uses the counts as the
     oracle for missed holders.
   - Run it over full test262, the local suites and Octane. The phase is
     additive.
3. **Free by sweep.**
   - The counts are still kept, but a string at zero is no longer freed: the
     ZCT stops freeing. The weak tables are cleared by mark.
   - Add allocation pins for strings and the `escaped` flag.
   - This is the head-to-head against deferred counting (option 2): same
     branch, same tests, only the reclamation changed.
   - **Gate:**
     - Fixed-iteration instructions geomean ≤ 1.00 against `jit` at phase 0.
     - Peak RSS within the agreed bounds on default, slim and tiny.
     - If memory is the binding constraint on small devices, stop here and
       give `main` the ZCT instead.
4. **Delete counts.**
   - `tval_copy_ref` becomes a plain copy; `incref`, `decref` for strings,
     `release_string`, the ZCT, segment counting, string teardown bits and
     `set_string_borrowed` go.
   - The JIT emitters drop their count and teardown code.
   - One subsystem per commit. The edits are mechanical and suit a sonnet
     agent each.
5. **Strings in the young generation.** Short-lived strings die in minor
   cycles. Tune the triggers for the default build and `SMALL_VM`.
6. **Port to `main` as a series.** `main` frees at zero today, so the port
   replaces eager counting rather than the ZCT.

## Branching

Work on `strings-gc` from `jit`, merging back into `jit` at each gate.
`GC_SIMPLE` touches only the interpreter and heap, so it can go to `main`
as soon as phase 1 passes. Traced strings go to `main` after phase 5, so
`main` and `jit` do not carry two string schemes across merges.

## Acceptance

- Full test262 pass count unchanged (53,380 / 0 at the last full run). Also
  test-local, test-api, rosetta, modules, ASan, `GC_STRESS`, the JIT
  GC-stress build and `GC_VERIFY`.
- Fixed-iteration Octane instructions geomean ≤ 1.00 against `jit` at
  phase 0.
- Peak RSS within the bounds set before phase 3.
- Tiny binary no larger than at phase 0.
- Net source lines down.

## Risks

- **A missed holder is a use-after-free.** Phase 2's verify mode exists to
  find these before anything stops counting. Raw-pointer holders (the
  `CompiledFunction` binding names, `IntlSegmentState.input`, atoms) need
  review by hand.
- **Peak memory between collections** on string-heavy scripts, which matters
  most on small devices. Phase 0 sets the baseline and phase 3 decides.
- **Marking work** grows with the number of string references visited. Each
  string is one bit, but there are many.
- **The in-place append rule** has no settled design for the binding-owned
  case.
- **Host extensions** with opaque payloads holding strings need a
  `gc_mark` callback; `IntlSegmentState` is the one in the tree.

## Open questions

- Peak RSS bounds for phase 3, for the default build and for slim and tiny.
- Whether slim also takes `GC_SIMPLE`, or only tiny.
- `ObjectPool` size classes for strings, against a bitmap added to
  `PagePool`.

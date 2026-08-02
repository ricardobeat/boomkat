# Multiple runtimes per process

Removing the process-global `_active_heap` (and the smaller tier of global
state around it) so that two or more independent runtimes can be open in one
process at the same time, on the same thread. This is the last structural
difference between this engine and the two it is benchmarked against: QuickJS
and Duktape both advertise unrestricted multi-instance operation as a headline
property, and both hold zero global state to get it.

Status: design document. Nothing here is implemented. Three throwaway
prototypes exist on scratch branches and are cited throughout; none is
landable as-is.

## Contents

- [The problem, measured](#the-problem-measured)
- [Verification of the premises](#verification-of-the-premises)
- [The recommended architecture](#the-recommended-architecture)
- [Rejected approaches](#rejected-approaches)
- [Performance, with the noise floor](#performance-with-the-noise-floor)
- [Runtime/Context split: no](#runtimecontext-split-no)
- [Secondary global state, itemised](#secondary-global-state-itemised)
- [The C ABI after the change](#the-c-abi-after-the-change)
- [Bindings](#bindings)
- [Cross-runtime values: the pointer-identity problem](#cross-runtime-values-the-pointer-identity-problem)
- [Phased implementation](#phased-implementation)
- [Test strategy](#test-strategy)
- [Sequencing against in-flight work](#sequencing-against-in-flight-work)
- [Risks](#risks)
- [Decisions](#decisions)
- [Sizing](#sizing)

---

## The problem, measured

`src/hobject.c3:35`:

```c3
/// The active heap, set at heap init and nulled at teardown. Holding it here
/// rather than per object saves 8 bytes on every allocation.
void* _active_heap;
```

A process-global heap pointer. Written by `hobject_set_active_heap`
(`hobject.c3:38`) from `heap.c3:961` (`heap::create`) and `heap.c3:1766`
(`Heap.reset`); cleared by `hobject_clear_active_heap` (`hobject.c3:65`) from
`heap.c3:1334` and `heap.c3:1507`.

**It is set exactly twice and never restored.** No entry point re-establishes
it. That is the whole bug: whichever heap was created or reset last owns the
slot, permanently.

### Distribution, as of `b6f5bf9e`

`grep -rn _active_heap src/` returns **102 lines**. Subtracting the declaration,
the two setter/clearer bodies and eight comment-only mentions
(`hobject.c3:1908, 2079, 2080`, `heap.c3:335`, `types.c3:430`, and three doc
comments) leaves **92 real reads**:

| File | Real reads |
|---|---|
| `src/hobject.c3` | 83 |
| `src/env.c3` | 4 |
| `src/heap.c3` | 2 (in `Heap.reset`; the other 3 hits are the set/clear calls and a comment) |
| `src/vm/vm_execute.c3` | 3 |
| `src/types.c3` | **0** — its single hit is a comment |

So the file list is **four files, not five**. The commonly-quoted "99 sites,
5 files" figure over-counts by ten and includes a file with no reads at all.
The numbers drift with main: the earlier survey found 88 reads in `hobject.c3`
at `f89fffd7`; main has since added four more. **Any implementation must
re-count rather than trust this table.**

### Concentration

92 reads live in **22 distinct functions**. The distribution is extremely
skewed:

| Function | Sites | Already has a heap? | Path |
|---|---|---|---|
| `hobject_free` (`hobject.c3:1994`) | 22 | **yes** — `void* heap_ptr` | teardown/GC, cold |
| `HObject.ensure_prop_hash` | 8 | no | hot |
| `HObject.delete_prop` | 8 | no | warm |
| `HObject.grow_props` | 6 | no | hot |
| `HObject.put_prop` | 5 | no | **hottest** |
| `HObject.grow_array` | 4 | no | hot |
| `hobject_free_header` | 4 | **yes** — `heap_ptr` | cold |
| `HObject.get_prop_or_accessor_proto` | 4 | no | hot |
| `HObject.has_prop_proto` | 4 | no | hot |
| `Vm.run` (`vm_execute.c3:5040`) | 3 | **yes** — `vm.heap` | hot |
| `HObject.seal` | 2 | no | cold |
| `HObject.make_shape_private` | 2 | no | warm |
| `HObject.set_array_idx` | 2 | no | hot |
| `HObject.get_prop_proto` | 2 | no | hot |
| `shape_create` | 2 | no | warm |
| `shape_free` | 2 | **yes** — `heap_ptr` | cold |
| `env_put` (`env.c3:186`) | 2 | no | hot (global assign) |
| `env_try_put_lex` (`env.c3:402`) | 2 | no | hot |
| `Heap.reset` | 2 | **yes** — self | cold |
| `HObject.get_shape` (`hobject.c3:871`) | 1 | no | **not compiled in the default build** |
| `heap::create` | 1 | **yes** — local `Heap* h` | cold |
| `Heap.destroy` | 1 | **yes** — self | cold |

**33 of 92 sites already have a `Heap*` in scope** and read the global purely
out of habit. Those are textual substitutions with zero signature churn.
**~55 sites are genuinely stranded**: 14 are `&self` methods on `HObject`,
which has no heap back-pointer, and 2 are free functions taking `EnvRecord*`,
which has none either (`env.c3:63` is `parent`, `bindings`, two bools).

`HObject.get_shape` at `hobject.c3:871` sits inside the `$else` arm of
`$if USE_SHAPE_CACHE` (`hobject.c3:80`, `USE_SHAPE_CACHE = !$feature(NOSHAPECACHE)`).
The default build never compiles it. This single site is worth **34 signature
changes** in the transitive closure, because it sits under `find_prop_idx`,
which sits under everything. Phase 4 deletes the cache outright rather than
paying that, so the 94-row below is what the alternative would have cost, not a
live option.

### The transitive closure — the number that matters

Method: parse every `.c3` in `src/` (2181 `fn`/`macro` definitions), brace-match
bodies, build a name-based call graph, seed with the direct readers, propagate
to callers, **and cut propagation at any function that already holds a heap**
(`Heap*` / `heap::Heap*` parameter, `Heap` / `Vm` / `BuiltinContext` receiver,
`Vm*`, `BuiltinContext*`, `Dispatch*`, `heap_ptr`).

| Model | Closure | % of 2181 |
|---|---|---|
| Naive — propagate to every caller | 1286 | 59% |
| Cut at heap-carrying callers, `NOSHAPECACHE` kept alive | 94 | 4.3% |
| **Cut at heap-carrying callers, default build** | **60** | **2.8%** |

The collapse from 1286 to 60 is the load-bearing fact and it is structural:
**345 functions already sit on the boundary as cut points.** The two dominant
ones are

- **`BuiltinContext*` — 158 cut points.** `src/builtins/core.c3:152` is
  literally `Heap* heap;`. The entire `builtins/` tree — typedarray (90),
  array (72), promise (69), object (64), date (51), string (48), which is 60%
  of the naive closure — **costs zero design work**.
- **`Heap*` — 140 cut points**, plus `Vm*` (21) and `Dispatch*` (15).
  `Vm` has `Heap* heap` (`vm_types.c3:258`) and `Dispatch` has `Vm* vm`
  (`vm_types.c3:316`), so the whole dispatch loop already has O(1) heap access.

The 60 leftovers are: `HObject` methods (17), `builtins/inspect.c3`'s recursive
walker (16), `env.c3` (10), `capi.c3` (6), `builtins/json.c3`'s walker (5),
`vm_execute.c3` (3), and three singletons. Max threading depth 8.

### Secondary global state

Same bug family, smaller tier. Two of these are **not** a smaller tier — they
are the same corruption class:

| Symbol | File:line | Nature |
|---|---|---|
| `builtin_length_key` | `hobject.c3:75` | interned `HString*` from **one** heap |
| `promise_reaction_next_key` | `hobject.c3:80` | interned `HString*` from **one** heap |
| `g_symbol_counter` | `builtins/symbol.c3:16` | per-runtime uniqueness counter |
| `g_private_class_id` | `compiler/private_names.c3:28` | per-runtime counter on `Heap` |
| `g_last_err_msg/_line/_col` | `compiler/context.c3:177-179` | per-compilation |
| `g_disable_optimize` | `compiler/context.c3:187` | process-wide CLI flag |
| `test262_host_enabled` | `vm/vm_lifecycle.c3:19` | test harness |
| `opprof_prev` | `vm/vm_opprofile.c3:27` | profiler |
| `g_threaded_handlers_init` | `vm/vm_execute_threaded.c3:44` | one-time table init |
| `g_rt`, `g_engine_ready` | `capi.c3:120, 124` | ABI |
| `g_sink`, `g_sink_len`, `g_sink_cap` | `capi.c3:549-551` | ABI string sink |

Full disposition in [Secondary global state, itemised](#secondary-global-state-itemised).

---

## Verification of the premises

Each claim in the brief was checked against the source. Two are wrong in ways
that change the design.

**1. `_active_heap` is a heap pointer. PARTIALLY WRONG — it is two things.**

At `hobject.c3:2079-2089`:

```c3
    // The allocator comes from `heap_ptr` rather than `_active_heap`, which
    // teardown clears before this walk. `_active_heap` still says whether the
    // heap is live...
        heap::gs_release(gs, heap_ptr, _active_heap != null);
```

`hobject_free` is passed `heap_ptr` *and* reads `_active_heap`. The second read
is a **teardown-liveness flag**, not a heap lookup. During `Heap.destroy` the
global is null while `heap_ptr` is non-null, and that difference is what stops
`hobject_free` refcounting strings into a string table that is being swept.

A mechanical substitution of `heap_ptr` for `_active_heap` **re-enables the
decref loop the code exists to suppress**, and prototype B hit exactly that:
teardown started freeing heap-allocated memory with `mem::free`, a
cross-allocator free. This needs an explicit replacement — an added `bool` or a
`Heap.tearing_down` field — before any other work.

**2. `shape_free(sh, heap_ptr)` has the same defect.** `hobject.c3:2376`:

```c3
fn void shape_free(Shape* sh, void* heap_ptr) {
    if (sh == null) return;
    if (heap_ptr != null) {
        ... decref every key ...
    }
    if (_active_heap != null) { ... free through the heap allocator ... }
```

A single `heap_ptr` argument means both "release the keys" *and* "allocate from
this heap". Callers pass `null` to mean the first, not the second. Both
prototypes had to split it into `shape_free(Shape*, Heap*, bool release_keys)`.

**3. `HObjectBase` has no room for a heap pointer. CONFIRMED, with a
correction.** Measured by compiling a layout-identical probe with c3c 0.8.2:

```
size = 80, align 8
flags 0  refcount 4  next 8  prev 16  prototype 24
shape_id 32  [PAD 34..39]  shape 40
prop_capacity 48  prop_count 50  array_size 52  array_used 56  [PAD 60..63]
prop_alloc 64  prop_hash 72
```

10 bytes of padding, but **no contiguous 8-byte hole**, and neither hole is
8-byte aligned. Adding `void* heap` measures **80 → 88**. Amplified:
`OBJ_SIZE_PLAIN` 112 → 120 (+7.1%), array/func 184 → 192 (+4.3%). Prototype B
instrumented the pool's own accounting: at 1M live objects,
**112,238,592 → 120,250,368 bytes, +7.14%**, reproducible exactly.

The correction: **a `ushort heap_id` index fits in the existing padding at
offsets 36–39 for free** — measured 80 → 80, and still 80 after main's
`uint shape_id` widening (`aa96e119`), which is itself free.

**Measurement warning.** macOS `/usr/bin/time -l` reported only **+33 KB** for
that same 8 MB, under-reporting pool pages by ~250x. Do not size object-layout
changes with `time -l` on this machine; instrument the pool.

**4. A `Heap*` cannot be derived from an object address today. CONFIRMED for
the shipped configuration; the reason usually given is wrong.**

The claim that `FixedBlockPool` cannot align pages is **false**.
`std::core::mem::mempool`'s `FixedBlockPool.init` takes an `alignment`
parameter (`mem_mempool.c3:57`) and `fixedblockpool_allocate_page` calls
`calloc_aligned` when it exceeds default (`:227-231`). Prototype B verified
this empirically at 2 MB alignment: 52,435 blocks over 3 pages,
`straddling_blocks=0, misaligned=0`, first-block offset 0. So masking *works*.

What kills it is arithmetic, not capability — see
[Rejected approaches](#rejected-approaches).

**5. `capi.c3` is not merely guarded — it is structurally single-runtime.
CONFIRMED, and worse than the brief states.**

`capi.c3:160` is the visible guard:

```c3
    if (g_rt != null) return JSE_ERR_INVALID;   // single-runtime rule
```

But deleting that line is *not* sufficient, and the adversarial review proved
it empirically. `host_trampoline` (`capi.c3:656`) publishes the innermost call
context onto `g_rt.active_ctx`, and **eight exported entry points resolve
through `g_rt` rather than through their arguments**:

- `jse_return` (`:738`), `jse_throw` (`:784`), `jse_value_persist` (`:793`),
  `jse_call` (`:807`) — all `if (g_rt == null) return`.
- `jse_get_number` (`:523`), `jse_get_bool` (`:535`), `jse_get_string` (`:560`)
  — all `Runtime* rt = rtp_in != null ? (Runtime*)rtp_in : g_rt;`, an explicit
  documented fallback that `test/capi/host_fn_abi.c:37` already exercises with
  `jse_get_number(NULL, ...)`.

With prototype A's guard removed but `g_rt` left in place, every host function
in runtime A breaks the moment B opens:

```
[host] A arg before=-1 after=-2 *** CORRUPTED ***
result = -4 (want 42)
```

and closing B leaves A permanently broken, because `jse_close` nulls `g_rt`.
**This is a required part of the work, not a follow-up.**

**6. `tlocal` works in this toolchain. CONFIRMED** — `bindings/c3/jse.c3:151`
(`tlocal JsRuntime* active_runtime`) and `:384` (`tlocal DString* utf8_sink`).
It is also not the answer; see [Rejected approaches](#rejected-approaches).

**7. `Heap` already has an anchor for a back-pointer. CONFIRMED.**
`heap.c3:681` is `void* vm_ptr;` and `:656-657` are `void* capi_roots;` /
`CapiMarkFn capi_mark;`. Adding `void* runtime_ptr` to `Heap` costs one pointer
*per runtime*, not per object, and gives `capi.c3` a ctx → heap → runtime path
that removes every `g_rt` read.

---

## The recommended architecture

**Explicit `Heap*` parameter threading, the QuickJS/Duktape model, with no
thread-local and no per-object back-pointer.** This is a hybrid only in the
narrow sense that the *reach* differs by tier; the mechanism is uniform.

### The three tiers, and where the boundary falls

The boundary is drawn by **what the callee already holds**, and it is drawn
that way because 345 functions already hold something:

| Tier | Reach | Sites | Change |
|---|---|---|---|
| **A. Already carries a heap** | `heap_ptr`, `vm.heap`, `ctx.heap`, `self` | 33 of 92 direct; ~1000 call sites in `builtins/` | Textual substitution. **Zero signature churn.** |
| **B. Stranded, threadable** | new `Heap*` parameter | ~55 direct reads across 60 functions | New trailing-or-leading parameter, every caller updated |
| **C. Owns per-runtime state today** | move the global into `Heap` | `builtin_length_key`, `promise_reaction_next_key`, `g_symbol_counter` | Field on `Heap`, read through the tier-A/B heap |

Tier C is the part that is easy to overlook and is not optional. Once tier B
gives `put_prop` a `Heap*`, `builtin_length_key` becomes `h.strs[LENGTH]` —
a direct read, no cache, no global. The same heap reference retires
`promise_reaction_next_key` and `g_symbol_counter`.

### Why this and not something cheaper

Four of the five production engines surveyed chose exactly this, and both
engines this project is measured against are among them:

| Engine | Object carries base? | Global/TLS state | Multi-instance |
|---|---|---|---|
| QuickJS | **no** — `JSObject` is 64 B, measured | **zero** (`grep __thread` → no matches) | unrestricted |
| Duktape | **no** — `duk_hobject` is just `duk_heaphdr` | **zero** | explicitly unrestricted |
| Hermes | no | none | yes |
| mJS/Elk | no | none | yes |
| V8 | **derived by masking** | `Isolate::Current` deprecated | yes, at high cost |
| JerryScript | no | global by default | opt-in build flag via macro |

QuickJS threads `JSContext *ctx` at 1,112 sites and `JSRuntime *rt` at 275, and
re-derives `JSRuntime *rt = ctx->rt;` at function entry in 29 places. Duktape
threads `duk_hthread *thr` at 1,654 sites, `duk_heap *heap` at 239, with 851
`thr->heap` derefs. Duktape's guide states the payoff directly:

> Almost every API call provided by the Duktape API takes a context pointer as
> its first argument. No global variables or states are used, and there are no
> restrictions on running multiple, independent Duktape heaps and contexts at
> the same time.

Note the second half of that sentence in Duktape's docs: *"only one native
thread can execute any code within a single heap at any time."* **Multi-instance
and thread-safety are separate properties.** This plan buys the first and does
not attempt the second. That is the right scope: it is what the guard at
`capi.c3:160` exists to reject, and it is what a plugin host, a test harness, or
a REPL-plus-sandbox actually needs.

### It was built, and it works

Prototype A (branch `proto/explicit-threading`, worktree
`.claude/worktrees/wf_55fe59ea-277-4`, 3 commits on base `f89fffd7`) deleted
`_active_heap` entirely — zero references remain, so every missed site was a
compile error. Final diff **50 files, +1380/−1323**. Correctness: 302/302
scripts, 214 module/syntax/uncaught checks, 5796 console lines matched,
independently reproduced by the adversarial reviewer. It is the **only** one of
the three prototypes that actually opens two runtimes:

```
both runtimes open: A=0x10383c230 B=0x103841f30
ok: A.x=111 survived B.x=222
ok: A.o.k199=199 survived B's 200-property build
ok: A.s='alpha-A' survived B interning 'alpha-B'
ok: B still works after A closed
```

B and C both still return `-5` from the second `jse_open`.

### The two-tier free API falls out on its own

Both reference engines split their API so that free paths, which cannot throw
and may outlive a context, take the lower tier: `JS_FreeValue(ctx,…)` vs
`JS_FreeValueRT(rt,…)` (`quickjs.h:685, 695`), and
`duk_heap_strtable_intern(heap,…)` vs `duk_heap_strtable_intern_checked(thr,…)`
(`duk_heap.h:697-698`). Prototype A arrived at the same shape without aiming
for it: `hobject_free(obj, heap_ptr, heap_live)` **is** Duktape's `rt`-tier
function. That convergence is a good sign the boundary is in the right place.

### What this costs that the "60 signatures" figure hides

The 60-signature closure is correct and I reproduced it independently at 61.
**It measures the wrong thing.** Signature changes are cheap; updating their
callers is not. Prototype A's first build produced **774 call-site errors**, and
the finished conversion touched **1,122 call sites across 44 files**. The
research's own data predicted this and the conclusion was missed: `put_prop`
has 224 callers, 208 of which already carry a heap. Those 208 are free of
*design* work but each still needs an edit. `object.c3` alone took 109.

Mechanically it is mild — **8.3 characters added per call site**, mean line
length 83, and C3's UFCS receiver syntax holds up:
`obj.put_prop(key, val, flags, h)` reads fine. The real ergonomic cost is that
"the heap" acquires **nine spellings**:

| Spelling | Count |
|---|---|
| `heap` | 584 |
| `ctx.heap` | 430 |
| `ds.vm.heap` | 168 |
| `h` | 116 |
| `vm.heap` | 105 |
| `heap_ptr` | 18 |
| `((Vm*)vm_ptr).heap`, `jctx.heap`, `rt.heap` | 30 |

`ds.vm.heap` at 168 sites is a two-hop reach through the dispatch struct in the
hottest code in the engine. Phase 3 should hoist `Heap* h = ds.vm.heap;` once
per handler rather than repeat the chain, both for readability and because it
is what QuickJS does with `JSRuntime *rt = ctx->rt;`.

---

## Rejected approaches

### Rejected: `tlocal void* _active_heap`

The one-line change. Prototype C (worktree `.claude/worktrees/wf_55fe59ea-277-6`).

**The performance objection everyone expected is wrong.** An early survey
predicted a ~70% regression from macOS's indirect-call TLV model. Measured, it
is not there: **LLVM hoists the TLS resolution to once per function**, not per
access. A probe with three reads separated by opaque calls emits **one** `blr`,
then `ldr x8, [x20]` reuses the cached address. Whole-binary indirect branches
went **2488 → 2518, +30 total** — one per reading function across 92 read sites.
Binary size **+64 bytes (+0.003%)**. Local suite green.

It is rejected on correctness, not speed. **It does not fix the stated problem.**
Controlled experiment, same demo against both binaries:

| Scenario | plain global (today) | `tlocal` |
|---|---|---|
| Two runtimes, **one thread** | broken | **still broken** |
| One runtime **per thread** | broken | fixed |

```
== two heaps, ONE thread ==   (tlocal build)
heapA=0x102fbad50 heapB=0x75e9028000
RESULT: heap A orphaned by heap B? YES (still broken)
```

Two runtimes on one thread is the likely embedding shape and precisely what
`capi.c3:160` rejects. The guard cannot be removed; it only becomes per-thread.

Three further defects. **(a)** It makes a runtime thread-affine: a runtime could
not migrate threads without an explicit re-set, and two threads could never
share one. **(b)** The nested-runtime hazard is structural — since
`hobject_set_active_heap` is called only from `create` and `reset`, a host
function in A that enters B leaves A's objects interning into B's table on
return. `host_trampoline` already does the save/restore dance for
`g_rt.active_ctx` and documents why; `_active_heap` gets no such treatment.
**(c)** Fixing (b) properly requires a `@scoped`-style guard on **all 27
`@export`ed `jse_*` entry points** plus the trampoline, with correctness then
depending on nobody adding entry point 28 without it.

**Where it still has value:** the baseline is *actively unsafe* across threads
today (the demo caught thread1 allocating from thread2's heap). If the full
conversion is deferred, this one line is a legitimate cheap bug fix, shipped
**documented as "one runtime per thread"** — not as multi-runtime support. If
the conversion lands, it is redundant.

### Rejected: `Heap*` back-pointer in `HObjectBase`

Prototype B variant (a), branch `proto/heap-from-object`, commit `05cd08f8`.
Fully built: all 92 reads converted, `_active_heap` and both accessors deleted,
**zero `HObject` method signatures changed**, only `shape_create`/`shape_extend`
altered (6 callers, all already holding a heap). Full local suite green.
Binary **−240 bytes** from ~30 removed null guards.

Rejected for two reasons, one measured and one structural.

**Measured: +7.14% heap memory.** `HObjectBase` 80 → 88; instrumented pool
accounting at 1M live objects, 112,238,592 → 120,250,368 bytes, exactly
reproducible.

**Structural, and decisive: it makes cross-runtime leakage silent.** Today two
runtimes cannot coexist, so the bug is unreachable. With a back-pointer, if a
host moves a value from A into an object of B, reading `obj.owner_heap` returns
**A** — the object's *creator*, not the owner of the memory being mutated. The
write then runs `A.decref_tval` on a slot in B's object, `A.str_table_remove` on
a string interned in **B's** table, and `A.free_func` on memory from **B's**
allocator. Given that string equality is pointer identity engine-wide, that
corruption is silent and arbitrarily delayed. Worse, the back-pointer is
*self-consistent*: every object confidently reports a heap, so no cheap
assertion can catch it.

**If a back-pointer is chosen anyway, use `ushort heap_id`, not `Heap*`.**
Measured to fit the existing padding at zero bytes, still zero after main's
`uint shape_id` widening. One indirection through a small heap table instead of
8 bytes per object. It does not fix the silent-leakage problem.

### Rejected: derive the heap by masking the object address (V8's cage)

Prototype B variant (b). The stdlib *does* support this — `FixedBlockPool.init`
takes `alignment`, `fixedblockpool_allocate_page` calls `calloc_aligned`, and a
2 MB-aligned probe produced 52,435 blocks over 3 pages with zero straddling and
zero misalignment. So the commonly-cited blocker ("no page header, no
alignment") is **wrong**.

Rejected because **the memory arithmetic does not survive scrutiny**, and the
figure quoted for it was derived from a configuration the engine does not ship.

The claim was "64 bytes wasted per 2 MB region = 0.0031%". But
`page_size = capacity * block_size`, independent of alignment. At the **shipped**
`capacity=512` (`heap.c3:936-938`, `FixedBlockPool.init(&LIBC_ALLOCATOR, size, 512)`),
pages are 56–96 KB and would need 2 MB alignment → **97.3% waste**. The
prototype's own "52,435 blocks / 3 pages" reverse-engineers to ~17,478
blocks/page, **34x the shipped capacity** — silently assumed. Making masking
cheap forces a **6 MB floor per empty runtime, 25.6x today's 240 KB**, which is
directly hostile to the many-small-runtimes use case multi-runtime exists to
serve.

Two further problems. `hobject_alloc` has a `pool_fallback` malloc path
(`flags.pool_fallback`) whose objects lie outside any aligned page; masking
those yields **garbage, silently**, so the fallback would have to be eliminated
first. And V8's own experience is a warning: pointer compression needed a
dedicated register (r13), the first implementation regressed ~35%, and
production measures 2–4% average latency overhead.

It does have one genuine advantage worth recording: masking answers *"which
heap owns this memory"*, not *"who created this object"*, and memory ownership
is what `decref`/`free`/`str_table_remove` actually need. It also makes
`heap_of(obj) != expected` a cheap check. If the memory arithmetic ever
changes — a custom pool with large uniform regions — revisit it.

### Rejected: macro indirection (JerryScript's `JERRY_CONTEXT`)

JerryScript shipped with our exact design and retrofitted multi-instance support
by rewriting every access as `JERRY_CONTEXT(field)`, swappable at build time
between a static global and `jerry_port_context_get()`. It is the only surveyed
answer that touches no signatures.

**Not available in C3.** Macros are hygienic and cannot capture an enclosing
variable — verified:

```c3
macro Obj* @obj_new_capture(long v) { return obj_new_explicit(heap, v); }
// Error: 'heap' could not be found, did you spell it right?
```

even with `Heap* heap` in the caller's scope. `$eval("heap")` fails identically.
JerryScript's trick works because C macros are textual; C3's are not. The option
is dead, and it would only have relocated the problem to whatever
`context_get()` returned — which, being TLS or a global, lands back on the two
rejections above.

### Rejected: interface / `any` dispatch

C3 supports `struct S (Iface)` with `@dynamic`, but it compiles to a
`dyn_search` selector-table lookup plus an indirect call that never inlines. At
`-O3` a direct call optimised an entire loop into arithmetic while the interface
version could not. Unusable at 92 hot sites.

---

## Performance, with the noise floor

**Recommendation: performance-neutral, and the noise floor on this machine
exceeds every measured effect.** Stated plainly rather than buried: the change
does *not* buy speed, and it does not cost any either.

Prototype A, interleaved A/B/A (ABABA…, median of 13–21 reps), same machine,
same flags:

| Benchmark | BASE | AFTER | Delta | Noise floor |
|---|---|---|---|---|
| property_lookup | 278.6 | 276.6 | −0.54% | 0.42% |
| object | 416.9 | 420.7 | +0.65% | 0.55% |
| ic_monomorphic | 105.0 | 105.2 | −0.22% | 0.76% |
| ic_proto | 127.0 | 127.6 | +0.20% | 0.52% |
| **property paths, mean** | | | **+0.02%** | **0.56%** |

Full 11-benchmark suite: mean **−0.30%**, median **+0.10%**, mean noise
**1.60%**. Every delta is inside the band.

**The decisive measurement is the adversarial reviewer's noise control**, which
none of the three prototypes ran: five binaries interleaved per rep, including a
**duplicate of the baseline**:

| Benchmark | base2 (**identical binary**) | A | B | C |
|---|---|---|---|---|
| loop @41 reps | **1.0377** | 1.0075 | 1.0437 | 1.0540 |
| object @21 reps | **1.0582** | 1.1047 | 1.0778 | 1.0675 |
| geomean, clean 15-rep run | 0.9990 | 0.9985 | 1.0050 | 1.0089 |

**The baseline measured itself 3.8–5.8% slower than itself.** Any claimed effect
below ~5% on this hardware, under thermal load, is not resolvable.

Two false alarms worth carrying forward so nobody re-reports them:

- `bench_loop` read **+2.23% against a 0.79% floor** for prototype A and looked
  real. It is not: `bench_loop` touches no properties at all, the whole
  interpreter is one 14.6k-instruction `Vm.run`, and its mnemonic histogram diff
  is almost entirely **branch targets moving to new addresses at identical
  counts**. A later commit shifted layout again and it fell to +0.55%.
  **A sub-3% delta on a megafunction is code alignment, not semantics.**
- Prototype C's naive *sequential* runs looked like a consistent regression;
  interleaving revealed it as thermal drift. Always interleave.

**Codegen answers the question directly, and the two effects cancel.** Callees
lose global loads (`adrp` count **−43, −0.60%** binary-wide; `has_prop_proto`
1→0, `ensure_prop_hash` 9→7); callers gain argument setup (**+1650 instructions,
+0.42%**, concentrated in `dispatch_property` at +389). A global read is not
worse than a register-passed parameter here — the load is cheap, LLVM hoists it,
and the argument shuffling at every call level costs slightly more than the load
saves. C3 0.8.2 also has **no usable `restrict`**: `@noalias` is listed by
`--list-attributes` but rejected in function, parameter and type position, and
`@pure` is documentation-only. So a threaded parameter cannot even be annotated
as non-aliasing, which is a real argument against assuming parameters optimise
better.

The **~30 removed `if (_active_heap != null)` guards** were predicted to be a
probable win. They are not measurable. Do not budget for them.

Binary size: **2,054,312 → 2,070,504 bytes, +16,192 (+0.79%)**. Confirmed
byte-exact by the reviewer. Prototype B was −240, prototype C +64.

---

## Runtime/Context split: no

**Keep the single Heap-rooted design. Do not introduce a `JSContext` analogue as
part of this work.**

QuickJS splits `JSRuntime` (1440 B: atom table `:315-321`, shape hash `:377-381`,
GC lists `:329-333`, malloc context, stack limits) from `JSContext` (472 B:
global object `:533-534`, per-realm prototypes `:520-521`, initial shapes
`:514-518`, `JSRuntime *rt` back-pointer `:508`). The split line is exactly
identity-and-allocation versus per-realm.

**It exists to let multiple realms share one runtime.** This engine has no realm
concept. `Heap` already holds the string table (`heap.c3:448-450`), the shape
table, the GC lists, `strs[]` (`:462`), *and* the prototypes. Splitting would
invent a distinction the engine does not make, and would double the diff of a
change that is already 1,100 call sites.

The two-tier *API* shape both reference engines use — the `rt` tier for free
paths that cannot throw — **is** worth keeping, and this plan adopts it. But
that is a parameter convention, not a second struct. Prototype A arrived at
`hobject_free(obj, heap_ptr, heap_live)` independently.

The one thing worth doing now is a **naming discipline that leaves the door
open**: use `Heap*` for the allocation/interning tier and `Vm*`/`BuiltinContext*`
where a throwing context is needed, and do not add anything realm-shaped to
`Heap`. If realms (`ShadowRealm`, or `vm.createContext`-style isolation) are
ever wanted, the split becomes a mechanical follow-on, because every site that
would need a `Context*` already takes a `Vm*` or `BuiltinContext*`.

The C ABI needs nothing from a split: `Runtime` (`capi.c3:99`) already holds
`heap` and `vm`, so `include/jse.h` is unchanged.

---

## Secondary global state, itemised

Three groups, three dispositions. Nothing is left as "and also fix the rest".

### Group 1 — per-runtime, must move onto `Heap` (blocking)

**`builtin_length_key`** (`hobject.c3:75`). Assigned at `heap.c3:992`
(`hobject::builtin_length_key = self.strs[BuiltinStr.LENGTH];`), then compared by pointer identity
in `put_prop` (`hobject.c3:1351, 1381, 1423` in the pre-conversion numbering).
Since string equality *is* pointer identity, a second heap's init steals it and
`arr.length` silently stops being recognised as a length write on the first
heap's arrays. **Delete the cache entirely** — once `put_prop` has a `Heap*`,
`h.strs[BuiltinStr.LENGTH]` is a direct array read. Prototype A did exactly
this and it cost nothing.

**`promise_reaction_next_key`** (`hobject.c3:80`). Same class. Assigned from
`builtin_intern_string(heap,…)` in `builtins/promise.c3`, read by `heap.c3`'s
mark phase to walk a Promise's pending reaction chain without importing
`builtins/promise.c3`. Move it to a `Heap` field. The comment explaining why it
is a global (import cycle avoidance) remains valid for *where* it lives — it
just lives on the heap instead of the module.

**`g_symbol_counter`** (`builtins/symbol.c3:16`). Move to `Heap`.
`create_symbol_string` already takes `Heap* heap` as its first parameter
(`symbol.c3:29`), so this is a two-line change with zero signature churn. It is
not a correctness bug today (two runtimes would just share a counter, producing
*more* uniqueness than needed) but it is per-runtime state and belongs on the
runtime.

Verification for the group: a JS-level test asserting `arr.length = 5` still
truncates, plus the two-runtime interleave test (see
[Test strategy](#test-strategy)) with a promise chain live in each.

### Group 2 — ABI-owned, must move onto `Runtime` (blocking)

**`g_rt`** (`capi.c3:120`). This is the second half of the bug, not a follow-up.
Every entry point must resolve its runtime from its arguments:

- `jse_return`, `jse_throw`, `jse_value_persist`, `jse_call` take
  `jse_call_ctx ctx`, which is a `BuiltinContext*`, which has `Heap* heap`
  (`builtins/core.c3:152`). Add `void* runtime_ptr` to `Heap` (alongside the
  existing `void* vm_ptr` at `heap.c3:681`) and resolve
  `ctx.heap.runtime_ptr`. **No ABI signature changes.**
- `active_ctx` moves from `Runtime` to being resolved the same way, or stays on
  `Runtime` but is reached via `ctx.heap.runtime_ptr` instead of `g_rt`. The
  save/restore in `host_trampoline` (`capi.c3:665-668`) is already correct once
  it names the right runtime.
- `jse_get_number`/`jse_get_bool`/`jse_get_string` currently accept
  `rtp_in == null` and fall back to `g_rt`. That fallback is **exercised by
  shipped test code** (`test/capi/host_fn_abi.c:37`) and is therefore a
  compatibility question, not a free deletion. See
  [The C ABI after the change](#the-c-abi-after-the-change).

`g_rt` itself may survive as a **debug-only "last runtime opened"** or be
deleted outright; it must stop being load-bearing either way.

**`g_engine_ready`** (`capi.c3:124`). Genuinely process-wide: it gates
`ensure_engine_init`, which validates compile-time-populated tables that outlive
any runtime. **Leave it.** Comment it as such.

**`g_sink`/`g_sink_len`/`g_sink_cap`** (`capi.c3:549-551`). The comment is
honest — `write_cesu8_as_utf8`'s callback takes no udata, "so a module-global
sink is the only option; single-runtime + no threads make it safe." That
justification **expires** with this change: two runtimes on one thread cannot
re-enter `jse_get_string` concurrently (there is no yield point inside), so it
remains *technically* safe, but it is fragile and the comment becomes wrong.

Fix it properly by giving `write_cesu8_as_utf8` a `void* udata` parameter and
passing a stack-local sink struct. That is a small, independently shippable
change to `hstring.c3` plus one caller, and it should land **before** the guard
is lifted so the comment never has to be re-litigated.

### Group 3 — per-compilation, a separate change (non-blocking)

**`g_last_err_msg`/`g_last_err_line`/`g_last_err_col`** (`compiler/context.c3:177-179`)
and **`g_private_class_id`** (`compiler/private_names.c3:28`).

**Resolved.** The error state now lives on the per-compile `Lexer`
(`record_error`, `lex.err_msg`), and `g_private_class_id` is a counter on each
runtime's `Heap` (`priv_class_id`), which keeps ids distinct across the
parent/arrow nested-context split without atomics. The compiler has no mutable
process-global state left except the `g_disable_optimize` CLI toggle.

**Are they a multi-runtime bug?** Only mildly. Two runtimes compiling
concurrently is impossible on one thread (compilation does not yield), so the
failure mode is limited to a stale error message from runtime A being read back
through runtime B's `jse_last_error`. `capi.c3` copies the message into
`rt.errmsg` at the point of failure, so in practice the window is closed
already. `g_private_class_id` colliding across runtimes produces *fewer*
collisions, not more.

**Disposition: track separately, do not block on it.** Landing it inside this
change would add compiler files to a diff that already spans 50. File it as its
own plan item; it is a genuine cleanup with an independent rationale
(testability of the compiler in isolation).

**`g_disable_optimize`** (`context.c3:187`) is a process-wide CLI flag set once
from `--no-optimize`. Leave it.

### Group 4 — genuinely process-wide, leave alone

- **`g_threaded_handlers_init`** (`vm_execute_threaded.c3:44`). A one-time
  dispatch-table initialisation guard. The table is derived from compile-time
  constants and is identical for every runtime. Correct as-is. **Note: this file
  has uncommitted user changes; do not touch it.**
- **`opprof_prev`** (`vm_opprofile.c3:27`). Profiler state, built only under the
  profiling target.
- **`test262_host_enabled`** (`vm_lifecycle.c3:19`). Test-harness toggle.

Add a one-line comment to each saying *why* it is allowed to be global, so the
next reader does not have to re-derive it.

---

## The C ABI after the change

### `include/jse.h`

Almost unchanged. Every exported signature stays byte-identical: `Runtime`
already holds `heap` and `vm`, and `jse_call_ctx` is already opaque
(`jse.h:72`, `typedef void *jse_call_ctx`).

Three edits:

1. `jse.h:17` — `" - NOT thread-safe, and single-runtime per process (see jse_open)"`
   becomes `" - NOT thread-safe. Multiple runtimes may be open at once, but a
   runtime must only be used from one thread at a time, and values must not
   cross runtimes."` This mirrors Duktape's wording, which is precise about the
   two properties being separate.
2. `jse_open` (`:108`) doc: remove the "second call fails" note.
3. A new paragraph on cross-runtime values, since that is the new failure mode
   the ABI exposes. See
   [Cross-runtime values](#cross-runtime-values-the-pointer-identity-problem).

### `src/capi.c3`

**`jse_open`'s guard is deleted, but not on its own.** `capi.c3:160`
(`if (g_rt != null) return JSE_ERR_INVALID;`) is one line, and prototype A
removed it in one line — and thereby shipped a live bug, because eight entry
points still read `g_rt`. The guard is the *last* thing to go, after:

- `Heap` gains `void* runtime_ptr`, set in `jse_open` next to the existing
  `hp.capi_roots = (void*)rt;` (`capi.c3:183`).
- `resolve_handle` (`capi.c3:634`) takes the runtime from `ctx.heap.runtime_ptr`
  rather than a `Runtime*` argument threaded from `g_rt`.
- `jse_return`, `jse_throw`, `jse_value_persist`, `jse_call` resolve
  `Runtime* rt = (Runtime*)((BuiltinContext*)ctxp).heap.runtime_ptr;`.
- `host_trampoline` (`capi.c3:656`) publishes `active_ctx` onto **that** runtime.
- `mark_slots` / `capi_roots` are already per-heap (`capi.c3:183-184`) and need
  no change — a good sign the design was already heading this way.

**The three readers get a context tier.** `jse_get_number(NULL, id, &d)`
resolves through `g_rt`, which is what lets a host function read its own
arguments without holding a runtime (`examples/c99/host_fn.c:82`,
`test/capi/host_fn_abi.c:38`). That cannot survive two runtimes: a global slot
handle is a runtime-scoped integer carrying no owner, so `NULL` has no answer,
and the failure mode is runtime A's handle resolving against runtime B's
registry and returning B's value.

This code is unreleased, so there is no compatibility cost and no transition
period to design. Take the shape both reference engines use:

- **`jse_ctx_get_number` / `_bool` / `_string`** take a `jse_call_ctx`. This is
  what a host function actually holds, and the ctx already reaches a heap
  (`BuiltinContext.heap`, `builtins/core.c3:152`) and from Phase 5 a runtime.
  Scope handles (high bit set, `capi.c3:635`) resolve here too, which the
  runtime tier cannot do at all.
- **`jse_get_number` / `_bool` / `_string`** keep taking a `jse_runtime` and
  reject `NULL` with `JSE_ERR_INVALID`.
- **`jse_ctx_runtime(ctx)`** for hosts that need the runtime itself, mirroring
  `JS_GetRuntime(ctx)` (`quickjs.h:391`).

`g_rt` is then unreferenced and is deleted rather than deprecated. Keeping a
global that names "the one runtime" would preserve in `capi.c3` exactly the
defect this plan removes from the engine.

The migration is mechanical and confined to unreleased callers: host-side reads
gain `_ctx_` and pass `ctx` instead of `NULL`.

---

## Bindings

Six surfaces. Only one has its own guard.

| Binding | Guard? | Work |
|---|---|---|
| **`bindings/c3/jse.c3`** | **yes** | Delete `RUNTIME_EXISTS` (`:53`), the `tlocal JsRuntime* active_runtime` (`:151`), the check at `:158`, the assignment at `:184`, the clear at `:207`, and rewrite the struct doc at `:132-136`. `ALREADY_OPEN` stays — it catches double-opening *the same* `JsRuntime`, which is still an error. |
| **`bindings/zig`** | no | Docs only, plus a two-runtime example. |
| **`bindings/rust`** | no | Docs. Worth checking whether `Runtime` is `Send`/`!Sync` — after this change it should be `Send` but **not** `Sync`, and values must not be `Send` at all. That is a genuine type-level improvement Rust can express and the others cannot. |
| **`bindings/ruby`** | no | Docs. |
| **`bindings/python`** | no | Docs. |
| **`examples/c99`** | no | Move host-side reads to the `jse_ctx_get_*` tier; add a two-runtime example. |

Note the irony worth recording in the C3 binding's commit message: its guard is
already `tlocal`, so it was *stricter* than the engine's in the multi-thread
case and *equally wrong* in the two-runtimes-one-thread case.

---

## Cross-runtime values: the pointer-identity problem

This is the hardest question in the plan and it is **not solved by any of the
three prototypes**. It must be answered in the ABI documentation before the
guard is lifted, because lifting the guard is what makes it reachable.

### The invariant

Per the project's own engine invariant: **string equality is pointer identity
engine-wide.** Two heaps intern independently, into separate `str_table`s
(`heap.c3:448`). Interning `"hello"` in runtime A and `"hello"` in runtime B
produces **two different `HString*`**, and:

- `A_hello === B_hello` evaluates **false** if the two ever meet.
- Using `B_hello` as a property key on an A object inserts a *second*,
  distinct `"hello"` property that `A.hello` will not find.
- `A.str_table_remove(B_hello)` during GC or teardown corrupts B's table, or
  frees memory B still owns.

The same applies to every `HeapHeader`-carrying value: objects, functions,
symbols. Refcounts, GC lists (`next`/`prev` are intrusive and singly rooted at
the Heap) and the allocator all belong to one specific heap.

### What the reference engines do

QuickJS is explicit: *"Several runtimes can exist at the same time but they
cannot exchange objects"* and *"There can be several JSContexts per JSRuntime
and they can share objects."* Exchange is legal only within a runtime.
Duktape's model is identical — the heap is the isolation unit.

### The rule this engine adopts

**A `jse_value` belongs to exactly one runtime. Passing it to another is
undefined behaviour, and the ABI detects it rather than corrupting.**

Detection is cheap and should be built in from the start, not retrofitted:

- **Global slot handles** are runtime-scoped integers already. A handle from A
  used against B indexes B's slot array, hits `used == false` or a generation
  mismatch, and already returns `JSE_ERR_INVALID` via `slot_get`. **This case is
  already safe**, by accident of the generation design landed in `97be88a2` /
  `8969e373`. It should be tested, and the accident should be documented as
  intentional.
- **Scope handles** (`SCOPE_HANDLE_BIT`, `capi.c3:635`) resolve against the
  `BuiltinContext*` passed alongside, so they are inherently ctx-scoped. Safe.
- **The residual hole** is a host that persists a value from A
  (`jse_value_persist`) and then passes the resulting integer to a B entry
  point where the generations happen to coincide. Mitigation: **seed each
  runtime's generation counter with a per-runtime nonce** rather than 0, so a
  collision requires deliberate effort. Cheap; do it in the same phase.

**The safe interchange path is by value, not by reference**: read the string out
of A with `jse_get_string` (UTF-8 bytes) and create a fresh one in B with
`jse_return_string`. Numbers and booleans carry no heap identity and cross
freely. Document this explicitly in `jse.h` — it is exactly what QuickJS
documents.

### Why this is not a reason to add a runtime tag to every value

`jse_value` is a 32-bit handle, not a `TVal`, so there is no per-value memory
cost to tagging — but there is also nowhere obvious to put a tag without
shrinking the slot index space. The generation nonce achieves the same
detection at zero structural cost. **Do not tag `TVal`.**

---

## Phased implementation

Seven phases. Phases 1–3 are independently shippable and leave the tree green
with the guard still in place. Phase 6 is the point of no return.

Every phase gates on: `test/run_local.sh` fully green (302 scripts, 14 modules,
101 syntax_positions, 63 export_names, 24 toplevel, 12 uncaught, 5796 console
lines), the golden bytecode set, and `bench-fast` **interleaved against a
same-session baseline**. Per project rules, do not run full test262.

### Phase 1 — retire the overloaded parameters (prerequisite, ships alone)

**Scope.** Two latent bugs that exist today, independent of multi-runtime:

- `hobject_free` / `hobject_free_header` use `_active_heap != null` as a
  **teardown-liveness flag** (`hobject.c3:2079-2089`). Replace with an explicit
  `bool tearing_down` on `Heap`, set by `Heap.destroy` and `Heap.reset`, read
  through the `heap_ptr` those functions already have.
- `shape_free(sh, heap_ptr)` overloads one argument to mean both "release the
  keys" and "allocate from this heap" (`hobject.c3:2376-2388`). Split into
  `shape_free(Shape*, Heap*, bool release_keys)`.

**Files.** `src/hobject.c3`, `src/heap.c3`.

**Verification.** Local suite; **plus a GC-stress run**, because these are
teardown paths the local suite covers thinly. `make duktape_c3_gc_stress` over
the object-lifetime and promise families, and an ASan pass over
`Heap.destroy`/`Heap.reset` cycles. Both prototypes hit real segfaults here;
this is not a formality.

**Ships alone: yes.** These are bug fixes with independent value. Landing them
first also removes the single most dangerous trap from every later phase.

### Phase 2 — retire the two cached key pointers and the symbol counter (ships alone)

**Scope.** Delete `builtin_length_key`; `put_prop` reads
`h.strs[BuiltinStr.LENGTH]` — but `put_prop` does not yet have `h`, so this
phase either waits for Phase 4 or threads exactly one parameter into `put_prop`
ahead of it. **Recommendation: thread `put_prop` early**, since it is the single
hottest converted function and landing it alone gives a clean bench signal
before 1,000 other call sites move.

Move `promise_reaction_next_key` and `g_symbol_counter` onto `Heap`.

**Files.** `src/hobject.c3`, `src/heap.c3`, `src/builtins/symbol.c3`,
`src/builtins/promise.c3`, plus `put_prop`'s 224 call sites (208 of which
already hold a heap).

**Verification.** Local suite; a targeted `arr.length = n` truncation test;
promise-chain GC marking under GC_STRESS.

**Ships alone: yes**, and it is the cleanest single-phase perf measurement in
the whole plan.

### Phase 3 — fix `write_cesu8_as_utf8`'s missing udata (ships alone)

**Scope.** `hstring.c3:803` is
`fn void write_cesu8_as_utf8(char[] data, PutByteFn put_byte_fn)`. Give it a
`void* udata` parameter (and widen `PutByteFn` accordingly); convert `capi.c3`'s
`g_sink`/`g_sink_len`/`g_sink_cap` into a stack-local struct in
`jse_get_string`.

**Files.** `src/hstring.c3`, `src/capi.c3`, plus any other caller of
`write_cesu8_as_utf8`.

**Verification.** The existing string round-trip tests in
`test/capi/host_fn_abi.c`, including the astral-character case.

**Ships alone: yes.** Small, and it retires a comment that this plan would
otherwise falsify.

### Phase 4 — thread `Heap*` through `hobject.c3` and `env.c3`

**Scope.** The bulk. ~55 stranded reads across ~17 `HObject` methods plus
`env_put` and `env_try_put_lex`; the 33 already-free sites converted to their
in-scope heap; the tier-A substitutions in `heap.c3` and `vm_execute.c3`.
`_active_heap` and its two accessors are **deleted at the end of this phase**,
so every missed site is a compile error.

**Delete the shape pointer cache along with the flag.** `HObject.shape` is an
8-byte per-object copy of what `heap.shapes[shape_id]` already gives, and it
exists only to avoid one indirection into an array that is permanently hot.
Measured on the paths that actually walk shapes (a megamorphic site that defeats
the inline cache, and `Object.keys`, both interleaved to cancel thermal drift),
the no-cache build is marginally *ahead*:

| | cache | no cache |
|---|---|---|
| megamorphic reads | 88-100ms | 86-94ms |
| `Object.keys` | 115-122ms | 113-117ms |
| chain walk | 8ms | 8-10ms |

`HObjectBase` goes 80 to 72 bytes and `OBJ_SIZE_PLAIN` 112 to 104. Note the RSS
win does not follow: both land in the same allocator size class, so 300k objects
moved 16 KB out of 56 MB. The reason to do this is not memory.

So there is no trade to configure, and `NOSHAPECACHE` stops being a build option
because both settings land on the same point. Remove the field, the `$if`/`$else`
in `get_shape`, all of `set_shape` (14 call sites become direct reads), the flag,
and the `build-noshape` recipe in `justfile`.

Sequencing matters: this is a consequence of the phase, not a prerequisite.
Removing the cache makes `get_shape` need a heap, which today means
`_active_heap`. Doing it first would make the engine's most-called accessor read
the global unconditionally rather than in an arm the default build never
compiles. It is cheap only once `Heap*` is threaded, which is why it belongs
here and not in its own phase.

A no-cache binary already passes the full local suite (303 scripts, 0 failed),
so this is a supported configuration today, just not one CI exercises.

**Files.** `src/hobject.c3`, `src/env.c3`, `src/heap.c3`,
`src/vm/vm_execute.c3`, and every caller — prototype A measured **1,122 call
sites across 44 files**, with `object.c3` alone at 109.

**The safety net has a hole and it must be plugged first.** C3's trailing
default arguments silently absorb a newly inserted parameter. Reproduced
standalone:

```
OLD sig: obj=1 heap=2 free_header=false
NEW sig: obj=1 heap=2 heap_live=false free_header=true
```

Identical call text, different meaning, **zero compiler diagnostics**. In
prototype A this produced a **double free** — the header freed in phase B and
again in phase C — surfacing as 47 tests failing with a bare SIGABRT and no
message. Three functions on the converted path have trailing defaults today:
`hobject_free(…, bool free_header = true)` (`hobject.c3:1994`),
`env_try_put_lex(…, bool check_tdz = false)` (`env.c3:389`), and
`env_declare_var(…, bool is_bare = false)` (`env.c3:237`).

**Mandatory sub-step, before any parameter insertion:** audit every function in
the closure for trailing defaults and make those arguments explicit at every
call site. **Do not delegate the mechanical portion to a script** — prototype
A's automation produced the silent double-free.

**Verification.** Local suite; golden bytecode; GC_STRESS over the whole local
suite; ASan. Interleaved bench with a same-session baseline duplicate as the
noise control — **required**, not optional, given that the baseline measures
itself 3.8–5.8% slower than itself under load.

**Ships alone: yes**, and it should. At this point the engine has no global
heap, the guard is *still in place*, and multi-runtime is not yet claimed.
That is a genuinely useful intermediate state: it is the whole correctness win
with none of the ABI risk, and it bisects cleanly.

### Phase 4 outcome

Landed as `0e135315` + `80670e34`. 37 signatures, 1483 call sites across 52 files.
`_active_heap`, both accessors, the shape pointer cache, `USE_SHAPE_CACHE`,
`NOSHAPECACHE` and the `build-noshape` recipe are gone; `HObjectBase` is 72 bytes
(was 80) and `OBJ_SIZE_PLAIN` 104 (was 112).

The purpose is achieved. With the guard temporarily lifted, two runtimes hold
independent globals, objects, prototype patches and interned strings, survive 20k-object
churn on both heaps, and one stays fully usable after the other closes: 15 checks, all
passing. The guard was restored and re-confirmed to reject.

**It costs performance, and the plan's prediction of neutrality was wrong.** Measured
interleaved with a duplicate-baseline noise control:

| benchmark | noise floor | delta |
|---|---|---|
| `bench_recursion_deep` | 0.0% | **+3.5%** |
| `bench_arithmetic` | 0.0% | **+10%** |
| `bench_ic_monomorphic` | | 0% |

The earlier neutrality claim came from measuring the shape-cache removal *alone*, on a
tree that still had the process-global. Combined with threading it does not hold.

Two hypotheses were tested and refuted rather than assumed:

- **Not `EnvRecord`.** Storing the heap on the record (rather than threading it through
  the env API) was adopted from the first attempt, where a parameter there cost ~7%.
  `fib` takes the register-resident-locals path and allocates no `EnvRecord` per call,
  so it is off this benchmark entirely. Note the record does grow 24 to 32 bytes: the
  padding after its two bools is 6, not the 8 this plan claimed.
- **Not the lost shape cache.** Restoring `HObject.shape` as an unconditional field,
  keeping the threading, made things *worse*: +18.8% on arithmetic against +12.5%
  without it. The probe was reverted.

The residue is the extra `Heap*` argument on `find_prop_idx` / `get_prop_flags`, which
every path funnels through. It is filed as a follow-up rather than fixed here: the
threading is what multi-runtime requires, and clawing back the argument cost is a
separate optimisation with its own design space.

### Phase 5 — make `capi.c3` per-runtime (guard still in place)

**Scope.** Add `void* runtime_ptr` to `Heap`; set it in `jse_open`; convert
`resolve_handle`, `jse_return`, `jse_throw`, `jse_value_persist`, `jse_call`,
`host_trampoline` and the three readers to resolve through
`ctx.heap.runtime_ptr`. Seed each runtime's slot generation counter with a
per-runtime nonce.

**Split the readers into two tiers** (see open question 2). Add
`jse_ctx_get_number` / `jse_ctx_get_bool` / `jse_ctx_get_string` taking a
`jse_call_ctx`, which is what a host function actually holds; the existing
`jse_get_*` keep taking a `jse_runtime` and now reject `NULL` with
`JSE_ERR_INVALID` instead of falling back to `g_rt`. Add `jse_ctx_runtime(ctx)`
for hosts that need the runtime itself, mirroring `JS_GetRuntime`.

`g_rt` is then dead and is **deleted in this phase**, not deprecated. It is the
last process-global in `capi.c3` and the plan's own premise is that a global
naming "the one runtime" is exactly the bug being removed.

**Files.** `src/capi.c3`, `src/heap.c3`, `include/jse.h`.

**Verification.** `test/capi/` passes after the reader-tier migration, which
touches `host_fn_abi.c:38`. Every other assertion must pass **unchanged** — a
diff that only adds `_ctx_` at the host-side read sites is the signal this phase
changed nothing else. Plus `host_fn_abi.c` under the GC_STRESS+ASan
shared target (`project.json:181`).

**Ships alone: yes.** No behaviour changes with one runtime open.

### Phase 6 — lift the guards

**Scope.** Delete `capi.c3:160`. Delete `bindings/c3/jse.c3`'s
`RUNTIME_EXISTS`, `active_runtime`, and the two sites that maintain it. Update
`include/jse.h`'s header comment and `jse_open` docs. Add the cross-runtime
value paragraph.

**Files.** `src/capi.c3`, `bindings/c3/jse.c3`, `include/jse.h`,
`docs/embedding.md`.

**Verification.** The entire new multi-runtime test suite (below). This is the
phase where those tests first *can* run.

**Ships alone: only after 4 and 5.** This is the point of no return: once two
runtimes can open, every latent cross-runtime bug becomes reachable.

### Phase 7 — bindings and examples

**Scope.** Zig, Rust, Ruby, Python, `examples/c99` — docs, a two-runtime
example each, and Rust's `Send`/`!Sync` audit. Parallelisable, one per binding.

**Ships alone: yes, per binding, at leisure.**

### Deferred, tracked separately

Both compiler globals this plan deferred (`g_last_err_*`, `g_private_class_id`)
have since been removed: the error state moved to the per-compile `Lexer`, and
the class id moved to a per-runtime counter on `Heap`. Not part of this diff.

---

## Test strategy

There is **zero multi-runtime coverage today**, and the existing suite is
entirely single-runtime — it caught none of the bugs the three prototypes hit.
New tests go in `test/capi/` (which already holds `host_fn_abi.c`,
`host_fn_phase1.c3`, `host_fn_phase2.c3`, `host_fn_phase4.c3`,
`value_registry_gc.c3`) with matching `project.json` targets following the
existing `*_gc_stress` naming.

### 1. Two runtimes, one thread, independent globals

`test/capi/two_runtimes.c`. Open A and B; interleave. Prototype A's version,
which must become a permanent test:

```
both runtimes open: A=… B=…
ok: A.x=111 survived B.x=222
ok: A.o.k199=199 survived B's 200-property build
ok: A.s='alpha-A' survived B interning 'alpha-B'
ok: B still works after A closed
```

Extend with: shape transitions interleaved (build the same property sequence in
both, assert both objects read back correctly — this is what would break if
shape tables were shared); array growth interleaved; and a third runtime, since
two can accidentally work by symmetry.

### 2. Host function in A calling into B

**This is the test that catches the `g_rt` bug the adversarial reviewer found,
and it must fail against a Phase-4-only build.** A registered host function in
runtime A that, from inside its callback, calls `jse_eval` on runtime B, then
reads its own argument again and returns it. The observed failure without
Phase 5:

```
[host] A arg before=-1 after=-2 *** CORRUPTED ***
result = -4 (want 42)
```

Variants: B closed *while* A's callback is live on the stack (must be refused or
safe); a host function registered in **both** runtimes with the same name and
different udata, asserting each gets its own; A→B→A three levels deep, asserting
`jse_this`/`jse_argc` are correct at every level on the way out.

### 3. Cross-runtime value passing

Because string equality is pointer identity, this is a correctness requirement,
not a nicety:

| Case | Expected |
|---|---|
| Persist a value in A, pass the handle to a B reader | `JSE_ERR_INVALID`, no crash, no corruption |
| Same, after A is closed | `JSE_ERR_INVALID` |
| Scope handle from A's callback used in a B entry point | `JSE_ERR_INVALID` |
| `jse_get_string` from A → `jse_return_string` into B | correct value; the two `HString*` are **different pointers** |
| Same string interned in A and B, then `===` compared **within** each | true in each; the test asserts they are separate tables |
| Numbers/booleans crossing | fine — they carry no heap identity |

The handle cases must be run **after** the generation-nonce seeding lands, and
one of them should deliberately construct the colliding-generation case that the
nonce is there to prevent.

### 4. GC under GC_STRESS with two live runtimes

Every test above, under `duktape_c3_gc_stress`. Specifically:

- A collection triggered in A while B holds live objects — assert B's objects
  survive and A's unreachable ones do not. `mark_roots` reaches `capi_roots`
  per-heap (`heap.c3:2683`), so this should hold; assert it rather than assume.
- Allocate heavily in B from inside a host callback running in A, forcing a
  collection in B while A has a native frame on the stack. `heap.c3:3034` and
  `:3112` suppress reclamation while `native_frame_depth > 0` — **per heap**.
  B's depth is 0 even though A's is not. This is the highest-risk interaction in
  the plan and there is no existing test for it.
- A promise chain live in both runtimes simultaneously, exercising the
  `promise_reaction_next_key` move.

### 5. Teardown of one runtime while another stays live

- Open A, open B, close A, assert B fully functional (eval, host call, GC).
- Close B, reopen a new B, assert it works — no stale global state.
- Interleave: open A, open B, close B, open C, close A, close C.
- 100 open/close cycles with a persistent runtime alive throughout, under ASan,
  asserting no leak and no growth.
- `jse_close` on A from inside a host callback running in A — already refused;
  assert it is still refused with B open.

### 6. Regression net for the phases that ship alone

Phases 1–3 have no multi-runtime story, so they need their own gates:

- Phase 1: GC_STRESS + ASan over `Heap.destroy`/`Heap.reset` cycles; a
  shape-heavy teardown that exercises `shape_free` with `release_keys` both
  ways.
- Phase 2: `arr.length = n` truncation; symbol uniqueness across 10k symbols.
- Phase 3: the astral-character and embedded-NUL string round trips.

### 7. Benchmark protocol

Not a correctness test but a required gate, and the protocol is non-obvious:

- **Interleave A/B/A**, never run sequentially. Prototype C's sequential runs
  produced a false regression that interleaving erased.
- **Include a duplicate of the baseline as a fifth binary.** The baseline
  measured itself 3.8–5.8% slower than itself. Without this control, any
  reported delta is uninterpretable.
- **Do not report sub-3% deltas on `bench_loop`.** It touches no properties;
  its entire body is one 14.6k-instruction function, and small deltas are code
  alignment. Diff the mnemonic histogram before believing anything there.

---

## Sequencing against in-flight work

Three fixes are in flight in separate worktrees, touching `hobject.c3`,
`heap.c3`, `vm_property.c3`, `capi.c3` and the compiler. **All three prototypes
were built on `f89fffd7`; main is `b6f5bf9e`, nine commits ahead.** Every
measurement above was taken against a base that no longer exists.

| In-flight work | Status | Interaction | Order |
|---|---|---|---|
| **Shape-id widening** | **already landed** — `aa96e119`, `uint shape_id` at `hobject.c3:726` | None. Measured: layout stays 80 bytes with `uint shape_id`, so it neither helps nor hurts the (rejected) back-pointer option. | Done. |
| **capi slot registry** | **landed** — `97be88a2` (no 1024 cap, generation retirement), `8969e373` (retire at generation max) | **Helps.** Generation-checked handles are what makes cross-runtime handle misuse detectable rather than corrupting. Phase 5's nonce seeding builds directly on it. | Done; Phase 5 depends on it. |
| **Compiler register allocation** | in flight | Touches `src/compiler/`. This plan touches the compiler **only** in the deferred Group-3 item, which is explicitly out of scope. | No conflict. Keep it that way. |

**Measured conflicts on cherry-pick to main:** prototype A conflicts on
`src/heap.c3` (1 hunk) and `src/hobject.c3` (1 hunk); prototype B on
`src/heap.c3` (1) and `src/hobject.c3` (2). Real but modest.

**Ordering rules:**

1. **Re-count `_active_heap` before starting.** It moved from 88 to 92 reads
   over nine commits. Do not implement against this document's table.
2. **Phase 1 lands first, on current main**, and is the only phase that should
   be attempted while other agents hold `hobject.c3`/`heap.c3`. Coordinate — its
   diff is small enough to rebase cheaply.
3. **Phase 4 must not run concurrently with any other `hobject.c3` work.** A
   1,100-call-site conversion cannot be rebased across a live editor of the same
   file. It needs an exclusive window on `hobject.c3`, `env.c3`, `heap.c3` and
   `vm_execute.c3`.
4. **Phase 5 must be sequenced against `capi.c3` work**, which has been
   modified three times in the last nine commits. It is a small phase; take a
   window rather than rebasing.
5. `src/vm/vm_execute_threaded.c3` has **uncommitted user changes**. No phase
   touches it. Verify that stays true.

---

## Risks

Ordered by expected pain.

**1. C3's trailing default arguments void the compile-error safety net.**
The central claim of the explicit-parameter approach — "delete the global and
every missed site is a compile error" — is **false for any function with a
trailing default**, and three such functions sit on the converted path. It
produced a silent double-free in prototype A, caught only by 47 failing tests
with a bare SIGABRT. Mitigation: audit and make explicit **before** inserting
any parameter; do not script the mechanical portion; and prefer inserting new
parameters *after* existing defaults where the language permits, or promote the
defaults to required.

**2. `native_frame_depth` is per-heap, and nested runtimes break the
assumption.** `heap.c3:3034` and `:3112` suppress reclamation while a native
frame is live. With A's callback on the stack calling into B, **B's depth is
zero**. Whether B may collect while A's C frame is live has never been
exercised. Test 4 above targets it specifically; it is the thing in this plan I
am least sure about, and it should be traced before Phase 6 rather than
discovered by it.

**3. `g_rt` is a bigger dependency than the guard.** Eight exported entry
points read it, including three with a *documented, tested* `NULL`-runtime
fallback. Deleting the guard without Phase 5 produces host functions that break
the instant a second runtime opens, and stay broken after it closes. This is the
failure mode most likely to be shipped by someone who reads only the problem
statement.

**4. The scale is the risk.** 1,122 call sites, 44–50 files, +1380/−1323.
It cannot be reviewed line by line and it cannot be bisected within itself.
Mitigation is the phasing: Phases 1–3 and 5 are small and independently
bisectable; Phase 4 is the one big diff and it lands with the guard still up, so
a regression there is a single-runtime regression with the full existing suite
as its net.

**5. The measurements were taken against a dead base.** Every number in this
plan comes from `f89fffd7`, nine commits behind. Re-measure before drawing any
conclusion, with the baseline-duplicate noise control.

**6. `ds.vm.heap` at 168 sites in the hottest code.** A two-hop chain in the
dispatch loop. It will read as noise and someone will "optimise" it. Hoist
`Heap* h = ds.vm.heap;` once per handler and comment it, following QuickJS's
`JSRuntime *rt = ctx->rt;` idiom.

**7. Cross-runtime value passing is undefined behaviour that looks like it
works.** A handle from A used against B usually returns `JSE_ERR_INVALID` today
by accident of the generation design. "Usually" is not a contract. The nonce
seeding makes it near-certain; document the rule regardless.

**8. Thread-affinity is not addressed and will be assumed.** This change buys
multiple runtimes, not thread-safety. Duktape documents the same limitation
explicitly. If `jse.h` says only "multiple runtimes supported", someone will run
two on two threads and hit the *other* latent bug — which prototype C's demo
already caught in today's code (`thread1 heap=… active=… match=NO`).

---

## Decisions

All five questions that once needed a call from the user are settled; each entry
records what was decided and why, so the reasoning survives the decision.

**1. `NOSHAPECACHE`: resolved, no decision needed.** Earlier drafts asked
whether the flag had to survive, because keeping it raises the signature closure
from 60 to 94 (36% of the total cost) via `get_shape` sitting under
`find_prop_idx`. The question is moot: the *cache* goes, not just the flag. It
measures no faster than resolving `heap.shapes[shape_id]`, so there is nothing
to preserve and nothing to configure. Folded into Phase 4; the closure stays at
60. See that phase for the measurements.

**2. The `NULL`-runtime reader fallback: resolved, no decision needed.** This
code is unreleased, so compatibility is not a constraint and the question is
simply what makes the best embedding API.

`jse_get_number`/`jse_get_bool`/`jse_get_string` take a runtime and accept
`NULL`, falling back to `g_rt`. That exists because a host function receives a
`jse_call_ctx` and no runtime, so without it every callback reading its own
arguments would have to thread one in. `examples/c99/host_fn.c:82` and
`test/capi/host_fn_abi.c:38` both rely on it.

It cannot survive two runtimes. A global slot handle is an index into *some*
runtime's registry, so `NULL` stops having an answer. The failure is not a crash:
runtime A's handle resolves against runtime B's registry and returns B's value at
that slot, which is the same silent-wrong-answer class as the handle ABA bug
fixed in `f89fffd7`.

**The fix is to make the reader take a context, not a runtime.** QuickJS is the
model: a `JSCFunction` receives `JSContext *ctx` as its first parameter and hands
it to everything downstream (`quickjs.h:347`), with `JS_GetRuntime(ctx)` for the
lower tier (`quickjs.h:391`). No call in that API is ambiguous about which
instance it addresses.

Our context is already self-sufficient: `BuiltinContext` carries `Heap* heap`
(`builtins/core.c3:152`), and Phase 5 adds `runtime_ptr` to `Heap`. So a host can
already answer "which runtime" from the ctx it holds; the readers just do not
accept one.

Adopt an explicit two-tier reader API, which is what both reference engines
converged on:

| Tier | Signature | For |
|---|---|---|
| context | `jse_ctx_get_number(jse_call_ctx, jse_value, double*)` | inside a host function |
| runtime | `jse_get_number(jse_runtime, jse_value, double*)` | outside one |

`NULL` is then rejected with `JSE_ERR_INVALID` in the runtime tier, because a
host that has no runtime should be using the context tier. Nothing is
ambiguous and nothing is silently wrong.

The alternative of adding `jse_ctx_runtime(ctx)` and keeping one reader tier
also works and is a smaller diff, but it makes every host-side read a
two-call dance (`jse_get_number(jse_ctx_runtime(ctx), ...)`) where the reference
engines need one. Prefer the two-tier form; add `jse_ctx_runtime` anyway, since
a host that wants to persist a value or open a nested eval genuinely needs the
runtime handle.

Sequencing: land with Phase 5, which is where `capi.c3` becomes per-runtime.
Phase 7 updates `examples/c99/host_fn.c`, `test/capi/host_fn_abi.c` and the six
bindings, none of which are released.

**3. Thread-safety: explicitly out of scope, and the per-thread story is
already covered.** The engine contains no threading of its own: no atomics, no
locks, refcounts are plain increments, and the GC, shape table, string intern
table and free lists are all mutated unsynchronised. Two threads inside one heap
corrupt it, and that is unchanged by how many heaps exist. Making it safe would
mean atomic refcounts, a GC able to stop other threads, and locking the intern
and shape tables: a different engine, and one both reference engines decline.
Duktape states both halves in the same breath, no global state *and* "only one
native thread can execute any code within a single heap at any time".

What this plan does buy, at no extra cost, is **one runtime per thread**. That
falls out of deleting `_active_heap` rather than needing prototype C's `tlocal`
on top: once no state is shared between heaps, two threads each driving their
own runtime share nothing. `tlocal` was only ever a way to make the *global*
per-thread, and there is no global left to scope. It should not be added.

**The decision that remains is narrower than "is thread-safety in scope".**
`g_rt` is a plain global today (`capi.c3:120`), so `jse_open`'s guard is
process-wide: a second runtime is refused even on another thread. Phase 5
deletes `g_rt` and Phase 6 deletes the guard, after which nothing prevents two
threads from opening two runtimes, which is correct, or from driving one runtime
from two threads, which is not. Options:

- **(a) Document the rule and enforce nothing**, as QuickJS and Duktape do.
  Cheapest, and consistent with the reference engines.
- **(b) Record the owning thread on `Heap` at `jse_open` and reject entry from
  another**, turning a corruption into a clean `JSE_ERR_INVALID`. A few lines at
  the ABI boundary, and it fits this project's stated preference for converting
  silent corruption into reported errors. It does prevent a runtime from
  legitimately migrating threads, so it would need an explicit handoff call.

**Decided: (a).** Thread-safety is out of scope. Document that a runtime must
be driven from one thread at a time and enforce nothing, as QuickJS and Duktape
do. (b) stays available later if a real embedder trips over it, but it does not
gate the guard lift and `tlocal` is not to be added.

**4. Ship the post-Phase-4 intermediate state: yes, decided.** At that point
`_active_heap` is gone, the engine is structurally multi-runtime-capable, the
guard is still up, and behaviour is identical to today. Land it as soon as it is
green rather than holding it until Phase 6.

Three reasons. The Phase 4 diff is the whole risk of this project (44 files,
~1,122 call sites, and the default-argument trap that already produced a silent
double free), and landing it behind the guard means a defect surfaces as an
ordinary failure on the existing suite instead of as a new-feature bug. The
refactor has value even if multi-runtime never lands, because the process-global
is an active cross-thread hazard today. And a diff this wide rots: `hobject.c3`
and `heap.c3` are under active change, so an unmerged conversion will conflict
more the longer it waits.

The cost is that "structurally capable but guarded" is verifiable only by
inspection, since the multi-runtime tests cannot run until Phase 6. Its
correctness rests on the existing suite plus the fact that deleting
`_active_heap` turns every missed site into a compile error. That is a real
limitation, not a formality, and it is the reason Phase 4's verification step
demands GC_STRESS and ASan rather than the local suite alone.

**5. How many runtimes: as many as memory allows, measured.** Nothing in the
design caps the count, and the prototype confirms it. Opening N runtimes and
evaluating an independent script in each, on branch `proto/explicit-threading`:

| Runtimes | Peak RSS | Correct |
|---|---|---|
| 1 | 3.2 MB | 1/1 |
| 50 | 21.4 MB | 50/50 |
| 200 | 76.4 MB | 200/200 |
| 2000 | 737 MB | 2000/2000 |

**~370 KB per runtime**, linear, with every runtime independently usable and all
of them closing cleanly. No ceiling was reached.

That per-runtime floor is the number to watch if the target is many small
sandboxes: it is dominated by the builtin object graph each heap constructs at
`create`, not by anything this plan introduces. Shrinking it (lazy builtin
realisation, or sharing immutable prototype objects across heaps) is a separate
change and should not be attached to this one. Sharing anything across heaps in
particular would reintroduce exactly the cross-heap coupling being removed here,
so it needs its own design.

---

## Sizing

**This is a large piece of work.** Stating it plainly:

| Phase | Size | Risk | Ships alone |
|---|---|---|---|
| 1 — overloaded parameters | ~2 files, ~60 lines | **high** (teardown paths, both prototypes segfaulted here) | yes |
| 2 — cached keys + symbol counter | 4 files + `put_prop`'s 224 callers | medium | yes |
| 3 — `write_cesu8_as_utf8` udata | 2–3 files, ~40 lines | low | yes |
| 4 — thread `Heap*` | **44 files, ~1,122 call sites, +1380/−1323** | high (scale, default-arg trap) | yes |
| 5 — per-runtime `capi.c3` | 2 files, ~80 lines | medium | yes |
| 6 — lift the guards | 4 files, ~30 lines | **highest** (makes everything reachable) | after 4+5 |
| 7 — bindings | 6 surfaces, docs + examples | low | yes, per binding |

Phase 4 alone is a multi-day change that cannot be delegated to a script and
cannot be reviewed line by line. The other six phases together are roughly one
phase-4-sized effort spread over small, independently bisectable pieces.

The payoff is proportionate: it is the last structural gap between this engine
and QuickJS/Duktape on a property both advertise as headline, and it is measured
at **0.02% on property paths against a 0.56% noise floor** and **+0.79% binary
size**. It costs no performance. It costs a lot of editing.

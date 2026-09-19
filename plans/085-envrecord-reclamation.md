# 085 — EnvRecord reclamation

Status: DONE. Source audit: 2026-09-19, based on `48e3db4f`.

Landed in six commits (pool accounting, typed pool cells, epoch tracing and
roots, weak variable caches, the pool sweep, and this write-up). The reclamation
oracle `out/env_pool_stats test/env_retention_baseline.js` shows a 100k-capture
loop holding 3 live cells in 3 blocks (6.1 KB reserved) instead of 100k cells
across 1563 blocks (3.2 MB). Deferred work from §13 — trimming unused captured
bindings, reducing unnecessary parent capture, pool compaction, and page-local
marking — remains open and out of scope for this plan.

## 1. Decision and scope

Make `EnvRecord` a non-moving, traced pool cell. Collect it in the existing full GC, trace its parent and bindings, and return fully empty pool blocks to the heap allocator. Keep reference counting on the edges that already own counts. Do not add environment reference counts or decref bindings when recycling an environment.

This closes a concrete retention path: ordinary scope exit drops pointers, but the environment pool does not reclaim those records until heap reset or destruction. Avoiding environments for functions that do not need them reduces allocation; functions with captured locals, direct eval, lexical scopes, and `with` still need reclamation.

The change includes the root inventory, internal environment references in registers, variable-cache invalidation, allocation failure handling, and diagnostics needed to prove reclamation safe. It does not depend on the collector optimizations proposed in [082](082-gc-pause-reduction.md). Recent research and the reasons for choosing this design are in [the companion research note](085a-gc-research-2025-2026.md).

Success means that repeated work with a bounded live scope graph has bounded environment storage after quiescent collections, while closures, suspended execution, and modules retain all environments they need. The collector can still retain ancestors of a live scope, unused bindings within a live scope, and partially occupied blocks. Those are distinct optimizations.

## 2. Current code and failure mechanism

| Location | Relevant behavior |
|---|---|
| `src/env.c3` | Allocates 64 records per block. Free cells use `parent` as a freelist link. Normal execution never returns completed scopes to this list. |
| `src/heap.c3`: `mark_env_chain` | Marks bindings along a parent chain, but has no environment liveness state or visited test. |
| `src/vm/vm_core.c3`: activation marking | Traces environments for active and shadow activations; has a separate scope-chain walk. |
| `src/heap.c3`: generator marking | Traces saved scope chains and saved registers. |
| `src/hobject.c3`: `VarICEntry` | Stores raw environment addresses in `env` and `search_head`. Shape recycling guards do not guard environment reuse. |
| `src/heap.c3`: compiled-function marking | Treats variable-cache bindings as strong roots. A cache can retain a bindings object containing a closure that retains the environment. |
| `src/vm/vm_execute.c3` | `RESOLVEVAR` and the environment arm of `WITHBASE` store environment addresses using the generic pointer TVal tag. Ordinary TVal tracing cannot distinguish these from opaque pointers. |
| `src/env.c3`: `env_destroy` | Frees a whole parent chain. Its initialization-failure use does not make it suitable for runtime scope exit: parents can be shared. |

The pool allocator also returns a successful null pointer on raw allocation failure. Its optional result must instead carry an allocation fault, so constructors cannot treat null as a valid cell.

Do not use bindings-object liveness to infer environment liveness. A bindings object can outlive its record through a module getter or a `with` object, while an environment can be live only through a saved reference. The collector needs explicit directed edges.

## 3. Lifetime and ownership contract

There are two independent questions: which graph edges retain a value for tracing, and which assignments own a reference count.

| Edge | Traced | RC operation introduced by this plan |
|---|---|---|
| Environment → parent | Yes | None |
| Environment → bindings object | Yes | None |
| Closure/activation/generator/module → environment | Yes | None |
| Internal `ENVREF` TVal → environment | Yes | None |
| Scoped native environment root → environment | Yes | None |
| Variable cache → environment/bindings | Weak | None |
| Variable cache → interned key | Existing strong/key ownership | Balanced release on cache clear |
| Bindings property → JS value | Existing object-property tracing | Existing property ownership rules |

Environment pointers never go through `HeapHeader.incref`, `Heap.decref`, or `is_heap_allocated`. There is no environment destructor that releases its outgoing graph edges. Object teardown remains responsible for the counted fields inside bindings objects.

`alloc_object` initializes an object count to one. Ordinary environment constructors keep their existing bindings allocation lifetime; this plan does not add or release that initial count. `with` wraps an existing object and keeps its existing ownership convention. A tracing pin does not protect against an incorrect decref outside sweep. Audit assignments that expose/replace bindings, and test an escaping `with` closure after all ordinary holders of its object disappear. Fix any unbalanced object ownership at that assignment, rather than adding an unexplained count to every environment.

During object sweep, the existing `decref` rule preserves marked objects even when dying counted holders release their last count. Keep this rule. After object sweep, an unreachable environment's bindings pointer may already point to freed memory; recycling the cell must only clear bytes and link the free cell, without dereferencing either outgoing pointer.

For a cycle `env → bindings → closure → env`, a root traces the complete cycle. With no root, the object collector tears down bindings and closure, and the environment sweep recycles the cell. No trial deletion or per-edge environment bookkeeping is required.

## 4. Cell and block representation

Use a C3 byte-sized bitstruct for semantic flags plus GC state:

```c3
bitstruct EnvFlags : char {
    bool is_declarative    : 0;
    bool is_function_scope : 1;
    bool is_with           : 2;
    bool is_catch          : 3;
    bool allocated         : 4;
    bool mark_epoch        : 5;
    bool temproot          : 6;
}

struct EnvRecord {
    EnvRecord* parent;
    HObject* bindings;
    EnvFlags flags;
    Heap* heap;
}

struct EnvPoolBlock {
    EnvPoolBlock* next;
    EnvRecord[ENV_POOL_BLOCK_SIZE] cells;
}
```

Update semantic flag accesses explicitly. The in-tree [layout probe](../test/env_layout.c3), compiled with C3 0.8.3 on macOS arm64 in both default and `NONANBOX` builds, gives 32 bytes for both the current and proposed record, alignment 8, and 2056 bytes for the proposed 64-cell block. The heap pointer starts at byte 24 in both record forms; the one-byte flags occupy byte 16, followed by seven padding bytes. The `NONANBOX` TVal remains 16 bytes with alignment 8 and uses the existing union pointer field. These figures are host measurements, not cross-platform assumptions. Add layout checks for supported target builds; `NONANBOX` must not accidentally alter environment layout.

Keep heap pool pointers opaque where required by the module dependency boundary. The first block field remains `next`; replace reset/destroy's raw block walk with the shared pool teardown helper so layout knowledge lives in one module.

A free cell has `allocated=false`; only its freelist link is meaningful. An allocated cell has a valid heap pointer, a null or allocated parent in the same heap, and null bindings only during construction. No record moves. No block backpointer, cell generation counter, or full `HeapHeader` is needed.

Use C3 fixed arrays, bitstructs, `mem::clear`, and `defer`; allocate/free blocks through `heap.alloc_func` and `heap.free_func` with `heap_udata`. The stdlib arena and generic collection allocators do not express the required individual cell lifetime or embedding allocator contract.

Reproduce the measurements against the actual runtime types:

```sh
c3c build env_layout
./out/env_layout
c3c -D NONANBOX build env_layout
./out/env_layout
```

The probe compares sizes, alignments, and heap/payload offsets with proposed layouts. Run it for each supported target; a target-specific padding difference must be measured before choosing that target's final representation.

## 5. Environment marking and construction

Add a one-bit `env_mark_epoch` to `Heap`. Flip it once at the beginning of each accepted full collection, after the `gc_running` guard. This is an environment-local epoch; object marks retain their current implementation.

An allocated record is marked iff its epoch equals the heap epoch. Every cell that survives a completed collection must have the current epoch. There is no path that keeps an unmarked cell merely because native code is active: native temporary roots are traced. This invariant makes a one-bit epoch safe across arbitrarily many collections.

`mark_env_chain` becomes an iterative first-visit walk:

```text
while env != null:
    verify allocated and owned by this heap
    if env.epoch == heap.epoch: stop
    env.epoch = heap.epoch
    account one environment visit
    mark_hobject(env.bindings) if non-null
    env = env.parent
```

`mark_hobject` enqueues object work; it must not recursively traverse the object graph here. The existing gray worklist completes mixed object/environment cycles. Shared chains are visited once per collection, rather than once per closure. No C-stack recursion is added.

Extend the existing opaque helpers in `hobject.c3` with narrow wrappers for environment first-visit/parent/bindings access and pool seed/sweep/destroy operations implemented in `env.c3`. Keep `heap.c3` independent of the concrete environment layout. Do not introduce a callback per visited cell or a general collector plugin interface.

Allocation sequence:

1. Obtain and clear a free cell. This operation only schedules GC; it does not collect synchronously.
2. Set `allocated`, `temproot`, heap, parent, and semantic flags. Initialize its epoch to the current heap epoch. Set bindings null until ready.
3. Allocate bindings where needed. An allocation-failure collection sees the new cell through its pin and can trace its initialized parent.
4. Store bindings and return the record. The caller publishes it in an activation, closure, module, or explicit root before reaching a quiescent safepoint.

At collection start, reset all object/string marks before tracing any environment pin. When `safepoint && native_frame_depth == 0`, clear environment pins. Otherwise, trace every pinned allocated cell and its outgoing graph. Follow the existing `gc_quiescent_pending` rule so a callback collection is followed by a collection that can expire native pins after the outermost native return.

Constructor failure returns only its unpublished cell to the freelist, with no parent walk. Replace `env_destroy`'s initialization-failure use with explicit unpublished cleanup or whole-heap teardown. A published cell can become reusable only during environment sweep, after cache pruning.

For raw block allocation failure, return `ALLOC_ERROR` through the optional. If adding a retry via the existing nonquiescent GC entry, first scope-root the supplied parent and protect a supplied `with` bindings object using the existing object-root mechanism; retry once. No GC may run between popping a cell and publishing its construction state. Fault injection must cover both paths.

## 6. Complete root and edge inventory

| Holder | Required tracing and audit |
|---|---|
| `Vm.global_env`, `Vm.global_lex_env` | Mark records even with no active activation. Registered bindings roots alone are insufficient. Cover initialization before the VM root hook is installed. |
| Active `Activation.var_env/lex_env` | Call the centralized environment tracer. |
| `ShadowActFrame` saved activations | Trace the same fields while native re-entry replaces the active VM stack. |
| Ordinary function/thread closure fields | Trace var/lex environments through existing class dispatch. Preserve bound-function dispatch. |
| Generator objects and `GeneratorState` | Trace var/lex scopes and saved TVal registers. Include suspended, running, completed-but-referenced, and error paths. |
| Async state objects | Preserve `is_async_state` discrimination: the field named `var_env` can hold `GeneratorState*`, not `EnvRecord*`. |
| Catcher chains | Mark `Catcher.saved_lex_env` as well as thrown/return values, both in active frames and saved generator states. |
| `ModuleDef.env` | Mark for every cached module status, including instantiated/unevaluated, errored, and synthetic modules. Namespace/value marking does not substitute for this edge. |
| Register snapshots | Recognize `ENVREF` in the common TVal marker, including generator save/restore and native shadow frames. |
| Native C3 locals | Add explicit scoped roots where a saved environment is absent from all the above holders across a GC-capable call. |

Module live-binding getter hidden slots hold a bindings object and a key; trace those existing object edges without inventing a reverse bindings-to-environment edge. Mapped arguments retain their existing activation/freeze behavior; test them without adding a fictitious environment owner.

For native roots, add an allocation-free intrusive stack:

```text
EnvRoot { previous: EnvRoot*, env: opaque EnvRecord* }
Heap.env_roots: EnvRoot*
push_env_root(root, env); defer pop_env_root(root)
```

The root stores a pointer value. If the protected local changes, update `root.env` before another GC-capable operation. Assert LIFO removal in verification builds. Trace this stack on every collection. This avoids ambiguous aliasing through a `void**` cast and avoids heap allocation while constructing roots.

Audit direct eval's saved var/lex scopes, call/construct scope setup, named function expression environments, private-field setup, getters/setters, proxy and `@@unscopables` callbacks, module construction, and any environment traversal local held across a user call. Fresh-cell pins do not protect arbitrary older detached scopes. Ordinary scope pops and returns remove roots; they do not free records.

## 7. Internal environment references in TVal registers

Introduce a dedicated internal `ENVREF` tag in both NaN-boxed and `NONANBOX` representations. `0xFFFB` is available in the current NaN tag table; verify the table when implementing. Append `ENVREF` after `DELETED` in the shared `enum TValTag : char`; it has ordinal 12 and leaves existing ordinals unchanged. Map `TAG_ENVREF = 0xFFFB` to `TValTag.ENVREF` in the NaN-box `get_tag` switch. The setter uses the existing union payload in the `$else` branch:

```c3
$if USE_NANBOX:
    self.bits = nanbox_encode_tagged(TAG_ENVREF, (usz)ptr);
$else
    self.tag = TValTag.ENVREF;
    self.pointer = ptr;
$endif
```

No union member or discriminator width changes. Implement `is_envref` and the accessor with the same representation split; neither setter nor accessor performs RC operations. A null `ENVREF` represents an unresolved saved reference where the opcode protocol requires one.

Convert these producers and all paired consumers together:

- `RESOLVEVAR` fast/slow/null results; `THROW_UNRESOLVED` and `PUTVAR_SNAP` consumers.
- `WITHBASE` environment results; `WTWR` environment consumers. Its object-base result remains an object TVal.
- Equivalent handlers in alternate dispatch paths and compiler assumptions about the snapshot register.

Leave generic pointer values, including `ForInState*` and opaque host pointers, unchanged. `mark_tval(ENVREF)` calls `mark_env_chain`; `is_heap_allocated(ENVREF)` stays false. RC copies and releases therefore perform no header access.

Add a separate predicate for slots requiring tracing/cleanup: existing heap values **or** `ENVREF`. Use it in `track_heap_store`, `track_restored_regs`, register-watermark verification, and snapshot restoration. Do not broaden the RC predicate. The frame cleanup loop must clear an environment-reference slot even though its decref is a no-op. Otherwise register overscan can retain a stale address and later trace a different cell allocated at that address.

Clear consumed snapshot temporaries when the compiler/opcode protocol proves they will not be used again; preserve them across compound assignment and RHS calls until their last use. Cover exception unwinding and generator/async suspension, not only normal return. Trace valid saved references conservatively until cleanup rather than guessing their lifetime from the current lexical head.

Audit tag switches in coercion, comparison, debugging, serialization, and C API conversion. `ENVREF` is an internal reference, not a JS value; reject/assert any escape into public values or persisted bytecode constants. NaN normalization and payload decoding must retain their current behavior.

## 8. Variable caches: weak ownership and address reuse

Stop marking variable-cache bindings as strong roots. Keep existing key ownership. After roots and gray work reach a fixed point, prune variable caches before freeing any object or environment memory.

For a `VarICEntry* vie`, a surviving entry requires marked, allocated records at `vie.env` and `vie.search_head`, a marked object at `vie.bindings`, and `((EnvRecord*)vie.env).bindings == (HObject*)vie.bindings`. Treat incomplete populated entries as invalid and clear them. Empty entries remain empty. Test `vie.env` and `vie.search_head` liveness before dereferencing `vie.bindings`; bindings cached for a dead `vie.env` need not remain valid. Verification builds check pool membership before dereferencing environment pointers.

Clear **every field** of an invalid entry. Some readers guard on `bindings`/`search_head` rather than `env`, so clearing only `env` is insufficient. Provide one `var_ic_clear` helper: save the old key, clear the entry, then release exactly its owned key count. Preserve whole-heap teardown's rule about avoiding releases into already destroyed string storage.

Audit direct cache fills, especially `CALL_GLOBAL` in `vm_calls.c3`, which can populate entries without going through `var_ic_fill`. Route fills through a coherent helper contract; initialize `env`, `bindings`, shape/recycle guards, key ownership, `search_head`, and store permissions together. Make replacing a key with itself safe by retaining the new key before releasing the old one. Keep readers' semantic/shape guards and verify that chain-head changes invalidate the entry.

Restructure the compiled-function root loop so `constants == null` skips only the constant loop, not IC processing. Every compiled function's variable caches must participate in pruning even if it has no constant array.

**Critical invariant: weak variable-cache pruning completes before object sweep, and before any published environment cell can be recycled.** Pool-membership verification alone cannot detect an address that already belongs to a different allocated cell.

Why this prevents address reuse errors: records only become reusable at GC; caches referring to dying records are cleared before that point. Surviving records keep their addresses. No extra environment generation comparison is needed on every variable lookup.

Between collections, bindings lifetime still depends on correct existing object ownership. Audit every cache reader to ensure it establishes the matching current scope before dereferencing cached bindings; do not assume a weak cache owns the object. Add verification for binding lifetime and exercise external `with` objects. If a counted-owner bug is exposed, fix the owner/drop pair before enabling weak caches. A cache incref would conceal the bug and restore retention.

## 9. Collection order and pool sweep

Use this exact ordering:

1. Reject recursive GC; set `gc_running`; reset work counters and object/string marks; flip the environment epoch.
2. Scan environment cells to clear pins at a quiescent safepoint or seed their graph otherwise. Trace explicit native environment roots and all ordinary roots.
3. Drain gray work to completion. Verify marked environments and their outgoing edges.
4. Prune weak variable caches while object marks and environment marks are readable.
5. Run the existing object sweep phases: unlink dying headers, tear down object contents, free headers. Keep all environment cells allocated throughout object teardown.
6. Sweep environments using their epoch. Never inspect outgoing pointers of dead records here. Release empty blocks and rebuild the freelist.
7. Preserve existing string-sweep safety rules, reset allocation budgets, and finish the collection.

The object sweep clears surviving object marks at its end. Therefore weak-cache pruning and graph verification must run before it, not in the environment sweep.

Pool sweep walks all cells of each block. First classify/recycle dead cells and count survivors. Release a block with zero survivors unless it is the single retained empty spare. For each kept block, append its free cells to a newly built freelist. Never link cells into the new freelist and then free their block. Rebuild block links before releasing a block, using the saved next pointer.

Keep at most one empty spare block per heap to reduce churn. A partially occupied block stays allocated. Track occupied blocks separately from live cells so fragmentation is visible; one surviving cell per block is a legitimate worst case for a non-moving pool.

Host object teardown invokes a native finalizer callback. Do not assume callbacks are absent during sweep. Enforce and document a non-reentrant host finalizer contract for VM entry and GC allocation while `gc_running`/`tearing_down`, with a deterministic error/assert at the relevant entry points. Native payload cleanup remains allowed. If supported finalizer semantics require resurrection, defer those callbacks to a separately rooted queue before enabling reclamation; silent mutation during this mark/sweep transaction is invalid. Add a C API regression for the selected contract rather than relying on a comment.

Gray-stack allocation failure currently calls the fatal hook. Collection must never continue into sweeping after incomplete marking, even if a supplied fatal hook returns. Make the failure path terminate or abort the collection safely. With a one-bit epoch, retry after a partial mark needs a full allocated-cell epoch reset, or an explicit failed-cycle state; do not merely flip again and mistake old marks for a complete traversal. Prefer the established fatal policy with an enforced non-returning fallback for this implementation.

## 10. Allocation pressure and diagnostics

Track environment pressure explicitly, including allocations from the freelist and `with` environments that allocate no bindings object. A freelist hit still creates potential garbage.

Initial policy, to be benchmarked rather than advertised as optimal:

- Each environment allocation decrements an `env_alloc_budget`; expiry sets `gc_pending` only.
- At completed GC, reset it to `max(64, live_env_count, mark_work_last / GC_MARK_WORK_DIVISOR)`, using saturating arithmetic and the collector's existing work units. Under `GC_STRESS`, use one.
- Account each first-visited environment in mark work. Keep object allocation debt separate so environments are not accidentally charged twice merely because they create bindings objects.
- Either existing object debt or environment debt can request the same next safe collection. Environment debt is independent of unrelated live object counts, but includes full-heap tracing cost to avoid repeated expensive scans beside a large live container.

The floor is one pool block, not a claim about an ideal threshold. Measure it against the existing mixed workloads. The budget bounds allocation-driven floating garbage relative to the measured live workload; it does not impose an absolute byte ceiling. Long native calls can retain construction pins until quiescence, consistent with the existing object contract.

Expose aggregate debug/test statistics: allocated/live/free cells, reserved/occupied/empty block counts, reserved bytes, allocations, reclaimed cells, released blocks, peak reserved bytes, cells visited per GC, pin survivors, and collection requests caused by environment debt. Reset them consistently on heap reset. Keep timing and per-site attribution optional; do not add a release-build hash lookup per allocation.

Internal reserved bytes are the reclamation oracle. RSS is a secondary integration measurement: the platform allocator may keep returned blocks cached. Use allocator-callback accounting to prove bytes are returned to the embedding allocator, and report the distinction in benchmarks.

## 11. Implementation sequence

Each stage keeps the runtime runnable. Reclamation remains disabled until the root/cache work is complete.

1. **Instrumentation and failing retention fixtures.** Add pool counters, baseline workloads, and allocator accounting. Record cold/warm timing and peak/reserved memory for stateless callbacks, captured callbacks, lexical loops, and long-lived closures.
2. **Pool metadata and construction.** Introduce typed blocks, packed flags, epoch state, explicit construction pins, allocation faults, unpublished-cell cleanup, and reset/destroy helpers. Add pool unit tests; no runtime reclamation yet.
3. **Exact root graph.** Centralize scope marking; add VM globals, modules, catcher saved scopes, native scoped roots, and `ENVREF` with watermark cleanup. Run graph verification while retaining cells so missed roots can be diagnosed before reuse.
4. **Cache ownership.** Normalize fills/clears and prune weak entries. Test pointer reuse in a controlled harness; verify object RC contracts, including `with`. Establish finalizer and mark-OOM behavior.
5. **Enable environment sweep.** Run it after object teardown, rebuild the freelist, release empty blocks, and use environment pressure to schedule collections. Verify every live root and cache before/after reuse.
6. **Tune and document.** Compare throughput/mark work against the baseline, adjust only measured thresholds, update `docs/architecture.md`, pool comments, and this plan's status. Do not combine nursery, moving collection, lazy sweep, or capture-layout changes into this patch series.

Changes in stages 3–5 should land as a coherent series: sweeping with generic pointer snapshots or strong variable-cache cycles is incomplete.

## 12. Validation matrix

Use a focused C3 test harness for collector states that JS cannot request deterministically, plus JS fixtures under normal, stress, verifier/ASan, and `NONANBOX` builds. Test GC at both nonquiescent allocation points and quiescent safepoints.

| Case | Required result |
|---|---|
| **First gate: hot variable cache, `vie.env`/`vie.search_head` death, exact address reuse** | Inspect the complete entry immediately after pruning and before object teardown; all fields must be clear. Force reuse of the same environment address, then verify lookup/store resolves the new scope correctly. Cover death of either field separately, both together, and direct-fill paths; assert no object/environment free precedes pruning. |
| Millions of short-lived captured scopes; bounded callback batches | After a forced quiescent collection, live cells return to the baseline; spare storage is at most one empty block. |
| Escaping closure, sibling closures sharing a parent, deep chain | Correct values after repeated collections; each reachable environment visited once per cycle; no C-stack growth proportional to chain depth. |
| Environment/bindings/closure cycle | Live with an external root, reclaimed after its final root disappears. A populated variable cache must not retain it. |
| One survivor in every block, then drop all survivors | Partial blocks remain valid; all empty blocks except one return to the allocator; freelist contains only retained blocks. |
| Saved assignment reference across allocating RHS, proxy/getter, eval, yield, await | Correct destination and value; reference remains traced even after lexical-head changes. |
| High-register `ENVREF`, normal return, throw, generator completion | Watermark includes the slot; cleanup removes stale references before slot/cell reuse. |
| Catch/finally and suspended catcher chains | Restored lexical scope survives while held only by `saved_lex_env` in the controlled harness. |
| Modules, live exports, top-level await, cycles, instantiation/evaluation errors | Module environment survives with no executing activation. Use `test/modules/.../main.js` and `--module`. |
| Direct eval, sloppy `with`, `@@unscopables`, mapped arguments | Bindings semantics and object RC remain correct across nested native callbacks and dropped outer holders. |
| Constructor OOM before/after cell allocation | Fault propagates; parent/bindings remain valid; unpublished cell returns once; no successful null record. |
| More than two successive collections, including native pin windows | Epoch wraps safely; every retained cell has the completed cycle's mark. |
| Gray worklist OOM and finalizer re-entry | Deterministic failure policy; no sweep with incomplete marks or mutation during teardown. |
| Heap reset/destroy, repeated embedding heaps | All blocks freed exactly once; no scoped-root links into an expired native stack. |

Extend `HEAP_VERIFY` to validate that traced pointers are cell-aligned members of allocated blocks, that allocated cells have the right heap, that marked parents/bindings are live before object sweep, and that caches never reference cells about to be recycled. Debug membership scans may be slow; they must not become release-build lookup costs. Allocated bits detect free cells, while precise roots and cache invalidation prevent aliases to a newly allocated cell at the same address.

Rebuild binaries before trusting results. Run `just test-gc-stress`, `just test-local`, `just rosetta`, `just test-temproot-rss`, and `just test-nonanbox` on the new fixtures. Use `just build-test262-verify` and narrow canonical test262 runs for closures, generators, async functions, eval, `with`, catch/finally, and typed-array comparator callbacks. Re-run the original `staging/sm/Number/parseInt-01.js` and `staging/sm/Array/sort_small.js` repros. Do not use a full test262 sweep as the development loop.

Memory tests must use collector counters/allocator accounting rather than WeakRef or FinalizationRegistry behavior: this engine's weak-collection implementation is not an appropriate oracle for this change.

## 13. Performance and acceptance gates

Measure identical optimized binaries and workloads, with several repetitions and reported variance. Record wall time, total GC time, median/p95/p99/maximum GC pause, collections, total environment visits, total mark work, reserved environment bytes, allocator-returned bytes, and peak RSS. Keep sanitizer timing separate.

Acceptance requires:

- No missed-root, stale-cell, RC-to-zero, ASan, or semantic failure in the matrix.
- Environment allocation remains a freelist pop plus initialization/counters; parent walking occurs only in tracing or language lookup.
- Mark work on shared scope chains scales with distinct live cells and edges, not closures multiplied by chain depth.
- Repeated bounded-live workloads plateau in internal environment storage; completely dead blocks return to the configured allocator.
- Variable-cache fast paths gain no environment refcount or generation operations. Any changes to cache hit rate are measured on globals, captured-variable loops, eval-heavy code, and comparator callbacks.
- A repeatable throughput regression above 3% in the focused suite triggers investigation before merge; a threshold change needs both time and memory evidence. Treat this as a review gate, not a promised measurement.

Deferred work includes trimming unused captured bindings, reducing unnecessary parent capture, compiled-function lifetime, pool compaction, and page-local marking. Reclaiming records does not itself solve retention caused by a genuinely reachable broad scope graph.

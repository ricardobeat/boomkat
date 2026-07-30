# Engine architecture

A guide to how this JavaScript engine is put together: what the major pieces
are, how a value moves through them, and which invariants hold everything
together. It is written for someone reading or changing the code, so it favours
the parts that are hard to work out from a single file.

Sections are added as each area of the codebase is reviewed.

## Memory: the heap, the collector, and strings

Everything the engine allocates at runtime belongs to a `Heap`. One heap holds
the object graph, the string tables, the shape system, the module cache, and the
microtask queue, and it owns the allocator those all draw from. A VM is created
against a heap, and a heap can outlive one VM and host another, which is what
`Heap.reset()` exists for.

### The allocator layer

The heap never calls `malloc` directly. It holds four function pointers set at
creation time (`alloc_func`, `realloc_func`, `free_func`, `fatal_func`), each
taking an opaque `udata` pointer, so an embedder can supply its own allocator.
Passing null selects defaults that route through the C3 thread allocator.

This matters more than it looks. Anything allocated through the heap must be
released through the same heap, including during teardown. `gs_release()` takes
an explicit heap pointer for exactly this reason: teardown clears the active-heap
global but still has to free through the heap's own allocator, and releasing to
libc instead would be a cross-allocator free.

On top of that sit three `FixedBlockPool` allocators for HObject headers, one per
size class, which avoid a malloc per object:

| Pool  | Classes                                | Why |
|-------|----------------------------------------|-----|
| plain | `OBJECT`, `ARGUMENTS`                  | no `HObjectExtra` needed |
| array | `ARRAY`                                | `array_length` lives in the union |
| func  | everything else, including `ERROR` and `PROXY` | carries subtype fields |

`alloc_size_for_class()` in `hobject.c3` is the authority on which class goes
where.

### Two collectors, one heap

The engine reclaims memory two ways at once, and knowing which one owns a given
object is the key to reading the memory code.

**Reference counting** handles the common case. Every `HeapHeader` carries a
refcount; `decref()` frees the object when it hits zero, unlinking it from the
`heap_allocated` list on the way. Strings are purely refcounted and are never on
that list at all.

**Mark-and-sweep** exists to collect what refcounting cannot: cycles. An object
in a cycle keeps a non-zero refcount forever, so the tracing collector finds the
objects no root can reach and frees them regardless of count.

The two interact carefully. Objects freed by refcounting are already off the
list, so the sweep never sees them. Conversely, while `Heap.sweep()` runs, the
`sweeping` flag makes `decref()` skip references into unmarked nodes: a dying
object's teardown can reference a sibling that the same sweep is also collecting,
and touching its header would be a use-after-free.

Marking is tri-colour with an explicit gray stack rather than recursion, so a
deep object graph cannot overflow the C stack. `mark_roots()` seeds it, and
`drain_gray()` walks to the transitive closure.

### Roots

Reachability is only as good as the root set, and a surprising amount lives
outside the object graph:

- registered GC roots and every built-in prototype and intrinsic
- the VM value stack, scanned from `valstack_base` to the live top pointer
- the microtask queue, whose handler, argument, and downstream promise are held
  nowhere else until the job runs
- constant pools and inline-cache entries of every `CompiledFunction`, which live
  in their own tracking array rather than the GC heap
- the symbol registry, the built-in string cache, and the cached well-known
  symbols
- generator state, including the in-flight async-generator request
- `ModuleDef` entries, which sit in a malloc'd cache the sweep never scans

### Temproots and safepoints

A freshly allocated object is anchored only in a C3 local, where the mark phase
cannot see it. `alloc_object()` therefore sets a *temproot* flag, and a
collection that happens outside a safepoint keeps temproots set so in-flight
allocations survive.

Clearing them is safe only at a genuine safepoint with no native builtin frame on
the stack. A builtin that allocates a result and then re-enters the VM, to call a
user callback or a getter, holds that result in a raw local while the nested
execution reaches safepoints of its own. `native_frame_depth` tracks this and
vetoes both the temproot clear and the string sweeps.

The sweep itself runs in three phases so that no teardown can touch memory
another teardown already freed:

1. unlink every dying node onto a private list, freeing nothing
2. run each node's teardown while all of that memory is still valid
3. release the header memory

### Strings

String equality in this engine is pointer identity, which makes interning an
engine-wide invariant rather than an optimisation. Any path that produces an
`HString` which escapes without interning will silently break `indexOf`, strict
equality, and property-key lookup.

The string table is open-addressed with linear probing and tombstones, hashed
with FNV-1a seeded per heap. Taking a slot makes the table an owner: the string
is marked interned and increfed for the table's reference.

Strings longer than `MAX_INTERN_BYTES` (256) are deliberately *not* interned.
They are almost never property keys, and interning them piles dead strings into
the table until the next GC, which gives O(n^2) growth in loops like `s += chunk`.
Because such a string is in neither the string table nor `heap_allocated`, a
separate **large-string registry** tracks it so the collector and teardown can
still find it. Each string records its own slot index, so removal is an O(1) swap
with the last element.

That difference shapes how each is swept. An interned string can be freed when
only the table still holds it, but a refcount of 1 is not enough on its own,
because property tables and IC entries hold keys without taking a reference:
reachability decides. The registry holds no reference at all, so for large
strings reachability is the whole test, which makes that pass a backstop for a
refcount that was never decremented.

Both sweeps run only when `string_sweep_safe` is set, since a GC can trigger from
any allocation, including one made while an opcode holds a freshly interned
string that nothing roots yet.

Two caches sit alongside: pre-interned built-in strings, and `HString*` for the
integer keys 0 to 255. Both are *pinned*, so refcounting and sweep never free
them and incref and decref against them do nothing.

### Shapes and inline caches

Objects that gain properties in the same order share a hidden class, or *shape*.
A transition table maps `(parent_shape_id, key, flags)` to a child shape id, so
two objects taking the same path converge on one shape. The flags are part of the
key: every instance of a class installing the same private field can share a
shape, while the same key installed with different attributes needs its own.

Above that sits a megamorphic property cache mapping `(shape_id, key)` to a
resolved `(proto, prop_idx, value)`, shared across all call sites to skip
repeated prototype-chain walks. It is a lossy single-slot table, so a collision
simply evicts. It is allocated apart from the `Heap` struct to keep that struct
small.

One consequence worth knowing: `Heap.reset()` must clear this cache. Pool
allocators restart at the same addresses, so a stale entry can be hit by a new
object at a recycled address and return the wrong value.

### Generators and async state

A suspended generator's execution context lives in a `GeneratorState`: saved
registers, program counter, environments, catcher chain, and the resume protocol
values. It is not an `HObject`, so its lifetime is managed by a small refcount
maintained by `gs_acquire()` and `gs_release()`.

That count is the *only* ownership signal, and the reason is worth stating.
Several `HObject`s can hold the same state: the generator instance, plus every
async reaction closure that parks the pointer in its `var_env`. The sweep tears
all of them down in a single pass, so deciding ownership by reading a field of
the state would race the siblings in that same pass. Counting makes the last
teardown, in whatever order the sweep reaches them, the one that frees.

The GC has to know about two back-edges that run against the usual direction:

- **The generator instance.** Normally the instance marks its state. But an async
  generator driven only by its own machinery has no JS-visible reference left,
  since `g().next()` drops the instance immediately and the only remaining path
  is a reaction closure on the awaited promise. Without `gs.gen_obj` the instance
  is swept while its request queue is still being serviced.
- **The in-flight request.** Once dequeued, the request is no longer on the
  queue the mark phase walks, so `gs.ag_current_request` is its only root until
  it settles.

Async generators queue concurrent `next`, `return`, and `throw` calls as
`AsyncGenRequest` records, each with its own promise, drained FIFO. Whether a
value coming back from the body settles the current request depends on how the
body suspended, which the `AWAIT` and `YIELD` opcodes record in
`ag_suspend_kind`: a `yield` settles, while an internal `await` leaves the
promise alone for a microtask resume to re-drive.

### Microtasks

Promise reaction jobs are held in a flat queue of `(handler, argument,
downstream)` triples, drained after each top-level script and after
`vm_call_fn_impl` returns. The drain walks a read cursor forward rather than
snapshotting the count, so jobs enqueued by a running handler append past the
cursor and run in the same drain, which is the ordering the spec requires.
`microtask_count` has to keep counting the whole queue while this happens:
resetting it early would let new jobs overwrite the in-flight batch from slot 0
and hide queued entries from the collector.

### Tearing down and reusing a heap

`Heap.destroy()` releases everything and frees the heap struct.
`Heap.reset()` does the same work but keeps the struct and its backing arrays,
leaving it ready to host a fresh VM. Reset exists because repeated
create/destroy cycles fragment the allocator and grow RSS, which matters for
batch runs.

Both enter a *teardown mode* by clearing the active heap, which makes
`hobject_free()` skip its refcount loop. Teardown frees everything directly, and
mixing decref with the string table's tombstone deletion would corrupt the table
for the sweep that follows.

Reset has one extra obligation: it decrefs string and bigint values held by live
objects *before* entering teardown mode, since bigint boxes have no list of their
own to drain later. It then clears every pointer that could outlive the freed
memory, including cached symbols, the megamorphic cache, generator init state,
and the environment freelist, whose nodes hold bindings pointing into the heap
that was just released.

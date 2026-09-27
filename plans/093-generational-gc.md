# 093: Generational collection with sticky mark bits

## Goal

Cut the pause of a program that retains a large graph and churns short-lived
objects around it (renderers, VDOM, servers holding caches). After lazy
sweeping (c3c18245), the scene benchmark's worst frame is 22 ms at 100k
retained nodes and 43 ms at 300k, and nearly all of it is re-marking the
retained graph. A minor collection marks only what was allocated since the
last collection, so its cost follows the churn, not the heap.

## Model

Non-moving, two generations, promotion after one survival:

- **Young list** `young_allocated`: every new object, buffer and BigInt node.
- **Old list** `heap_allocated`: nodes that survived a promoting collection.
  Each carries the sticky `old` header bit, never cleared while the
  node lives.
- **Remembered set** `remembered`: old objects that may hold a pointer to a
  young node. The `remembered` header bit flags membership, so an object is
  pushed once per cycle.

A **minor** collection marks from the roots plus the remembered set, treating
every old node as already marked, so tracing stops at the old generation. It
sweeps the young list only: dead nodes are freed and survivors move to the old
list. It skips the string sweeps and the env pool sweep; their garbage waits
for the next major.

A **major** collection is today's collector: it marks everything, sweeps the
young list eagerly and the old list lazily, and sweeps strings and the env
pool.

### Promotion only at quiescent collections

A node allocated in native code is a temproot until the next quiescent
safepoint, and its native owner may still be filling in its fields. If a
collection promoted such a node, a later field store would create an
old-to-young edge with no barrier behind it, since the store site
treats the node as fresh. Only collections that drop temproots promote. The
others free dead young nodes and clear the survivors' marks, leaving them
young, and keep the remembered set intact.

This rule is what lets initialisation stores go unbarriered: a node is young
from allocation until at least the next quiescent safepoint, and no
initialisation sequence spans one.

## Write barrier

```
if (owner.gc.old && !owner.gc.remembered && v.is_traced()) remember(owner)
```

Object granularity: the barrier records the owner, never the slot, so a minor
collection re-traces the whole owner. It is a flag test on the owner's header
in the common case.

Stores that need it are stores into an object that may already be old:

- property and element slots (`prop_values()`, `array_part()`), which also
  covers every variable, since an `EnvRecord` keeps its values in a
  `bindings` object
- `[[SetPrototypeOf]]` on an existing object
- the internal fields mutated after construction: promise result and reaction
  list, generator and async state saved at suspension, ArrayBuffer view list,
  iterator state, Map/Set storage, and anything else the verifier finds

`EnvRecord.bindings` and `parent` are written only while the record is being
built, so env records need no barrier of their own.

Host objects hand their payload to an embedder mark callback the engine cannot
see into. An old host object with a `gc_mark` callback stays in the remembered
set for its lifetime. Promotion calls `remember_promoted_host`; major sweeps
retain surviving callback instances in the set.

`GeneratorState` has an intrusive heap registry. `alloc_generator_state` adds
each state and `free_generator_state` removes it. A minor collection scans every
registered state's saved values because an old generator or reaction closure
can hold young values there without an HObject field write. A full collection
reaches states through their owning HObjects; tracing the entire registry as
a full-collection root would keep generator instances alive.

## Enforcement

Two layers, because the type system cannot see every store:

1. **Types.** `PropValue` is a distinct `TVal` type, and
   `array_part()` returns `PropValue*`. Reads use `get()`;
   `slot = v` does not compile, so every raw slot store has to go through
   `Heap.store_slot(owner, slot, v)`. What the type misses: `TVal` mutator
   methods called on a slot, and a `&slot` passed on as a `TVal*`.
   Internal HObject fields use `Heap.@set_edge(owner, #field, value)`, which
   selects the TVal or pointer barrier from the value type. Initialisation
   stores on young objects do not need a barrier. A prototype chosen after an
   observable getter or generator parameter evaluation uses `set_prototype`,
   since that call can reach a safepoint before the store.
2. **Verifier.** `$feat(GC_VERIFY)` runs a full mark before each minor
   collection, tracking the owner of every edge `drain_gray` follows. An edge
   from an old, unremembered owner to a young node, including through an
   owner's env chain, is a missing barrier; the verifier reports the owner's
   class and aborts. The check reuses the marker's own edge walk, so it
   cannot drift from what the collector traces. test262 under this build is
   the audit.

## Scheduling

- Minor collections run on the existing allocation trigger.
- A major collection runs when the old generation has grown by
  `GC_MAJOR_GROWTH` over its size after the last major, on allocation failure,
  and on explicit requests.
- A pending lazy sweep finishes before any collection starts.

## Barrier baseline

Before promotion is enabled, 25 interleaved pairs against the pre-barrier
binary on macOS give these median wall times:

| Benchmark | Baseline | Barrier build | Change |
| --- | ---: | ---: | ---: |
| Object properties | 76.9 ms | 76.5 ms | -0.5% |
| Arrays | 15.3 ms | 15.1 ms | -1.9% |
| Property lookup | 49.5 ms | 49.2 ms | -0.5% |
| Loop | 42.3 ms | 43.3 ms | +2.3% |

`scripts/bench_interleaved.py` preserves the raw pairs. These runs measure
barrier plumbing with every node still young; system load can move such short
wall-time measurements by a few percent.

## Steps

1. Header bits, typed slots and barrier calls at every store. Nothing is old
   yet, so this changes no behaviour.
2. The GC_VERIFY verifier.
3. Young list, minor collections, promotion and the major policy. Run test262
   under GC_VERIFY and GC_STRESS.
4. Benchmarks: scene churn at 10k/100k/300k, plus the microbenchmarks for
   barrier overhead.

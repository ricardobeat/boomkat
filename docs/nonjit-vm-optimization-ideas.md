# Non-JIT VM optimization ideas

This note targets portable bytecode and native C3 helpers. It does not propose
machine-code generation. Every gain below is an **estimated target**, unless it
is explicitly measured; the estimates describe work removed from a specific
regime and still need benchmarks.

The ES6 review measured Boomkat/QuickJS ratios of 7.0× for `forof`, 5.1× for
destructuring, 4.5× for `spread_rest`, and 8.4× for templates. Boomkat already
has direct threaded dispatch, `th_add` fast-int handling, `ADDI`/`SUBI` fusion,
`GETPROPC_CACHED`, `ITER_NEXT_FAST`, property/variable ICs, and fixed-block
pools. Another generic `ADD_FASTINT` or property cache is therefore not a
credible 10× proposal.

## Candidates with a plausible 10× regime

### Dense-array bulk iteration

**Target:** dense arrays with the intrinsic array iterator in `for-of`, array
spread, destructuring, and spread/rest argument setup.

**Mechanism:** guard the array shape, iterator/prototype versions, density, and
absence of observable indexed accessors. Copy dense `TVal` elements directly
into the destination array or argument registers. Return the generic iterator
path on a hole, mutation, replaced `Symbol.iterator`, or any failed guard. The
internal helper should return `(value, done)` separately, as QuickJS does, so
the fast path does not construct an iterator-result object for every element.

`ITER_NEXT_FAST` covers some array/arguments cases, but the bytecode has
separate `ARRSPRD` and `SPREAD_ARG` paths and the review still finds spread
slow. This is a coverage gap, not a claim that all iteration is generic.

**Work model:** a generic element may perform iterator dispatch, a call,
result-object allocation, `done`/`value` property reads, and several refcount
operations. The guarded path performs one bounds/density check and one direct
slot copy. For a 100,000-element dense array, removing those per-element
operations gives a **target of 5–20×** in the dense-only fixture; no gain is
expected for custom iterators.

**Risks and experiment:** preserve holes, inherited indexed properties,
mutation, Unicode string iteration, and `IteratorClose`. Start with a no-hole
array and the intrinsic iterator identity. Count iterator-result allocations
and compare `forof`, array spread, and spread/rest separately.

**Priority:** very high for `bench-es6`.

### Compact internal Promise reactions

**Target:** long chains of built-in Promises and async functions awaiting
already-settled built-in Promises.

**Mechanism:** use a pooled C3 reaction record containing handler, argument,
downstream promise, and next pointer. Queue an internal record directly rather
than allocating an `ObjClass.OBJECT` reaction, storing its link as a hidden
property, and copying a three-`TVal` queue tuple. Keep user-visible `.then`
objects, custom thenables, and arbitrary handlers on the generic path.

`HObjectPromise` currently links reaction HObjects, while `Heap` queues handler,
argument, and downstream as three `TVal`s. The proposed path removes several
allocations and hidden-property lookups per internal step.

**Work model:** for a built-in chain, replace one reaction object, one hidden
link property, and repeated object/property/refcount work with one pool record
and direct queue traversal. A **target of 3–8×** for long native chains is
reasonable; 10× is a goal only for a chain whose time is allocation/GC bound,
not for arbitrary Promise code.

**Risks and experiment:** preserve FIFO ordering, rejection tracking, handler
throws, jobs queued during a drain, and Promise resolution. Begin with `await`
of an already-settled intrinsic Promise and retain the existing `.then` path.
Measure allocations and drain time.

**Priority:** very high for the promise benchmark.

### Shape-directed object literal initialization

**Target:** fixed-key object literals and class instances created in a loop.

**Mechanism:** emit an initialization operation that selects the final shape,
allocates storage, and writes known slots directly. It replaces `NEWOBJ`
followed by repeated key lookup, shape transitions, and `PUTPROP`. Reuse the
existing transition table and inline property storage; do not create a second
shape system.

**Work model:** an object with `k` fixed keys currently pays roughly `k`
property-install operations plus transition/hash work. A specialized path pays
one allocation and `k` indexed stores after one shape lookup. For a loop that
creates and immediately reads fixed-shape objects, the **target is 2–8×**, with
10× reserved for the case where property installation dominates the whole
fixture.

**Risks and experiment:** exclude spread, computed keys, accessors, duplicate
keys, `__proto__`, proxies, and abrupt initializers. Preserve value evaluation
order. Start with unique constant data keys and verify `Object.keys`, duplicate
keys, and a throwing initializer.

**Priority:** high for `class` and object-heavy destructuring.

### Interpreted superblocks for dispatch-bound loops

**Target:** very long loops whose body stays on one branch path and contains
only already-safe operations.

**Mechanism:** after a loop is hot, pack one basic block or common trace into a
decoded micro-op array. Run a bounded C3 interpreter over that array, with
exits for branch miss, call, throw, GC/interrupt poll, and failed type or shape
guards. This remains bytecode interpretation; it emits no executable code.

`run_threaded_burst` already provides a useful boundary, but its static handler
set cannot combine a whole loop. `OP_PROFILE` also needs a threaded-handler
record hook before it can guide this experiment.

**Work model:** the trace can eliminate one handler-table tail jump and operand
decode per operation and can keep decoded registers in native locals. Existing
`th_add` means the arithmetic itself is already specialized; the target is
dispatch and decode removal. A realistic target is **2–4×** for a dispatch-bound
loop, with 10× only for a tiny loop where dispatch is nearly all the work.

**Risks and experiment:** retain bytecode-PC maps for exceptions/debugging and
poll at the same cadence. First pack `LDREG`/fast arithmetic/comparison/
back-edge only, then compare dispatch counts and time.

**Priority:** high infrastructure value; medium for the current ES6 aggregate.

## Other high-value, regime-specific work

### Indexed closure cells

`GETVAR`/`PUTVAR` still resolve names through environments for captures, while
the compiler knows the lexical capture index. Emit `GET_CAPTURE`/`SET_CAPTURE`
for strict functions without direct eval or `with`, using a compact cell vector
attached to the closure. Keep `EnvRecord` chains for dynamic scope and
per-iteration binding cases.

The work removed is repeated name lookup and chain walking. A **target of
2–6×** is plausible for closure-heavy loops; 10× requires capture access to
dominate. Preserve TDZ, const errors, GC ownership, and detached cells. Start
with one immutable capture and compare `closure_capture`.

### Monomorphic compiled calls

After a call site repeatedly sees one compiled function, a guarded opcode can
skip function-kind classification and enter the existing sliding-window frame
setup directly. A tiny leaf can be cloned as bytecode into the caller, with a
normal call side exit. This is bytecode specialization, not machine-code JIT.

The ES6 review makes call setup a meaningful cost (`capturedAndCalled` and
constructor paths). A **target of 2–5×** is credible for a tiny hot callee;
10× requires calls to dominate. Guard `this`, `new.target`, arguments/
rest/default setup, direct eval, strictness, and exceptions.

### Suspension liveness and ownership-safe snapshots

Await currently allocates `GeneratorState`, saved register storage, resume and
reject functions, and copies every register. Emit liveness maps at suspension
points and save only live registers. When a dead slot is discarded, release
its owned reference exactly once; when a value is moved into saved storage,
transfer or retain ownership explicitly. A bitmap cannot justify simply
skipping `decref`.

The likely gain is **1.5–4×** for allocation-heavy await/generator workloads,
plus lower retained memory. Keep asynchronous ordering and exception/finally
state exact. Measure live-register counts first and test one await shape under
GC stress.

## Order and evidence

First instrument allocation counts, result-object creation, threaded dispatch,
GC cycles, and peak memory without running agents concurrently. Then try dense
array bulk iteration, compact Promise reactions, and shape-directed literals;
these remove concrete work visible in the current ES6 measurements. Follow
with superblocks, indexed captures, and suspension liveness.

Use an immutable baseline and retain semantic checks for every guarded path.
The proposed 10× results are feature-specific targets: none should be reported
as an aggregate ES6 prediction until a benchmark demonstrates both preserved
work and the claimed ratio.

Source anchors: `src/bytecode.c3`, `src/vm/vm_execute*.c3`,
`src/vm/vm_control.c3`, `src/vm/vm_objects.c3`, `src/hobject.c3`,
`src/heap.c3`, `src/env.c3`, `src/vm/vm_generators.c3`,
`src/builtins/promise.c3`, and `docs/es6-vm-performance-review.md`.

# Engine architecture investigation

Status: GC64 and verified string-accumulator binding ownership are applied.
Call/resume frames, compact object storage, and semantic IR remain research.

## String ownership implementation

`vm_concat_accumulate` accepts `PUTVAR_SNAP` after verifying the captured
environment's writable data slot still owns the accumulator. The same actual
slot check guards the ordinary binding stores. This preserves aliases when RHS
coercion replaces the binding and prevents mutation through a failed read-only
global assignment.

Five measured runs: 80k lexical appends take 5 ms instead of 1,019 ms inside the
loop; whole-process time is 8.89 ms versus 1,022.06 ms. The unchanged mixed
iteration benchmark takes 139.19 ms versus 209.36 ms (33.5% less), with peak RSS
64.33 MiB versus 62.72 MiB. The 100k retained scene changes +0.5%; no VDOM gain
is attributed to this fix.

Backing-string copy counters for 20k appends fall from 1,000,050,000 bytes to
143,430 bytes plus 99,965 appended bytes. There are seven initial concat strings
and eleven geometric growths. These counters exclude temporary buffers and
other engine memory traffic.

Validation: 454 compound-assignment test262 cases, 42 Rosetta cases, focused
ownership fixtures, and fresh optimized threaded ASAN/GC-stress checks pass.
The new regression fixture also passes in QuickJS and Node. The implementation
reuses the existing string representation; general compiler ownership analysis
and shared-string representations remain separate candidates.

[Measurements, source patch, instrumentation, and validation logs](../benchmarks/architecture-investigation/string-ownership-fix/README.md).

## Diagnostic baseline: GC64 without the string ownership fix

The GC64 change passes the ASAN/GC verification target; the release CLI passes
42 Rosetta cases.
`just bench-vdom` takes 5.00 seconds: the 100k-node scene takes 1.440 seconds
in Boomkat and 0.861 seconds in QuickJS. This recipe uses integer-millisecond
frame timing; its 2 ms versus 1 ms worst-frame medians are coarse measurements.

Splitting the existing class and mixed-iteration benchmarks gives these median
phase times, in milliseconds, from five alternating measured pairs after warmup:

| Phase | Boomkat | QuickJS |
|---|---:|---:|
| Construct Point and read getter, 1M iterations | 307 | 117 |
| Method calls on one existing Point, 1M iterations | 94 | 36 |
| Derived construction and getter, 500k iterations | 259 | 118 |
| Build array, 300k elements | 19 | 7 |
| Build Map and Set, 100k entries each | 17 | 9 |
| Build string, 20k appends | 73 | 1 |
| Array for-of, 300k elements | 16 | 7 |
| Array indexed loop, 300k elements | 3 | 6 |
| Set iteration, 100k entries | 4 | 2 |
| Map iteration with destructuring, 100k entries | 34 | 10 |
| String iteration, 100k characters | 10 | 1 |
| Generator iteration, 100k yields | 29 | 3 |

These are diagnostic phases within the original workloads, not isolated CPU
profiles. Date.now has 1 ms resolution; do not infer precise ratios from 0–2 ms
values. Script result checksums match between engines. Adding phase output can
affect execution, so these times locate work rather than replace suite results.

Raw results, source scripts, binary hashes, and the exact runtime diff are in
[`benchmarks/architecture-investigation`](../benchmarks/architecture-investigation/).

## 1. Binding and ownership representation, then robust string concatenation

The strongest new finding is algorithmic. This simple loop changes behavior
depending on the loop binding:

```js
let s = "";
for (let i = 0; i < N; i++) s += "abcde";
```

| Appends | Boomkat, let loop | QuickJS, let loop |
|---|---:|---:|
| 10,000 | 17 ms | 0 ms |
| 20,000 | 69 ms | 1 ms |
| 40,000 | 258 ms | 2 ms |

Replacing only the loop's `let i` with `var i` keeps Boomkat around 0–1 ms at
these sizes. Local-function and global-var accumulator controls are also fast.
Three measured pairs follow a warmup; the final string length and character
are checked. The near-fourfold increase when doubling the let-loop length is
consistent with quadratic copying. Confirm copied-byte counters before
attributing all of the growth to a specific guard.

The engine already has non-interned strings, capacity growth, and
`vm_concat_accumulate` (`src/vm/vm_execute.c3`). That helper requires `ra == rb`
and checks reference counts; its two-owner exception recognizes selected
immediately following binding stores. Adding another opcode handler does not
make those ownership proofs robust across lexical scopes.

Architectural direction:

- Represent binding identity and value ownership explicitly through compiler
  lowering. Distinguish a moved value, a borrowed value, and an independently
  observable alias; do not infer ownership from adjacent bytecodes alone.
- Complete lexical scope identities and transitive capture forwarding from
  plan 090. Preserve per-iteration cells only when observable; retain dynamic
  paths for eval and with.
- Use the ownership proof for destructive append to an unshared buffer.
  For shared concatenation, evaluate a balanced rope or chunk representation
  with delayed flattening, independent of a particular register layout.
- Measure bytes copied, allocation count, and peak retained memory. Exercise
  retained prefixes, `s += s`, property-key conversion, regex, Unicode,
  equality, and C API string access. Flattening cost belongs in the benchmark.

QuickJS's local source contains both `JS_ConcatStringInPlace` and string ropes.
An architectural string experiment must compare the two mechanisms separately;
the presence of ropes alone does not prove which mechanism wins this fixture.

## 2. Call frames and resumable execution

Ordinary method calls on an existing object still take about 2.6 times QuickJS's
time. That phase does not repeatedly construct receivers. Generator iteration
is also substantially slower. Both deserve investigation independent of GC.

Current code already has sliding register windows, environment elision, indexed
captures, and ordinary-call fast paths. The remaining architectural concern is
the amount of shared machinery every entry/resume must maintain:

- `Activation` contains ordinary-frame state alongside constructor, exception,
  enumeration, async, and generator state. Call entry initializes these fields
  and publishes roots across several paths in `vm_calls.c3`.
- Native reentry in `vm_execute.c3` saves the active activation prefix to a
  shadow frame, clears slots, then restores the prefix. Work can scale with
  caller depth even when a callback itself is small.
- Generator yield paths in `vm_generators.c3` copy registers into saved storage;
  result objects and resume dispatch add separate costs. Async functions already
  have a restricted liveness optimization; that does not solve generator frames.

Architectural direction: a compact ordinary frame with optional cold state,
a shared entry/return ABI, and stable suspended frame segments. A native callback
should push above the current stack boundary rather than require copying the
entire active prefix. Evaluate keeping generator registers in owned resumable
storage rather than copying on every yield. Borrowed-string lifetimes, GC root
publication, stack growth, exception unwinding, and reentrant host calls are
explicit design constraints.

First experiment: instrument entry work, bytes saved/restored, and allocation
counts for ordinary calls, getters, constructors, nested native callbacks, and
generators. Then prototype ordinary synchronous frames and generators separately.
The method phase also includes lookup and arithmetic; timing alone does not
prove all of its gap is frame setup.

## 3. Object storage and GC metadata locality

Class-specific pools and shared shapes already exist. A further structural
change should reduce the representation paid for by every object:

- `HObjectBase` embeds allocation-list next/prev links, gray-list and remembered
  links, prototype, shape, property metadata, and array metadata. Its four list
  pointers alone occupy 32 bytes on the measured 64-bit platform. Moving them
  elsewhere has its own metadata cost; 32 bytes is not a promised net saving.
- Small objects reserve four inline named-property values. Dense array storage
  follows named-property storage in `prop_alloc`; arrays allocate through that
  shared representation even when they have no custom named properties.
- The generic FixedBlockPool supplies blocks and a free list. It does not supply
  the collector's mark/remembered maps or a heap-page ownership contract.

Architectural direction: compare a compact ordinary-object/array header and
storage specialized by shape, with collection metadata on heap pages. Page
bitmaps or indexed queues could replace per-object list links and improve scan
locality. Keep object addresses stable in the first experiment; moving collection
would add native-pointer, IC, and C API requirements unrelated to proving the
layout benefit. Large/fallback allocations still need a supported path.

First experiment: account for live bytes by header, values, elements, strings,
shape metadata, allocator slack, and garbage awaiting sweep. Then prototype one
ordinary-object pool and measure allocation, traversal, retained memory, and
freeing. Existing per-class size reductions are not evidence for the benefit of
this additional change.

## 4. Semantic compiler IR and allocation elimination

Introduce a binding-aware intermediate representation with value identities,
effects, control flow, and escape information before final register bytecode.
Its first useful outcome should be removal of work: inline a provably stable
small helper, replace a non-escaping record with scalar registers, and emit GC
root maps from value liveness. Numeric type facts can also remove repeated
checks within a guarded region.

This is larger than frame compaction (whose earlier experiment was rejected).
It needs an independent allocation-elimination result to justify its cost.
Start with intraprocedural non-escaping records and explicit unsafe-operation
barriers. Constructor/getter inlining and speculative materialization come later.
Most scene vectors and matrices are stored in a retained view and escape their
creating function; their lifetime alone does not prove they can be eliminated.

Mutation of prototypes, accessors, identity, eval, proxies, exceptions, and native
calls require conservative fallback or precise guards. Track compiler time,
bytecode size, and memory as well as runtime on low-powered targets.

## Research references

- [QuickJS source](https://github.com/bellard/quickjs/blob/master/quickjs.c):
  in-place concatenation and rope representation; local source is the reference
  for the binary measured here.
- [Lua 5.0 implementation](https://www.lua.org/doc/sblp2005.pdf): register VM and
  closure/upvalue representation. Boomkat already uses a register VM; the useful
  comparison is frame and captured-value ownership.
- [V8 escape analysis](https://v8.dev/blog/disabling-escape-analysis): eliminating
  allocations whose identities do not escape. Its JIT implementation and speedups
  are not results for a C3 bytecode compiler.
- [V8 fast properties](https://v8.dev/blog/fast-properties): separate elements,
  named storage, shared shapes, and a distinct hole sentinel. Boomkat already
  implements several of these ideas; representation changes need local evidence.
- [Micro QuickJS](https://github.com/bellard/mquickjs): compact memory-oriented
  representation as a design comparison. Its scope and moving-GC contract differ
  from Boomkat's; it is not a drop-in collector recommendation.

## Order

1. Complete: verify actual binding ownership and remove the lexical-loop
   copying cliff. Wider ownership lowering and shared-string representations
   require separate workload evidence.
2. Measure and prototype shared call/resume frame machinery.
3. Quantify heap composition, then test compact storage with page metadata.
4. Build semantic IR incrementally around demonstrated allocation elimination.

No architectural speedup percentages are promised. Each prototype gets immutable
baseline comparisons, QuickJS throughput and frame latency, memory accounting,
and targeted semantic/GC validation before adoption.

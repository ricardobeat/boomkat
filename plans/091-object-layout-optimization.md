# 091: Class-specific object layouts and pools

Status: proposed; layout study complete, implementation and performance measurements pending.

## Goal

Reduce object storage and allocation work across ordinary JavaScript workloads by
giving each object class storage appropriate to its payload. Preserve the common
object header, inline property capacity, GC behavior, and existing semantics.

## Findings

The C3 skill, language layout reference, and installed C3 0.8.3 stdlib support
typed layouts with an `inline HObjectBase` prefix. `FixedBlockPool.init_for_type`
derives block size and alignment from the complete struct.

An isolated compiler probe on macOS ARM64, with NaN-boxing enabled, measured:

- `TVal`: 8 bytes.
- `HObjectBase`: 80 bytes.
- `HObjectExtra`: 104 bytes, alignment 8, determined by the Temporal payload.
- Existing inline property storage: 32 bytes.

| Class | Current pool block | Candidate typed layout | Reduction |
|---|---:|---:|---:|
| Array | 216 B | 120 B | 44% |
| Arguments | 216 B | 128 B | 41% |
| Function | 216 B | 192 B | 11% |
| Promise | 216 B | 152 B | 30% |
| RegExp | 216 B | 136 B | 37% |
| Getter/setter | 216 B | 96 B | 56% |

Candidate layouts retain existing inline property capacity where applicable.
Getter/setters have no inline properties. Plain objects already occupy 112-byte
blocks and do not carry the extra union.

These figures describe object storage, not total heap savings or throughput.
Shared size-class pools may round candidate layouts up to larger blocks.

Getter/setters request 96 bytes through `alloc_size_for_class`, but
`pool_for_class` routes them to the 216-byte function pool. Allocation size and
physical pool block size must both change to realize savings.

The installed pool clears recycled blocks; `hobject_alloc` clears them again.
Fresh bump-allocated pool blocks are uninitialized. Removing duplicate clearing
requires an explicit initialization contract covering both paths.

A `NONANBOX` probe fails the existing compile-time assertion that
`HObjectTemporal::size > HObjectFunction::size`. Layout selection must work when
the largest payload differs between configurations.

## Design

### Typed layouts

Define complete structs containing an `inline HObjectBase`, the class payload,
and inline properties where applicable. Use compiler-derived size, alignment,
and member offsets. Keep payloads in the same allocation as their header.

Use typed payload accessors as layouts migrate. Retain unions only where their
members intentionally share storage. Packing structs does not address the
oversized union and would weaken alignment guarantees.

### Central layout information

Centralize the relationship between object class, logical allocation size,
inline property offset, and pool selection. Allocation, access, and freeing must
agree on the same layout. Pool block size may exceed logical layout size; inline
properties must remain at their typed field offset.

Preserve these contracts:

- Callable proxies share the `builtin_fn_index` offset with function payloads.
- Arrays and arguments have different payload requirements; arguments include
  their mapped-parameter bits.
- GC and reference-count traversal visit the correct class-specific fields.
- Pool fallback, pool bypass, reset, and destruction use matching sizes and
  ownership rules.
- Initialization preserves required JavaScript values: zeroed `TVal` storage is
  not an undefined value.

Add compile-time checks for common-prefix compatibility, relevant field offsets,
alignment, and the callable-proxy contract in both value representations.

### Pool organization

Use a small number of size classes, selected from measured layouts and workload
allocation counts. Use `init_for_type` where a pool corresponds to a concrete
layout; shared pools must provide sufficient size and alignment for every member.

Avoid a separate eagerly allocated pool for every object kind. Existing pools
initialize with capacity 512, so excessive pools can increase baseline memory.
Account for initial reservation and partially occupied pages when measuring.

Treat duplicate clearing as a separate follow-up experiment so its effects can
be measured independently of layout changes.

## Implementation checklist

- [x] Read C3 layout and pool references; measure representative typed layouts.
- [x] Identify pool-size mismatch and `NONANBOX` assertion failure.
- [ ] Record baseline timings, allocation counts, and memory for representative
  workloads, including small heaps and retained objects.
- [ ] Define shared layout machinery and compile-time invariants.
- [ ] Implement compact arrays, arguments, and getter/setters with suitable pools.
- [ ] Audit payload access, inline properties, GC, freeing, fallback allocation,
  heap reset, and pool bypass for the migrated classes.
- [ ] Validate correctness and report measured results before expanding scope.
- [ ] Extend the same machinery to functions, promises, RegExp, and other classes
  where measurements justify it.
- [ ] Evaluate single-clear allocation separately.
- [ ] Update `docs/architecture.md` for the accepted design and commit validated
  stages with results recorded here.

Give implementation agents bounded class or helper changes with explicit
contracts and minimal validation. Run shared regression suites and performance
comparisons centrally.

## Validation and acceptance

Run focused fixtures for dense and sparse arrays, mapped arguments, accessors,
inline-property growth, callable proxies, and GC lifetime behavior. Use the local
suite, Rosetta, and relevant narrow test262 directories. Rebuild ASAN before
testing; exercise both production pooling and pool-bypass allocation. Build and
validate the `NONANBOX` representation after fixing the layout assertion.

Compare repeated release-build runs against an unchanged baseline. Measure
allocation-heavy and retained-object workloads alongside the existing benchmark
suites. Include peak memory and small-heap baseline memory so pool reservation
does not hide the cost of additional size classes.

Accept the change only with correctness preserved and a useful measured memory
or performance benefit without material regressions elsewhere. Report experiment
results before proceeding to another optimization. No speedup is established by
the layout probe alone.

## References

- C3 skill: `/Users/rtomasi/.agents/skills/c3-lang/SKILL.md` and its advanced and
  stdlib references.
- [C3 structs and unions](https://c3-lang.org/language-common/structs-and-unions/).
- Installed C3 0.8.3 stdlib: `std/core/mem_mempool.c3`, especially
  `FixedBlockPool.init`, `init_for_type`, and `alloc`.
- `src/hobject.c3`: object payloads, layout constants, allocation, property
  accessors, and pool selection.
- `src/heap.c3`: pool initialization, reset, and destruction.

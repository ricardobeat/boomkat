# Plans Index

| Plan | Status | Notes |
|------|--------|-------|
| [001-architecture-improvements.md](001-architecture-improvements.md) | ✅ DONE | NaN-boxing implemented and default |
| [002-tval-inlining.md](002-tval-inlining.md) | ✅ DONE | TVal methods converted from `@inline fn` to `macro` |
| [003-hotpath-optimization.md](003-hotpath-optimization.md) | ✅ DONE | CALL/RET three fixes applied |
| [004-codebase-review.md](004-codebase-review.md) | ✅ DONE | Review completed; findings actioned across later plans |
| [005-libc-memory-removal.md](005-libc-memory-removal.md) | 🔶 PARTIAL | Some allocations routed through Heap; ~30+ `libc::malloc` sites remain |
| [006-tech-debt.md](006-tech-debt.md) | ✅ DONE | All 4 items: buffer constants, CallableKind, PropLookupResult, `is_prototype_of` |
| [007-vm-dispatch-optimization.md](007-vm-dispatch-optimization.md) | ✅ DONE | Debug printf removed; threaded dispatch deferred/superseded |
| [008-ic-crash-gc-roots.md](008-ic-crash-gc-roots.md) | ✅ DONE | IC crash fixes, GC root marking, iterator support all applied |
| [009-hobject-subtype-split.md](009-hobject-subtype-split.md) | ✅ DONE | `HObjectExtra` tagged union exists; derived pointers are methods |
| [010-VM-GC-issues.md](010-VM-GC-issues.md) | ✅ DONE | Bug 1 (IC base) + Bug 2 (delete_prop) fixed; Bug 3 resolved by refcounting |
| [011-memory-optimization.md](011-memory-optimization.md) | 🔶 STALLED | Superseded by plans 029–033; kept for historical context |
| [012-speed-optimization.md](012-speed-optimization.md) | ✅ DONE | All items completed across Sessions 114–123 |
| [013-speed-optimization-2.md](013-speed-optimization-2.md) | ✅ DONE | All items done: RC, RET restart, valstack_top cache |
| [014-test262-review.md](014-test262-review.md) | ✅ DONE | Status snapshot; remaining gaps tracked in progress.md |
| [018-rebase-rc-on-delta-shapes.md](018-rebase-rc-on-delta-shapes.md) | ✅ DONE | String RC rebased on delta shapes (Session 146) |
| [019-shape-optimize-bench.md](019-shape-optimize-bench.md) | ✅ DONE | bench_shape 73×→0.8× (Session 147) |
| [020-fable-review.md](020-fable-review.md) | ✅ DONE | All 8 items complete per plan 021 status table |
| [021-struct-cleanup.md](021-struct-cleanup.md) | ✅ DONE | Items B (CallableKind→accessor) & C (PropHashInfo side struct) complete |
| [022-property-descriptor-correctness.md](022-property-descriptor-correctness.md) | 🔶 IN PROGRESS | Session 167: defineProperties non-configurable validation fix (+16 net); Session 163: NEW_OBJ lightfunc constructable check (+170 net); Session 162: ToString exponential notation fix (+67 net); Bugs A & C already fixed (seal/freeze dense arrays, GOPD flags) |
| [024-fused-opcodes.md](024-fused-opcodes.md) | ✅ DONE | GETPROPC + compare-and-branch fused opcodes; peephole passes; rotated loops (Session 148–149) |
| 025-callback-error-propagation | ✅ DONE | vm_call_fn_impl Case 3 fix; arr_call_callback error handling; find/findIndex native builtins; print toString (Session 149) |
| [023-missing-prototype-methods.md](023-missing-prototype-methods.md) | 🔶 PARTIAL | Date.toDateString/toTimeString, String.replaceAll/matchAll/normalize added (Session 150); remaining methods TBD |
| 027-declvar-ic | ✅ DONE | DECLVAR inline cache: skip find_prop_idx on repeat calls (Session 150) |
| 028-test262-conformance | ✅ DONE | arr_throw_type_error propagation; sloppy-mode PUTPROP; Array.prototype metadata; Object.seal/freeze non-objects; global `this` (Session 151) |
| [029-memory-low-hanging-fruit.md](029-memory-low-hanging-fruit.md) | 🔶 PARTIAL | Items 1, 3, 4 done. Items 2 (default proto), 5 (sparse IC) remain; see plan 033 |
| [030-memory-profiling.md](030-memory-profiling.md) | ✅ DONE | Inline props, unified prop_alloc, and FixedBlockPool object pools implemented. Boxed accessor pairs deferred to plan 033 |
| [031-string-intern-bloat.md](031-string-intern-bloat.md) | ✅ DONE | Skip-interning for ADD concat + lazy intern in get_prop_key; memory 15,776→6,688 KB. Fix 2 (GC in alloc_no_gc) retracted post-completion — caused double-frees and the ~1s shape bench regression |
| [032-gc-safepoints.md](032-gc-safepoints.md) | ✅ DONE | `gc_pending`, `safepoint_gc()`, and `temproot` protection implemented in heap.c3/vm.c3 |
| [033-memory-next-steps.md](033-memory-next-steps.md) | 🔄 IN PROGRESS | GC on backward jumps (item 2) done; boxed accessor pairs (item 1) done. Remaining: default-prototype elision |
| [034-novel-vm-optimizations.md](034-novel-vm-optimizations.md) | ✅ DONE | Megamorphic cache, GETPROPC_CACHED adaptive opcode, GETPROPC2 chain fusion. +40% property-heavy benchmarks. |

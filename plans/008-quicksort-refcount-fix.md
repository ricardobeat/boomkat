# VM Refcount Underflow in Sliding-Window Calls (Quicksort Bug Fix)

**Date:** 2026-06-12  
**Status:** Fixed (commit be0410b on worktree-fix-quicksort-vmerror, merged to main as 6485f46)  
**Impact:** Critical — manifested as VM_ERROR crashes and heap double-frees in recursive nested closures

## Summary

The Boomkat VM crashed on `rosetta/quicksort.js` and related tests with `VM_ERROR` during `Math.floor` invocation in the second call to the quickSort function. The root cause was a reference count underflow in the sliding-window call mechanism that freed the global Math object prematurely, recycled its memory as a closure, and triggered a double-free on heap teardown.

## Root Cause

### Sliding-Window Calls

The VM uses a sliding-window register model: when function A calls function B, the callee B's register frame starts immediately after the caller's func/this/args slots:

```
Caller frame:     [... result_reg | func | this | arg0 arg1 ...]
                                   ^
                                   callee_reg
Callee frame:                          [arg0 arg1 ... | temps ...]
                                       ^
                                       callee bottom = caller bottom + callee_reg + 2
```

This avoids copying: the callee's params are already in place.

### The Bug

1. When a callee B returned, `decref_callee_regs(vm, B_activation)` decremented the refcount of every TVal in B's registers (0 to max_heap_reg).
2. **Critical flaw:** The slots were never cleared—the TVal bits remained in place.
3. When the caller A itself returned, it called its own `decref_callee_regs(vm, A_activation)` with its `max_heap_reg` (which extended into the overlap region due to the func/this/arg stores for the call to B).
4. **Result:** The overlapping slots were decref'd twice—once by B's cleanup and again by A's.

### Why Quicksort Failed

In `quickSort(arr)`:
- First call `quickSort([2,1,4,3])` creates nested `qs(lo, hi)` closures
- Each `qs` call does `var pivot = a[Math.floor(...)]`
- `Math` is loaded via `GETVAR Math` into a register in the overlap region
- After innermost `qs` returns, `decref_callee_regs` on the innermost activation decrements Math's refcount
- When the intermediate `qs` returns, its `decref_callee_regs` decrements Math again (same stale slot in the overlap)
- Math's refcount underflows to 0; the object is freed while still bound in the global environment
- The allocator recycles Math's memory for a closure object
- Second call `quickSort([...])` does `Math` lookup → finds the closure object
- `Math.floor` → "undefined is not a function" → `VM_ERROR`
- Heap teardown tries to free the recycled object again → segfault (exit 139)

## The Fix

**File:** `src/vm.c3`, function `decref_callee_regs` (line ~1283)

**Change:** Clear each register to `undefined` immediately after decrefing it:

```c
for (uint i = 0; i <= limit; i++) {
    // Clear the slot after releasing the ref: callee frames overlap the
    // caller's register window (sliding-window calls), and the caller's
    // own decref_callee_regs would otherwise decref the stale bits a
    // second time, underflowing the refcount.
    vm.heap.decref_tval(&regs[i]);
    regs[i].set_undefined();
}
```

By setting slots to undefined (a non-heap value), the caller's second decref on the overlap region becomes a no-op (undefined has no heap pointer to release).

## Validation

- ✅ `test/rosetta/quicksort.js`: 6/6 tests pass (was: failing)
- ✅ `test/rosetta/reduce_sum.js`: passes (was: failing with same root cause)
- ✅ Local test suite (`test/*.js`): 113/118 pass, 5 pre-existing failures unrelated to this fix
- ✅ Benchmark suite `bench-fast`: no regressions
- ✅ Rosetta suite: 19 passed / 1 failed (remaining regexp failure is tracked separately)

## Broader Implications

This fix affects all function calls and returns in the VM. The sliding-window optimization trades allocation speed for potential overlap bugs—the fix ensures cleanup is idempotent. No performance regression observed (all overlapping slots are being cleared anyway post-return, just now defensively zeroed).

## Notes

- Agents were less effective here (one blocked on permissions, others stopped mid-investigation), but refcount tracing on a watched pointer and per-instruction register scanning proved the underflow.
- The bug only manifested in nested recursive closures where: (1) inner activation holds a heap ref in the overlap, (2) outer activation's `max_heap_reg` extends into that overlap. Shallower call stacks or non-recursive code rarely triggered it.

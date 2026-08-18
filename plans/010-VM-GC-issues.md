# VM/GC Bug Investigation — June 1

## Summary

Two bugs found and fixed, one remaining GC correctness bug under investigation.

---

## Bug 1: IC (Inline Cache) base pointer not updated on function calls (FIXED)

**Symptom:** `bench_ic_monomorphic.js`, `bench_ic_proto.js` crash with SIGBUS/SIGABRT when run via `boomkat`. `test_vm` works because the disassembly pass touches memory in a way that masks the crash.

**Root cause:** The VM's inner dispatch loop maintains a local `ic_base` pointer for the current function's inline cache. Five locations in `vm.c3` update `code_base` (when switching functions on call/return), but `ic_base` was only initialized once at the start of the run loop, never updated when calling into a new function or returning from one.

When function `bench()` is called and then accesses `p.x`, `pc_off = curr_pc - 1 - code_base` gives the correct offset into `bench`'s code, but `ic_base` still points to the outer script's IC array. For large offsets, this is an out-of-bounds write → SIGBUS/SIGABRT.

**Fix (`src/vm.c3`):** Added `ic_base = (hobject::ICEntry*)target.ic_entries` next to every `code_base = target.code` assignment (4 locations: fast-path CALL direct dispatch, slow-path CALL direct dispatch, RET direct dispatch, RETUNDEF direct dispatch).

**Status:** Fixed. All `bench_ic_*.js` pass.

---

## Bug 2: `delete_prop` corrupts shared Shape (FIXED)

**Symptom:** 3 or more set+delete cycles on the same property causes a crash. Example:
```javascript
var obj = {};
obj.x = 1; delete obj.x;  // cycle 1
obj.x = 2; delete obj.x;  // cycle 2
obj.x = 3; delete obj.x;  // cycle 3 — CRASH
```

**Root cause (two interrelated issues):**

1. **Missing tombstone:** The hash table uses `0` as "empty slot" sentinel in the probe chain (`if (entry == 0) return -1`). `delete_prop` was marking deleted entries as `0` (same as empty). This broke the probe chain — subsequent lookups stopped early and could not find keys that were inserted after the deleted slot.

   The code defined `HASH_UNUSED = 0xFFFFFFFF` and `HASH_DELETED = 0xFFFFFFFE` as tombstone constants but never used them.

2. **Shared shape mutation:** Shapes are shared between objects with the same property layout. `delete_prop` was directly mutating `self.shape.hash_table()` — the shared shape. Every other object with the same shape layout would have its hash table corrupted.

3. **prop_count desync:** `delete_prop` cleared the value slot but did NOT decrement `prop_count`. On re-adding the same key, `transition_shape` would find the key not in the hash table (because it was zeroed) and append a NEW entry, incrementing `prop_count` to 2. After 3 cycles, `prop_count = 3` with three duplicate `x` entries.

**Fix (`src/hobject.c3`):** Rewrote `delete_prop` to:
1. Compact `prop_values` by shifting entries `[ui+1..prop_count-1]` down to `[ui..prop_count-2]`
2. Decrement `prop_count`
3. Build a new private shape (not in the transition table) that reflects the new property set
4. Register the new private shape with the heap's shape table and attach to this object

**Status:** Fixed. `bench_object.js` and `del_minimal.js` pass.

---

## Bug 3: GC collects live array elements (ONGOING)

**Symptom:** In `vdom_test.js`, `prev[j]` (elements of a global array) become `undefined` during the frame loop, starting around frame 11-15. This causes `countChanges(prev[j], curr)` to throw "Cannot read properties of undefined (reading 'cls')".

**Key observations:**
- Works with fewer frames/components (FRAMES=2, COMPONENTS=2)
- Works when debug `print()` calls are added INSIDE the frame loop (changes bytecode structure, likely instruction count/offsets)
- Same bytecode structure (identical disassembly) but still fails at 60 frames
- `prev[j]` is `undefined` (not a collected pointer — the array slot itself becomes undefined), suggesting GC is overwriting live array elements, not just freeing objects
- The global `prev` array's bindings object IS registered as a GC root
- `prev[j]` TVal is on the value stack during `countChanges` execution (at registers 14 and 15 of the outer function frame)

**Hypotheses under investigation:**

1. **GC scans stale value stack pointers:** When `env_create_function_scope` triggers GC during the fast-path CALL setup, `vm.valstack_top` is not yet updated to include the callee's registers. The args (`prev[j]`, `curr`) are at the CALLER's register positions (r14, r15 of outer function), which ARE within the current `valstack_top` range (r0-r16). Should be OK.

2. **Array dense part scan is wrong:** `drain_gray` scans `array_part[0..array_size-1]`. The `prev` array has `array_size = 16` (initial), `array_used = 15`. All slots should be scanned. Need to verify.

3. **The IC change broke something:** The IC fix changed when each function's IC entries are used. Possible that a GETPROP in the outer function now reads a stale/cold IC entry and returns wrong data? Unlikely to cause `undefined` values — IC misses fall through to slow path.

4. **`PUTPROP r10 = r11, r13` in the outer loop overwrites `prev[j]`:** This is `prev[j] = curr`. After this, the old `prev[j]` is no longer in `prev.array_part[j]`. If GC runs just before this instruction and marks the old `prev[j]`, it would be protected during that GC cycle. But after the `PUTPROP`, the old value is overwritten. This is normal — the old object should then be collectible.

   The issue would be if `PUTPROP` writes `undefined` instead of `curr`. This could happen if: `curr` TVal is `undefined` because a GC cycle collected the `curr` object while its reference was being passed as a GETVAR result.

5. **GETVAR returns undefined for `curr`:** `curr` is declared via `DECLVAR r9, 16` into the var_env. If the var_env's bindings HObject is collected... but the var_env IS marked via `vm_mark_activations`. This marks the activation's `var_env.bindings`. If the bindings object is properly marked, `curr` can't be collected.

**Next steps:**
- Check if `curr` is undefined when passed to `countChanges`, or if `prev[j]` itself was overwritten with undefined
- Check if the IC path for GETPROP returns `undefined` incorrectly (e.g., stale IC entry with wrong `pi` after a delete + re-add cycle that changes shape)
- Verify that `vm_mark_activations` correctly marks the var_env for inner function scopes created during `renderComponent`

**Suspected root cause (working theory):**
The IC fast path uses the shape's generation to validate cache entries. After our `delete_prop` fix, each delete creates a new shape with a new (but reset) `generation = 0`. If a freshly created private shape gets generation=0 and an IC entry also has gen=0 (from the initial zeroed state), the IC validation check passes incorrectly: `gen == vm.heap.shapes[hobj.shape_id].generation` would be `0 == 0` — always true for fresh shapes! This could cause the IC to return wrong `pi` (property index) for the wrong object type, resulting in wrong or garbage values being returned as "properties".

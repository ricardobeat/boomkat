# Register Pressure: concat holey array Failure

**Date**: May 31, 2026
**Status**: Closed 2026-11-03, superseded by plans 029–033. Earlier status: root cause
identified, fix attempted but failed.

## Problem

`test/array.js`: 74/75 pass, 1 fail (`concat holey array`). The failing test
calls `arr_holey.concat([4])` where `arr_holey = [1, , 3]` (holey array).
The argument `[4]` arrives in `builtin_array_proto_concat` as tag=0 (garbage/zero)
instead of tag=6 (object).

## Root Cause (Confirmed)

**8-bit instruction field truncation.** The compiler's register allocator lets
`next_reg` grow beyond 255. The `Instruction` bitstruct has 8-bit fields
(A, B, C each 8 bits), and `make_abc()` silently truncates via `& 0xFF`.

For `test/array.js` (367 lines), the top-level function reaches **nregs=1162**.
When registers exceed 255, instruction operands are silently truncated:

- `[4]` array literal allocated at register 1024 → truncated to `NEWARR reg=0`
- `arr_holey.concat` callee at register 1022 → truncated to 254
- CALL expects arg at register 256 (also truncated) → reads garbage

## Why nregs=1162

Three vectors contribute:

### 1. Global var declarations (~55 registers, permanent)

`declare_var()` at line 723 calls `alloc_reg()` unconditionally. At global scope
(`is_global=true`), the variable is NOT added to `scope_stack` (line 726 check),
so it can never be freed by `pop_scope`. Each `var x = expr;` at top level
permanently consumes one register.

Global vars use GETVAR/PUTVAR at runtime — the register is only needed briefly
as the PUTVAR source, then it's dead. But the stack-based allocator can't reclaim
it because higher-numbered temporaries sit above it.

### 2. emit_call callee+this leak (~160 registers)

`emit_call()` at line 3766: `self.free_regs_to(first_arg)` where
`first_arg = callee_reg + 2`. This frees argument registers but NOT the callee
register or the `this` slot. Each function call leaks 2 registers. With ~80 calls
in the test file, that's ~160 leaked registers.

**Attempted fix**: Change to `self.free_regs_to(callee_reg)`.
**Result**: Correct in isolation, but combined with other changes caused
regressions in other tests. The fix alone did NOT reduce nregs below 256.

### 3. Binary expression temp inflation

Left/right temporaries in expressions like `a + b` aren't always freed because
`free_reg()` only frees the top of the stack. Intermediate registers accumulate.

## Attempted Fixes (All Failed)

### Fix 1: emit_call register leak (alone)
- Changed `free_regs_to(first_arg)` → `free_regs_to(callee_reg)` in `emit_call`
- Same change in `new_expr`
- **Result**: Still 74/75 — nregs still >256, concat holey still fails

### Fix 2: Skip declare_var at global scope
- In `var_declaration`, when `self.is_global`, skip `declare_var` entirely
- Compile initializer directly, PUTVAR with val_reg, free val_reg
- **Result**: concat holey PASSES, but "splice remove one" and "shift after push" regress (73/75)
- **Problem**: Changing register allocation order changes which registers get
  truncated, exposing different bugs. The truncated registers now clobber
  different live values.

### Fix 3: free_reg after emit_var_store at global scope
- Keep `declare_var`, add `self.free_reg(reg)` after `emit_var_store` when global
- **Result**: concat holey PASSES, but "shift third" and "shift empty" regress (73/75)
- **Problem**: Same root issue — `free_reg(reg)` only works if `reg` is at the top
  of the stack. After complex initializers (e.g., `f(x)`), temporaries sit above
  `reg`, so `free_reg` is a no-op and the register isn't actually freed. When the
  next var declaration gets a different register number than before, the truncation
  pattern changes and breaks different tests.

## Key Insight

The fundamental problem is that `make_abc()` silently truncates. Fixing register
leaks changes WHICH registers get truncated but doesn't prevent truncation.
Different register layouts expose different bugs in different tests.

## Correct Solutions (Not Yet Tried)

### Option A: Error on overflow (safest, simplest)
In `alloc_reg()`, if `next_reg > 255`, emit a compile error. This prevents
silent corruption and makes the problem visible. Not a real fix for large scripts,
but eliminates the silent failure mode.

### Option B: Register spilling
When `next_reg` would exceed a threshold (e.g., 240), spill dead registers to
memory. Emit SPILL/UNSPILL instructions that save/restore registers to a
stack-based spill area. This is the correct long-term solution.

### Option C: Widen instruction fields
Change the instruction format to support more than 8-bit register fields. Could
use variable-length instructions or a 16-bit register field format. Major
architectural change.

### Option D: Register allocation with liveness tracking
Replace the stack-based allocator with a proper register allocator that tracks
liveness and reuses dead registers. This would keep nregs low without needing
spilling. More complex than Option A but doesn't require VM changes.

## Recommended Next Steps

1. **Implement Option A first** — add `MAX_REG` check in `alloc_reg()` that
   emits a compile error when registers exceed 255. This turns silent corruption
   into a clear error message.

2. **Then combine Options A + D** — fix the three leak vectors (global vars,
   emit_call, binary temps) with proper liveness tracking so nregs stays under
   256 for typical scripts. If it still overflows, the error from Option A
   catches it.

3. **Option B (spilling) as fallback** — if register pressure can't be reduced
   enough, implement spilling as the VM-level solution.

## Files

- `src/compiler.c3:517-548` — `alloc_reg`, `free_reg`, `free_regs_to`
- `src/compiler.c3:723` — `declare_var` (allocates register unconditionally)
- `src/compiler.c3:3654-3776` — `emit_call` (callee/this leak at line 3766)
- `src/compiler.c3:3949-4018` — `new_expr` (same leak at line 4009)
- `src/bytecode.c3:42-44` — `MAX_A/B/C = 0xFF` (8-bit limits)
- `src/bytecode.c3:457-466` — `Instruction` bitstruct (8-bit fields)
- `src/bytecode.c3:475-482` — `make_abc()` (silent truncation via `& MAX_A`)
- `test/array.js:332-336` — the failing `concat holey array` test

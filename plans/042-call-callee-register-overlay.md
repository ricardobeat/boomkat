# Plan 042: CALL callee-frame register overlay

**Status:** Done; fixed systematically by [plan 043](043-call-frame-isolation.md). Closed 2026-11-03.
Earlier status: worked around (compiler-side register placement).
**Priority:** Medium — blocks clean compiler register allocation for any
multi-CALL loop that carries live state between iterations (rest collection,
for-of destructuring, etc.).

## The CALL convention

From `src/bytecode.c3:197-200`:

```
/// `A = B(C..C+N)` — function call.
/// A = result register, B = callee register, C = argument count.
/// Value stack: valstack[B] = callee, valstack[B+1..B+C] = args.
/// After call: valstack[A] = return value.
```

And from `src/vm/vm_calls.c3:67-68`:

```c3
// New callee frame starts right after func and this in the caller frame
uint frame_start = callee_reg + 2;
TVal* new_bottom = ds.regs_base + frame_start;
```

The callee's register frame (r0, r1, …) is placed **directly in the caller's
register array**, starting at `callee_reg + 2`. The caller and callee share the
same physical register array. When the callee runs, its `r0` overwrites the
caller's register at `callee_reg + 2`, its `r1` overwrites `callee_reg + 3`, and
so on.

**Any caller-owned register at or above `callee_reg + 2` is clobbered during a
CALL.**

## Why it matters

The destructuring compiler emits a loop that calls `.next()` repeatedly to
collect remaining iterator values for rest elements:

```
loop:
  CALL result_reg, callee_reg, 0    ← callee frame starts at callee_reg+2
  GETPROP .done from result
  IF_TRUE → break
  GETPROP .value from result
  GETPROP .push from array_reg       ← array_reg must survive the CALL
  CALL push(array_reg, value)
  JUMP back to loop
```

The array collecting values lives in `array_reg`. That register must survive
**every iteration** of the loop. If `array_reg >= callee_reg + 2`, the CALL at
the top of the loop overwrites it with the callee's `r0`, and the subsequent
`GETPROP .push` reads garbage.

## How the bug manifested

In the original rest-emission code, `array_reg` was allocated via `alloc_reg()`
inside the rest-emission branch. Since `callee_reg` was already allocated during
iterator setup (from a preceding element like `[a, ...rest]`), `array_reg` landed
at `callee_reg + 2` or higher:

```
callee_reg      = r9     (the .next function, allocated by emit_destruct_iter_setup)
callee_this_reg = r10    (the iterator object, r9+1)
array_reg       = r11    (allocated later by the rest code — this is callee_reg+2!)
result_reg      = r12
```

`CALL r12, r9, 0` places the callee frame at `r9+2 = r11`. The callee's `r0`
overwrites the array. When the loop tries `GETPROP .push` from `r11`, it reads
whatever the callee left there — typically `undefined` from the callee's
register init.

This only manifested with **user-JS `.next()` functions** (custom iterables,
generators) because native built-in iterators (Array Iterator) use a different,
lighter call path that doesn't overlay the caller's registers in the same way.

## Current workaround

### Leaf rest (`[...rest]`)

Use `bind_reg` directly for the array. `bind_reg` is allocated early via
`declare_var` (register numbers like `r1`, `r2`), well below `callee_reg`
(typically `r9+`). The CALL frame at `r9+2` doesn't touch `r1`/`r2`.

### Synthetic rest (`[...[...x]]`)

The synthetic's `group_reg` needs to hold the collected array for children to
destructure from. Pre-allocate `group_reg` in a pass **before** any iterator
setup, so it lands below `callee_reg + 2`. This is the pre-scan in
`emit_destruct_bindings` (`src/compiler/functions.c3`):

```c3
// Pre-scan: allocate group_regs for rest synthetics before any iterator
// setup, so they land below callee_reg and are safe from CALL frame overlay.
for (uint di = 0; di < count; di++) {
    if (binds[di].is_synthetic && !binds[di].is_object && binds[di].key_idx == 0xFFFF) {
        group_regs[di] = self.alloc_reg();
    }
}
```

## Proper fix options

### Option A: Copy registers per activation

Allocate a separate `TVal[]` for each activation's register file. Copy
arguments in, copy return value out. No overlay, no clobbering.

- **Pro:** Clean separation. The compiler never needs to worry about register
  placement relative to CALL.
- **Con:** Memory overhead (one extra register array per live activation).
  Copy overhead per call. Significant VM refactor.

### Option B: Compiler clobber tracking

Teach the register allocator that `callee_reg + 2` through
`callee_reg + 2 + max_callee_regs` is clobbered by a CALL instruction. The
allocator then avoids placing live state in that region, or spills it to
a safe register before the CALL.

- **Pro:** Systematic. No VM changes.
- **Con:** Requires knowing `max_callee_regs` at compile time, which isn't
  always possible (callee may be a runtime value, not a known compiled
  function). Conservative upper bound wastes registers. Complex to implement
  in the current linear-scan allocator.

### Option C: Pad the call frame

Insert padding registers between `callee_this_reg` and the first caller-owned
register above it. The compiler explicitly reserves `callee_reg + 2` through
`callee_reg + 2 + N` as "callee-owned" and never allocates caller state there.

- **Pro:** Simple to implement in the compiler (just bump `next_reg` past the
  danger zone before each CALL loop).
- **Con:** Wastes registers (N must be a conservative upper bound). Still
  requires knowing max callee regs.

### Option D: Result-register separation

Change the CALL convention so the result register (`A`) is **not** part of the
callee frame, and the callee frame starts at a dedicated frame pointer separate
from the caller's register array. This is essentially a hybrid of option A
(separate frame) but keeping the current shared register model for arguments.

- **Pro:** Less overhead than full copy. Caller registers remain untouched.
- **Con:** Requires VM changes. Adds frame pointer indirection.

## Recommendation

For now the compiler workaround (using low-numbered registers pre-allocated
before iterator setup) is sufficient. The next time this issue surfaces
(likely during for-of destructuring or async generator work), option B
(compiler clobber tracking with a conservative bound) is the most practical
systematic fix — it keeps the VM fast path intact while giving the compiler
the knowledge it needs to place registers safely.

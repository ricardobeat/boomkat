# VM Dispatch Optimization Plan

## Context

The C3 port is 1.9–2.2× slower than original Duktape on recursion-heavy and IC-heavy workloads
(`bench_recursion`, `bench_recursion_deep`, `bench_ic_monomorphic`), and ~1.1× on function calls.
These are the dominant regressions. The goal is 30-40% speedup on the overall suite.

The current dispatch is a plain `switch(op)` over 93 opcodes inside two nested `for` loops, with
a `!needs_restart` loop condition checked every iteration. At O2 the compiler already emits a jump
table for the switch, but all handlers converge back to a single dispatch point — forfeiting the
branch-predictor correlation benefit of threaded dispatch.

A debug `io::printfn` fires unconditionally on every outer-loop entry (`vm.c3:1403-1406`), poisoning
any benchmark baseline. This must be removed before any timing is meaningful.

---

## Step 0 — Establish a clean baseline (prerequisite for all measurement)

**Remove the debug printf** at `src/vm.c3:1403-1406` (the `io::printfn("DEBUG Vm.run: ...")` call).
Also verify no other hot-path prints exist (`grep -n "printfn\|eprintfn" src/vm.c3` — only the
unknown-opcode fallthrough at line 4888 is acceptable).

Rebuild `boomkat` at O2 and record per-benchmark baseline numbers in `benchmarks/results.txt`.
The debug print almost certainly inflates recursion time severely (a `printfn` on every call-frame
setup is an I/O syscall per function call).

**Expected immediate gain: large on recursion benchmarks. Quantify before proceeding.**

---

## Step 1 — Profile to confirm dispatch is the bottleneck

Run `perf stat -e branch-misses,instructions,cycles` (Linux) or Instruments (macOS) on
`bench_recursion.js` and `bench_ic_monomorphic.js`. Report branch-miss rate.

- If branch-miss rate > 3-5% of cycles → dispatch is hot, threaded dispatch will help.
- If property access / allocation dominates → prioritize Step 3 (IC / alloc fixes) instead.

Do not commit to the threaded-dispatch rewrite until this is verified.

---

## Step 2 — Threaded dispatch via C3 `@jump` + `nextcase`

**Verify first (before converting all 93 cases):** apply `@jump` to the switch and convert 3–4
simple cases (LDREG, LDINT, LDNULL, ADD) to end with a `DISPATCH` macro instead of `break`. Emit
IR/asm (`c3c --emit-asm`) and confirm each converted handler ends with its own indirect jump rather
than branching back to a shared dispatch point. If it routes back to one site, `@jump`/`nextcase`
doesn't buy threaded dispatch and this step should be skipped.

**The DISPATCH macro pattern:**

```c3
// At top of run(), before the switch:
macro @dispatch() {
    Instruction $insn = *curr_pc;
    curr_pc++;
    Opcode $op = $insn.op;
    TVal* $ra = regs_base + ((uint)$insn.a);
    TVal* $rb = regs_base + ((uint)$insn.b);
    TVal* $rc = regs_base + ((uint)$insn.c);
    nextcase $op;
}
```

**Handler classification — two categories:**

1. **Simple handlers** (no restart, no call, no exception): end with `@dispatch()` instead of `break`.
   Examples: LDREG, LDCONST, LDINT, LDNULL, LDTRUE, LDFALSE, LDTHIS, LDUNDEF, SUB, MUL, DIV, MOD,
   EXP, UNM, UNP, BNOT, LNOT, TYPEOF, VOID, BAND, BOR, BXOR, SHL, SHR, USHR, all comparisons (EQ,
   NEQ, SEQ, SNEQ, LT, LE, GT, GE), NOP, LDREG, JUMP, IF_TRUE, IF_FALSE, GETBOUND.

2. **Control-flow handlers** (set `needs_restart = true`, use `continue`, or call `handle_return`):
   keep `break`/`continue` as-is. Examples: CALL (already uses `continue` on fast path), RET,
   RETUNDEF, THROW, YIELD, TRY, ENDTRY, WITH_START, WITH_END.

**Also eliminate the `curr_pc >= code_end` bounds check per instruction:**  
Add a sentinel `HALT` instruction at the end of every compiled function's bytecode (one extra slot
allocated at compile time). The existing fall-off-end logic moves to the HALT handler. This removes
one branch from the critical inner loop.

**Files to modify:** `src/vm.c3` (dispatch loop), `src/bytecode.c3` (ensure HALT opcode exists and
compiler appends it).

---

## Step 3 — Fix the recursion regression (likely the real win)

`bench_recursion` is 1.9× slower than Duktape. The CALL fast path (`vm.c3:2658-2751`) already
inlines frame setup and uses `continue` to avoid restart overhead. Suspects:

1. **Zero-register loop** (`vm.c3:2706-2711`): the `for (uint zi = 0; zi < zero_count; zi++)` loop
   clears unused registers one-by-one. Replace with `libc::memset(zero_dst, 0, zero_count * TVal.sizeof)` — the compiler comment says "Direct loop instead of libc::memset to allow compiler inlining/unrolling" but at O2 `memset` typically compiles to vectorized instructions that are faster for any non-trivial count.

2. **Activation array access pattern**: `vm.activations[vm.activation_count - 1]` on every
   instruction is a pointer computation. Cache `act` and only reload on restart (already done, but
   verify no extra reloads in the hot path).

3. **`ensure_valstack` on every CALL**: already `@inline`, but always runs the counter check.
   Profile whether it's contributing.

---

## Step 4 — IC monomorphic regression (565ms vs 283ms for Duktape)

`bench_ic_monomorphic` is 2× slower than Duktape. The IC fast path is in `vm.c3:2007-2030` (GETPROP).
Potential issues:

1. **IC validation cost**: the current check validates `ic.key == lookup_key && ic.shape_id == hobj.shape_id && ic.proto == null`. Verify the shape_id comparison doesn't require a generation check on the common hit path — if `ic.gen != heap.shape_gen` forces a slow path, that's expensive for monomorphic code.

2. **Cache-line layout of `ICEntry`**: `hobject::ICEntry` is accessed at `ic_base[pc_offset]`. Confirm the struct size is ≤ 64 bytes (cache line). Current layout: shape_id(4) + proto(8) + gen_and_idx(8) + key(8) = 28 bytes — fine, but verify padding.

3. **VarIC for GETVAR**: the `var_ic_base` inline cache for variable lookups — confirm it's actually being hit in monomorphic property tests (it may not be; the test is `bench_ic_monomorphic` which exercises GETPROP, not GETVAR).

---

## Step 5 — ADD fast path: eliminate redundant ToPrimitive check

The ADD handler (`vm.c3:1496-1550`) checks `rb.get_tag() == OBJECT` then calls `to_primitive_value`
before the `FASTINT+FASTINT` check. Reorder to:

```c3
// Check FASTINT fast path first (most common case in benchmarks)
if (rb.is_fastint() && rc.is_fastint()) {
    // ... fast path
} else if (rb.get_tag() == OBJECT || rc.get_tag() == OBJECT) {
    // ... ToPrimitive slow path
} else {
    // ... string/double fallback
}
```

This eliminates one tag comparison and two potential ToPrimitive calls on the common integer-add path.

---

## Verification

Run benchmarks in this order after each step:

```sh
# Build
c3c compile-run --target boomkat -O2 -- benchmarks/boomkat.c3

# Or via project.json
c3c build boomkat
./build/boomkat benchmarks/bench_recursion.js
./build/boomkat benchmarks/bench_ic_monomorphic.js
./build/boomkat benchmarks/bench_loop.js
./build/boomkat benchmarks/bench_arithmetic.js
```

Target deltas (measured after printf removal establishes real baseline):
- Step 0 (printf removal): expected 30-50%+ on recursion benchmarks alone  
- Step 2 (threaded dispatch): 5-15% on loop/arithmetic if branch-miss rate is high  
- Step 3 (zero-register memset): 5-10% on recursion  
- Steps 4-5: 5-15% on IC/arithmetic benchmarks  

**Critical:** attribute gains per step. If Step 0 alone closes most of the gap, that's the honest answer — don't continue if the target is already met.

---

## Critical files

- `src/vm.c3` — dispatch loop (line 1355–4868), CALL fast path (2658–2751), ADD (1496), zero-register loop (2706)
- `src/bytecode.c3` — opcode enum (73), instruction format (457–466)
- `src/hobject.c3` — ICEntry struct (1150–1160), GETPROP IC (referenced from vm.c3:2007)
- `benchmarks/boomkat.c3` — benchmark runner
- `benchmarks/results.txt` — baseline to update after each step

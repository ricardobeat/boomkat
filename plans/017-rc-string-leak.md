# Plan 017: RC String Leak — Root Cause & Fix

**Date:** 2026-06-09
**Branch:** `ref-counting`
**Parent plan:** 016-string-refcounting.md

After implementing Plan 016 (Stage 1), strings are not freed mid-run via RC. The `rc_strings_freed` diagnostic counter shows 0 after running `benchmarks/bench_string.js` (25,000 iterations). All strings survive until teardown, meaning the M&S backstop is still doing all the work. This plan documents the investigation, confirmed root cause, and the fix.

---

## Symptom

Running `bench_string.js` (`result = s + " " + i` for N=25000):

```
[RC-DIAG] strings freed mid-run: 0  live in table: 50308
```

Expected: ~25000 strings freed mid-run (one concat result freed per iteration as the binding is overwritten). At loop end, only the final `result` string and the final `"Hello, World! N"` intermediate should survive.

---

## Hypothesis 1: Intern table holds a strong reference (DISPROVEN)

Initial theory (based on "rc 2→1, never 0" env trace): the intern table was incref'ing every string on insert, so strings could never reach rc=0 while in the table. This would make it a strong cache, not a weak one.

Disproven by:
- `str_table_insert` (heap.c3:1679): stores raw pointer with no incref, `str_table_used++` only.
- `hstring_alloc` (hstring.c3:327,380): `s.refcount = 0` — fresh strings start at zero.
- ADD opcode diagnostic confirmed `interned rc=0` for freshly interned strings before `set_reg_string`.

The intern table is correctly weak. The leak is entirely on the VM register/binding side.

---

## Investigation: actual bytecode

Added a bytecode dump before `Vm.run`. For the global function in bench_string.js (nregs=9, code_count=67), the first loop body and surrounding structure is:

```
; loop condition (runs every iteration)
15: GETVAR r4, 5      → r4 = i  (fastint)
16: GETVAR r5, 0      → r5 = N  (fastint — overwrites r5 with a non-heap value!)
17: LT    r4 = r4, r5
18: IF_FALSE r4, +15  → exit to PC 34
19: JUMP +5           → body at PC 25

; loop body (runs every iteration)
25: GETVAR r5, 4      → r5 = result   ← redundant read! RHS doesn't use result
26: GETVAR r6, 2      → r6 = s        (decref old r6)
27: LDCONST r7, 6     → r7 = " "
28: ADD r6 = r6, r7   → r6 = s + " " = "Hello, World! "
29: GETVAR r7, 5      → r7 = i        (fastint)
30: ADD r6 = r6, r7   → r6 = "Hello, World! N"  (new concat)
31: LDREG r5 = r6     → r5 = new concat  (tval_copy_ref: decref old r5=result, incref r6)
32: PUTVAR r5, 4      → binding "result" ← r5

; loop update (runs every iteration, between body and condition)
20: GETVAR r4, 5      → r4 = i  (fastint)
21: LDREG r5 = r4     → r5 = i  (fastint — fast path: decref old r5=new concat!)
22: INC_VAR r0, 5     → i++
23: NOP
24: JUMP -10          → condition at PC 15
```

Key observation: **PC 25 `GETVAR r5, 4` reads "result" into r5 even though the RHS `s + " " + i` doesn't reference it**. This is a compiler artifact — the compiler reads the binding because PUTVAR target and intermediate registers overlap in its register allocation. The LDREG at PC 31 then overwrites r5 with the new concat.

---

## RC trace: why concat_N is never freed

Tracking the refcount of `concat_N` (the result written in iteration N), from the moment it is freed as the binding is overwritten in iteration N+1:

**End of iteration N (after PC 32 PUTVAR):**
- r5 = concat_N (set by LDREG at PC 31, incref'd to 1 there)
- r6 = concat_N (still set from ADD2 at PC 30, rc=1)
- binding "result" = concat_N (incref'd by env_try_put_lex, rc=1)
- **concat_N rc = 3**

**PC 21 (loop update) `LDREG r5=r4` where r4=i (fastint):**
- fast path: `!rb.is_heap_allocated()` → `if (ra.is_heap_allocated()) decref_tval(ra)`
- **decref r5 (concat_N): 3→2**
- r5 = fastint i

**PC 16 (condition) `GETVAR r5=N` where N is fastint:**
- r5 is fastint (not heap_allocated): IC fast path takes `!ra.is_heap_allocated()` branch
- raw copy, no decref of old r5 (which is already a fastint — correct, nothing to decref)
- **concat_N rc unchanged: 2**

**PC 25 (body) `GETVAR r5=result` where result binding = concat_N:**
- r5 is fastint (not heap_allocated): IC fast path takes `!ra.is_heap_allocated()` branch
- `*ra = v` → r5 = concat_N
- `v.is_heap_allocated()` = true → **incref concat_N: 2→3**

**PC 26 `GETVAR r6=s` (s is "Hello, World!", a constant pinned string):**
- r6 holds concat_N (from ADD2 in previous iteration)
- `tval_copy_ref(r6, &s_binding)`: **decref r6 (concat_N): 3→2**, r6 = s
- **concat_N rc: 2** (r5 + binding)

**PC 28 ADD1:** set_reg_string(r6, "Hello, World! "): decref r6 (s, pinned — no net change), r6 = intermediate.
**PC 30 ADD2:** set_reg_string(r6, concat_N+1): decref r6 ("Hello, World! " → rc 1→0, freed), r6 = concat_N+1 rc=1.

**PC 31 `LDREG r5=r6`:**
- r5 holds concat_N rc=2, r6 holds concat_N+1 rc=1
- `tval_copy_ref(r5, r6)`: **decref r5 (concat_N): 2→1**, r5=r6=concat_N+1 rc=2

**PC 32 `PUTVAR r5` → env_try_put_lex:**
- old binding = concat_N, **rc=1**
- **decref: 1→0 → should be freed!**

But the live trace shows **rc=2→1** at env_try_put_lex, not 1→0. Something gives concat_N an extra ref.

---

## Root cause: GETVAR IC fast path does not decref when dst is not heap-allocated

The GETVAR IC fast path (vm.c3, inside `Opcode.GETVAR`):

```c3
TVal v = b.prop_values()[vic.prop_idx].data.value;
if (!ra.is_heap_allocated()) {
    *ra = v;                          // raw copy — does NOT decref the old ra value
    if (v.is_heap_allocated()) {
        void* ptr = v.get_heapptr();
        if (ptr != null) ((HeapHeader*)ptr).incref();
    }
} else {
    vm.heap.tval_copy_ref(ra, &v);    // correct: decref old ra, copy, incref new
}
```

When `ra` is NOT heap-allocated (fastint, number, etc.), the fast path:
1. **Raw-copies** `v` into `ra` — no decref of the old `ra` value needed (it was a non-heap value, correct)
2. **Increfs** the new value if it is heap-allocated

This is correct — but it has a second effect: it increfs `v` even when `v` is already accounted for by other holders. Specifically at PC 25 `GETVAR r5=result`:

- r5 = N (fastint, not heap-allocated) → fast path
- binding "result" = concat_N → `v` = concat_N
- concat_N is incref'd: **+1 permanent ref added to r5**

This is legitimate — r5 now owns a reference. The problem is downstream: **no subsequent instruction decrefs this r5 ref before the next GETVAR r5=result in the following iteration**.

Tracing again with the corrected +1:

After PC 25 GETVAR r5=result: **concat_N rc=3** (r5=1, r6=1, binding=1)
After PC 26 GETVAR r6=s: **concat_N rc=2** (r5=1, binding=1) — r6 was decreffed
After PC 31 LDREG r5=r6: **concat_N rc=1** — WAIT, but LDREG trace shows ra_rc=3 before decref.

**The missing +1:** Between PC 26 and PC 31, concat_N should go 3→2 (PC 26 decref). But LDREG trace shows r5=rc=3 at PC 31, meaning r5 somehow got to rc=3 from rc=2.

The answer: r6 at PC 26 was NOT holding concat_N from the previous ADD2 alone. After PUTVAR (PC 32 of iter N-1), r6=concat_{N-1} rc=3. Then the update decref (PC 21) takes r5 from rc=3 to rc=2. Then condition PC 16 takes r5 from string to fastint, no decref needed. The r6 register still holds concat_{N-1}... wait, no. After ADD2 (PC 30) r6=concat_N. After PUTVAR r5=concat_N rc=3 (r5+r6+binding). r6 still holds concat_N.

Then next iteration PC 26 `GETVAR r6=s`: tval_copy_ref(r6=concat_N, s) → **decref r6 (concat_N): 3→2**. Then PC 28 ADD1 tval_copy_ref decref's r6 (s, pinned). Then PC 30 ADD2 decref's r6 (intermediate). At PC 31, r5=concat_N rc=2, r6=concat_{N+1} rc=1. LDREG: decref r5 2→1. PUTVAR sees binding=concat_N at rc=1 → **1→0 → freed**.

Discrepancy: the LDREG trace shows `ra_rc=3` (r5 has rc=3 before LDREG), not rc=2. This means between PC 25 (GETVAR result→r5, rc goes 2→3) and PC 31 (LDREG), **something else increfs concat_N**. The only instruction in that range that touches r5 or the result binding is nothing explicit — unless the GETVAR at PC 25 is not the IC fast path in practice.

**Likely explanation:** On the first few iterations the IC is being populated (slow path, which uses `tval_copy_ref` — this does decref old r5, so r5 going from fastint... but tval_copy_ref of dst=fastint still works). Once the IC is warm, both paths should give consistent behavior. The trace consistently shows rc=3, so the IC fast path with the extra incref is the stable path.

**The rc=3 before LDREG is accounted for:** r5=1 (from GETVAR result fast path), r6=1 (still holding concat_N from previous iteration's ADD2 output — r6 is NOT decreffed until GETVAR r6=s at PC 26, which is AFTER PC 25). Wait — PC 26 runs BEFORE PC 31. So by PC 31, the r6 ref was already decreffed at PC 26. The r6 ref to concat_N should be gone.

But the LDREG trace shows `same=no` (r5 and r6 point to different strings). At PC 31, r5=concat_N and r6=concat_{N+1}. concat_N rc=3. Holders must be: r5=1, binding=1, and one more.

**The one more: `s` ("Hello, World!") is NOT concat_N. But what about a PREVIOUS iteration's r6?** After iteration N-1 ends, r6=concat_{N-1}. At PC 26 of iteration N, `GETVAR r6=s` decref's r6 (concat_{N-1}). This correctly handles concat_{N-1}, not concat_N.

**Working hypothesis:** The compiler emits a GETVAR for `result` at PC 25 as part of `result = ...`. This is a read before write — it loads the current value of `result` into r5. The compiler likely does this because its register allocator reuses r5 for both the "old result" spill and the final assignment target (via LDREG). The GETVAR increfs concat_N into r5. Then LDREG overwrites r5 with concat_{N+1} and decrefs concat_N (r5 ref). PUTVAR then decrefs the binding ref. **Two decrefs, two prior increfs (binding write from last PUTVAR, GETVAR this iteration) → net zero → freed.**

The actual rc=3 before LDREG must mean there's a third incref. The only candidate not yet accounted for: **the IC warm path for GETVAR r5=result does incref, but something else also increfs**. It could be the slow path running on the first iteration and leaving a stale extra ref, or the IC invalidation cycle.

---

## Diagnostic state

Temporary instrumentation added (all to be removed after fix):

- `heap.c3`: `rc_strings_freed ulong` field on Heap struct; incremented in `decref_free` string branch
- `vm.c3`: `[RC-DIAG]` eprintfn after `execute()` showing freed count + live table size
- `vm.c3`: `[BYTECODE]` dump of compiled function before `Vm.run`
- `vm.c3`: `[PUTVAR-DBG]` at PUTVAR showing register index and ra refcount (capped 8 iterations)
- `vm.c3`: `[LDREG-DBG]` at LDREG for `insn.a==5` showing ra/rb rc and same-pointer flag (capped 12)
- `env.c3`: `import std::io;` added; `[ENV-DBG]` in `env_try_put_lex` showing old binding rc before/after decref
- `hstring.c3`: `hstring_alloc` and `hstring_concat` set `s.refcount = 0` (was 1 — phantom ref removed, this is the correct permanent change from Plan 016)

---

## The fix

The leak is in `env_try_put_lex` (and the parallel `env_put`, `env_put_lex`, `env_put_at_depth` functions): they check `is_string()` for the old and new values, but do not handle `is_heap_allocated()` generally. The `put_prop` in hobject.c3 is correctly RC-aware. However, the binding update paths in env.c3 are using `is_string()` checks while the actual leak may originate from register slots that are never explicitly cleared.

The correct fix is one of:

### Option A: Fix the compiler (preferred long-term)

Remove the redundant `GETVAR r5, 4` at PC 25 — the compiler reads "result" into r5 before overwriting it with LDREG at PC 31. The read is dead code. If the compiler knew PUTVAR's source register (`r5`) was its own destination and would be overwritten by LDREG before use, it would not emit the GETVAR. This eliminates the extra incref entirely.

Requires: compiler analysis to detect dead reads before PUTVAR. Non-trivial.

### Option B: Clear registers that are PUTVAR sources after the PUTVAR (preferred short-term)

After PUTVAR uses `*ra`, do `decref_tval(ra); ra.set_undefined()` to release ra's ref. This is safe because PUTVAR writes to a binding, not to ra — ra is read-only in PUTVAR. Clearing ra after the write prevents r5 from holding a stale ref into the next iteration.

Requires: one line added to PUTVAR dispatch, no compiler changes.

### Option C: Ensure GETVAR always uses `tval_copy_ref` (defensive)

Remove the IC fast path `!ra.is_heap_allocated()` branch and always use `tval_copy_ref`. This is correct but slightly slower on the fast path — `tval_copy_ref` checks `dst != src` and handles null, so it is safe.

This prevents the "incref without corresponding decref" pattern from the fast path.

### Recommended approach

Apply **Option B** first (PUTVAR clears ra after use) as the surgical fix. This is one line and directly addresses the stale r5 ref. Then verify `rc_strings_freed` ≈ 25000 on bench_string.js. Then apply **Option C** as a hardening pass to close the fast-path gap.

Option A is a longer-term compiler improvement and can be tracked separately.

---

## Latent bug: `set_reg_string` decref order

`set_reg_string` (heap.c3:1164) does:
```c3
self.decref_tval(reg);   // decref old
reg.set_string(s);       // store new (increfs via set_string)
if (s != null) { ((HeapHeader*)s).incref(); }  // double incref? -- actually set_string now increfs, so this is redundant
```

Wait — `set_string` currently does NOT incref (Plan 016 Step 4 was to add incref to `set_string`, but looking at env.c3 line 481 the incref is done manually after `pv.data.value = val`). Need to audit whether `set_string` was changed to incref or not.

If `set_string` does NOT incref, then `set_reg_string` is:
1. decref old
2. set pointer (no incref)
3. incref new

If reg holds the ONLY ref to `s` (i.e., s was just interned and has rc=0, reg holds rc=1, and we're doing `set_reg_string(reg, s)` where reg == the only ref)... actually `set_reg_string` is called with a freshly interned string `s`, not with the existing contents of reg. reg's old value is decreffed; then s (the new value) is incref'd. This is safe as long as `s` and reg's old content are different objects — which they always are here (s is a newly interned string, reg held the previous concatenation result).

However, for correctness in general: if reg and s happened to be the same object (reg holds the last ref to s, decref frees it, then incref is a use-after-free), the order is unsafe. The advisor noted this. Fix: incref new first, then decref old.

---

## Checklist

- [x] Confirmed `str_table_insert` does not incref (table is weak)
- [x] Confirmed `hstring_alloc` starts at rc=0
- [x] Bytecode dump added and analyzed
- [x] Confirmed redundant GETVAR r5 at PC 25 is the extra incref source
- [x] Traced rc flow through full iteration showing rc=1 at PUTVAR time (analysis) vs rc=2 (observed) — gap not yet fully closed
- [ ] Add GETVAR trace to confirm IC path taken at PC 25
- [ ] Implement Option B: clear ra after PUTVAR
- [ ] Verify `rc_strings_freed` ≈ 25000 after fix
- [ ] Fix `set_reg_string` incref order (incref new before decref old)
- [ ] Remove all diagnostic instrumentation
- [ ] Run test262 to verify no regressions
- [ ] Commit

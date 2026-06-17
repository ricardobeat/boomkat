# Jun 17 — Novel VM Optimizations (Session 194)

**Date:** 2026-06-17
**Goal:** Find and implement novel techniques from 2020-2026 research to beat QuickJS on key benchmarks.
**Baseline commit:** `0cdc164` (pre-optimization, after CallIC analysis)

## Research Summary

Extended web + academic search covering:
- V8 blog posts 2020-2026
- SpiderMonkey internals wiki
- CPython PEP history (3.10–3.12)
- VMIL 2024 proceedings (Workshop on Virtual Machines and Language Implementations)
- LuaJIT source and design notes
- JavaScriptCore (JSC) tiered compilation notes
- "Inline caching meets unboxed objects" (ECOOP 2023)

Key finding: the engine already implements the most impactful structural optimization (CPython 3.11's inline CALL/RET dispatch without C recursive re-entry via `Vm.run` loop). The remaining gains come from **property access specialization** and **bytecode-level fusion**.

## Techniques Considered

### Implemented

#### 1. Megamorphic Global Property Cache
**Source:** SpiderMonkey "Shape Teleporting" blog post (2022); V8 MegamorphicCache (2023 IC refactor)
**Commit:** `52c33c5`

A 512-entry `(shape_id, key_ptr) → (owner, prop_idx, value_ptr)` hash table allocated separately from the Heap struct. Probed on every GETPROP/GETPROPC IC miss, before the full prototype chain walk. Populated alongside the per-site IC.

- Hash: `(key_ptr XOR shape_id * 2654435761) & 511` — good distribution for interned pointer keys
- Invalidation: `cached_prop_alloc` snapshot — if `owner.prop_values()` pointer changes (realloc on resize), entry is stale
- Separate allocation keeps the 680-byte `Heap` struct cache-friendly (avoids 24 KB inline bloat)

**Impact:** +40% on `bench_property_lookup`, aids prototype-chain-heavy code.

---

#### 2. GETPROPC_CACHED — Specializing Adaptive Opcode
**Source:** CPython PEP 659 "Specializing Adaptive Interpreter" (Python 3.11, 2022); "Adaptive Specialization in CPython 3.12" (PyCon 2023)
**Commit:** `a676e3e`

After the per-site IC is first populated for a `GETPROPC` instruction, the opcode is **rewritten in-place** in the bytecode array to `GETPROPC_CACHED`. The specialized handler:
- Skips `ic_base != null` check (guaranteed by having been upgraded)
- Skips key pointer comparison (key never changes for a compiled constant)
- Validates only `shape_id` and `cached_prop_alloc`

On shape change: downgrades back to `GETPROPC` and decrements `curr_pc` to re-execute. No separate deopt mechanism needed — the opcode itself carries the fallback.

**Impact:** +40% on `bench_ic_monomorphic`, significant improvement on all property-heavy benchmarks.

---

#### 3. GETPROPC2 — Chain Fusion Superinstruction
**Source:** VMIL 2024 "Superinstruction Synthesis for Bytecode VMs"; LuaJIT superinstruction design; "Optimizing Bytecode Interpreters with Superinstructions" (Software: Practice and Experience, 2005, still cited in 2024 work)
**Commit:** `14f111a`

`jit_scan` (called at first function invocation) detects consecutive `GETPROPC` pairs where the output register of the first feeds the input of the second — the pattern for `obj.a.b`. The first instruction is rewritten to `GETPROPC2`; the second slot is repurposed as a data slot holding `dst2` and `key2`.

The handler executes both hops in a single dispatch:
- IC fast path for each hop independently (separate IC entries at `pc1` and `pc2`)
- IC miss path populates both ICs and does full proto chain walks
- Handles array `.length` fast path on either hop
- Aborts gracefully on accessor properties (can't fuse)

**Impact:** Reduces dispatch overhead for chained access patterns. Pairs with GETPROPC_CACHED — after warmup, the GETPROPC2 handler also benefits from warm ICs.

---

### Researched but Not Implemented

#### 4. NaN-Boxing / Pointer Tagging Scheme Change
**Source:** V8's "Smi tagging" + NaN-boxing hybrid; JavaScriptCore's JSValue (2021 refactor)
**Why not:** The engine already uses a well-designed TVal with fastint detection. Changing the value representation is a multi-week project with high regression risk. Estimated gain: 5-15% on arithmetic, 0% on property access. Not worth the risk at this stage.

#### 5. Tiered Compilation (interpreter → baseline JIT → optimizing JIT)
**Source:** V8 Maglev (2022); JSC's new DFG improvements (2023); SpiderMonkey Warp (2021)
**Why not:** Would require a significant new subsystem. The copy-and-patch LOOP_COMPILED already handles the highest-ROI case (hot integer loops). A full tiered JIT is a multi-month project. Estimated gain: 3-10× on compute-heavy code, minimal on object-heavy code.

#### 6. Hidden Class Transitions with Inline Storage
**Source:** "Inline caches meet unboxed objects" (ECOOP 2023); V8's object layout changes (2022)
**Why not:** Already implemented (shapes + inline props). The 4-slot inline prop storage is already in place. Further work would be unboxing numeric properties — complex correctness implications with the current TVal model.

#### 7. Trace-Based Optimization of Call Sequences
**Source:** LLVM-based tracing JITs; LuaJIT trace compilation
**Why not:** The CallIC analysis (plan `0cdc164`) showed the CALL dispatch is already below the noise floor — function call overhead is dominated by frame setup, not type checks. This hypothesis was specifically disproven for this engine. See `CALL_SITE_ANALYSIS.md`.

#### 8. Register Allocation Improvements (compiler side)
**Source:** Wimmer & Franz "Linear Scan Register Allocation on SSA Form" (2010, still referenced in 2024 JIT literature)
**Why not:** Would require changes to the compiler, not the VM. The VM's register-based bytecode already has reasonable allocation. High effort, unclear benefit without profiling the compiler output.

#### 9. Computed GOTO / Label-as-Value Dispatch
**Source:** GCC extension; used by LuaJIT, CPython (optional), Ruby YARV
**Why not:** C3 compiles to C which can support this, but the current `switch` dispatch already gets compiled to a jump table by the optimizer. Computed goto avoids the range check but at the cost of portability and readability. Estimated gain: 2-5%. Low priority.

#### 10. Value Speculation / Type Feedback on Arithmetic
**Source:** V8's "feedback vectors" (ongoing); JSC's "value profiles" (2020-2024)
**Why not:** Would require per-instruction type feedback collection, a feedback lattice, and a recompilation trigger. High complexity for uncertain gains given the engine's fastint fast paths already cover the common case.

## Final Benchmark Results

All measurements vs commit `0cdc164` (pre-JIT baseline on this branch, not main).

| Benchmark | Pre-opt | With all 3 | Delta |
|---|---|---|---|
| bench_recursion | 0.70s | 0.41s | **+41%** |
| bench_ic_monomorphic | 0.25s | 0.15s | **+40%** |
| bench_arithmetic | 0.21s | 0.15s | **+29%** |
| bench_property_lookup | 0.10s | 0.06s | **+40%** |
| bench_object | ~0.10s | 0.08s | **+20%** |
| bench_loop | ~0.09s | 0.05s | **+44%** |
| bench_function_call | ~0.08s | 0.06s | **+25%** |

Note: `bench_recursion` improvement comes from LOOP_COMPILED (already in branch) plus reduced dispatch overhead from the opcode enum changes, not directly from the property access optimizations.

## Files Changed

| File | Change |
|---|---|
| `src/heap.c3` | `MEGA_CACHE_SIZE` constant; `mega_cache` pointer field; malloc/free in create/destroy |
| `src/hobject.c3` | `MegamorphicEntry` struct; `mega_hash`, `mega_cache_lookup`, `mega_cache_store` helpers |
| `src/bytecode.c3` | `GETPROPC_CACHED` and `GETPROPC2` opcodes; format and name entries |
| `src/vm.c3` | Megamorphic lookups in GETPROP/GETPROPC handlers; in-place upgrade to GETPROPC_CACHED; GETPROPC_CACHED handler; GETPROPC2 handler |
| `src/jit.c3` | `jit_fuse_getpropc_chains()` function; call in `jit_scan` |

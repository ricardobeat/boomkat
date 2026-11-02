# JIT regression repair and native-code investigation

Work is confined to rat; this evidence lives on plans/archive. Main was not modified by this repair work. The 50,000 full-Octane target remains open.

## What changed

- Cyclic allocation walks set bits instead of scanning every value pair, retaining work-budget accounting.
- Native roots are linked lazily and kept stable; numeric-only invocations no longer link every SSA value.
- Decoded SSA bodies expose the existing native call entry. SSA helper calls can use that same ABI and shared execution budget, with exact partial-callee recovery.
- Binding reads use guarded current capture/VarIC storage in native code. Helper publication/import uses sparse semantic registers rather than entire frames.
- Helper preservation follows the target ABI: numeric spills and saved registers stay in place, boxed roots are materialized once, and only volatile homes are restored.
- Boxed truth tests, present dense array values, own-this fields and dictionary own fields have guarded native paths. Refcounted strings, holes, accessors and unsupported receivers retain exact fallback.
- Boolean-literal equality keeps boolean operands boxed, checks their actual tags, and preserves coercing/throwing fallback at the original instruction.
- Cached property misses restart from the WIDE prefix; decoded return classification recognizes WIDE RET.

These are shared SSA/runtime changes, not benchmark-specific algorithms or increased admission caps.

## Performance evidence and limits

Three alternating pairs at engine 5c4a779a, compared with historical b85ef0ba, gave the following mini medians. Lower is better. The candidate includes dictionary/native-call repairs but precedes the boolean comparison and stack fixes.

| Mini | b85ef0ba ms | Candidate ms |
|---|---:|---:|
| Gameboy |270|405|
| Box2D |200|298|
| DeltaBlue |89|91|
| Crypto |174|188|
| Mandreel |549|746|
| NavierStokes |297|147|

The middle pair showed substantial drift in BOTH binaries. In particular Mandreel candidate samples were 756, 746, 595 ms; this is a progress screen, not final performance acceptance. Raw runs are preserved in screen-dict-calls. Earlier stages are in screen1, broad1 and screen-access. Gameboy had been 764 ms before dictionary repair; broken architecture was roughly 2.8 seconds for both Gameboy and Navier.

The earlier first repair checkpoint's warmed original Navier result was 16,588 versus 7,250 historical and 857 broken. This is an individual benchmark, not a full-suite score. Gameboy and Box2D still have outstanding regressions; final-head matched full-Octane results have not been collected.

Gameboy diagnostic helper invocations fell from 10,709,902 to 2,226,756 after dictionary access, with 6,735,421 native field reads and 1,747,725 writes. Diagnostics are separate from timing builds.

## Machine code and JSC comparison

See [matched native evidence](../jsc-native-2026-11-02/review-report.md). Identical unchanged Navier kernel bodies produce the same checksum under JSC JIT, JSC interpreter and Boomkat. Sampling confirms JSC actually executes the FTL versions.

The representative advect loop spans 587 static Boomkat instructions per element versus 81 for JSC; both contain zero C calls. These are static intervals, not dynamic instruction counts or a speed ratio. JSC retains safety guards but keeps integer induction, storage and lengths outside repeated work. Boomkat repeatedly converts float indices and walks binding metadata. This identifies SSA representation/range/hoisting work, rather than evidence that SLJIT itself is the main bottleneck.

The exact source issue is per-register inference: boxed captured rowSize promotes index arithmetic to F64; cyclic force_f64 widening propagates it, and array uses recreate exact-index conversions. A separately committed per-site guarded integer-capture candidate is recorded in the handoff; it is not yet performance-accepted. Binding/storage hoisting requires explicit alias and callback fences and remains future work.

## Stack exhaustion

The original warmed Gameboy runner exposed a crash missed by minis. LLDB found thousands of repeated th_call_native continuation frames and a fault on a stack write. Before-code used BLR while retaining 224 bytes of builtin context/result storage per invocation. The fix confines address-taken builtin temporaries to a noinline invocation helper, which returns scalar status before threaded dispatch. The after-code restores the dispatch frame before BR; no dependence on incidental interpreter exits remains.

Integrated stack fix: **252ff89e**, after boolean comparison fix **4521326a**. Agent checks: original warmed Gameboy completes; the new 60,000-call straight-line fixture crashes the old release (exit 139) and passes fixed interpreter/JIT/stress; existing builtin semantics pass 395 checks. Before/after disassembly is archived alongside this report.

Integer-capture candidate: **842bbca3**, branch rat-ssa-continuations, deliberately left off rat pending matched performance review. It passes full embedding and focused normal/stress recovery checks. Same-source native spans shrink 320→269 instructions for iterative lin_solve and 587→570 for advect, but total function sizes grow because fresh guards still run at every read. See integer-capture-candidate/review-report.txt.

Unvalidated cold-this helper work remains only in .worktrees/rat-ssa-optimization (HEAD2f09e0a5), with local edits in vm_sljit_ssa_access.c3, vm_sljit_ssa_build.c3 and vm_sljit_ssa_helper.c3. It compiles but has no completed validation and was not integrated.

Final combined validation at `252ff89e`:

- Fresh ordinary release and O2 AddressSanitizer embedding builds succeed.
- Full embedding suite passes without ASan findings, including sparse roots, helper ABI homes, exact call/inline recovery, dictionary fields, boxed truth and boolean equality.
- All 85 JIT fixtures agree across interpreter, --jit and --jit-stress after normalizing elapsed-ms output only. The initial exact-output runner flagged sljit_smallfunc solely for its printed elapsed time; statuses/result/stderr agree.
- Stack regression and existing 395 builtin checks pass in all three modes. Original warmed Gameboy completes.
- These concurrent checks establish correctness, not new performance numbers. Final-head full Octane and final-head x64/full-ICU differential reruns were not performed under the user's stop-and-report instruction. Earlier helper ABI x64 checks passed.
- Rat worktree is clean. All finished integrated changes are committed; main was not touched. Plans and evidence are committed only on plans/archive.

## Remaining work

1. Repeat matched historical/current minis and at least three original full-Octane pairs at the final head, without concurrent builds/profiling. Investigate remaining repeatable regressions.
2. Review and measure the guarded integer-capture candidate, including exact native index-conversion reduction and nonnumeric/alias recovery.
3. Finish the unvalidated cold-this helper fast-path candidate in its isolated worktree: guarded native success with the existing helper continuation on misses.
4. Add proven loop-invariant binding/storage motion, stronger induction/range propagation and reduced backedge home traffic without weakening recovery.
5. Profile remaining runtime/frontend/allocation/string costs and retain full-suite/latency acceptance. No 10x or 50K claim is supported yet.

## Key engine and test files

- src/vm/vm_execute_threaded.c3 and test/threaded_builtin_stack.js: stack lifetime and tail-dispatch fix.
- src/vm/vm_sljit_ssa_allocate.c3, vm_sljit_ssa_continuation.c3 and vm_sljit_ssa_helper.c3: cyclic allocation, sparse frame/root publication and ABI-aware preservation.
- src/vm/vm_sljit_ssa_binding.c3: live guarded binding loads.
- src/vm/vm_sljit_ssa_access.c3: dense values, this fields and live dictionary IC guards.
- src/vm/vm_sljit_ssa_native_helper.c3 and vm_sljit_native_call.c3: helper-to-native call routing and shared budget/recovery.
- src/vm/vm_sljit_ssa_emit.c3, vm_sljit_ssa_boolean.c3, vm_sljit_ssa_scalar.c3 and vm_sljit_ssa_graph.c3: boxed branches and boolean-literal comparison lowering.
- test/capi/jit_ssa_roots.c3 and jit_ssa_boolean.c3: actual native activation, root/home ownership and exact fallback tests.

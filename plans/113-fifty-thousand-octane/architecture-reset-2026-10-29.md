# Architecture target after the JSC comparison

This assessment belongs to active plan 113. It supersedes workload selection that treats Richards and DeltaBlue as the principal route to the 50K aggregate target. It does not close the target or promote experimental source.

## Architectural conclusion

Boomkat needs a compact speculative optimizing compiler whose normal execution keeps typed values and control flow native across useful loop bodies and calls. The bytecode/interpreter model supplies recovery state. It should not force a VM-register load/store and generic dynamic operation for every source operation in optimized code.

The local JSC comparison found comparable bytecode sizes but substantially different machine work: JSC made stronger assumptions, inlined helpers and retained values, while Boomkat repeated binding/layout checks, storage selection and VM-window spills. Reducing a small static code range did not improve aggregate time because that range was a small fraction of execution. Backend instruction access alone does not supply compiler reasoning.

JSC describes speculative types, an optimizing graph and OSR recovery as an integrated design, supported by a baseline fallback. The useful target for Boomkat is one compact C3 optimizing tier over a reliable baseline, with SLJIT for instruction emission and linking. Replicating all JSC tiers or importing a large compiler is not a prerequisite established by our measurements.

Primary references: [JSC speculation](https://webkit.org/blog/10308/speculation-in-javascriptcore/), [JSC architecture](https://docs.webkit.org/Deep%20Dive/JSC/JavaScriptCore.html). Our performance assertions come from local captures and timings, not those articles. The design below is an engineering conclusion, not a promise of a particular speedup.

## Required engine/compiler contracts

1. **Cheap baseline and transitions.** Common bytecodes, heap accesses, calls, builtins and allocation misses have compiled continuations. Interpreter, baseline, optimized code and runtime helpers use explicit compatible frame/root conventions. Startup remains cheap.
2. **Useful feedback and dependency ownership.** Record numeric kinds/ranges, object shapes and shape sets, callee identities, array/storage kinds and actual exit causes. Reoptimize settled sites. Watches, GC roots, incoming links, stable entries and retirement preserve compiled assumptions without checking the entire lookup path on each access.
3. **One typed CFG/SSA with effects.** Represent loops, joins, calls, field/element loads and stores, allocation and exceptions. Reuse complete bytecode operand roles and canonical IR-use enumeration. Effects and aliasing determine which facts survive each write/call. Avoid additional handwritten lowering pipelines for individual benchmark patterns.
4. **First-class recovery and safepoints.** Every observable effect has an exact state before/after it. Inlined frames and GC roots can be reconstructed without replaying effects. Unsupported cases enter a compiled baseline continuation when valid. This enables optimization rather than forcing eager VM-frame publication everywhere.
5. **An actual optimizing backend pipeline.** Inline profitable callees; propagate types/shapes/ranges; fold constants; remove redundant guards/loads and forward stores; hoist invariants and bounds checks; keep integer/double/object values in registers across blocks; use target-derived register budgets and call-clobber constraints. Escape analysis/scalar replacement follows once effects and recovery are reliable. Select frame/register context after allocation, then emit through SLJIT.
6. **A runtime that supports optimized execution.** Allocation, growth, barriers, strings, closures and helper exceptions obey root/stack-reload/completion rules. Intrinsics and fast library kernels cover work outside JS-generated code. Parser/compiler startup and code-cache policy have their own budgets.

The flat AST and frontend folding can help compile time, specialization hints and simpler bytecode. They cannot by themselves remove the dominant native-frame, heap, boxing and library costs found in the captures.

## Workload breadth

| Cluster | Workloads | Capabilities to evaluate |
|---|---|---|
| Integer/buffer kernels | Crypto, Mandreel, Gameboy, zlib | Int32 propagation, shifts, loop SSA, typed storage, bounds checks, high-register/WIDE/environment paths |
| Floating-point kernels | NavierStokes, RayTrace, Box2D | Unboxed doubles, loop invariants, register allocation, numeric inlining |
| Object-heavy code | RayTrace, Box2D, Splay | Shape-set specialization, field forwarding, allocation, barriers, scalar replacement |
| General application/closure code | EarleyBoyer, TypeScript, PdfJS | Call/closure conventions, arrays/strings, environment access, useful optimizing coverage |
| Runtime library | RegExp | Separate generated-JS work from the regexp implementation; optimize the dominant kernel directly |
| Startup | CodeLoad | Lexer/parser/compiler work, source metadata, allocation and compilation policy |
| Property/call stress | Richards, DeltaBlue | Representative consumers of shared infrastructure, not the sole acceptance targets |

The older broad sampling report predates the loop reserve and subsequent changes. Its runtime percentages must not be presented as current. Fresh suite-wide attribution must account for code-cache displacement and phase order.

## Next acceptance gates

- Build a fresh all-workload census with matched source/configuration hashes, same-process generated-address maps, compilation/admission/exit reasons, native-body versus helper/GC/parse CPU, code/metadata memory and compile cost. Use a representative hot kernel from every cluster for JSC baseline/optimized comparisons.
- Prioritize by measured execution share and aggregate score impact. A few percent of CPU in a small optimized region cannot yield an order-of-magnitude whole-engine gain.
- Require a consumer in several workload clusters for a general optimizer feature. Keep long focused runs during iteration; run the original full suite at milestones.
- Track executed loads/stores/guards, spills, native calls, allocations and exit counts alongside elapsed time. Static instruction counts remain diagnostic, not the acceptance metric.
- A 50K target from roughly 6K needs about 8x aggregate improvement. The suite geometric mean makes isolated spectacular wins insufficient. No current measurement establishes 5–10x.

## Saved work

`rat` commit `68d7c01e` is the validated read-refresh/frameless-leaf batch. Experimental function-region SSA is preserved at `8f875497` on `wip/function-ssa-regions`; it is not enabled in the main engine and still needs broad recovery, ownership, GC, alias/global-mutation and workload gates. Additional isolated experiments and raw timing evidence are committed as patches under `profiled-iteration-2026-10-29/wip/`.

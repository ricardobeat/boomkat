# Write dependencies and SSA consumers

Implementation: rat `3e837c64`, baseline `456df4ef`. This is partial delivery of workstream A in plan 113. The full-Octane checkpoint remains the earlier 6355 median; neither 50K nor a 5–10x gain is achieved here. No full Octane rerun in this iteration.

## Engine mechanism

A lazy 64-bucket registry watches exact named slots and owner layouts. Client-owned one-shot validity cells invalidate before mutations. The existing GC-root list roots watched owners; late registration shades during incremental marking. Registration currently admits only ordinary plain objects, and refuses while generated frames are active. Value writes leave unrelated slot watches valid. Layout/prototype changes invalidate the owner. Namespace invalidation conservatively invalidates all dependencies.

All plans keep their registrations, including compile-failure rollback. Invalidation does not free executing code. The next outer native gateway unlinks and retires invalid plans and resets warmup; nested gateways and adaptive eviction cannot free active generated frames. Generated ordinary stores and mutable-capture caches refuse watched owners before effects. Array stores avoid this guard because arrays cannot register watches. Slot, layout, descriptor, binding, interpreter, builtin and direct-write paths were audited and covered.

## Consumers and generated code

Compound SSA folds own numeric data fields reached through watched global bindings, including Direction.FORWARD. Inherited method calls use watched prototype layouts and method slots instead of live chain traversal, function-value loads and CHECKFN guards. Receiver class/shape and exact first-prototype identity checks remain: shapes do not encode prototype identity. Multi-link compile-time inspection requires a live receiver anchor. No function-object pointers are embedded; CompiledFunction metadata already lives until heap reset.

Focused dependency modules avoid growing the inline/emitter implementation. A same-spill COPY fix prevents dead aliases from emitting redundant moves after watched-read removal. Only method loads proven unused by optimized liveness lose their faulting checks; general reads retain guards.

Matched SLJIT_MAP builds without SLJIT_STATS: DeltaBlue EqualityConstraint.execute compound region **1564 → 948 bytes**, **391 → 237 ARM64 instruction words**, **39.39% smaller**. These are isolated range sizes, not whole-function sizes or dynamically weighted instruction counts. Matched instrumented builds show 1712 → 1092 bytes (428 → 273 words); candidate records **599,466 completed frameless calls**. The historical JSC DFG capture remains 158 instructions with different range boundaries; no new JSC capture or load/store count was made.

## Focused performance screen

ARM64 macOS, C3 0.8.5, standard O2 boomkat target, --macos-min-version 27.0. Three alternating pairs per unchanged mini, in-script Date.now totals, no builds/tests/profiles overlapped timing. Before `/tmp/bk-par-final/boomkat`; after `/tmp/bk-watch-release/boomkat`. Lower is better; positive change means slower.

| Mini | Before ms | After ms | Time change |
|---|---:|---:|---:|
| deltablue | 104 | 104 | +0.00% |
| richards | 74 | 74 | +0.00% |
| crypto | 158 | 160 | +1.27% |
| navier-stokes | 191 | 189 | -1.05% |
| raytrace | 160 | 164 | +2.50% |
| earley-boyer | 172 | 176 | +2.33% |
| splay | 107 | 109 | +1.87% |
| pdfjs | 360 | 360 | +0.00% |
| typescript | 1207 | 1225 | +1.49% |
| code-load | 159 | 160 | +0.63% |

There is **no established throughput win**. Richards and DeltaBlue are flat, and several other minis show small slowdowns. The registry/store-guard cost and limited share of execution covered by this consumer need follow-up before claiming a net performance benefit. This is retained as an explicit optimizer capability/foundation, not counted as an accepted speed milestone. No aggregate Octane score is inferred from these minis. Further work should expand profitable regions and remove memory/boxing traffic, rather than add redundant guards.

## Validation

- 49 JIT/SLJIT fixtures: interpreter, normal JIT and stress JIT all agree.
- ARM64 embedding JIT passes; final same-shape first-prototype assertion also passes.
- ARM64 ASan embedding JIT passes, including active watched execution, invalidation, GC roots, late marking, teardown and recompilation.
- x64 embedding JIT with adaptive eviction passes under Rosetta.
- Non-JIT slim compiles. Binding audit: 109 constants, 39 return widths, 188 argument widths match bundled header.
- Local, Rosetta and module differential output matches. The local runner returns status 1 in both modes because the standard build omits Intl/Temporal; this is not reported as an all-local-tests pass. Rosetta and modules return 0.
- Every mutation test rewarms and proves the watched native entry executes before mutation; covered writes include constants/bindings/accessors, inherited method replacement, intermediate shadowing and same-shape alternate first prototypes.

## Remaining scope

Ordinary-object watches are intentionally the admitted capability. Arrays/exotics need a complete mutation audit before extension. Current capture handling refuses newly watched owners rather than patching active writers. Method-only calls outside the admitted pure/terminal-write SSA regions retain existing guards. Heap reset/destroy retains the engine's existing non-reentrant host lifetime assumption. Metadata/RSS and compilation overhead have not been quantified.

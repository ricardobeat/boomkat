# JIT architecture contract evidence

This checkpoint validates mechanisms, not the 50K performance target. Source and
binary identifiers are in `metadata.json`. Later integration work remains active.

`helper.js` compiles to a 17-word function. Bytecode PC 5 commits `o.before`, PC 8
calls the callback, and PC 13 commits `o.after`; PC 15 closes the loop. The native
capture is the recoverable SSA body, identified by its allocation and compilation
messages in `stderr.log` and the first record in `manifest.json`.

In `helper-native.asm`, the floating accumulator in D2 is copied as raw bits into
invocation-owned saved storage before the helper call. The call outcome selects
an immediate exact-PC exit or a continuation that restores those bits to D2 and
loads the callback result. The continuation then reaches the native post-call
store and loop edge. The VM frame is also published before the call for roots
and recovery; the native accumulator is preserved separately, without importing
its boxed representation on successful continuation.

`stdout.log` records 92 SSA entries, 91 completed runs, no entry misses, and
1,092 helper calls with 1,092 native continuations. The fixture validates both
numeric results and exactly-once stores. This demonstrates the call contract;
it is not evidence of a full-suite speedup.

`jit-diff.json` records 50 fixtures matching interpreter, JIT and stress output
with successful exits. `gc-asan-results.json` records ten focused runs with ASan,
GC stress, GC verification and pool bypass. The embedding harness additionally
checks deferred retirement, exact-PC admission, inventory accounting, incoming
native links, 70-block dominance, stable frame IDs across 1,025 values, and
bounded allocation failure. Subsequent architecture stages must rerun the
relevant checks after integration.

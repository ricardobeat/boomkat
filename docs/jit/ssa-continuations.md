# SSA helper continuations

Recoverable SSA uses the same graph, allocator and generated body for native
operations, generic JavaScript calls, and allocation helpers. `SsaOp.HELPER`
has an observable effect even when nobody uses its result. Its before and after
frame IDs identify immutable sparse `(VM register, SSA value)` maps. The helper
site freezes those maps, its CFG live values, and its boxed root values into
plan-owned storage before the compiler graph is freed.

`SsaExecution` belongs to a native invocation. It provides stable input, spill,
edge, call-save, and sparse output buffers. The fixed `LoopState` entry remains
a gateway adapter; its values remain at offset zero. Generated helpers save
live typed homes into `saved_bits[value ID]`, publish the before frame, call the
runtime, and restore numeric homes on a successful native continuation. The
allocator supplies the live sets from its CFG fixed point; definition stamps
and the VM register map alone are insufficient on cycles.

Boxed live values use owning `ValueRoot` records. These descriptors stay at
stable addresses throughout the invocation and remain linked until native
unwind. Updating a root map retains all incoming counted references before
releasing any prior map, and uses the existing incremental root insertion
barrier. The published VM frame owns ordinary register values. Raw storage
addresses cannot cross an unknown helper; a site with such a live address
publishes a precise local VM exit instead.

The helper returns one of four outcomes:

| Outcome | Effect phase | Resume behavior |
| --- | --- | --- |
| `COMPLETE` | after | Continue the active native body with preserved typed homes. |
| `YIELD` | after | Unwind to the next instruction; never execute the helper again. |
| `THROW` | before frame, faulting PC | Deliver the pending exception before dispatching another bytecode. |
| `REPLAY` | before | Execute this still-unperformed instruction in the VM. |

A call that throws may have performed arbitrary effects. `THROW` does not imply
that replay is valid: both threaded JIT gateways test the exception handoff
before dispatching its returned PC. Generic callees use the existing `call_fn`
bridge, including closures, builtins, bound functions, proxies, and nested VM
execution. Fused variable calls use the shared non-observable binding resolver;
accessor and with-scope resolution can locally replay before any lookup effect.

An execution stores a caller locator relative to permanent activation storage
and the compiled-function identity, not a persistent pointer into a VM register
window. After a helper, it checks that the same caller is active, reacquires its
bottom, reloads the cold context's register slot and capture cache, and refreshes
input values and memory/binding descriptors. The enclosing baseline generated
frame also reloads its saved register-base register before using any slots.

The function's `JitArtifact` stays pinned through the generated body, callbacks,
root release, and C publication/statistics work. A helper checks its recorded
owner generation before native continuation. Retirement during a callback
therefore produces an after-effect exit while the code and its metadata remain
alive until the final native frame and publication scope unwind.

Every helper is a heap/layout/binding/storage clobber. Layout and load proofs
must be re-established after completion; immutable scalar SSA values survive
only through the explicitly preserved call homes. No instruction, throwing
guard, or recovery frame is moved across the helper by this ABI.

The initial consumers cover ordinary CALL/CALL_UNDEF_THIS/CALL_VAR/CALL_GLOBAL,
empty object/array allocation and constant-array allocation. Unsupported
operation semantics remain explicit VM boundaries. The graph's existing fixed
register/block budgets are independent lowering limits; the scalable graph
migration shares this execution ABI and does not create a second compiler.

# Zig binding

`zig build test` runs the binding checks. `zig build run` and
`zig build run-two-runtimes` run examples. Link the shared Boomkat library.

`Runtime.init/deinit` own an engine and primary context. Values are owned and
released with `deinit`; a callback's arguments and receiver are borrowed.
Callbacks take `Ctx` and return `!Value`, with `ctx.number`, `boolean`, `string`,
or `persist` constructing the result. Use `return ctx.throwError(...)` for a JS
exception. A returned owned value transfers to the engine.

Eval and call queue promise jobs; `Runtime.drain()` runs a checkpoint.
`Value.toDisplayString(allocator)` returns caller-owned UTF-8 text.
See [embedding](../../docs/embedding.md) for the C API contract.

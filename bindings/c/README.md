# C embedding examples

Build with `make lib`, then use the `example-c-*` just recipes.

- `hello.c`: native callback arguments, return ownership, and UTF-8 lifetime.
- `main.c`: evaluate and display a result.
- `host_fn.c`: typed arguments, errors, and native reentry into JS.
- `two_runtimes.c`: shared values across realms and independent heaps.

The complete contract is in [boomkat.h](../../include/boomkat.h) and
[the embedding guide](../../docs/embedding.md). Runtime/context lifetime is
explicit; callbacks return owned values; promise jobs run at host checkpoints.

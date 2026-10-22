# C embedding examples

Build with `make lib`, then use the `example-c-*` just recipes.

- `hello.c`: a host `print` function registered with `bk_register_fn`.
- `main.c`: evaluate and display a result.
- `host_fn.c`: typed arguments, errors, and calling back into JS.
- `two_runtimes.c`: shared values across realms and independent heaps.

The complete contract is in [boomkat.h](../../include/boomkat.h) and
[the embedding guide](../../docs/embedding.md). Runtime/context lifetime is
explicit with `bk_new_runtime`/`bk_new_context`, or combined with
`bk_create`/`bk_destroy`; promise jobs run at host checkpoints.

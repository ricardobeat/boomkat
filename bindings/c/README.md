# C99 embedding examples

The public C interface is [boomkat.h](../../include/boomkat.h). The static
library leaves host globals such as `console` to the application. These examples
use the library built at `out/boomkat.a`.

| Example | Shows |
|---|---|
| [hello_console.c](hello_console.c) | A minimal host `console.log` and JavaScript evaluation |
| [main.c](main.c) | Values, UTF-8 strings, error reporting, and cleanup |
| [host_fn.c](host_fn.c) | C callbacks, `udata`, exceptions, and calls back into JS |
| [two_runtimes.c](two_runtimes.c) | Independent runtimes and rejected cross-runtime handles |

From the repository root:

```sh
make lib shared
just example-c-hello
just example-c-static
just example-c-shared
just example-c-multiple
```

The examples build with `cc -std=c99 -Wall -Wextra -pedantic`. On Linux, static
linking also needs `-lm -ldl`. To use a downloaded release archive instead,
extract the library package and follow its `README.txt`; it includes the public
header and `hello_console.c`.

An evaluation returning `0` failed. Read `bk_error(ctx)` for the message, then
continue using or close the runtime. Release each nonzero owned `bk_value` with
`bk_free(ctx, value)`. `bk_arg`, `bk_this`, and `bk_new_target` provide callback
scope handles that remain valid only until the callback returns. Use
`bk_persist` if a callback needs to keep one afterward.

`bk_register_fn` registers a C callback as a global function when its target is
`0`; pass an object handle to add a method to that object. `bk_call` invokes JS
from C and returns an owned handle, or `0` when the call throws. In a callback,
return after a failed `bk_call` so its recorded exception reaches JavaScript.
`bk_throw_error` also records an exception and returns normally, leaving C code
to finish its own cleanup.

Strings have three routes: `bk_read_string` copies UTF-8 bytes into a caller
buffer, `bk_cstr` gives temporary context-owned text after JS string coercion,
and `bk_strdup` gives a copy that the host must free. Strict readers do not
coerce values. See [the embedding guide](../../docs/embedding.md) for the full
ABI and lifetime rules.

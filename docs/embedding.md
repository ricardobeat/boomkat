# Embedding Boomkat

The C interface is [boomkat.h](../include/boomkat.h). Build it with `make lib`
for C toolchains or `make shared` for Rust, Zig, Python, and Ruby. Foreign
linkers should use the shared library so C3 startup constructors resolve against
the library's own image.

## Quick start

```c
static bk_value print(bk_ctx js, bk_value self, unsigned argc,
                      const bk_value *argv, void *out) {
    fprintf(out, "%s\n", argc ? bk_cstr(js, argv[0], NULL) : "");
    return BK_UNDEFINED;
}

bk_ctx js = bk_create();
bk_register_fn(js, 0, "print", print, 1, 0, stdout);
if (bk_exec(js, "print(40 + 2)")) fprintf(stderr, "%s\n", bk_error(js));
bk_destroy(js);
```

`bk_create` makes a context that owns its runtime, and `bk_destroy` releases
both. `bk_eval(ctx, source)` runs a NUL-terminated sloppy script and returns an
owned result; `bk_exec` discards the result and returns non-zero on failure.
`bk_cstr` coerces any value to context-owned UTF-8 that stays valid for the next
three `bk_cstr` calls, so it needs no free. The header's inline shorthands
(`bk_get`, `bk_set`, `bk_str`, `bk_is_*`) take NUL-terminated
names and forward to the full calls below.

## Runtimes and contexts

A `bk_runtime` owns a heap, VM, value registry, job queue, module loader, memory
limit, and interrupt hooks. A `bk_ctx` is a realm: globals, intrinsics, module
instances, JSX settings, pending exception, diagnostics, and host data belong to
that context. Values cross contexts in the same runtime without cloning.
Independent runtimes reject each other's handles.

```c
bk_runtime runtime = bk_new_runtime(NULL);
bk_ctx app = bk_new_context(runtime);
bk_ctx sandbox = bk_new_context(runtime);
/* use app and sandbox */
bk_free_context(sandbox);
bk_free_context(app);
bk_free_runtime(runtime);
```

`bk_new_runtime` takes a `bk_runtime_options` pointer, or `NULL` for the
defaults. Its `alloc`, `realloc` and `free` route the runtime's heap through a
host allocator; they come as a set, and a partial set makes the call return
`NULL`. `realloc` behaves like C `realloc`. `fatal` reports an unrecoverable
engine failure and must not return; the default prints and aborts.
`bk_alloc`, `bk_realloc` and `bk_free_memory` hand the host memory from the same
allocator. The compiler, lexer, regexp engine and shared-memory blocks still
allocate through libc.

```c
bk_runtime_options options = { my_alloc, my_realloc, my_free, &my_arena, my_fatal };
bk_runtime runtime = bk_new_runtime(&options);
```

Context records and realms live until runtime destruction, so escaped functions
keep working after the host releases their original context. Releasing a context
clears its pending exception and invalidates the host's use of that pointer.
Creating a realm per request accumulates realm storage; use long-lived contexts.
Realms share resources and are not a security boundary.

Each runtime runs on one thread at a time. Separate workers use separate
runtimes. A watchdog may call `bk_request_interrupt(runtime)` concurrently;
stop and join it before destroying the runtime. Requests stay latched until
`bk_clear_interrupt`. Poll handlers must not reenter the engine.

## Values and exceptions

A `bk_value` is an opaque 64-bit handle. Outside any local scope, value results
are owned registry roots that remain valid until `bk_free_value` or runtime
destruction. `bk_dup_value` always creates another owned root. Ordinary
arguments are borrowed: setters and `bk_throw` leave the caller's handle owned
by the caller. A callback's `this` and `argv` borrow the current call; duplicate
a handle to keep it after return.

### Local scopes

```c
bk_scope scope = bk_scope_open(app);
for (int i = 0; i < 1000; i++) {
    bk_value n = bk_new_number(app, i);       /* a local: no free needed */
    bk_set_property_uint32(app, array, i, n);
}
bk_value kept = bk_scope_close_escape(app, scope, array_or_result);
```

While a local scope is the innermost one, every value-returning call yields a
local handle instead of a registry root. Locals need no free (`bk_free_value`
ignores them) and all die when the scope closes; a stale local fails with
`BK_ERR_INVALID`. Scopes nest strictly. Closing a scope also closes any scope
opened inside it, and `bk_scope_close_escape` closes a scope and returns one
value in the enclosing scope, or as an owned root when no local scope encloses
it. `bk_scope_local` copies any handle into the innermost local scope, and
`bk_scope_current` returns it, or 0. A scope holds at most 131,072 values;
past that, calls fail with `BK_ERR_FULL`, so open a nested scope inside large
loops. `bk_dup_value` is the way a local outlives its scope.

`BK_UNDEFINED`, `BK_NULL`, `BK_TRUE` and `BK_FALSE` (and `BK_BOOL(b)`) are
immediate handles. They are valid with any context and need no free;
`bk_free_value` ignores them and `bk_dup_value` returns them unchanged. Every
call whose result is undefined, null or a boolean returns the immediate, so
those results take no registry slot.

Value-producing functions return `BK_EXCEPTION` on failure. Use
`bk_is_exception` to check it, then `bk_get_exception(ctx)` to take the actual
thrown value. This preserves identity, primitives, and `throw undefined`.
API failures such as invalid handles produce an Error when taken. A successful
call may clear diagnostics but leaves a pending exception available until taken
or replaced. Taking an empty exception slot yields `BK_UNDEFINED`.

Calls that report a `bk_status` return `BK_OK` (0) or a negative code;
`bk_status_str` names it. `BK_ERR_UNSUPPORTED` means the feature is compiled out
of this build, as some are in the tiny profile.

`bk_get_error_message`, `bk_get_error_code`, and `bk_get_error_info` provide
context-local diagnostics without executing getters, Proxy traps, or user
string conversion. `bk_to_cstring` performs JS string coercion and returns UTF-8
storage, including a trailing NUL. Its optional length includes embedded NUL
bytes and excludes the terminator. Release it with `bk_free_cstring`.
## Strings

A JS string is a sequence of UTF-16 code units and may hold lone surrogates.
Each encoding has its own creator and reader; UTF-8 is the default.

| Direction | UTF-8 | Latin-1 | UTF-16 |
|---|---|---|---|
| Create | `bk_new_string` | `bk_new_string_latin1` | `bk_new_string_utf16` |
| Read | `bk_read_string`, `bk_read_string_utf8` | | `bk_read_string_utf16` |

`bk_new_string` rejects invalid UTF-8 (overlong forms, encoded surrogates, values
above U+10FFFF, truncated sequences) with `BK_ERR_ENCODING` and returns
`BK_EXCEPTION`; nothing is stored. Latin-1 bytes are the code points
U+0000..U+00FF. `bk_new_string_utf16` keeps lone surrogates as given.

`bk_read_string` and `bk_read_string_utf8` measure or copy a string into a
caller-provided buffer without allocating or coercing. A lone surrogate has no
UTF-8 form, so the mode chooses: `BK_UTF8_REPLACE` writes U+FFFD (the behavior of
`bk_read_string`), and `BK_UTF8_STRICT` fails with `BK_ERR_ENCODING`.
`bk_read_string_utf16` copies code units, lone surrogates intact, with no
terminator. Every reader returns `BK_ERR_FULL` when the buffer is too small and
leaves the size it needs in `*length`, so a caller sizes a buffer in two calls
with a `NULL` buffer first. UTF-8 lengths are in bytes and exclude the NUL;
UTF-16 lengths count code units. `bk_string_length` returns the UTF-16 length.

### Views and external strings

The engine stores a string one byte per unit (Latin-1) when every unit is at
most U+00FF and two bytes per unit (native-endian UTF-16) otherwise; the width
is determined by the content, never by how the string was made.
`bk_string_view_get` exposes the stored units without a copy:

```c
bk_string_view view;
if (bk_string_view_get(app, value, &view) == BK_OK) {
    if (view.width == 1) use_latin1((const uint8_t *)view.data, view.length);
    else                 use_utf16((const uint16_t *)view.data, view.length);
}
```

`length` counts units, the data has no terminator, and `ascii` is nonzero when
`width` is 1 and every byte is below 0x80, so such a view is also valid UTF-8.
A view is valid only until the next call into the engine: a collection may free
the string once the host drops its handle, and any call can run one. Copy the
units or finish with the view before calling again.

`bk_new_external_string_latin1` and `bk_new_external_string_utf16` build a
string over host memory with no copy. The buffer must stay unchanged until the
`bk_string_release` callback runs, once, with the buffer and its length in units
when the string is freed. That is after the last handle and script reference
are gone, or when the runtime is destroyed, so the callback may run after the
context is gone. `release` may be `NULL` for static data. An empty buffer, or a
UTF-16 buffer whose units are all at most U+00FF, is copied and released before
the call returns. If the call fails it returns `BK_EXCEPTION` and `release` is
not called. A view of an external string points at the host buffer itself.

## Evaluation and jobs

```c
const char *source = "40 + 2";
bk_value result = bk_eval_ex(app, source, strlen(source), "app.js", BK_EVAL_GLOBAL);
if (bk_is_exception(result)) {
    fprintf(stderr, "%s\n", bk_get_error_message(app));
} else {
    printf("%g\n", bk_to_number(app, result));
}
bk_free_value(app, result);
```

`bk_eval_ex` takes an explicit length, a script name for diagnostics, and flags.
Scripts default to sloppy mode. `BK_EVAL_STRICT` selects a strict global script;
`BK_EVAL_MODULE` selects an ES module and returns its namespace object. Module
jobs, including top-level await, finish when the host pumps the queue.
`bk_define_module` supplies module source before filesystem lookup, and
`bk_set_jsx` configures JSX lowering for one context.

Eval and call do not drain promise jobs. The host decides when a batch of
callbacks has finished, then calls `bk_run_jobs(runtime)`. Alternatively,
`bk_execute_pending_job(runtime, &context)` runs one pending job and returns 1,
0 for an empty or reentrant queue, or a negative error status. The output context
identifies the job's realm. `bk_is_job_pending` inspects the queue.

Promise rejection tracking reports reject/handle transitions synchronously.
The promise and reason are borrowed handles; retain them with `bk_dup_value`.
Report rejections still unhandled after the task's job checkpoint. Hooks must
not execute JS or replace themselves.

## Native C callbacks

```c
static bk_value add(bk_ctx ctx, bk_value receiver, unsigned argc,
                    const bk_value *argv, void *opaque) {
    double total = 0;
    for (unsigned i = 0; i < argc; i++) total += bk_to_number(ctx, argv[i]);
    return bk_new_number(ctx, total);
}

bk_value function = bk_new_c_function(app, add, "add", 2, 0, NULL);
bk_set_global_property(app, "add", 3, function);
bk_free_value(app, function);
```

The callback receives its stable defining context. Its call is a local scope:
every value it creates is a local that dies when it returns, like its `argv`,
so a callback frees nothing it made. It returns any live handle (a local, an
argument, an immediate or a registry root), which the engine copies, or returns
`bk_throw_error`, `bk_throw`, or `BK_EXCEPTION` to propagate a pending failure.
Return `BK_UNDEFINED` for a normal undefined result. A value kept past the call
must be `bk_dup_value`d. Scopes the callback opens and leaves open close when
it returns.
`bk_call` can invoke JS from a callback, and the host can catch its failure with
`bk_get_exception` before returning a normal result. Interrupts remain
uncatchable across native reentry.

`bk_set_function_list` installs a `bk_fn_def` table terminated by `BK_FN_END`.
`BK_CTOR` allows construction; `bk_get_new_target` returns borrowed `new.target`,
and `bk_is_constructor_call` identifies a constructor call. Opaque user pointers
are borrowed for the runtime's lifetime.

Runtimes and contexts each carry `BK_DATA_SLOTS` (4) embedder pointers, set
with `bk_set_runtime_data`/`bk_set_context_data` and read with the matching
getters. Slots 0 to 2 belong to the host; slot 3 is reserved for the C++
layer, so a C++ host and a C library can share a context.

`bk_register_fn` installs one callback on a target object, or as a global when
the target is 0. `bk_argc`, `bk_arg`, `bk_this` and `bk_get_new_target` read
the current call from anywhere inside the callback, including helpers it calls,
and borrow it like `argv` does; arguments past `argc` read as `BK_UNDEFINED`.

```c
bk_register_fn(js, 0, "add", add, 2, 0, NULL);
```

## Native C3

The [public C3 API](../src/embedding.c3) is part of the engine sources and package. It uses
faults and optionals for errors, rooted `JsValue` handles between calls, and
raw `JsArg` values inside callbacks.

```c3
JsRuntime runtime;
runtime.create()!;
defer runtime.destroy();
JsContext context;
context.create(&runtime)!;
defer context.destroy();
JsValue value = context.eval("40 + 2")!;
defer context.release(value);
runtime.drain_microtasks()!;
```

For one isolated realm, use `context.create()` without an explicit runtime.
The context then owns its runtime and destroys it on `context.destroy()`.
`context.get_runtime()` exposes its runtime controls. With `create(&runtime)`,
the runtime is borrowed and must outlive its contexts. Each no-argument call
on a different context creates a separate runtime.

Live owners must stay at stable addresses and must not be copied. Repeated
`create` returns `ALREADY_CREATED` without replacing the live owner; `destroy`
is idempotent, and creation can follow destruction.

`context.create()` owns a private runtime; `context.create(&runtime)` borrows an
explicit owner. Destroy borrowed contexts before their owner. Runtime controls
include interrupts, module loading, and rejection tracking.
Context methods cover evaluation, calling, properties, scoped roots, and
`get_exception`. A native callback takes `JsCtx`, which wraps the builtin call
frame directly; `arg`, `this_value`, `ret`, and throw helpers avoid C ABI
marshalling and per-argument registry allocation.

The Python, Ruby, Rust, and Zig convenience bindings own a runtime and a primary
context. Their explicit drain methods choose a job checkpoint. Their raw ABI
calls use the same signatures as the C header.

See [C examples](../bindings/c), [C3 examples](../bindings/c3/example), and
[API contract tests](../test/capi/api_lifecycle.c).

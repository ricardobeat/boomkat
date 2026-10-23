# Embedding Boomkat

The C interface is [boomkat.h](../include/boomkat.h). Build it with `make lib`
for C toolchains or `make shared` for Rust, Zig, Python, and Ruby. Foreign
linkers should use the shared library so C3 startup constructors resolve against
the library's own image.

## Quick start

```c
static void print(bk_ctx js, void *out) {
    fprintf(out, "%s\n", bk_cstr(js, bk_arg(js, 0), NULL));
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
(`bk_get`, `bk_set`, `bk_str`, `bk_is_*`, `bk_return_*`) take NUL-terminated
names and forward to the full calls below.

## Runtimes and contexts

A `bk_runtime` owns a heap, VM, value registry, job queue, module loader, memory
limit, and interrupt hooks. A `bk_ctx` is a realm: globals, intrinsics, module
instances, JSX settings, pending exception, diagnostics, and host data belong to
that context. Values cross contexts in the same runtime without cloning.
Independent runtimes reject each other's handles.

```c
bk_runtime runtime = bk_new_runtime();
bk_ctx app = bk_new_context(runtime);
bk_ctx sandbox = bk_new_context(runtime);
/* use app and sandbox */
bk_free_context(sandbox);
bk_free_context(app);
bk_free_runtime(runtime);
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

## Native compilation

The standard libraries include JIT support, disabled by default. Call
`bk_set_jit(runtime, 1)` to enable native compilation for eligible template
rendering, numeric array loops, ASCII scans, and hot property/counter segments
in all contexts sharing the runtime; use zero to return to interpreter execution. Compiled code remains
cached until its function is released.
Enabling returns `BK_ERR_INVALID` when the build or architecture lacks support.
The setter belongs to the runtime's engine thread, like other configuration
operations. See [build-flags.md](build-flags.md#jit) for supported patterns
and source-build requirements.

## Values and exceptions

A `bk_value` is an opaque 64-bit GC root. Owned value results remain valid until
`bk_free_value` or runtime destruction. `bk_dup_value` creates another owned
root. Ordinary arguments are borrowed: setters and `bk_throw` leave the caller's
handle owned by the caller. A callback's `this` and `argv` borrow the current
call; duplicate a handle to keep it after return.

Value-producing functions return `BK_EXCEPTION` on failure. Use
`bk_is_exception` to check it, then `bk_get_exception(ctx)` to take the actual
thrown value. This preserves identity, primitives, and `throw undefined`.
API failures such as invalid handles produce an Error when taken. A successful
call may clear diagnostics but leaves a pending exception available until taken
or replaced. Taking an empty exception slot yields owned undefined.

`bk_get_error_message`, `bk_get_error_code`, and `bk_get_error_info` provide
context-local diagnostics without executing getters, Proxy traps, or user
string conversion. `bk_to_cstring` performs JS string coercion and returns UTF-8
storage, including a trailing NUL. Its optional length includes embedded NUL
bytes and excludes the terminator. Release it with `bk_free_cstring`.
`bk_read_string` measures or copies a string into a caller-provided buffer
without allocating or coercing.

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

The callback receives its stable defining context. It returns an owned handle,
which transfers to the engine, or returns `bk_throw_error`, `bk_throw`, or
`BK_EXCEPTION` to propagate a pending failure. Return `bk_new_undefined` for a
normal undefined result. Returning a borrowed argument requires duplication.
`bk_call` can invoke JS from a callback, and the host can catch its failure with
`bk_get_exception` before returning a normal result. Interrupts remain
uncatchable across native reentry.

`bk_set_function_list` installs a `bk_fn_def` table terminated by `BK_FN_END`.
`BK_CTOR` allows construction; `bk_get_new_target` returns owned `new.target`,
and `bk_is_constructor_call` identifies a constructor call. Opaque user pointers
are borrowed for the runtime's lifetime. Runtime and context opaque data have
separate setters/getters.

A `bk_host_fn` is the short form. `bk_register_fn` installs one on a target
object, or as a global when the target is 0. The callback reads its call with
`bk_argc`, `bk_arg`, and `bk_this`, which borrow the call like `argv` does;
arguments past `argc` read as undefined. `bk_return` stages a borrowed result,
and returning without one yields undefined. A throw raised during the callback,
by `bk_throw_error` or by a failing `bk_call`, takes precedence over any staged
result.

```c
static void add(bk_ctx js, void *opaque) {
    double total = 0;
    for (unsigned i = 0; i < bk_argc(js); i++) total += bk_to_number(js, bk_arg(js, i));
    bk_return_number(js, total);
}

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

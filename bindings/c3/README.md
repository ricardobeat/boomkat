# C3 embedding

The public C3 API lives in [`src/embedding.c3`](../../src/embedding.c3),
part of the engine source and package. Import `boomkat` to use typed values,
C3 faults, and callbacks that pass raw engine values. `JsValue` holds a rooted
handle between calls.

| File | Purpose |
|---|---|
| [`src/embedding.c3`](../../src/embedding.c3) | public API (`module boomkat`) |
| `example/hello.c3` | evaluating source and reading values back |
| `example/host_functions.c3` | JS calling into C3, and C3 calling back into JS |
| `example/project.json` | standalone build for `host_functions` (see below) |

## Lifecycle

For an isolated context, omit the runtime:

```c3
JsContext context;
context.create()!;
defer context.destroy();
JsValue result = context.eval("40 + 2")!;
defer context.release(result);
context.get_runtime().drain_microtasks()!;
```

To share a runtime between realms, create it explicitly:

```c3
JsRuntime runtime;
runtime.create()!;
defer runtime.destroy();
JsContext first, second;
first.create(&runtime)!;
defer first.destroy();
second.create(&runtime)!;
defer second.destroy();
```

`create()` embeds its runtime owner inside the context; destroying the context
also destroys that runtime. `create(&runtime)` borrows the runtime, which must
outlive every context using it. `get_runtime()` returns the owner, or `null`
when the context is uninitialized. Keep live owners at stable addresses and
do not copy them. A sibling created from an owned context's `get_runtime()`
must be destroyed before the owning context.

Calling `create` on an initialized owner returns `ALREADY_CREATED` and leaves
it intact. `destroy` is idempotent, and the owner can be created again afterward.
An uninitialized explicit runtime reports `NOT_CREATED`.

Each context is a realm. Context methods evaluate, call, inspect, and root
values. Runtime methods configure module loading, interrupts, and rejection
tracking. Eval and call leave promise jobs queued for an explicit checkpoint.
`context.get_exception()` takes the actual thrown value after `JS_EXCEPTION`.

Build from source with the engine's C3 compiler and vendored C dependencies;
no prebuilt library is needed. `c3c build boomkat_example_c3` builds the basic
example. Standalone callback examples live in `example/project.json`.

## Host functions

JS can call C3. Register a `fn void(JsCtx, void*)` as a global and the engine
dispatches straight into it. Plain calls, methods, `.call`/`.apply`/`.bind`,
getters and setters, `new` and `super()` all work, because a host function is
indistinguishable from a built-in at every dispatch site.

```c3
fn void host_hypot(JsCtx ctx, void* udata) {
    double? a = ctx.arg(0).as_number();
    double? b = ctx.arg(1).as_number();
    if (catch a) { ctx.throw_error(TYPE, "hypot: expected a number"); return; }
    if (catch b) { ctx.throw_error(TYPE, "hypot: expected a number"); return; }
    ctx.ret_number(math::sqrt(a * a + b * b));
}

context.register_fn("hypot", &host_hypot, arity: 2)!!;
context.eval("hypot(3, 4)")!!;   // 5
```

Three rules govern how callbacks behave:

`throw_error` does not unwind. It records the exception and returns, so the
callback keeps running. Put a `return` right after it unless you mean to
continue. If `ret` is also called, the throw wins. This mirrors how the engine's
own builtins report failure, which is what every dispatch site is written
against.

A `JsArg` is scoped to the call, and is a different type from `JsValue` for
exactly that reason. `JsValue` is a registry slot rooted until `release`;
`JsArg` dies when the callback returns. The compiler rejects the mix-up that
would otherwise be a use-after-free.

C3 function pointers cannot capture. Mutable host state reaches a callback
through the `udata` pointer given to `register_fn`, which the engine stores
verbatim and never frees. It must outlive the runtime.

`ctx.call(fn, args)` invokes a JS function from host code, so host functions can
call back into JS instead of being leaf-only. If the callee throws, `call`
reports `JS_EXCEPTION` and the exception is already pending on this call, so
returning propagates it to JS unchanged.

Arguments are copied into a GC-rooted call scope rather than read from VM
registers, so they stay valid across a nested `ctx.call` that reallocates the
value stack. The example produces byte-identical output under the `GC_STRESS`
plus AddressSanitizer target, where a collection happens at every allocation.

### Host API

| Call | Notes |
|---|---|
| `context.register_fn(name, handler, udata:, arity:, constructable:)` | binds a global; lasts until runtime destruction |
| `ctx.argc()` / `ctx.arg(i)` | out-of-range `arg` is undefined, so no arity check |
| `ctx.this_value()` / `ctx.new_target()` / `ctx.is_construct()` | the receiver as the call path bound it (sloppy `this` already coerced) |
| `arg.type_of()` / `as_number()` / `as_bool()` / `as_string()` | strict, `WRONG_TYPE` on mismatch |
| `ctx.number/string/boolean/null_value/undefined_value(v)` | build a `JsArg` |
| `ctx.ret(v)` / `ret_number` / `ret_string` / `ret_bool` / `ret_null` | never calling one yields undefined |
| `ctx.get_prop(obj, key)` / `ctx.set_prop(obj, key, v)` | data properties only; `get_prop` does not run getters |
| `ctx.throw_error(kind, msg)` / `ctx.throw_value(v)` | does not unwind |
| `ctx.call(fn, args, this_value)` | calls JS; faults `NOT_CALLABLE`, `JS_EXCEPTION` |
| `ctx.persist(arg)` / `ctx.value(v)` | move between call-scoped `JsArg` and rooted `JsValue` |

`JsErrorKind` is `ERROR`, `TYPE`, `RANGE`, `REFERENCE`, `SYNTAX`.

Nesting `js -> host -> js -> host` is bounded: past the limit the engine throws
a `RangeError` rather than faulting the stack.

### Building the host-functions example

It needs its own target, and the repo's `project.json` does not have one, so
`example/project.json` is a standalone build run from the example directory:

```sh
cd bindings/c3/example
c3c build host_functions
./out/host_functions
```

Expected output:

```
-- arguments and return values --
hypot(3, 4)          = 5
greet('world')       = hello, world
hypot.length         = 2
hypot.name           = hypot

-- host state via udata --
counter() x3         = 3
C3 side saw   = 3 hits

-- throwing, caught by JS --
caught RangeError    = RangeError: insufficient funds
no throw             = 70
wrong arg type       = hypot: first argument must be a number

-- calling a JS callback from C3 --
applyTwice(double, 5) = 20
callback throws      = from JS
not a function       = applyTwice: first argument must be a function

-- new --
new Point(3, 4).r    = 5
instance shape       = {"x":1,"y":2,"r":2.23606797749979} true
Point without new    = Point requires 'new'

-- bounded recursion --
1000 deep            = RangeError: Maximum call stack size exceeded
```

`c3c build host_functions_stress && ./out/host_functions_stress` builds the same
example with `GC_STRESS` and AddressSanitizer. It must print the same thing.

To fold this into the repo's own `project.json` instead, add:

```json
"boomkat_example_host_c3": {
  "type": "executable",
  "sources": ["src", "bindings/c3/example/host_functions.c3"],
  "opt": "O2",
  "single-module": true,
  "fp-math": "relaxed",
  "debug-info": "none",
  "features": ["THREADED_DISPATCH"]
}
```

## Using it in your own target

A project that depends on the `boomkat` package can `import boomkat;` directly.
A source build includes the engine's `src` directory and the C dependencies
listed in the repository's `project.json`:

```json
"my_app": {
  "type": "executable",
  "sources": ["src", "app/main.c3"],
  "opt": "O2",
  "single-module": true,
  "features": ["THREADED_DISPATCH"]
}
```

```c3
import boomkat;

JsContext context;
context.create()!;
defer context.destroy();
JsValue value = context.eval("40 + 2")!;
io::printfn("%g", context.as_number(value)!);
context.release(value);
```

## API

| Call | Notes |
|---|---|
| `runtime.create()` / `runtime.destroy()` | owns the heap, VM, roots, and job queue |
| `context.create(runtime = null)` / `context.destroy()` | owns a private runtime or borrows the supplied runtime |
| `context.get_runtime()` | runtime controls for either ownership form |
| `context.eval(src)` | a trailing expression is the result |
| `context.exec(src)` | run for side effects, discard the value |
| `context.type_of(v)` | `JsType`; never fails |
| `context.as_number/as_bool/as_string(v)` | strict: no coercion, `WRONG_TYPE` on mismatch |
| `context.to_display_string(v)` | coerces like `String(v)`; can run JS and throw |
| `context.release(v)` | drop one value's root |
| `context.last_error()` / `context.get_exception()` | inspect a failure or take its thrown value |
| `runtime.drain_microtasks()` | explicit promise job checkpoint |
| `context.eval_module(src, name)` | runs an ES module, returns its namespace |
| `context.define_module(name, src)` | makes `src` importable as `name` |
| `context.call(fn, args, this_value)` | calls a JS function from host code |
| `context.object()` / `context.array()` / `context.global()` | build or fetch objects |
| `context.get(obj, key)` / `get_index` / `set` / `set_index` / `length` | full Get/Set semantics; getters and setters run |
| `context.register_method(obj, name, handler)` | host function as a method |
| `context.@scope() { ... }` | releases values rooted inside the block |
| `context.persist(v)` / `runtime.persist(v)` | retain an independent root |

Faults: `NOT_CREATED`, `ALREADY_CREATED`, `OUT_OF_MEMORY`, `SYNTAX_ERROR`,
`JS_EXCEPTION`, `INTERNAL_ERROR`, `INTERRUPTED`, `WRONG_TYPE`, `STALE_VALUE`,
`VALUE_TABLE_FULL`, `NOT_CALLABLE`, `REGISTER_FAILED`.

Allocating accessors (`as_string`, `to_display_string`) take an optional
`Allocator`, defaulting to `tmem`. Pass `mem` (and free it) to keep a string
past the current temp scope.

## Lifetime and threading

A `JsValue` stays valid until its runtime is destroyed or the value is released.
The embedding core's registry roots values directly during GC. Copying a handle
aliases its slot; release that slot once. Use `persist` for an independent root.
Values can cross contexts in the same runtime; other runtimes reject them with
`STALE_VALUE`.

Release values in loops to avoid retaining them until runtime teardown. Released
slots are reused with new generations, so a stale handle cannot name a new value.
A raw `TVal` does not keep its object alive across garbage collection.

Multiple runtimes can coexist. Each runtime must be driven by one thread at a
time. Separate threads can drive separate runtimes.

## Choosing an API

For C3 hosts, use this public module when building against the engine sources or
C3 package. Native callbacks receive call-scoped `JsArg` values with typed
accessors; rooted `JsValue` handles keep host-held values alive between calls.

Use the C ABI (`include/boomkat.h`, `src/capi.c3`) for other host languages or a
shared-library boundary. Both APIs use the same embedding core. C3 source
consumers rebuild with the engine; the public C3 module does not provide a
binary ABI guarantee.

Registrations last until runtime destruction. Registering the same name twice
replaces the global binding; a function object JS already holds keeps working.

## Event-loop hooks

`runtime.set_promise_rejection_tracker(handler, udata:)` installs a callback with
signature `fn void(JsRuntime*, ulong promise_id, JsValue promise, JsValue reason,
bool handled, void*)`. `handled == false` adds a rejected promise to the host's
pending set; `true` removes it when the first reaction is attached later.
Callbacks run immediately on the engine thread and must not execute JS or
replace the hook. Values are borrowed for the callback: use `runtime.persist` to
retain the promise and reason, then `release` them when removed. The identity
is stable while the retained promise stays alive. Keep the `JsRuntime`
stationary while the hook is installed. Report pending entries only after the
macrotask finishes and `runtime.drain_microtasks()` succeeds, so a catch or await
attached by another microtask cancels the report.

A watchdog thread calls `runtime.request_interrupt()` when a dispatch exceeds its
deadline. The runtime must remain alive and stationary until that thread stops.
Bytecode safepoints and regex backtracking check the request; `eval`, `call`
and `drain_microtasks` return `INTERRUPTED`. JS catch handlers cannot intercept
termination, and finally blocks run during unwind. Stop/join the watchdog,
call `runtime.clear_interrupt()` on the engine thread, and then dispatch more work.
The runtime remains usable; application state can reflect partial execution.
Host callbacks and other native operations must enforce their own deadlines.

`runtime.set_interrupt(handler, opaque:)` also accepts an engine-thread poll
callback, returning nonzero to terminate. It must not re-enter the engine.

Regression checks from `bindings/c3/example`:

```sh
c3c build runtime_hooks && ./out/runtime_hooks
c3c build runtime_hooks_asan && ./out/runtime_hooks_asan
```

The C API watchdog regression runs with `make test-runtime-hooks`.

Run the C3 ownership and realm lifecycle checks with `just test-c3-api`.
`c3c build embedding_lifecycle_asan --build-dir out/build/embedding_lifecycle_asan`
builds the same checks with AddressSanitizer and `GC_STRESS`.

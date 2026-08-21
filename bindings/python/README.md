# Python binding

A pure-Python [`ctypes`](https://docs.python.org/3/library/ctypes.html) wrapper over the
`bk_` C ABI (`include/boomkat.h`). There is no C extension and nothing to compile on the
Python side. The module loads the engine's shared library at runtime.

## Prerequisites

Python 3, with no third-party packages. Verified on CPython 3.12.9 (macOS/arm64);
`ctypes` is in the standard library, so any 3.x should work.

You also need the engine shared library, built with the repo's C3 toolchain (c3c 0.8.2).

## Build

From the repository root:

```sh
make shared
```

This produces `out/libboomkat.dylib` (macOS) or `out/libboomkat.so` (Linux). The binding finds
it automatically by walking up from its own location. To point at a library elsewhere,
set `BK_LIBRARY=/path/to/libboomkat.dylib` or pass `Runtime("/path/to/libboomkat.dylib")`.

## Run

```sh
python3 bindings/python/example.py
python3 bindings/python/example_two_runtimes.py
```

## Expected output

```
engine version: 0.1.0
sum of squares: 30.0
greeting: hello 😀
counter: 5.0
hostAdd(40, 2): 42.0
via .apply: 10.0
shout('hi'): HI 😀
checkAge(21): True
caught in JS: RangeError: age must not be negative
describe(x => x * 3, 5): 5.0 -> 15.0
describe with a builtin: 81.0 -> 9.0
callback throw: RangeError: nope
caught throw: [uncaught exception] TypeError: Cannot read properties of null (reading 'oops')
caught syntax: [syntax error] expected '<identifier>', got '('
still alive: yes
runtime closed
```

And from `example_two_runtimes.py`:

```
a.x: 111.0  b.x: 222.0
b cannot see onlyInA: ReferenceError: onlyInA is not defined
a.o.k199: 199.0  b.o.k199: -199.0
a: s === 'shared text' -> True
b: s === 'shared text' -> True
host fn invoked from a says: a
host fn invoked from b says: b
b received from a: a/7
b still works after a closed: 223.0
a is closed: this Runtime is closed
both runtimes closed
```

## Usage

```python
from js import Runtime, JsError

with Runtime() as rt:                 # closes the engine on exit, even on error
    print(rt.eval("1 + 1"))           # 2.0
    try:
        rt.eval("boom()")
    except JsError as err:
        print(err.kind, err)          # uncaught exception  boom is not defined
```

### Value mapping

| JavaScript            | Python                          |
| --------------------- | ------------------------------- |
| number                | `float` (always, per JS semantics) |
| string                | `str` (UTF-8, astral-safe)      |
| boolean               | `bool`                          |
| `null` / `undefined`  | `None`                          |
| object, function, symbol, bigint | `JsObject` (opaque)  |

Objects and functions cannot cross the boundary as data. Serialize them in JS first,
with `rt.eval("JSON.stringify(obj)")`, and parse the string on the Python side.

Errors raise `JsError`, carrying `.code` (the raw `bk_status` integer) and `.kind`
(a readable name such as `syntax error` or `uncaught exception`).

## Host functions

`@rt.function` binds a Python callable as a JS global. It receives a single `Call`
and its return value becomes the JS result; `None` yields `undefined`.

```python
@rt.function("hostAdd", arity=2)
def host_add(call):
    return sum(call.args)

rt.eval("hostAdd(40, 2)")        # 42.0
rt.eval("hostAdd.length")        # 2, from arity=
```

The JS name defaults to the Python one (`@rt.function()`), and `rt.register(name, fn)`
is the non-decorator form. `constructable=True` allows `new fn()`. Without it, `new`
throws a `TypeError`, which is how JS built-ins behave.

The `Call` carries `args` (arguments as plain Python values), `raw` (the same
arguments as live `JsValue` references), `this`, `new_target`, `is_construct`, and
`runtime` (the `Runtime` this call is executing inside).

Arguments arrive as *scope* handles, which name a slot in the call rather than in the
runtime's value registry. The binding reads them through the ABI's context tier
(`bk_ctx_type_of`, `bk_ctx_get_number`, `bk_ctx_get_bool`, `bk_ctx_get_string`),
which is the only tier that resolves them.

### Throwing

Raising inside a host function converts to a JS throw, so a Python exception never
escapes into C. The exception class maps by name, so a Python `TypeError` becomes a
JS `TypeError`; anything unrecognised becomes a plain `Error`. Raise `JsThrow` to
choose a class explicitly:

```python
@rt.function("checkAge", arity=1)
def check_age(call):
    if call.args[0] < 0:
        raise JsThrow("age must not be negative", "RangeError")
    return call.args[0] >= 18
```

The original Python exception object stays on `rt._last_host_exception`, so its
traceback survives for logging even though JS only ever sees the message text.

### Calling JS back

Function arguments arrive as callables. Invoking one runs it through `bk_call`, and
a throw from the callee propagates out with its class intact:

```python
@rt.function("describe", arity=2)
def describe(call):
    fn, value = call.args
    return "%s -> %s" % (value, fn(value))

rt.eval("describe(Math.sqrt, 81)")     # '81.0 -> 9.0'
```

The engine bounds host recursion: a runaway host to JS to host chain throws a
`RangeError` rather than exhausting the native stack.

### What a host function can pass and return

Returns may be `float`/`int`, `str`, `bool`, `None`, or a `JsValue` from `call.raw`.

Arguments to a JS callback must be values *this call received*, either a `JsValue`
from `call.raw` or a `call.args` entry passed through unchanged. `fn(x)` works;
`fn(x + 1)` raises `JsError`, because this ABI version has no way to construct a
JS value inside a callback (`bk_return_*` writes the return slot rather than
producing a handle, and `bk_eval` must not be re-entered from a callback). Do the
arithmetic on the Python side of the result, or return data and let JS assemble the
call. Returning a `dict` or `list` raises for the same reason; return
`json.dumps(...)` and `JSON.parse` it in JS.

## Multiple runtimes

Several `Runtime` objects can be open at once. They share no globals, no objects, no
prototypes and no interned strings.

```python
with Runtime() as a, Runtime() as b:
    a.eval("globalThis.x = 111")
    b.eval("globalThis.x = 222")
    a.eval("x")                       # 111.0
    b.eval("x")                       # 222.0
```

Closing one does not disturb the other. `bindings/python/example_two_runtimes.py` runs
through independent globals, objects, string tables and host functions.

### Moving values between runtimes

A JS value belongs to the runtime that produced it, and nothing in the ABI transfers
one. That costs the binding nothing, because a raw handle is never exposed: `eval()`
hands back a plain Python object, and a `JsValue` from `call.raw` is confined to the
host call it came from. So the Python value is what crosses:

```python
payload = a.eval("JSON.stringify(config)")
b.eval("globalThis.config = JSON.parse(%r)" % payload)
```

Numbers, strings and booleans need no ceremony. Objects and functions have to be
serialized, exactly as they do when leaving the engine for Python at all.

### Host functions

`Call.runtime` is the runtime the callback is executing inside, resolved from the call
context via `bk_ctx_runtime` rather than from whichever `Runtime` registered the
function. Registering one Python callable in several runtimes therefore works, and each
invocation can tell them apart:

```python
def which(call):
    return names[call.runtime]

a.register("whichRuntime", which)
b.register("whichRuntime", which)
```

## Limitations

These come from the C ABI, not the binding.

A runtime is driven from one thread at a time. Nothing enforces this: the engine has
no locking, and two threads inside one runtime corrupt it. Two threads each driving
their *own* runtime share nothing and are fine. CPython's ctypes callbacks take the
GIL automatically, so host functions are safe on the thread the ABI already requires.

Registration is permanent. The ABI has no way to unbind a host function, and its ctypes
trampoline is held on the `Runtime` for the process lifetime. (It must be: ctypes keeps
no reference of its own, and a collected trampoline would leave the engine calling
freed memory.)

No value construction inside a host function. As described above, callbacks can forward
the arguments they were given, but cannot build new ones.

`bk_eval` is not re-entrant. Do not call `rt.eval()` from inside a host function; it is
a top-level entry point and re-entering it crashes the engine. Use a JS callback
argument instead.

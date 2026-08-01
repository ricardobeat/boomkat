# Python binding

A pure-Python [`ctypes`](https://docs.python.org/3/library/ctypes.html) wrapper over the
`jse_` C ABI (`include/jse.h`). There is no C extension and nothing to compile on the
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

This produces `out/libjse.dylib` (macOS) or `out/libjse.so` (Linux). The binding finds
it automatically by walking up from its own location. To point at a library elsewhere,
set `JSE_LIBRARY=/path/to/libjse.dylib` or pass `Runtime("/path/to/libjse.dylib")`.

## Run

```sh
python3 bindings/python/example.py
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

Errors raise `JsError`, carrying `.code` (the raw `jse_status` integer) and `.kind`
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
arguments as live `JsValue` references), `this`, and `is_construct`.

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

Function arguments arrive as callables. Invoking one runs it through `jse_call`, and
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
JS value inside a callback (`jse_return_*` writes the return slot rather than
producing a handle, and `jse_eval` must not be re-entered from a callback). Do the
arithmetic on the Python side of the result, or return data and let JS assemble the
call. Returning a `dict` or `list` raises for the same reason; return
`json.dumps(...)` and `JSON.parse` it in JS.

## Limitations

These come from the C ABI, not the binding.

One runtime per process. The engine holds process-global state; a second `Runtime()`
raises `JsError` with code `-5` rather than corrupting the first.

Not thread-safe. Confine a runtime to a single thread. CPython's ctypes callbacks take
the GIL automatically, so host functions are safe on the single thread the ABI already
requires. That is a throughput ceiling rather than a correctness problem.

Registration is permanent. The ABI has no way to unbind a host function, and its ctypes
trampoline is held on the `Runtime` for the process lifetime. (It must be: ctypes keeps
no reference of its own, and a collected trampoline would leave the engine calling
freed memory.)

No value construction inside a host function. As described above, callbacks can forward
the arguments they were given, but cannot build new ones.

`jse_eval` is not re-entrant. Do not call `rt.eval()` from inside a host function; it is
a top-level entry point and re-entering it crashes the engine. Use a JS callback
argument instead.

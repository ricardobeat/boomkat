# Python binding

A pure-Python [`ctypes`](https://docs.python.org/3/library/ctypes.html) wrapper over the
`jse_` C ABI (`include/jse.h`). There is no C extension and nothing to compile on the
Python side — the module loads the engine's shared library at runtime.

## Prerequisites

- **Python 3** — no third-party packages. Verified on CPython 3.12.9 (macOS/arm64);
  `ctypes` is in the standard library, so any 3.x should work.
- **The engine shared library**, built with the repo's C3 toolchain (c3c 0.8.2).

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
caught throw: [uncaught exception] Cannot read properties of null (reading 'oops')
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

Objects and functions cannot cross the boundary as data. Serialize them in JS first —
`rt.eval("JSON.stringify(obj)")` — and parse the string on the Python side.

Errors raise `JsError`, carrying `.code` (the raw `jse_status` integer) and `.kind`
(a readable name such as `syntax error` or `uncaught exception`).

## Limitations

These come from the C ABI, not the binding:

- **One runtime per process.** The engine holds process-global state; a second
  `Runtime()` raises `JsError` with code `-5` rather than corrupting the first.
- **Not thread-safe.** Confine a runtime to a single thread.
- **No Python callbacks into JS.** Built-in dispatch is a compile-time ordinal table
  with no slot for host function pointers, so registering a native callback is
  impossible without engine changes.
- **No direct function calls** (`jse_call` is not in v1). Wrap the call in JS source and
  pass it to `eval` instead.

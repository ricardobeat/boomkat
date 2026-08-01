# Rust bindings for the duktape-c3 JavaScript engine

Two crates over the `jse_` C ABI (`include/jse.h`):

| Crate | What it is |
|---|---|
| `jse-sys` | Raw `extern "C"` declarations, one per header symbol. A `build.rs` finds and links the static archive. Everything is `unsafe`. |
| `jse` | The safe wrapper: `Runtime`, `Value`, `Result<_, Error>`, `Drop`. No raw pointer or handle is exposed. |

## Prerequisites

- **Rust 1.70+** (developed and tested against `cargo 1.95.0` / `rustc 1.95.0`).
- **A C toolchain** for the final link step — `cc` on the `PATH`.
- **The engine's static archive.** Build it from the repo root:

  ```sh
  make lib          # produces out/jse_static.a
  ```

  `build.rs` walks up from the crate looking for the checkout (the directory
  containing `include/jse.h`) and links `out/jse_static.a` from it. To link
  against an installed copy instead, set `JSE_LIB_DIR` to a directory holding
  `libjse.a` or `jse_static.a`:

  ```sh
  make install PREFIX=/usr/local
  JSE_LIB_DIR=/usr/local/lib cargo build
  ```

The archive is self-contained: the vendored C (`libregexp`, `cutils`, `dtoa`)
is already inside it, so nothing else needs compiling. On Linux `build.rs` adds
`-lm -ldl`; macOS resolves both from libSystem.

## Build and run

From this directory (`bindings/rust`):

```sh
cargo build
cargo run --example hello_js
cargo test
```

## Expected output

```
jse 0.1.0
sum        = 10
greeting   = hello world 😀
its type   = String
wrong type = wrong type: value is not a string
counter    = 10
syntax     = syntax error: SyntaxError
throw      = uncaught exception: nope
recovered  = TypeError
before job = pending
after job  = done
Null Undefined Boolean Number String Object Function 
second rt  = a runtime is already open in this process
ok
```

## Usage

```rust
use jse::{Kind, Runtime};

let rt = Runtime::new()?;

let v = rt.eval("[1, 2, 3].reduce((a, b) => a + b)")?;
assert_eq!(v.as_number()?, 6.0);

match rt.eval("throw new TypeError('nope')") {
    Err(e) if e.kind() == Kind::Throw => println!("caught: {}", e.message()),
    _ => unreachable!(),
}
// `rt` and every Value drop here.
```

## What the safe layer adds

- A `Value` borrows its `Runtime`, so the borrow checker rejects a value
  outliving the engine that owns it — the one case the C ABI leaves to
  discipline.
- Slots are released on `Drop`, so the 1024-entry registry cannot be leaked
  into exhaustion by ordinary use.
- Error messages are **copied** out of the engine's buffer immediately, since
  that buffer is only valid until the next `jse_*` call.
- `Runtime` is neither `Send` nor `Sync`. The ABI is documented as not
  thread-safe and does not lock, so this is a compile-time error rather than a
  convention.

## Limitations

These come from the C ABI, not from this binding.

- **One runtime per process.** The engine keeps process-global state. A second
  `Runtime::new()` returns `Kind::AlreadyOpen` instead of racing. This is why
  `tests/basic.rs` is a single test function — `cargo test` would otherwise
  open runtimes on parallel threads.
- **No Rust callbacks into JS.** Built-in dispatch is an index into a table
  sized and filled at compile time, never a host pointer, so there is nothing
  to register against without engine changes.
- **No direct `call` of a JS function.** Absent from the v1 ABI. Wrap the call
  in a JS snippet and use `eval`.
- **Readers do not coerce.** `as_number` on a string is `Kind::Type`, not a
  parse. Call `String(x)` or `Number(x)` in JS first.

## ABI fix made while writing this

`jse_get_number`, `jse_get_bool`, and `jse_get_string` returned `JSE_ERR_TYPE`
and `JSE_ERR_FULL` without ever touching the runtime's error state, so
`jse_last_error` reported whatever the *previous* failure had left there —
a stale message, sometimes from an unrelated call. They now set a specific
message on failure and clear it on success, matching what the header promises
of every other entry point. Fixed in `src/capi.c3`; the contract is now spelled
out in `include/jse.h` under `jse_last_error`.

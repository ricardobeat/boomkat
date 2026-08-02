# Rust bindings for the duktape-c3 JavaScript engine

Two crates over the `jse_` C ABI (`include/jse.h`):

| Crate | What it is |
|---|---|
| `jse-sys` | Raw `extern "C"` declarations, one per header symbol. A `build.rs` finds and links the static archive. Everything is `unsafe`. |
| `jse` | The safe wrapper: `Runtime`, `Value`, `Ctx`, `Result<_, Error>`, `Drop`. No raw pointer or handle is exposed. |

## Prerequisites

- Rust 1.70+ (developed and tested against `cargo 1.95.0` / `rustc 1.95.0`).
- A C toolchain for the final link step, meaning `cc` on the `PATH`.
- The engine's static archive. Build it from the repo root:

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
cargo run --example host_fns
cargo run --example two_runtimes
cargo test
```

## Expected output

`cargo run --example hello_js`:

```
jse 0.1.0
sum        = 10
greeting   = hello world 😀
its type   = String
wrong type = wrong type: value is not a string
counter    = 10
syntax     = syntax error: SyntaxError
throw      = uncaught exception: TypeError: nope
recovered  = TypeError
before job = pending
after job  = done
Null Undefined Boolean Number String Object Function 
second rt  = undefined
first rt   = 10
ok
```

`cargo run --example host_fns`:

```
add(40, 2)        = 42
add(1,2,3,4)      = 10
[1,2,3].map(...)  = 11,12,13
nextId() x3       = id-1,id-2,id-3
checkedSqrt(81)   = 9
caught in JS      = Error: cannot sqrt -1
bad argument type = TypeError
uncaught in Rust  = Error: cannot sqrt -4 (Throw)
panic became      = host panic: something went wrong
mapTwice(x*3, 5)  = 45
mapTwice(abs, -7) = 7
callee throw      = RangeError: from JS
runaway recursion = RangeError
ok
```

`cargo run --example two_runtimes`:

```
A.tag             = A
B.tag             = B
A sees onlyInB    = undefined
A.o.k7            = replaced in A
B.o.k7            = 7
A [].mine()       = patched in A
B sees [].mine    = undefined
A shout('hi')     = A says hi
B shout('hi')     = B says hi
A -> B by copy    = made in A
A interning       = true
A after B closed  = A
thread            = worker 0
thread            = worker 1
thread            = worker 2
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

## Host functions

`register_fn` binds a Rust closure as a JS global:

```rust
rt.register_fn("add", 2, |ctx| {
    Ok(ctx.number(ctx.arg(0).as_number()? + ctx.arg(1).as_number()?))
})?;

assert_eq!(rt.eval("add(40, 2)")?.as_number()?, 42.0);
```

The second argument is the reported `.length`; JS may still pass any number of
arguments, and `ctx.arg` past the end reads as `undefined`. Registered
functions behave like built-ins everywhere: as methods, under
`.call`/`.apply`/`.bind`, as accessors, and as callbacks handed to `Array.map`.
`register_ctor` is the same but also allows `new`.

Returning `Err` throws into JS. The error's `Kind` picks the constructor:
`Error::throw(msg)` becomes a plain `Error`, and a failed reader (`as_number`
on a string) becomes a `TypeError`. Uncaught, it comes back out of `eval` as an
ordinary `Err`.

`ctx.call` calls JS back from Rust. A throw from the callee propagates as
itself, so `?` re-raises the original exception rather than replacing it with a
generic host error. A failure of the call itself, such as an exhausted value
registry, is reported separately, as `Kind::Full` or `Kind::Invalid` with a
message, so it can never be mistaken for a JS exception. Host to JS to host
recursion is bounded by the engine with a `RangeError` instead of exhausting
the native stack.

The result is a `Retained` guard owning one registry slot. Deref reads it as an
ordinary `HostValue`, and it frees its slot on drop:

```rust,ignore
rt.register_fn("mapTwice", 2, |ctx| {
    let f = ctx.arg(0);
    let once = ctx.call(f, &[ctx.arg(1)], None)?;   // freed as the closure ends
    Ok(ctx.call(f, &[*once], None)?.keep())          // handed to the call
})?;
```

`keep()` gives the slot to the enclosing host call, which frees it on return.
That is what you want for the value being returned, but not inside a loop.

Three things this layer handles that the raw ABI leaves to the caller:

- Panics never unwind into C, which would be undefined behaviour. Every
  callback runs inside `catch_unwind`, and a caught panic becomes a JS `Error`
  reading `host panic: <message>` that the script can catch. The engine stays
  consistent and the panic does not propagate out of `eval`.
- Scope handles cannot escape the call. Arguments and `this` are valid only
  until the callback returns. `Ctx` and `HostValue` are invariant over a
  lifetime tied to the call, so stashing one in a `static` is a compile error
  (`borrowed data escapes outside of closure`) rather than a use-after-free.
  To keep one anyway, `ctx.persist` copies it into the runtime's own registry
  and returns a `Persisted` that is not tied to the call:

  ```rust,ignore
  let last = RefCell::new(None);
  rt.register_fn("remember", 1, move |ctx| {
      *last.borrow_mut() = Some(ctx.persist(ctx.arg(0))?);
      Ok(ctx.undefined())
  })?;
  ```

  A `Persisted` holds a registry slot until it drops, and knows which runtime
  it belongs to.
- Reads inside a callback address the right runtime. A callback is handed a
  call context, not a runtime, and with several open there is no "the runtime"
  to fall back on — so `HostValue`'s readers go through the ABI's context tier
  (`jse_ctx_get_number` and friends), which is also the only tier that resolves
  the scope handles arguments carry. This is invisible from Rust: `ctx.arg(0)`
  carries its context, so `.as_number()` simply works.
- `ctx.call` results are freed for you. Each comes back runtime-owned,
  holding one of the registry's 65535 slots, and its `Retained` guard releases it
  on drop. That is what lets a host function call JS in a loop: the slot goes
  back as the loop turns, rather than piling up until the callback returns.

The closure is leaked deliberately. It is boxed and its pointer handed to
the engine as `udata`; the engine holds it for as long as the runtime lives and
offers no way to unregister, so there is no later moment at which dropping it
would be sound. This is bounded by the number of `register_fn` calls, never per
JS call. It is also why the closure must be `'static`: it can run at any point
up to `Runtime` drop, so it cannot borrow anything shorter-lived. Captured state
therefore uses `move`, and mutable state a `Cell`/`RefCell`, since the closure
is `Fn` (the engine may re-enter it) rather than `FnMut`.

## What the safe layer adds

- A `Value` borrows its `Runtime`, so the borrow checker rejects a value
  outliving the engine that owns it. The C ABI leaves that case to the
  caller's discipline.
- Slots are released on `Drop`, so the registry cannot be leaked into
  exhaustion by ordinary use.
- Error messages are copied out of the engine's buffer immediately, since
  that buffer is only valid until the next `jse_*` call.
- `Runtime` is `Send` but not `Sync`, which is the engine's threading rule
  stated in the type system rather than in prose. See below.

## Several runtimes

Any number of runtimes can be open at once. They share nothing — separate
globals, objects, prototypes, shapes, and interned strings:

```rust
let a = Runtime::new()?;
let b = Runtime::new()?;

a.eval_unit("globalThis.x = 'from A'")?;
b.eval_unit("globalThis.x = 'from B'")?;

assert_eq!(a.eval("x")?.as_string()?, "from A");
assert_eq!(b.eval("x")?.as_string()?, "from B");
```

A value belongs to the runtime that made it. The C ABI answers a handle from
the wrong runtime with `JSE_ERR_INVALID` rather than resolving it against an
unrelated value; in Rust the case cannot arise, because `Value<'rt>` borrows its
runtime and no method on another accepts one. To move a value, read it out and
write it back in. `cargo run --example two_runtimes` walks all of this.

### Threads

`Runtime` is `Send` and deliberately not `Sync`:

- **Two runtimes on two threads share nothing.** They hold no common state, so
  this is sound, and `Send` is what lets you build a runtime on one thread and
  drive it on another, or give every worker its own.
- **One runtime on two threads at once would corrupt it.** The engine takes no
  locks. `!Sync` makes that a compile error: with no shareable `&Runtime`, two
  threads cannot both reach one instance. Wrapping it in a `Mutex<Runtime>` is
  the opt-in, and is `Sync`, because the lock supplies the exclusion the engine
  does not.

`Value` is neither `Send` nor `Sync`, which follows for free: it borrows its
runtime, and `&Runtime` is not `Send` precisely because `Runtime` is not `Sync`.

## Limitations

These come from the C ABI, not from this binding.

- Registration is permanent. There is no `unregister`, which is why leaking
  the closure matches its actual lifetime.
- A JS function cannot be called from outside a callback. `ctx.call` needs a
  live call context, so from plain Rust code wrap the call in a JS snippet and
  use `eval`.
- Readers do not coerce. `as_number` on a string is `Kind::Type`, not a
  parse. Call `String(x)` or `Number(x)` in JS first.
- The ABI has no entry point for building objects or arrays. A host function
  can return numbers, booleans, strings, `null`, `undefined`, or a value it was
  handed; anything structured has to be assembled in JS.

## ABI fix made while writing this

`jse_get_number`, `jse_get_bool`, and `jse_get_string` returned `JSE_ERR_TYPE`
and `JSE_ERR_FULL` without ever touching the runtime's error state, so
`jse_last_error` reported whatever the *previous* failure had left there: a
stale message, sometimes from an unrelated call. They now set a specific
message on failure and clear it on success, matching what the header promises
of every other entry point. Fixed in `src/capi.c3`; the contract is now spelled
out in `include/jse.h` under `jse_last_error`.

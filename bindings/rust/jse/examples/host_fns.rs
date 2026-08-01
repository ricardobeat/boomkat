//! Call Rust from JavaScript.
//!
//!     cargo run --example host_fns
//!
//! `register_fn` binds a Rust closure as a JS global. This walks the four
//! things a host actually needs: arguments and a return value, captured state,
//! throwing, and calling a JS function back from Rust.

use jse::{Error, Kind, Runtime};
use std::cell::Cell;

fn main() -> Result<(), Error> {
    let rt = Runtime::new()?;

    // --- arguments in, a value out ---------------------------------------
    //
    // The closure reads its arguments off the context and returns a value
    // built from it. `2` is the reported `.length`; JS may still pass any
    // number of arguments, and `arg` past the end reads as `undefined`.
    rt.register_fn("add", 2, |ctx| {
        let mut sum = 0.0;
        for i in 0..ctx.argc() {
            sum += ctx.arg(i).as_number()?;
        }
        Ok(ctx.number(sum))
    })?;

    println!("add(40, 2)        = {}", rt.eval("add(40, 2)")?.as_number()?);
    println!("add(1,2,3,4)      = {}", rt.eval("add(1,2,3,4)")?.as_number()?);
    println!("[1,2,3].map(...)  = {}", rt.eval("[1,2,3].map(n => add(n, 10)).join()")?.as_string()?);

    // --- captured state ---------------------------------------------------
    //
    // The closure is boxed and leaked at registration, so whatever it captures
    // lives as long as the runtime. It is `Fn`, not `FnMut` — the engine can
    // re-enter it — so mutable state goes through a `Cell`.
    let calls = Cell::new(0u32);
    rt.register_fn("nextId", 0, move |ctx| {
        calls.set(calls.get() + 1);
        Ok(ctx.string(&format!("id-{}", calls.get())))
    })?;

    println!("nextId() x3       = {}", rt.eval("[nextId(), nextId(), nextId()].join()")?.as_string()?);

    // --- throwing ---------------------------------------------------------
    //
    // Returning `Err` throws into the calling script, where an ordinary
    // try/catch sees it. The error's `Kind` picks the JS constructor:
    // `Error::throw` is a plain `Error`, and a failed reader — `as_number` on
    // a string, below — is a `TypeError`.
    rt.register_fn("checkedSqrt", 1, |ctx| {
        let n = ctx.arg(0).as_number()?;
        if n < 0.0 {
            return Err(Error::throw(format!("cannot sqrt {n}")));
        }
        Ok(ctx.number(n.sqrt()))
    })?;

    println!("checkedSqrt(81)   = {}", rt.eval("checkedSqrt(81)")?.as_number()?);
    println!(
        "caught in JS      = {}",
        rt.eval("try { checkedSqrt(-1) } catch (e) { e.constructor.name + ': ' + e.message }")?
            .as_string()?
    );
    println!(
        "bad argument type = {}",
        rt.eval("try { checkedSqrt('nope') } catch (e) { e.constructor.name }")?.as_string()?
    );

    // Uncaught, the same throw reaches Rust as an ordinary `Err`.
    match rt.eval("checkedSqrt(-4)") {
        Ok(_) => println!("unexpected: throw returned a value"),
        Err(e) => println!("uncaught in Rust  = {} ({:?})", e.message(), e.kind()),
    }

    // A panic must never unwind into C, so the boundary catches it and throws
    // instead. The engine stays consistent and the script can catch it.
    rt.register_fn("panics", 0, |_| panic!("something went wrong"))?;
    let hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {})); // keep the default trace out of the output
    let caught = rt.eval("try { panics() } catch (e) { e.message }")?.as_string()?;
    std::panic::set_hook(hook);
    println!("panic became      = {caught}");

    // --- calling JS back from Rust ----------------------------------------
    //
    // `ctx.call` invokes a JS function from inside the callback. A throw from
    // the callee propagates as itself, so `?` here re-raises the original
    // exception rather than replacing it with a host error.
    //
    // Each result is a `Retained` guard owning one registry slot. `*once`
    // passes it on while it is alive, and `keep()` hands the final one to the
    // call, which frees it on return. `once` is freed as this closure ends.
    rt.register_fn("mapTwice", 2, |ctx| {
        let f = ctx.arg(0);
        let once = ctx.call(f, &[ctx.arg(1)], None)?;
        Ok(ctx.call(f, &[*once], None)?.keep())
    })?;

    println!("mapTwice(x*3, 5)  = {}", rt.eval("mapTwice(x => x * 3, 5)")?.as_number()?);
    println!("mapTwice(abs, -7) = {}", rt.eval("mapTwice(Math.abs, -7)")?.as_number()?);
    println!(
        "callee throw      = {}",
        rt.eval(
            "try { mapTwice(() => { throw new RangeError('from JS') }, 1) } \
             catch (e) { e.constructor.name + ': ' + e.message }"
        )?
        .as_string()?
    );

    // Host -> JS -> host recursion is bounded by the engine rather than
    // running the native stack into the ground.
    println!(
        "runaway recursion = {}",
        rt.eval("try { mapTwice(function f(n) { return mapTwice(f, n) }, 1) } catch (e) { e.constructor.name }")?
            .as_string()?
    );

    // Everything still works after all of that.
    assert_eq!(rt.eval("add(21, 21)")?.as_number()?, 42.0);
    assert_eq!(rt.eval("checkedSqrt(-1)").unwrap_err().kind(), Kind::Throw);

    println!("ok");
    Ok(())
}

//! Evaluate JavaScript from Rust.
//!
//!     cargo run --example hello_js
//!
//! Covers the whole v1 surface: open, eval for a value, read numbers and
//! strings, surface a syntax error and a thrown exception as `Result::Err`,
//! and let `Drop` clean everything up.

use jse::{Kind, Runtime, Type};

fn main() -> Result<(), jse::Error> {
    let rt = Runtime::new()?;
    println!("jse {}", Runtime::version());

    // A value comes back from the completion value of the snippet, exactly as
    // `eval()` would produce it.
    let sum = rt.eval("[1, 2, 3, 4].reduce((a, b) => a + b, 0)")?;
    println!("sum        = {}", sum.as_number()?);

    // Strings are copied out as UTF-8. The engine stores text as CESU-8
    // internally, so astral characters survive the trip intact.
    let greeting = rt.eval("'hello ' + ['w','o','r','l','d'].join('') + ' \\u{1F600}'")?;
    println!("greeting   = {}", greeting.as_string()?);
    println!("its type   = {:?}", greeting.type_of());

    // Reading a value as the wrong type is an error, not a silent coercion.
    match sum.as_string() {
        Ok(s) => println!("unexpected: {s}"),
        Err(e) => println!("wrong type = {e}"),
    }

    // Side-effecting evaluation: state persists across calls on one runtime.
    rt.eval_unit("globalThis.counter = 0;")?;
    rt.eval_unit("for (let i = 0; i < 5; i++) counter += i;")?;
    println!("counter    = {}", rt.eval("counter")?.as_number()?);

    // A syntax error surfaces as Err, with the engine's own message.
    match rt.eval("var = = =") {
        Ok(_) => println!("unexpected: bad syntax compiled"),
        Err(e) => {
            assert_eq!(e.kind(), Kind::Syntax);
            println!("syntax     = {e}");
        }
    }

    // So does an uncaught throw. The runtime stays usable afterwards.
    match rt.eval("throw new TypeError('nope')") {
        Ok(_) => println!("unexpected: throw returned a value"),
        Err(e) => {
            assert_eq!(e.kind(), Kind::Throw);
            println!("throw      = {e}");
        }
    }

    // Caught in JS, the engine recovers and hands back a normal value.
    let recovered = rt.eval("try { null.x } catch (e) { e.constructor.name }")?;
    println!("recovered  = {}", recovered.as_string()?);

    // Promise jobs are drained before eval returns.
    let resolved = rt.eval("let out = 'pending'; Promise.resolve('done').then(v => out = v); out")?;
    println!("before job = {}", resolved.as_string()?);
    println!("after job  = {}", rt.eval("out")?.as_string()?);

    // Types are reported without coercion.
    for src in ["null", "undefined", "true", "1.5", "'s'", "({})", "(()=>{})"] {
        print!("{:?} ", rt.eval(src)?.type_of());
    }
    println!();

    // Only one runtime may exist per process; a second is refused rather than
    // corrupting the first.
    match Runtime::new() {
        Ok(_) => println!("unexpected: second runtime opened"),
        Err(e) => println!("second rt  = {e}"),
    }

    assert_eq!(rt.eval("'x'")?.type_of(), Type::String);

    // `rt` and every Value drop here: slots released, then the heap freed.
    println!("ok");
    Ok(())
}

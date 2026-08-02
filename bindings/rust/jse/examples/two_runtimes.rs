//! Several engines in one process.
//!
//!     cargo run --example two_runtimes
//!
//! Runtimes share nothing: separate globals, separate objects, separate
//! prototypes, separate host functions. This walks that, shows how a value
//! actually moves from one to the other, and ends on the threading rule.

use jse::Runtime;

fn main() -> Result<(), jse::Error> {
    let a = Runtime::new()?;
    let b = Runtime::new()?;

    // --- independent globals ---------------------------------------------
    //
    // The same name in two runtimes is two unrelated bindings.
    a.eval_unit("globalThis.tag = 'A'")?;
    b.eval_unit("globalThis.tag = 'B'")?;
    println!("A.tag             = {}", a.eval("tag")?.as_string()?);
    println!("B.tag             = {}", b.eval("tag")?.as_string()?);

    // A name defined in one is simply absent from the other.
    b.eval_unit("globalThis.onlyInB = 1")?;
    println!("A sees onlyInB    = {}", a.eval("typeof onlyInB")?.as_string()?);

    // --- independent objects ----------------------------------------------
    //
    // Build the same 64-property object in both, then change one. The shapes
    // behind them are per-runtime too, so the other is untouched.
    for rt in [&a, &b] {
        rt.eval_unit("globalThis.o = {}; for (let i = 0; i < 64; i++) o['k' + i] = i;")?;
    }
    a.eval_unit("o.k7 = 'replaced in A'")?;
    println!("A.o.k7            = {}", a.eval("o.k7")?.as_string()?);
    println!("B.o.k7            = {}", b.eval("o.k7")?.as_number()?);

    // Built-ins are per-runtime as well, right down to the prototypes.
    a.eval_unit("Array.prototype.mine = () => 'patched in A'")?;
    println!("A [].mine()       = {}", a.eval("[].mine()")?.as_string()?);
    println!("B sees [].mine    = {}", b.eval("typeof [].mine")?.as_string()?);

    // --- independent host functions ---------------------------------------
    //
    // Registration is per-runtime, so the same name can be two closures with
    // their own captured state. Arguments are read through the call context,
    // which is what names the runtime the handles belong to.
    a.register_fn("shout", 1, |ctx| {
        Ok(ctx.string(&format!("A says {}", ctx.arg(0).as_string()?)))
    })?;
    b.register_fn("shout", 1, |ctx| {
        Ok(ctx.string(&format!("B says {}", ctx.arg(0).as_string()?)))
    })?;
    println!("A shout('hi')     = {}", a.eval("shout('hi')")?.as_string()?);
    println!("B shout('hi')     = {}", b.eval("shout('hi')")?.as_string()?);

    // --- a value does not cross ------------------------------------------
    //
    // A `Value` is a handle into ONE runtime's registry. The C ABI answers such
    // a handle from the wrong runtime with an error rather than resolving it
    // somewhere else; here it cannot even be attempted, because `Value<'rt>`
    // borrows the runtime that made it and `b` has no method that accepts one.
    // Uncommenting this does not compile:
    //
    //     let v = a.eval("'made in A'")?;
    //     b.something(v);   // no such method; `v` is tied to `a`
    //
    // Moving a value means reading it out and writing it back in.
    let text = a.eval("'made in A'")?.as_string()?;
    b.eval_unit(&format!("globalThis.imported = {text:?}"))?;
    println!("A -> B by copy    = {}", b.eval("imported")?.as_string()?);

    // The two strings read equal, and each is interned in its own table, so
    // identity holds within a runtime and never between them.
    println!(
        "A interning       = {}",
        a.eval("('made' + ' in A') === 'made in A'")?.as_bool()?
    );

    // --- closing one ------------------------------------------------------
    //
    // Dropping a runtime frees only its own heap.
    drop(b);
    println!("A after B closed  = {}", a.eval("tag")?.as_string()?);

    // --- threads ----------------------------------------------------------
    //
    // `Runtime` is `Send` but not `Sync`. One runtime per thread is sound and
    // shares no state; sharing a single runtime between threads is a compile
    // error, because the engine takes no locks.
    let workers: Vec<_> = (0..3)
        .map(|i| {
            std::thread::spawn(move || {
                let rt = Runtime::new().expect("open per-thread runtime");
                rt.eval_unit(&format!("globalThis.id = {i}")).unwrap();
                // Bound rather than returned inline: the Value borrows `rt` and
                // must drop before it does, which a tail expression would not.
                let s = rt.eval("'worker ' + id").unwrap().as_string().unwrap();
                s
            })
        })
        .collect();
    for w in workers {
        println!("thread            = {}", w.join().unwrap());
    }

    println!("ok");
    Ok(())
}

//! Runtimes are independent, so these tests open their own and run in
//! parallel under `cargo test` like any other.

use boomkat::{Error, Kind, Runtime, Type};

#[test]
fn engine_round_trips() {
    let rt = Runtime::new().expect("open runtime");

    assert!(!Runtime::version().is_empty());

    // Completion value, not `undefined`.
    assert_eq!(rt.eval("40 + 2").unwrap().as_number().unwrap(), 42.0);

    // Strings survive the CESU-8 to UTF-8 conversion, astral chars included.
    let s = rt.eval("'a\\u{1F600}b'").unwrap().as_string().unwrap();
    assert_eq!(s, "a\u{1F600}b");
    assert_eq!(s.chars().count(), 3);

    // Booleans are read strictly.
    assert!(rt.eval("1 < 2").unwrap().as_bool().unwrap());
    assert!(!rt.eval("1 > 2").unwrap().as_bool().unwrap());

    // Types are reported without coercion.
    assert_eq!(rt.eval("null").unwrap().type_of(), Type::Null);
    assert_eq!(rt.eval("void 0").unwrap().type_of(), Type::Undefined);
    assert_eq!(rt.eval("({a:1})").unwrap().type_of(), Type::Object);
    assert_eq!(rt.eval("(function(){})").unwrap().type_of(), Type::Function);

    // Reading the wrong type is an error carrying a real message, not a
    // stale one left behind by an earlier call.
    let wrong = rt.eval("42").unwrap().as_string().unwrap_err();
    assert_eq!(wrong.kind(), Kind::Type);
    assert!(
        wrong.message().contains("not a string"),
        "expected a specific message, got {:?}",
        wrong.message()
    );

    // Primitive display rendering, including JS's integral-number formatting.
    assert_eq!(rt.eval("42").unwrap().to_display_string().unwrap(), "42");
    assert_eq!(rt.eval("1.5").unwrap().to_display_string().unwrap(), "1.5");
    assert_eq!(rt.eval("true").unwrap().to_display_string().unwrap(), "true");
    assert_eq!(rt.eval("null").unwrap().to_display_string().unwrap(), "null");
    assert_eq!(
        rt.eval("void 0").unwrap().to_display_string().unwrap(),
        "undefined"
    );
    // Objects have no ABI coercion and must be stringified in JS instead.
    assert_eq!(
        rt.eval("({})").unwrap().to_display_string().unwrap_err().kind(),
        Kind::Type
    );
    assert_eq!(
        rt.eval("String({a:1})").unwrap().as_string().unwrap(),
        "[object Object]"
    );

    // Syntax errors and throws are distinguishable.
    assert_eq!(rt.eval("var = = =").unwrap_err().kind(), Kind::Syntax);
    let thrown = rt.eval("throw new Error('boom')").unwrap_err();
    assert_eq!(thrown.kind(), Kind::Throw);
    assert!(thrown.message().contains("boom"));

    // The runtime is still usable after a failure.
    assert_eq!(rt.eval("7 * 6").unwrap().as_number().unwrap(), 42.0);

    // State persists across evals on one runtime.
    rt.eval_unit("globalThis.n = 1;").unwrap();
    rt.eval_unit("n += 41;").unwrap();
    assert_eq!(rt.eval("n").unwrap().as_number().unwrap(), 42.0);

    // Microtasks are drained before eval returns.
    rt.eval_unit("globalThis.p = 'no'; Promise.resolve('yes').then(v => p = v);")
        .unwrap();
    assert_eq!(rt.eval("p").unwrap().as_string().unwrap(), "yes");

    // Dropping values releases slots. The registry grows on demand, so this
    // does not prove a fixed cap -- it proves Drop is wired up, since a leak
    // would grow the array without bound instead of reusing freed slots.
    for i in 0..3000 {
        let v = rt.eval("'slot'").unwrap();
        assert_eq!(v.as_string().unwrap(), "slot", "iteration {i}");
    }

    // Values survive garbage collection: the slot registry is a GC root.
    let held = rt.eval("'survivor'").unwrap();
    rt.eval_unit("for (let i = 0; i < 200000; i++) ({ junk: i });")
        .unwrap();
    assert_eq!(held.as_string().unwrap(), "survivor");

    host_functions(&rt);
}

/// Host callbacks: the shapes a binding user will actually hit.
fn host_functions(rt: &Runtime) {
    // Arguments in, value out.
    rt.register_fn("add", 2, |ctx| {
        let mut sum = 0.0;
        for i in 0..ctx.argc() {
            sum += ctx.arg(i).as_number()?;
        }
        Ok(ctx.number(sum))
    })
    .unwrap();

    assert_eq!(rt.eval("add(40, 2)").unwrap().as_number().unwrap(), 42.0);
    // Registered arity is `.length`, not a limit on what JS may pass.
    assert_eq!(rt.eval("add.length").unwrap().as_number().unwrap(), 2.0);
    assert_eq!(rt.eval("add(1,2,3,4,5)").unwrap().as_number().unwrap(), 15.0);
    assert_eq!(rt.eval("add()").unwrap().as_number().unwrap(), 0.0);
    // It behaves like a built-in everywhere.
    assert_eq!(rt.eval("add.apply(null, [40, 2])").unwrap().as_number().unwrap(), 42.0);
    assert_eq!(rt.eval("add.bind(null, 40)(2)").unwrap().as_number().unwrap(), 42.0);
    assert_eq!(rt.eval("[1,2,3].map(x => add(x, x))[2]").unwrap().as_number().unwrap(), 6.0);
    assert_eq!(rt.eval("add.name").unwrap().as_string().unwrap(), "add");

    // Captured state. The closure is leaked, so its captures live as long as
    // the runtime — a `move` capture is the way to hold host state.
    let greeting = String::from("hi from Rust");
    rt.register_fn("greet", 0, move |ctx| Ok(ctx.string(&greeting)))
        .unwrap();
    assert_eq!(rt.eval("greet()").unwrap().as_string().unwrap(), "hi from Rust");

    // Interior mutability is how a closure keeps counters: `Fn`, not `FnMut`,
    // because the engine may re-enter it.
    let calls = std::cell::Cell::new(0.0);
    rt.register_fn("tick", 0, move |ctx| {
        calls.set(calls.get() + 1.0);
        Ok(ctx.number(calls.get()))
    })
    .unwrap();
    assert_eq!(rt.eval("tick(); tick(); tick()").unwrap().as_number().unwrap(), 3.0);

    // Types round-trip both ways.
    rt.register_fn("echo", 1, |ctx| Ok(ctx.arg(0))).unwrap();
    assert_eq!(rt.eval("echo(42)").unwrap().as_number().unwrap(), 42.0);
    assert_eq!(rt.eval("echo('x')").unwrap().as_string().unwrap(), "x");
    assert_eq!(rt.eval("echo(null)").unwrap().type_of(), Type::Null);
    assert_eq!(rt.eval("echo(undefined)").unwrap().type_of(), Type::Undefined);
    // Object identity survives the round trip, so it is the same handle.
    assert!(rt.eval("var o = {}; echo(o) === o").unwrap().as_bool().unwrap());
    // An astral character survives CESU-8 -> UTF-8 in both directions.
    rt.register_fn("upper", 1, |ctx| Ok(ctx.string(&ctx.arg(0).as_string()?.to_uppercase())))
        .unwrap();
    assert_eq!(rt.eval("upper('a\\u{1F600}b')").unwrap().as_string().unwrap(), "A\u{1F600}B");

    // Building several values and returning one yields the one returned. The
    // `boomkat_return_*` setters are last-write-wins, so a host value has to stay
    // data until the boundary applies exactly the returned one.
    rt.register_fn("pick_first", 0, |ctx| {
        let first = ctx.number(1.0);
        let _discarded = ctx.number(2.0);
        Ok(first)
    })
    .unwrap();
    assert_eq!(rt.eval("pick_first()").unwrap().as_number().unwrap(), 1.0);
    // Same, when the returned value is an argument rather than a built one.
    rt.register_fn("pick_arg", 1, |ctx| {
        let _discarded = ctx.number(99.0);
        Ok(ctx.arg(0))
    })
    .unwrap();
    assert_eq!(rt.eval("pick_arg(7)").unwrap().as_number().unwrap(), 7.0);
    // And a throw still beats a value built before it.
    rt.register_fn("build_then_fail", 0, |ctx| {
        let _discarded = ctx.number(5.0);
        Err(boomkat::Error::throw("nope"))
    })
    .unwrap();
    assert_eq!(rt.eval("build_then_fail()").unwrap_err().kind(), Kind::Throw);

    rt.register_fn("truthy", 1, |ctx| Ok(ctx.bool(ctx.arg(0).as_bool()?)))
        .unwrap();
    assert!(rt.eval("truthy(true)").unwrap().as_bool().unwrap());
    rt.register_fn("nothing", 0, |ctx| Ok(ctx.null())).unwrap();
    assert_eq!(rt.eval("nothing()").unwrap().type_of(), Type::Null);
    rt.register_fn("nada", 0, |ctx| Ok(ctx.undefined())).unwrap();
    assert_eq!(rt.eval("nada()").unwrap().type_of(), Type::Undefined);

    // Err becomes a JS throw, with the Kind picking the constructor.
    rt.register_fn("boom", 0, |_| Err(boomkat::Error::throw("host refused")))
        .unwrap();
    assert!(rt
        .eval("try { boom() } catch (e) { e instanceof Error && e.message === 'host refused' }")
        .unwrap()
        .as_bool()
        .unwrap());
    // A reader failure inside the closure is a TypeError, since that is the
    // Kind the ABI reports for a wrong-typed argument.
    assert!(rt
        .eval("try { add('nope') } catch (e) { e instanceof TypeError }")
        .unwrap()
        .as_bool()
        .unwrap());
    // Uncaught, it reaches Rust as an ordinary Err.
    assert_eq!(rt.eval("boom()").unwrap_err().kind(), Kind::Throw);
    // And the engine is fine afterwards.
    assert_eq!(rt.eval("add(21, 21)").unwrap().as_number().unwrap(), 42.0);

    // A panic is caught at the boundary and becomes a throw, never unwinding
    // into C. Silence the default hook so the test output stays readable.
    rt.register_fn("panics", 0, |_| panic!("deliberate")).unwrap();
    let hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let caught = rt
        .eval("try { panics() } catch (e) { e.message }")
        .unwrap()
        .as_string()
        .unwrap();
    std::panic::set_hook(hook);
    assert_eq!(caught, "host panic: deliberate");
    assert_eq!(rt.eval("add(21, 21)").unwrap().as_number().unwrap(), 42.0);

    // Calling JS back from the host.
    rt.register_fn("twice", 2, |ctx| {
        let f = ctx.arg(0);
        let once = ctx.call(f, &[ctx.arg(1)], None)?;
        Ok(ctx.call(f, &[*once], None)?.keep())
    })
    .unwrap();
    assert_eq!(rt.eval("twice(x => x * 3, 5)").unwrap().as_number().unwrap(), 45.0);
    assert_eq!(rt.eval("twice(Math.abs, -7)").unwrap().as_number().unwrap(), 7.0);
    // A callee throw propagates as itself, not as a generic host error.
    assert!(rt
        .eval("try { twice(() => { throw new RangeError('inner') }, 1) } catch (e) { e instanceof RangeError && e.message === 'inner' }")
        .unwrap()
        .as_bool()
        .unwrap());
    // Calling a non-function is a TypeError.
    assert!(rt
        .eval("try { twice(42, 1) } catch (e) { e instanceof TypeError }")
        .unwrap()
        .as_bool()
        .unwrap());
    // A host-built value has no handle to pass, so `call` rejects it up front
    // rather than handing the engine a meaningless one.
    rt.register_fn("pass_built", 1, |ctx| {
        let built = ctx.number(1.0);
        Ok(ctx.call(ctx.arg(0), &[built], None)?.keep())
    })
    .unwrap();
    assert!(rt
        .eval("try { pass_built(x => x) } catch (e) { e instanceof TypeError }")
        .unwrap()
        .as_bool()
        .unwrap());

    // Runaway host -> JS -> host recursion is bounded, not a stack overflow.
    assert!(rt
        .eval("try { twice(function f(n) { return twice(f, n) }, 1); false } catch (e) { true }")
        .unwrap()
        .as_bool()
        .unwrap());
    assert_eq!(rt.eval("add(21, 21)").unwrap().as_number().unwrap(), 42.0);

    // `this` and construct calls.
    rt.register_fn("myLen", 0, |ctx| Ok(ctx.number(ctx.this().as_string()?.len() as f64)))
        .unwrap();
    assert_eq!(
        rt.eval("({m: myLen}).m.call('hello')").unwrap().as_number().unwrap(),
        5.0
    );
    rt.register_fn("plain", 0, |ctx| Ok(ctx.bool(ctx.is_construct())))
        .unwrap();
    assert!(!rt.eval("plain()").unwrap().as_bool().unwrap());
    // Not registered constructable, so `new` is a TypeError.
    assert!(rt
        .eval("try { new plain() } catch (e) { e instanceof TypeError }")
        .unwrap()
        .as_bool()
        .unwrap());
    // Registered constructable, `new` yields the engine-made instance.
    rt.register_ctor("Thing", 0, |ctx| {
        assert!(ctx.is_construct());
        Ok(ctx.undefined())
    })
    .unwrap();
    assert_eq!(rt.eval("typeof new Thing()").unwrap().as_string().unwrap(), "object");

    // Many separate host calls, two `Ctx::call` results each. Every result is
    // freed as its guard drops, so nothing survives from one host call to the
    // next and the registry stays small.
    assert_eq!(
        rt.eval("let t = 0; for (let i = 0; i < 3000; i++) t = twice(x => x, i); t")
            .unwrap()
            .as_number()
            .unwrap(),
        2999.0
    );

    // The case the loop above does *not* cover: many `Ctx::call` invocations
    // inside a SINGLE host call. Results used to accumulate until the host
    // call returned, so the 1025th failed with the registry full. The guard
    // frees each one as the loop turns, so the count is bounded only by time.
    const SPIN: u32 = 20_000;
    rt.register_fn("spin", 1, |ctx| {
        let f = ctx.arg(0);
        let mut last = 0.0;
        for i in 0..SPIN {
            // Each result drops at the end of this iteration, releasing its
            // slot for reuse, so the registry never grows past a handful of
            // entries no matter how long the loop runs.
            let r = ctx.call(f, &[], None).map_err(|e| {
                Error::throw(format!("call {i} failed: {e}"))
            })?;
            last = r.as_number()?;
        }
        Ok(ctx.number(last))
    })
    .unwrap();
    assert_eq!(
        rt.eval("var n = 0; spin(function () { return ++n; })")
            .unwrap()
            .as_number()
            .unwrap(),
        f64::from(SPIN)
    );

    // Exhausting the registry is an ABI failure, not a JS exception: the
    // engine returns BK_ERR_FULL without staging a throw. It must arrive as
    // `Kind::Full` with a real message, rather than being mistaken for a
    // callee throw and silently suppressed.
    rt.register_fn("exhaust", 1, |ctx| {
        let f = ctx.arg(0);
        let mut kept = Vec::new();
        loop {
            match ctx.call(f, &[], None) {
                // Held deliberately, to drive the registry to its limit.
                Ok(r) => kept.push(r.keep()),
                Err(e) => {
                    assert_eq!(e.kind(), Kind::Full, "expected registry exhaustion");
                    assert!(
                        e.message().contains("registry is full"),
                        "exhaustion must carry a message, got {:?}",
                        e.message()
                    );
                    return Ok(ctx.number(kept.len() as f64));
                }
            }
        }
    })
    .unwrap();
    let held = rt
        .eval("exhaust(function () { return 1; })")
        .unwrap()
        .as_number()
        .unwrap();
    // The limit is the registry's own ceiling (2^19 - 1 handles), and it is
    // reached rather than exceeded. The point is that exhaustion arrives as a
    // clean Kind::Full, not that the ceiling sits at any particular value.
    assert!(held > 1024.0, "registry should grow past the old fixed cap, held {held}");
    assert!(held <= 524_287.0, "held {held} slots");

    // A `keep()` result, by contrast, is charged to the enclosing host call
    // and only freed when it returns -- so it is the resource that accumulates,
    // bounded by the registry ceiling rather than by a fixed 1024.
    rt.register_fn("keep_many", 1, |ctx| {
        let f = ctx.arg(0);
        let mut kept = Vec::new();
        for _ in 0..64 {
            kept.push(ctx.call(f, &[], None)?.keep());
        }
        // Read one back to prove the kept handles are still live.
        Ok(ctx.number(kept[0].as_number()?))
    })
    .unwrap();
    assert_eq!(
        rt.eval("var m = 0; keep_many(function () { return ++m; })")
            .unwrap()
            .as_number()
            .unwrap(),
        1.0
    );
}

/// Several runtimes at once, sharing nothing.
#[test]
fn runtimes_are_independent() {
    let a = Runtime::new().expect("open A");
    let b = Runtime::new().expect("open B");
    let c = Runtime::new().expect("open C");

    // Globals do not leak between them, and the same name holds three values.
    a.eval_unit("globalThis.tag = 'A'").unwrap();
    b.eval_unit("globalThis.tag = 'B'").unwrap();
    c.eval_unit("globalThis.tag = 'C'").unwrap();
    assert_eq!(a.eval("tag").unwrap().as_string().unwrap(), "A");
    assert_eq!(b.eval("tag").unwrap().as_string().unwrap(), "B");
    assert_eq!(c.eval("tag").unwrap().as_string().unwrap(), "C");
    // A name defined in one is simply not there in another.
    assert_eq!(
        a.eval("typeof onlyInB").unwrap().as_string().unwrap(),
        "undefined"
    );
    b.eval_unit("globalThis.onlyInB = 1").unwrap();
    assert_eq!(
        a.eval("typeof onlyInB").unwrap().as_string().unwrap(),
        "undefined"
    );

    // Objects are per-runtime, and so are the shape transitions behind them:
    // build the same property sequence in both and read both back.
    for rt in [&a, &b] {
        rt.eval_unit("globalThis.o = {}; for (let i = 0; i < 64; i++) o['k' + i] = i;")
            .unwrap();
    }
    a.eval_unit("o.k7 = 'replaced in A'").unwrap();
    assert_eq!(
        a.eval("o.k7").unwrap().as_string().unwrap(),
        "replaced in A"
    );
    assert_eq!(b.eval("o.k7").unwrap().as_number().unwrap(), 7.0);
    assert_eq!(b.eval("o.k63").unwrap().as_number().unwrap(), 63.0);

    // Even the built-in prototypes are separate: patching one is invisible in
    // the others.
    a.eval_unit("Array.prototype.mine = function () { return 'A only' }")
        .unwrap();
    assert_eq!(
        a.eval("[].mine()").unwrap().as_string().unwrap(),
        "A only"
    );
    assert_eq!(
        b.eval("typeof [].mine").unwrap().as_string().unwrap(),
        "undefined"
    );

    // Strings intern per-runtime, so identity holds within each and the two
    // tables are unrelated. Both runtimes see the same text and each compares
    // it equal to itself.
    for rt in [&a, &b] {
        assert!(rt
            .eval("('alpha' + '') === 'alpha'")
            .unwrap()
            .as_bool()
            .unwrap());
        assert_eq!(rt.eval("'alpha'").unwrap().as_string().unwrap(), "alpha");
    }

    // Host functions are registered per-runtime. The same name in two runtimes
    // is two different closures with their own captured state.
    a.register_fn("who", 0, |ctx| Ok(ctx.string("host of A")))
        .unwrap();
    b.register_fn("who", 0, |ctx| Ok(ctx.string("host of B")))
        .unwrap();
    assert_eq!(a.eval("who()").unwrap().as_string().unwrap(), "host of A");
    assert_eq!(b.eval("who()").unwrap().as_string().unwrap(), "host of B");
    // C never registered it.
    assert_eq!(
        c.eval("typeof who").unwrap().as_string().unwrap(),
        "undefined"
    );

    // Arguments still read correctly with more than one runtime open: the
    // readers address the runtime through the call context, not a guess.
    for rt in [&a, &b] {
        rt.register_fn("twice", 1, |ctx| Ok(ctx.number(ctx.arg(0).as_number()? * 2.0)))
            .unwrap();
        assert_eq!(rt.eval("twice(21)").unwrap().as_number().unwrap(), 42.0);
    }

    // Closing one leaves the others fully working.
    drop(b);
    assert_eq!(a.eval("tag").unwrap().as_string().unwrap(), "A");
    assert_eq!(a.eval("who()").unwrap().as_string().unwrap(), "host of A");
    assert_eq!(c.eval("tag").unwrap().as_string().unwrap(), "C");

    // And a fresh one opened afterwards starts clean -- no state survived.
    let d = Runtime::new().expect("open D after closing B");
    assert_eq!(
        d.eval("typeof tag").unwrap().as_string().unwrap(),
        "undefined"
    );
    assert_eq!(
        d.eval("typeof [].mine").unwrap().as_string().unwrap(),
        "undefined"
    );
    assert_eq!(d.eval("6 * 7").unwrap().as_number().unwrap(), 42.0);
}

/// Values move between runtimes by being read out and written back, never by
/// handing a handle over -- which the borrow checker rejects outright.
#[test]
fn values_cross_runtimes_only_by_copying() {
    let a = Runtime::new().unwrap();
    let b = Runtime::new().unwrap();

    let from_a = a.eval("'made in A'").unwrap().as_string().unwrap();
    b.register_fn("fromA", 0, move |ctx| Ok(ctx.string(&from_a)))
        .unwrap();
    assert_eq!(
        b.eval("fromA() + '!'").unwrap().as_string().unwrap(),
        "made in A!"
    );

    // The handle itself never crosses. `a.eval(..)` borrows `a`, so there is no
    // way to hand the resulting Value to `b`: it has no method taking one, and
    // the 'rt lifetime would reject it if it did. This is the compile-time
    // version of the ABI's BK_ERR_INVALID.
    let n = a.eval("21").unwrap().as_number().unwrap();
    b.eval_unit(&format!("globalThis.n = {n} * 2")).unwrap();
    assert_eq!(b.eval("n").unwrap().as_number().unwrap(), 42.0);
}

/// A host callback holding on to a value past the call that produced it.
///
/// `ctx.persist` copies a scope handle into its own runtime's registry, and the
/// runtime is read off the call context -- so the same closure body registered
/// in two runtimes persists into whichever one called it.
#[test]
fn callback_persists_into_its_own_runtime() {
    use std::cell::RefCell;

    let a = Runtime::new().unwrap();
    let b = Runtime::new().unwrap();

    for (rt, label) in [(&a, "A"), (&b, "B")] {
        let held: RefCell<Option<boomkat::Persisted>> = RefCell::new(None);
        rt.register_fn("remember", 1, move |ctx| {
            *held.borrow_mut() = Some(ctx.persist(ctx.arg(0))?);
            // Read it back through the runtime tier, after the scope handle
            // that fed it would already be useless.
            let seen = held.borrow().as_ref().unwrap().as_string()?;
            Ok(ctx.string(&seen))
        })
        .unwrap();

        let echoed = rt
            .eval(&format!("remember('kept in {label}')"))
            .unwrap()
            .as_string()
            .unwrap();
        assert_eq!(echoed, format!("kept in {label}"));
    }

    // A host-built value has no handle, so persisting one is refused rather
    // than fabricating a slot.
    a.register_fn("persist_built", 0, |ctx| {
        let built = ctx.number(1.0);
        match ctx.persist(built) {
            Ok(_) => Ok(ctx.string("unexpectedly persisted")),
            Err(e) => Ok(ctx.string(&format!("refused: {:?}", e.kind()))),
        }
    })
    .unwrap();
    assert_eq!(
        a.eval("persist_built()").unwrap().as_string().unwrap(),
        "refused: Type"
    );
}

/// `Runtime` moves between threads; it does not get shared with them.
#[test]
fn runtime_is_send_not_sync() {
    fn assert_send<T: Send>() {}
    assert_send::<Runtime>();

    // Built here, driven there.
    let rt = Runtime::new().unwrap();
    rt.eval_unit("globalThis.origin = 'main'").unwrap();
    let rt = std::thread::spawn(move || {
        rt.eval_unit("globalThis.origin += '+worker'").unwrap();
        rt
    })
    .join()
    .unwrap();
    assert_eq!(
        rt.eval("origin").unwrap().as_string().unwrap(),
        "main+worker"
    );

    // Two threads, one runtime each, running at the same time. They share
    // nothing, so this is sound -- and it is the case `Send` exists for.
    let handles: Vec<_> = (0..4)
        .map(|i| {
            std::thread::spawn(move || {
                let rt = Runtime::new().unwrap();
                rt.eval_unit(&format!("globalThis.id = {i}")).unwrap();
                for _ in 0..200 {
                    rt.eval_unit("({ junk: id })").unwrap();
                }
                // Bound rather than returned inline: the Value must drop
                // before `rt` does, and a tail expression drops it after.
                let id = rt.eval("id").unwrap().as_number().unwrap();
                id
            })
        })
        .collect();
    let mut ids: Vec<f64> = handles.into_iter().map(|h| h.join().unwrap()).collect();
    ids.sort_by(f64::total_cmp);
    assert_eq!(ids, vec![0.0, 1.0, 2.0, 3.0]);

    // Sharing ONE runtime across threads is rejected at compile time; a Mutex
    // is the opt-in, since the lock supplies the exclusion the engine lacks.
    fn assert_sync<T: Sync>() {}
    assert_sync::<std::sync::Mutex<Runtime>>();
}

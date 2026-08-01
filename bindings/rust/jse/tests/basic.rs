//! The engine allows only one runtime per process, and `cargo test` runs test
//! functions on parallel threads in a single process. So this is deliberately
//! ONE test function: opening a second runtime concurrently would fail by
//! design, and the failure would be an artefact of the harness, not a bug.

use jse::{Kind, Runtime, Type};

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

    // A second runtime is refused rather than corrupting the first.
    assert_eq!(Runtime::new().unwrap_err().kind(), Kind::AlreadyOpen);

    // Dropping values releases slots; the registry holds 1024, so this would
    // exhaust it if Drop were not wired up.
    for i in 0..3000 {
        let v = rt.eval("'slot'").unwrap();
        assert_eq!(v.as_string().unwrap(), "slot", "iteration {i}");
    }

    // Values survive garbage collection: the slot registry is a GC root.
    let held = rt.eval("'survivor'").unwrap();
    rt.eval_unit("for (let i = 0; i < 200000; i++) ({ junk: i });")
        .unwrap();
    assert_eq!(held.as_string().unwrap(), "survivor");
}

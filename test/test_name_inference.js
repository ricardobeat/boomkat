/// Regression tests for Function.prototype.name inference (B09).
///
/// ES2015 §14.1.20 SetFunctionName — anonymous function expressions inherit
/// the name of the variable/property they're being assigned to. Prior to the
/// fix, `var f = function() {}` produced f.name === ""; now it produces "f".

function check(name, actual, expected) {
    var ok = actual === expected;
    if (!ok) {
        print("FAIL: " + name + " — expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
        return false;
    }
    return true;
}

var all_pass = true;

// ── var/let/const inference ────────────────────────────────────────────────
{
    var f = function() {};
    all_pass &= check("var f name", f.name, "f");
}

{
    let g = function() {};
    all_pass &= check("let g name", g.name, "g");
}

{
    const h = function() {};
    all_pass &= check("const h name", h.name, "h");
}

// ── Multi-declarator var ──────────────────────────────────────────────────
{
    var x = function bar() {}, y = function() {};
    all_pass &= check("var x (named) name", x.name, "bar");
    all_pass &= check("var y name", y.name, "y");
}

{
    // `var a = 1` does NOT consume the inferred name, so the next declarator
    // `b = function() {}` should still see "b" as the inferred name.
    var a = 1, b = function() {};
    all_pass &= check("var b in multi-decl name", b.name, "b");
}

// ── Named function expression overrides inference ─────────────────────────
{
    var i = function innerFn() {};
    all_pass &= check("named override", i.name, "innerFn");
}

// ── Object literal value inference ─────────────────────────────────────────
{
    var o1 = { m: function() {} };
    all_pass &= check("obj value name", o1.m.name, "m");
}

// ── Object literal method shorthand ────────────────────────────────────────
{
    var o2 = { method() {} };
    all_pass &= check("method shorthand name", o2.method.name, "method");
}

// ── Object literal getter/setter ───────────────────────────────────────────
{
    var o3 = { get x() {}, set x(v) {} };
    var d = Object.getOwnPropertyDescriptor(o3, "x");
    all_pass &= check("obj getter name", d.get.name, "get x");
    all_pass &= check("obj setter name", d.set.name, "set x");
}

// ── Computed property key — inference from the runtime key value ──────────
// ES2015 §12.2.6.9 PropertyDefinitionEvaluation step 6 runs NamedEvaluation
// whenever IsAnonymousFunctionDefinition is true, with no exception for
// computed keys — SetFunctionName uses whatever propKey evaluates to.
{
    var key = "dynamic";
    var o4 = { [key]: function() {} };
    all_pass &= check("computed key name", o4.dynamic.name, "dynamic");
}

{
    var o5 = { ["dyn" + "amic"]: function() {} };
    all_pass &= check("computed expression name", o5.dynamic.name, "dynamic");
}

// ── Class methods ──────────────────────────────────────────────────────────
{
    class C {
        method() {}
        get prop() { return 1; }
        set prop(v) {}
        static staticMethod() {}
    }
    all_pass &= check("class method name", C.prototype.method.name, "method");
    var pd = Object.getOwnPropertyDescriptor(C.prototype, "prop");
    all_pass &= check("class getter name", pd.get.name, "get prop");
    all_pass &= check("class setter name", pd.set.name, "set prop");
    all_pass &= check("class static method name", C.staticMethod.name, "staticMethod");
}

// ── IIFE: inner var doesn't inherit outer var's inferred name ──────────────
{
    var outer = function() {};
    (function() {
        var inner = function() {};
        all_pass &= check("IIFE inner name", inner.name, "inner");
    })();
}

// ── Anonymous IIFE assigned to a variable ──────────────────────────────────
{
    // `var iife = (function() {})` infers the name "iife" from the assignment.
    var iife = (function() {});
    all_pass &= check("IIFE assigned to var name", iife.name, "iife");
}

// ── Arrow functions keep their name from the assignment ────────────────────
{
    var arrowFn = () => {};
    all_pass &= check("arrow assigned to var name", arrowFn.name, "arrowFn");
}

// ── Inner function with explicit name creates a name binding ──────────────
{
    // Named function expressions have the name in scope inside the body.
    var named = function inner() {
        return typeof inner;  // should be "function" — inner is in scope
    };
    all_pass &= check("named expr name binding", named(), "function");
}

// ── Nested assignment — inner function gets its own variable's name ────────
{
    var outer2 = function() {
        return function() {};
    };
    var fn = outer2();
    // fn was assigned via return, so it has no inferred name
    all_pass &= check("returned fn name", fn.name, "");
}

// ── Self-referential: inferred name does NOT create a name binding ─────────
{
    // Per ES2015 §14.1.20, only EXPLICIT named function expressions create
    // a name binding inside the body. `var f3 = function() {}` infers the
    // name "f3" but `f3` is NOT in scope inside the body (no name binding).
    var f3 = function() {
        try {
            return typeof f3;  // outer var is in scope, but here we test absence
        } catch (e) {
            return "threw";
        }
    };
    // The outer f3 is in scope (var hoisting), so this returns "function".
    all_pass &= check("outer var accessible", f3(), "function");
}

if (all_pass) {
    print("PASS: all B09 name inference assertions");
} else {
    print("FAIL: some B09 name inference assertions");
}

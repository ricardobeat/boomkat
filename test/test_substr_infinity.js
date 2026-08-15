// Regression test for String.prototype.substr edge cases the original
// implementation mis-handled: an explicit `undefined` length means "+∞"
// (§B.2.3 step 4), not the 0 that ToInteger(NaN) produces from a missing
// arg; and `start = ±Infinity` previously coerced through `(int)(long)Inf`
// (UB on most platforms, INT_MIN), which then leaked into the
// result-length computation and either hung or produced a runaway slice.

function expect(name, fn, expected) {
    try {
        var actual = fn();
        if (actual === expected) {
            print("PASS " + name + ": " + JSON.stringify(actual));
            return true;
        }
        print("FAIL " + name + ": got " + JSON.stringify(actual) + " expected " + JSON.stringify(expected));
        return false;
    } catch (e) {
        print("FAIL " + name + ": unexpected " + e.constructor.name + ": " + e.message);
        return false;
    }
}

// undefined length — the regression that surfaced the bug.
expect("substr(0, undefined)",      function () { return "abc".substr(0, undefined); },      "abc");
expect("substr(1, undefined)",      function () { return "abc".substr(1, undefined); },      "bc");
expect("substr(2, undefined)",      function () { return "abc".substr(2, undefined); },      "c");
expect("substr(3, undefined)",      function () { return "abc".substr(3, undefined); },      "");
expect("substr(-1, undefined)",     function () { return "abc".substr(-1, undefined); },     "c");
expect("substr(NaN, undefined)",    function () { return "abc".substr(NaN, undefined); },    "abc");

// null length still goes through ToInteger → 0.
expect("substr(0, null)",           function () { return "abc".substr(0, null); },           "");
expect("substr(1, null)",           function () { return "abc".substr(1, null); },           "");

// ±Infinity start — was UB before; now properly clamps.
expect("substr(Infinity, 1)",       function () { return "abc".substr(Infinity, 1); },       "");
expect("substr(Infinity, 5)",       function () { return "abc".substr(Infinity, 5); },       "");
expect("substr(-Infinity, 2)",      function () { return "abc".substr(-Infinity, 2); },      "ab");
expect("substr(Infinity, Infinity)",function () { return "abc".substr(Infinity, Infinity);},"");
expect("substr(-Infinity, undefined)", function () { return "abc".substr(-Infinity, undefined); }, "abc");

// Sanity checks for the unaffected branches.
expect("substr(1, 3)",              function () { return "hello".substr(1, 3); },            "ell");
expect("substr(-3, 2)",             function () { return "hello".substr(-3, 2); },           "ll");
expect("substr(0, undefined) of empty", function () { return "".substr(0, undefined); },     "");
expect("substr(10, 2)",             function () { return "hello".substr(10, 2); },           "");
expect("substr(0, -1)",             function () { return "hello".substr(0, -1); },           "");
expect("substr(NaN, 2)",            function () { return "hello".substr(NaN, 2); },          "he");
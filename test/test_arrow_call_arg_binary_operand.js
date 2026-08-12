// An arrow passed as a CALL ARGUMENT must not be mistaken for a bare arrow
// used as a binary operand.
//
// ArrowFunction is AssignmentExpression-level, so it may not appear directly
// as a binary operand — `1 + () => 2` is a SyntaxError (ES §13.16, §13.15).
// `check_no_arrow_rhs` enforces that via a `last_was_arrow_expr` flag.
//
// But an arrow inside a call's parentheses is NOT that: the flag survived the
// argument parse, and nothing between there and the enclosing binary_expr's
// post-RHS check cleared it. So every one of these was rejected with
// "arrow function in expression position not allowed":
//
//     true  && a.every((x, i) => x > 0)
//     false || a.every((x, i) => x > 0)
//     null  ?? a.every((x, i) => x > 0)
//     1 + a.filter((x, i) => x > 0).length
//
// Any binary operator, any arrow arity. This is extremely common in real code
// — `a.length === b.length && a.every((x, i) => eq(x, b[i]))` is the line that
// broke typescript 5.4.5 — yet the whole test262 corpus passes with it
// present, because the suite tests the two constructs separately and never
// nests one in the other this way.
//
// The fix clears the flag when a CallExpression finishes parsing. The negative
// cases below matter as much as the positive ones: the guard must still reject
// a genuinely bare arrow.
var failures = 0;
function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        print("FAIL: " + msg + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

var a = [1, 2, 3];

// Every binary operator, with a call-argument arrow on the right.
assertEq(true && a.every(function (x) { return x > 0; }), true, "control: function expression");
assertEq(true && a.every((x, i) => x > 0), true, "&& with a 2-parameter arrow");
assertEq(true && a.every((x) => x > 0), true, "&& with a parenthesised 1-parameter arrow");
assertEq(true && a.every(x => x > 0), true, "&& with a bare-parameter arrow");
assertEq(false || a.every((x, i) => x > 0), true, "|| with an arrow argument");
assertEq(null ?? a.every((x, i) => x > 0), true, "?? with an arrow argument");
assertEq(1 + a.filter((x, i) => x > 0).length, 4, "+ with an arrow argument");
assertEq((1 === 1) && a.every((x, i) => x > 0), true, "=== then && with an arrow argument");
assertEq(a.length === 3 && a.every((x, i) => x === a[i]), true,
    "the typescript 5.4.5 shape");

// The arrow on the LEFT operand of the binary operator.
assertEq(a.every((x, i) => x > 0) && true, true, "arrow argument on the left of &&");
assertEq(a.filter((x, i) => x > 1).length + 1, 3, "arrow argument on the left of +");

// Chained and nested.
assertEq(true && a.every((x, i) => x > 0) && a.some((x, i) => x === 2), true,
    "two arrow-argument calls in one && chain");
assertEq(true && a.map((x, i) => x + i).every((y, j) => y >= 1), true,
    "arrow argument on a chained method call");
assertEq([true && a.every((x, i) => x > 0)][0], true, "inside an array literal");
assertEq((function () { return true && a.every((x, i) => x > 0); }()), true,
    "inside a function body");

// A multi-statement arrow body, and an arrow returning an object literal.
assertEq(true && a.every((x, i) => { return x > 0; }), true, "block-bodied arrow argument");
assertEq(true && a.map((x) => ({ v: x }))[0].v, 1, "arrow returning an object literal");

// Async arrows and default/rest parameters in the same position. (The async
// arrow is asserted only as far as PARSING here — `a.map(async x => x)` not
// returning promises is a separate builtin bug, tracked as B18.)
assertEq(typeof (true && a.map(async (x) => x)), "object", "async arrow argument parses");
assertEq(true && a.every((x, i = 0) => x > i), true, "arrow with a default parameter");
assertEq(true && a.every((...xs) => xs[0] > 0), true, "arrow with a rest parameter");

// NEGATIVE side: a genuinely bare arrow as a binary operand is still a
// SyntaxError. These cannot be written directly (the file would not parse), so
// they are asserted through the compile-error surface instead — see
// test/compile_error_messages/run.sh, which pins `1 + () => 2` and friends.
// What is checked here is that a PARENTHESISED arrow, which is legal, works:
assertEq(true && ((x, i) => x > 0)(1, 2), true, "parenthesised arrow, then called");
assertEq(typeof (true && ((x, i) => x > 0)), "function", "parenthesised arrow as an operand");

if (failures === 0) {
    print("PASS: arrow as a call argument in a binary operand");
} else {
    print("FAILURES: " + failures);
}

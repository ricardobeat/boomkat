// A YieldExpression operand inherits the enclosing `[In]` grammar parameter.
//
// `yield [no LineTerminator here] AssignmentExpression[?In, +Yield]` — the
// `?In` propagates, so in a `[~In]` position (a C-style for head) the operand
// may not consume an `in` either. `for (yield '' in {}; ; ) ;` is therefore a
// SyntaxError, and so is the `yield*` form.
//
// binary_expr consumes `forbid_in` on entry, so it cannot leak into a nested
// `[+In]` construct like `f(a in b)`. That is right for those, but a
// YieldExpression is not one of them: it propagates `?In` rather than forcing
// `+In`, and it is handled in primary_expr, far below the point where the flag
// was cleared. The operand consequently parsed with `in` allowed.
//
// test262 language/expressions/yield/in-iteration-stmt.js and
// star-in-iteration-stmt.js cover exactly this; both are negative PARSE tests,
// which is why nothing in the runtime suites could have caught it.
//
// NOTE: the rejection cases live in test/toplevel_syntax (a parse-time
// failure takes the whole file down), so this file asserts the cases that must
// still be ACCEPTED — the over-correction risk. The two rejections are pinned
// by test262 itself.
var failures = 0;
function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        print("FAIL: " + msg + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// `in` inside a yield operand is legal wherever the position is `[+In]` —
// which is everywhere except a for head. Reaching this line means it parsed.
function* g1() { var x = yield 'k' in { k: 1 }; return x; }
(function () {
    var it = g1();
    var first = it.next();
    assertEq(first.value, true, "the operand's `in` evaluated before yielding");
    assertEq(first.done, false, "generator suspended at the yield");
    assertEq(it.next("resumed").value, "resumed", "resume value is returned");
}());

// Parenthesised, which re-fixes `[+In]`, so it is legal even in a for head.
function* g2() { for (var a = ('k' in { k: 1 }); false;) { } return a; }
(function () {
    var it = g2();
    assertEq(it.next().value, true, "a parenthesised `in` is legal in a for-init");
}());

// A yield in a for-init with no `in` at all must keep working.
function* g3() { for (yield 1; false;) { } return "done"; }
(function () {
    var it = g3();
    assertEq(it.next().value, 1, "a bare yield in a for-init still yields");
    assertEq(it.next().value, "done", "and the loop still completes");
}());

// The parenthesised yield operand form, also legal in a for-init.
function* g4() { for (var i = (yield 'a' in { a: 1 }); i !== "x";) { break; } return "ok"; }
(function () {
    var it = g4();
    assertEq(it.next().value, true, "parenthesised yield operand with `in` in a for-init");
    assertEq(it.next("x").value, "ok", "generator completes");
}());

// yield* takes the same operand grammar, so its `[+In]` positions stay legal.
function* g5() { var y = yield* ['a' in { a: 1 }]; return y; }
(function () {
    var it = g5();
    assertEq(it.next().value, true, "yield* delegates an array holding an `in` result");
    assertEq(it.next().done, true, "yield* completes");
}());

// A plain `in` outside any for head is untouched.
assertEq('k' in { k: 1 }, true, "an ordinary `in` still works");
assertEq(0 in [7], true, "`in` on an array index still works");

// And the for-head restriction itself still applies to a non-yield operand,
// so the fix did not loosen the original rule. Parsed via eval-free indirection
// is not available here, so this is asserted by test/toplevel_syntax instead;
// what this line pins is that a legal for head with `in` inside parens works.
(function () {
    var seen = 0;
    for (var q = ('a' in { a: 1 }); seen < 1; seen++) { assertEq(q, true, "for-init value survives"); }
    assertEq(seen, 1, "loop ran once");
}());

if (failures === 0) {
    print("PASS: yield operand inherits the [In] parameter");
} else {
    print("FAILURES: " + failures);
}

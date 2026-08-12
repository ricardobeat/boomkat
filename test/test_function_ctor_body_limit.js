// The Function / GeneratorFunction constructors must reject an oversized body,
// not truncate it.
//
// Both build their compilation source in a fixed `char[16384]` stack buffer.
// The copy was bounds-checked, so nothing overflowed — but a body that did not
// fit was SILENTLY CUT, mid-token, and then compiled. The results were
// entertaining and useless:
//
//   - `... retu` — a truncated `return`, surfacing at CALL time as
//     "retu is not defined", nowhere near the constructor.
//   - a body cut at a statement boundary, which compiled cleanly and returned
//     `undefined` instead of its real value.
//   - a body cut inside a block, giving "SyntaxError in Function constructor"
//     with no hint that length was the issue.
//
// The limit is ~16 KB of body text. Whether that is the right limit is a
// separate question; what matters here is that exceeding it is an ERROR rather
// than a corrupted function, so the failure names its own cause.
//
// Found while generating a 400-iteration loop body through `new Function` for
// an unrelated test. test262 has no fixture anywhere near this size.
var failures = 0;
function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        print("FAIL: " + msg + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

function pad(n) {
    var s = "";
    while (s.length < n) { s += "xxxxxxxxxx"; }
    return s.substring(0, n);
}

// Ordinary bodies are unaffected.
assertEq(new Function("return 5;")(), 5, "a small body still works");
assertEq(new Function("a", "b", "return a + b;")(2, 3), 5, "parameters still work");

// A body comfortably under the limit compiles and runs correctly, including
// one built by concatenation (the shape that found this).
(function () {
    var src = "var n = 0, i = 0;";
    for (var k = 0; k < 200; k++) {
        src += "for (i = 0; i < 3; i++) { if (i === 1) break; n++; }";
    }
    src += "return n;";
    assertEq(new Function(src)(), 200, "200 generated loops, under the limit");
}());

// A body just under the limit must still produce the RIGHT value — the
// truncation bug's quietest form returned undefined from a body cut at a
// statement boundary.
(function () {
    var src = "var n = 0; /*" + pad(15000) + "*/ n = 42; return n;";
    assertEq(new Function(src)(), 42, "a ~15 KB body returns its real value");
}());

// Past the limit. The INVARIANT asserted here is deliberately the weaker,
// portable one: either the body compiles and returns the right value, or the
// constructor throws. What must never happen is the third outcome — building
// a function that runs and answers WRONG. node has no such limit and takes the
// first branch; this engine takes the second. Both are correct; silent
// truncation was not.
(function () {
    var src = "var n = 0; /*" + pad(20000) + "*/ return 7;";
    var outcome;
    try {
        outcome = new Function(src)();
    } catch (e) {
        outcome = "threw:" + e.message;
    }
    assertEq(outcome === 7 || /too large/.test(outcome), true,
        "an oversized body either works or throws, never returns wrong: " + outcome);
}());

// The same guard on the GeneratorFunction constructor.
(function () {
    var GeneratorFunction = Object.getPrototypeOf(function* () {}).constructor;
    assertEq(GeneratorFunction("yield 1; yield 2;")().next().value, 1,
        "a small generator body still works");

    var src = "var n = 0; /*" + pad(20000) + "*/ yield 7;";
    var outcome;
    try {
        outcome = GeneratorFunction(src)().next().value;
    } catch (e) {
        outcome = "threw:" + e.message;
    }
    assertEq(outcome === 7 || /too large/.test(outcome), true,
        "an oversized generator body either works or throws: " + outcome);
}());

// An oversized body must not leave the constructor unusable for later calls.
assertEq(new Function("return 11;")(), 11, "the constructor still works afterwards");

if (failures === 0) {
    print("PASS: Function constructor body limit");
} else {
    print("FAILURES: " + failures);
}

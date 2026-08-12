// A call's callee was materialized into the wrong register when BOTH of these
// held:
//   1. SHADOWING — some nested function rebinds the callee's name. Any form
//      does it: `var e` in an inner declaration, `var e` in a function
//      expression, or an inner parameter named `e`. The outer binding may be
//      a parameter or a `var`.
//   2. A PARENTHESIZED PROPERTY-ASSIGNMENT around the call: `(o.b = e("q"))`.
//      A plain variable target `(z = e("q"))` does not trigger it, nor does
//      `o.b = e("q")` without the parentheses. A further `.y = 1` on the
//      result is NOT required.
//
// Method calls and `new` in the same position are unaffected, so this is
// specific to a bare-identifier callee.
//
// Each ingredient alone is harmless. Together, the disassembly shows the
// callee copied into r6 while CALL reads r5:
//
//   [  6] LDREG           r6 = r2, r0      <-- callee into r6
//   [  8] CALL            r5 = r5, r1      <-- CALL reads r5
//
// so it called a stale register and reported "undefined is not a function".
//
// Root cause: the callee's GETVAR is STRIPPED from the code stream up front,
// on the promise that CALL_VAR at the end will load the callee itself. But
// CALL_VAR is only emitted when `undef_this` holds, and that is false whenever
// a receiver register is pending. A stale `call_prop_obj_reg` left by the
// enclosing property assignment made the strip fire and then emit a plain
// CALL, reading a register nothing had written. The sibling getglobal_callee
// guard already carried the `call_prop_obj_reg == REG_NONE` precondition, with
// a comment naming this exact hazard; getvar_callee was missing it.
//
// This broke jszip 3.10.1, marked 4.3.0, handlebars 4.7.8 and bluebird 3.7.2 —
// all four failed to load, with symptoms that looked unrelated (handlebars
// reported "Object.defineProperty called on non-object"). The entire test262
// corpus (49814 tests) passes with the bug present, so the oracle here is node
// under an explicit "use strict"; qjs on a plain script runs sloppy mode and
// disagrees about the shadowing cases for the wrong reason.
// The ENTIRE test262 corpus (49814 tests) passes with this bug present, so the
// oracle here is node under an explicit "use strict" — not the suite.
//
// See plans/070-real-world-battle-testing.md (B16). The adjacent shapes below
// are probes for blast radius, not confirmed failures: verify each against
// node before treating a difference as a second bug.
var failures = 0;
function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        print("FAIL: " + msg + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// The reported shape, minimized.
(function (e) {
    function n() { var e = 1; return e; }
    (n.x = e("k")).y = 1;
    assertEq(JSON.stringify(n.x), '{"v":"k","y":1}', "callee resolves through a shadowed parameter");
}(function (k) { return { v: k }; }));

// Ingredient 1 alone: shadowing, plain call. Already passes.
(function (e) {
    function n() { var e = 1; return e; }
    var z = e("k");
    assertEq(JSON.stringify(z), '{"v":"k"}', "shadowing alone is fine");
}(function (k) { return { v: k }; }));

// Ingredient 2 alone: parenthesized assignment, no shadowing. Already passes.
(function (e) {
    function n() { var q = 1; return q; }
    (n.x = e("k")).y = 1;
    assertEq(JSON.stringify(n.x), '{"v":"k","y":1}', "parenthesized assignment alone is fine");
}(function (k) { return { v: k }; }));

// Blast-radius probes: other bases for the parenthesized assignment.
(function (e) {
    function n() { var e = 1; return e; }
    var a = {};
    (a.b = e("i")).c = 2;
    assertEq(JSON.stringify(a.b), '{"v":"i","c":2}', "plain object base");
}(function (k) { return { v: k }; }));

(function (e) {
    function n() { var e = 1; return e; }
    var arr = [];
    (arr[0] = e("j")).c = 3;
    assertEq(JSON.stringify(arr[0]), '{"v":"j","c":3}', "indexed base");
}(function (k) { return { v: k }; }));

// A method call as the shadowed callee.
(function (o) {
    function n() { var o = 1; return o; }
    var t = {};
    (t.p = o.make("m")).c = 4;
    assertEq(JSON.stringify(t.p), '{"v":"m","c":4}', "method call as callee");
}({ make: function (k) { return { v: k }; } }));

// `new` in the same position.
(function (C) {
    function n() { var C = 1; return C; }
    var t = {};
    (t.p = new C("n")).c = 5;
    assertEq(t.p.v, "n", "constructor call as callee");
    assertEq(t.p.c, 5, "property set on the constructed object");
}(function (k) { this.v = k; }));

// No further property set on the result — the parenthesized property
// assignment alone is enough.
(function (e) {
    function n() { var e = 1; return e; }
    var o = {};
    var w = (o.b = e("q"));
    assertEq(w.v, "q", "parenthesized property assignment with no further set");
}(function (k) { return { v: k }; }));

// A plain variable target does NOT trigger it; pinned so a fix cannot narrow
// to the wrong condition.
(function (e) {
    function n() { var e = 1; return e; }
    var z;
    var w = (z = e("q"));
    assertEq(w.v, "q", "plain variable target in parens still works");
}(function (k) { return { v: k }; }));

// Shadowing by a function EXPRESSION rather than a declaration.
(function (e) {
    var g = function () { var e = 1; return e; };
    var o = {};
    var w = (o.b = e("q"));
    assertEq(w.v, "q", "shadowing inside a function expression");
}(function (k) { return { v: k }; }));

// Shadowing by an inner PARAMETER rather than a var.
(function (e) {
    function n(e) { return e; }
    var o = {};
    var w = (o.b = e("q"));
    assertEq(w.v, "q", "shadowing by an inner parameter");
}(function (k) { return { v: k }; }));

// The outer binding is a `var`, not a parameter.
(function () {
    var e = function (k) { return { v: k }; };
    function n() { var e = 1; return e; }
    var o = {};
    var w = (o.b = e("q"));
    assertEq(w.v, "q", "outer binding is a var");
}());

// The jszip shape itself, with a nested function expression doing the
// shadowing rather than a plain inner declaration.
(function (e, t) {
    function n() {
        this.files = Object.create(null);
        this.clone = function () { var e = new n; return e; };
    }
    (n.prototype = e("./object")).loadAsync = e("./load");
    assertEq(n.prototype.o, 1, "prototype assigned from the shadowed callee");
    assertEq(typeof n.prototype.loadAsync, "function", "second call also resolved");
    t.exports = n;
}(function (k) {
    return k === "./object" ? { o: 1 } : function () { return 1; };
}, { exports: {} }));

if (failures === 0) {
    print("PASS: call callee register with a shadowed parameter");
} else {
    print("FAILURES: " + failures);
}

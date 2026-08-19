// Oracle for plan 045: locals referenced by nested callables (or direct eval)
// must be env-resident so closure/eval reads and writes stay coherent with
// the outer function's view.
var p = 0, f = 0;
function ck(n, got, want) { if (got === want) p++; else { f++; print("FAIL " + n + ": " + got + " != " + want); } }

// closure writes, outer reads
function m1() { var x = 1; function g() { x = 2; } g(); return x; }
ck("closure-write-var", m1(), 2);
function m2() { let y = 1; function g() { y = 2; } g(); return y; }
ck("closure-write-let", m2(), 2);

// outer writes after closure creation, closure reads
function m3() { let x = 1; const g = function() { return x; }; x = 2; return g(); }
ck("outer-write-closure-read", m3(), 2);

// read-modify-write ping-pong
function m4() {
    var n = 0;
    function inc() { n++; }
    inc(); n += 10; inc();
    return n;
}
ck("rmw-pingpong", m4(), 12);

// captured accumulator via native callback
function m5() { let s = 0; [1, 2, 3].forEach(function(v) { s += v; }); return s; }
ck("callback-accumulate", m5(), 6);

// arrow capturing and mutating
function m6() { let c = 0; const bump = () => { c += 5; }; bump(); bump(); return c; }
ck("arrow-mutate", m6(), 10);

// expression-bodied arrow capturing a param
function m7(a) { const dbl = () => a * 2; a = 21; return dbl(); }
ck("arrow-expr-param", m7(1), 42);

// captured param mutated by closure
function m8(v) { function set9() { v = 9; } set9(); return v; }
ck("closure-write-param", m8(1), 9);

// eval writes to caller local
function m9() { var w = 7; eval("w = 9;"); return w; }
ck("eval-write", m9(), 9);

// eval reads updated value after outer write
function m10() { let z = 1; z = 3; return eval("z"); }
ck("eval-read-after-write", m10(), 3);

// mutation before the closure is defined, inside a loop (pre-position read)
function m11() {
    let x = 0, log = "";
    for (var i = 0; i < 2; i++) {
        log += x;
        const g = function() { x = 5; };
        g();
    }
    return log;
}
ck("loop-pre-position-read", m11(), "05");

// shadowing: inner function declares its OWN x — outer x stays register-eligible
// (false-positive capture is allowed, but the VALUE must still be right)
function m12() { var x = 1; function g() { var x = 99; return x; } g(); return x; }
ck("shadowed-name", m12(), 1);

// two closures sharing one binding
function m13() {
    let n = 0;
    const a = () => { n += 1; };
    const b = () => n;
    a(); a();
    return b();
}
ck("shared-binding", m13(), 2);

// method shorthand in object literal capturing a local
function m14() { let t = 1; const o = { bump() { t = 8; } }; o.bump(); return t; }
ck("method-shorthand", m14(), 8);

// getter capturing and reading a mutated local
function m15() {
    let v = 1;
    const o = { get val() { return v; } };
    v = 6;
    return o.val;
}
ck("getter-after-write", m15(), 6);

// class method capturing a local (degrades to capture_all)
function m16() { let k = 1; class K { get() { return k; } } k = 4; return new K().get(); }
ck("class-method-capture", m16(), 4);

// destructured local captured by closure
function m17() { const [a, b] = [1, 2]; let sum = 0; const add = () => { sum = a + b; }; add(); return sum; }
ck("destructured-capture", m17(), 3);

// --- Body-level declaration shadowing -------------------------------------
// A nested callable declaring its own body-level var/let/const of an outer
// name cannot reach the outer local, so the outer local stays register-
// resident. These pin the shape down: shadowing must not change any value,
// and the cases that are NOT shadowed must still capture.

// the plain G-case: inner redeclares both names, outer loop is unaffected
function s1() { let s = 0, i = 0; const g = function () { let s = 1, i = 2; return s + i; }; while (i < 3) { s = s + i; i = i + 1; } return s + "|" + g(); }
ck("body-decl-shadow", s1(), "3|3");

// `var` hoists over the whole body, so the outer `s` is never visible
function s2() { var s = 1; var g = function () { const a = typeof s; var s = 2; return a + "|" + s; }; return g() + "|" + s; }
ck("var-hoist-shadow", s2(), "undefined|2|1");

// a block-scoped decl shadows only its block: the first read IS the outer one
function s3() { var s = "OUT"; var g = function () { const a = s; { let s = 9; } return a; }; return g(); }
ck("block-decl-does-not-shadow", s3(), "OUT");

// an initialiser is a reference, not a binder
function s4() { var s = "S"; var g = function () { let a = s, b = 2; return a + b; }; return g(); }
ck("initialiser-still-captures", s4(), "S2");

// a parameter must stay captured even when a sibling body-declares the name
function s5(b) { var h = function () { var b = 99; return b; }; var k = function () { return b; }; return h() + "|" + k(); }
ck("param-capture-survives-sibling-decl", s5(7), "99|7");

// same, reached through methods on an object literal
function s6(a) { var o = {}; o.m = function () { var a = 1; return a; }; o.n = function () { return a; }; return o.m() + "|" + o.n(); }
ck("param-capture-survives-method-decl", s6(5), "1|5");

// `for (var i = ...)` at body level shadows the whole body
function s7() { var i = "OUT"; var g = function () { for (var i = 0; i < 3; i++) {} return i; }; return g() + "|" + i; }
ck("for-var-shadow", s7(), "3|OUT");

// destructuring binders are skipped (over-capture), values must still be right
function s8() { var x = "OUT"; var g = function () { var { x, y } = { x: 1, y: 2 }; return x + y; }; return g() + "|" + x; }
ck("destructuring-decl-shadow", s8(), "3|OUT");

// catch binding and inner function declaration
function s9() { var e = "OUT"; var g = function () { try { throw 1; } catch (e) { return "C" + e; } }; return g() + "|" + e; }
ck("catch-binding", s9(), "C1|OUT");
function s10() { var g0 = "OUT"; var g = function () { function g0() { return "IN"; } return g0(); }; return g() + "|" + g0; }
ck("inner-fn-decl-shadow", s10(), "IN|OUT");

// a declaration inside the inner body does not stop a deeper closure from
// capturing the inner binding
function s11() { var s = "OUT"; var g = function () { var s = "IN"; var inner = function () { return s; }; return inner(); }; return g() + "|" + s; }
ck("nested-closure-reads-inner-decl", s11(), "IN|OUT");

// a body-level decl appearing AFTER a closure that reads the name: `var`
// hoisting means the closure still sees the inner binding
function s12() { var s = "OUT"; var g = function () { var h = function () { return s; }; var s = "IN"; return h(); }; return g() + "|" + s; }
ck("decl-after-closure", s12(), "IN|OUT");

// a comma inside an initialiser is not a declarator separator
function s13() { var z = "Z"; var g = function () { var a = 1, b = z; return a + b; }; return g(); }
ck("comma-in-initialiser", s13(), "1Z");

// assignment (not declaration) to an outer name must still capture
function s14() { var s = "OUT"; var g = function () { s = "SET"; return 1; }; g(); return s; }
ck("assignment-still-captures", s14(), "SET");
function s15() { var s = "OUT"; var g = function () { { s = "SET"; } return 1; }; g(); return s; }
ck("nested-block-assignment-captures", s15(), "SET");

// a no-parameter arrow with a braced body can shadow too
function s16() { var s = "OUT"; var g = () => { let s = 1; return s; }; return g() + "|" + s; }
ck("arrow-body-decl-shadow", s16(), "1|OUT");

print(p + " passed, " + f + " failed");
if (f > 0) { throw new Error(f + " capture-analysis failures"); }

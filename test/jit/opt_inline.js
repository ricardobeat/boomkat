// Calls the optimizing tier replaces by the callee's body: a short straight-line function the
// call site has always reached. The checks are the guard on the callee, the exits from inside a
// body (which publish the callee's frame and continue in its baseline code), and the calls that
// must stay calls.
//
// The callers add a double (0.5) so that they carry operand feedback and are optimized without
// --opt-always; the callees are called in a loop of their own first so that they have baseline
// code, which an exit from their inlined body continues in.
var N = 400;
var out = [];
function show(label, v) { out.push(label + "=" + v); }

function warm(f, a, b) {
    for (var i = 0; i < 3000; i++) f(a, b);
}

// A numeric callee.
function add(a, b) { var c = a + b; return c; }
function mul(a, b) { var c = a * b; return c; }
function sub(a, b) { var c = a - b; return c; }
warm(add, 1, 2);
warm(mul, 3, 4);
warm(sub, 5, 6);

function sumAdd(n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = add(s, i) + 0.25;
    return s;
}
for (var k = 0; k < N; k++) sumAdd(50);
show("add", sumAdd(1000));

// Overflow inside the inlined body: the sum leaves the int32 range.
function bigAdd(n, x) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = add(x, i) + 0.25;
    return s;
}
for (var k = 0; k < N; k++) bigAdd(50, 1);
show("overflow", bigAdd(100, 2147483600));
show("double", bigAdd(100, 1.5));

// A getter-like callee and a method reading this.
function getX(o) { return o.x; }
function Point(x, y) { this.x = x; this.y = y; }
Point.prototype.getX = function () { return this.x; };
var p = new Point(7, 8);
warm(getX, p);
for (var i = 0; i < 3000; i++) p.getX();
function sumGet(n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = getX(p) + p.getX() + s;
    return s;
}
for (var k = 0; k < N; k++) sumGet(50);
show("getter", sumGet(100));

// The shape of the receiver changes under an inlined read: the exit publishes the callee's frame.
function Other(y, x) { this.y = y; this.x = x; }
var odd = new Other(1, 100);
function readBoth(o, n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = getX(o) + o.getX2() + s;
    return s;
}
Point.prototype.getX2 = function () { return this.x; };
Other.prototype.getX2 = function () { return this.x; };
for (var i = 0; i < 3000; i++) { p.getX2(); }
for (var k = 0; k < N; k++) readBoth(p, 50);
show("shape-before", readBoth(p, 50));
show("shape-after", readBoth(odd, 50));
show("shape-again", readBoth(p, 50));
show("shape-after2", readBoth(odd, 50));

// A nested real call after the exit, and an exception from the callee after it.
function deep(o) { return o.a.b; }
var good = { a: { b: 5 } };
var bad = { c: 1, a: undefined };
warm(deep, good);
function callDeep(o, n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = deep(o) + s;
    return s;
}
for (var k = 0; k < N; k++) callDeep(good, 50);
show("deep", callDeep(good, 10));
try { callDeep(bad, 10); show("deep-bad", "no throw"); } catch (e) { show("deep-bad", e instanceof TypeError); }
show("deep-again", callDeep(good, 10));

function nested(o, n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = getX(o) + add(s, i) + helper(i);
    return s;
}
function helper(i) { var t = i * 2; for (var j = 0; j < 3; j++) t += j; return t; }
warm(helper, 1);
for (var k = 0; k < N; k++) nested(p, 50);
show("nested-before", nested(p, 20));
show("nested-after", nested(odd, 20));

// The callee at one site changes.
function apply2(f, n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = f(s, i) + 0.25;
    return s;
}
for (var k = 0; k < N; k++) apply2(add, 50);
show("apply-add", apply2(add, 100));
show("apply-mul", apply2(mul, 100));
show("apply-sub", apply2(sub, 100));
show("apply-add-again", apply2(add, 100));

// The number of arguments differs from the number of parameters.
function fewer(n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = add(i) + 0.25 + s;
    return s;
}
function more(n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = add(i, 1, 2) + 0.25 + s;
    return s;
}
for (var k = 0; k < N; k++) { fewer(50); more(50); }
show("fewer", fewer(20));
show("more", more(20));

// Strict and sloppy callees.
function strictAdd(a, b) { "use strict"; var c = a + b; return c; }
function sloppyAdd(a, b) { var c = a + b; return c; }
warm(strictAdd, 1, 2);
warm(sloppyAdd, 1, 2);
function mixed(n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = strictAdd(s, i) + sloppyAdd(i, 1);
    return s;
}
for (var k = 0; k < N; k++) mixed(50);
show("strict-sloppy", mixed(100));

// A callee reading a closure capture stays a call.
function maker(k) { return function (a) { var c = a + k; return c; }; }
var addK = maker(3);
warm(addK, 1);
function useCapture(n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = addK(i) + s;
    return s;
}
for (var k = 0; k < N; k++) useCapture(50);
show("capture", useCapture(100));

// Deep recursion through a frame published by an exit.
function recurse(n, o) {
    if (n == 0) return getX(o);
    return recurse(n - 1, o) + 0.5;
}
function drive(o, n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = recurse(40, o) + s;
    return s;
}
for (var k = 0; k < 100; k++) drive(p, 20);
show("recurse", drive(p, 5));
show("recurse-odd", drive(odd, 5));
show("recurse-deep", recurse(3000, p));
try { (function over() { return over() + getX(p); })(); } catch (e) { show("overflow-depth", e instanceof RangeError); }

// Callees returning a constant or undefined (LDUNDEF, LDNULL, LDTRUE, LDFALSE, RETUNDEF), and one that
// writes a field and then returns nothing.
function retUndef(a, b) { var c = a + b; }
function retUndef2(a, b) { return; }
function retNull(a, b) { return null; }
function retTrue(a, b) { return true; }
function retFalse(a, b) { return false; }
function varUndef(a, b) { var u; return u; }
function setRet(a, o) { o.x = a; }
warm(retUndef, 1, 2);
warm(retUndef2, 1, 2);
warm(retNull, 1, 2);
warm(retTrue, 1, 2);
warm(retFalse, 1, 2);
warm(varUndef, 1, 2);
warm(setRet, 1, { x: 0 });
var constsObj = { x: 0 };
function consts(n) {
    var s = 0.5, o = constsObj, t = 0;
    for (var i = 0; i < n; i++) {
        s = s + i + 0.25;
        var u = retUndef(s, i), u2 = retUndef2(s, i), nu = retNull(s, i), tr = retTrue(s, i), fa = retFalse(s, i);
        var vu = varUndef(s, i), su = setRet(i, o);
        t += (u === undefined) + (u2 === undefined) + (nu === null) + (tr === true) + (fa === false) + (vu === undefined) + (su === undefined) + o.x;
    }
    return s + t;
}
for (var k = 0; k < N; k++) consts(50);
show("consts", consts(100));

// A callee that has not run enough to have baseline code when its caller is optimized.
function coldAdd(a, b) { var c = a + b; return c; }
function coldCaller(n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = coldAdd(s, i) + 0.25;
    return s;
}
for (var k = 0; k < N; k++) coldCaller(20);
show("cold-callee", coldCaller(200));

print(out.join("\n"));

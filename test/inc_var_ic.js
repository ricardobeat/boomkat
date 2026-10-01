// Captured-variable ++/-- keep working once the site's variable cache is warm.
function counter() {
    var c = 0;
    return { inc: function () { return ++c; }, dec: function () { c--; }, get: function () { return c; } };
}
var a = counter(), b = counter();
for (var i = 0; i < 50; i++) { a.inc(); b.inc(); b.inc(); a.dec(); }
if (a.get() !== 0 || b.get() !== 100) throw new Error("per-closure state " + a.get() + " " + b.get());

// The same site must follow the closure it runs under, not the first one it saw.
function make(start) { var n = start; return function () { n++; return n; }; }
var f1 = make(10), f2 = make(20);
for (var j = 0; j < 5; j++) { f1(); f2(); }
if (f1() !== 16 || f2() !== 26) throw new Error("shared site");

// Non-numeric and overflowing values leave the cached path.
function conv() { var s = "5"; var big = 9007199254740991; var inc = function () { s++; big++; }; inc(); inc(); return [s, big]; }
var r = conv();
if (r[0] !== 7 || r[1] !== 9007199254740993) throw new Error("coercion " + r);
function bigint() { var x = 1n; var inc = function () { x++; }; inc(); inc(); return x; }
if (bigint() !== 3n) throw new Error("bigint");

// A const stays read-only after the site has been hot.
function frozen() { const k = 1; return function () { try { k++; } catch (e) { return e instanceof TypeError; } return false; }; }
var g = frozen();
for (var m = 0; m < 5; m++) if (!g()) throw new Error("const increment");

// A let binding raises its TDZ error, then increments normally.
function tdz() { var f = function () { x++; return x; }; try { f(); } catch (e) { var threw = e instanceof ReferenceError; } let x = 1; return [threw, f(), f()]; }
var t = tdz();
if (t[0] !== true || t[1] !== 2 || t[2] !== 3) throw new Error("tdz " + t);
console.log("ok");

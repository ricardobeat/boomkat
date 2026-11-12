// Equality producing a boolean (COMPARE_WINDOW) over VALUE nodes taken from their registers:
// strict and loose, against another field, a constant, null and undefined, over objects, strings
// (the same and equal ones), numbers, booleans, null, undefined and a symbol, in the root body and
// an inlined one, and the boolean then stored, tested and returned.
function Pair(a, b) { this.a = a; this.b = b; }
var sym = Symbol("s"), obj = {};
var pairs = [
    new Pair(obj, obj), new Pair(obj, {}), new Pair("ab", "a" + "b"), new Pair("x", "y"),
    new Pair(1, 1), new Pair(1, "1"), new Pair(0, false), new Pair(null, undefined),
    new Pair(undefined, undefined), new Pair(null, 0), new Pair(true, 1), new Pair(sym, sym),
    new Pair(NaN, NaN), new Pair(1.5, 1.5), new Pair("", 0)
];
function strict(p) { return p.a === p.b; }
function loose(p) { return p.a == p.b; }
function differ(p) { return p.a !== p.b; }
function vsnull(p) { return p.a == null; }
function vsundef(p) { return p.b === undefined; }
function vsconst(p) { return p.a === "x"; }
function mix(p) { var e = p.a == p.b, s = p.a === p.b; return (e ? 1 : 0) + (s ? 2 : 0) + (!e ? 4 : 0) + (vsnull(p) ? 8 : 0); }
function keep(p, o) { o.eq = p.a == p.b; o.ne = p.a != p.b; return o; }
var sum = 0, trace = "", out = {};
for (var i = 0; i < 30000; i++) {
    // Objects and strings first, so that the code is built for them; then everything.
    var p = i < 15000 ? pairs[i % 4] : pairs[i % pairs.length];
    var x = (strict(p) ? 1 : 0) + (loose(p) ? 2 : 0) + (differ(p) ? 4 : 0) + (vsnull(p) ? 8 : 0) + (vsundef(p) ? 16 : 0) + (vsconst(p) ? 32 : 0) + mix(p) * 64;
    keep(p, out);
    x += (out.eq ? 1024 : 0) + (out.ne ? 2048 : 0);
    sum = (sum + x) | 0;
    if (i >= 29985) trace += x + ",";
}
print(sum, trace);

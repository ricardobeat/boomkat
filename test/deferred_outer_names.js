// A deferred function body compiles from its own source, with a record of the
// names around it (record_outer_names): which a function binds, which the
// script declares, and which no scope can gain later. Each case reads or
// writes a name through one or two levels of deferred functions.

var out = [];
var g1 = "global-var";
function gf() { return "global-fn"; }
let glet = "global-let";
var counter = 0;

// An eval in an unrelated function leaves these names provable.
function usesEval(src) { var hidden = "local"; return eval(src); }

function readsGlobals() {
    return (function () { counter++; return g1 + "," + gf() + "," + glet; })();
}
out.push(readsGlobals(), counter);

// A global created after the function was compiled, and one never created.
function late() { return (function () { return typeof lateName + ":" + (typeof lateName == "undefined" ? "" : lateName); })(); }
out.push(late());
globalThis.lateName = "late";
out.push(late());
function missing() { return (function () { try { return nope; } catch (e) { return e.constructor.name; } })(); }
out.push(missing());

// Bindings two and three functions out, read and written.
function outer(a) {
    var b = a + 1;
    let c = b + 1;
    function mid() {
        var own = 10;
        return function inner(d) {
            b++;
            return function innermost() { c += d; return [a, b, c, own, d].join("/"); };
        };
    }
    return mid;
}
var m = outer(1);
out.push(m()(5)(), m()(7)());
out.push(outer(100)()(1)());

// A nearer binding shadows the outer one, declared after its use.
function shadow(x) {
    return function () {
        return function () { var r = typeof x + ":" + x; return r; var x; };
    };
}
out.push(shadow(3)()());
function shadow2(x) {
    return function () {
        var x = "mid";
        return function () { return x; };
    };
}
out.push(shadow2(3)()());

// A direct eval between the reader and the binding can bind the name nearer.
function evalBetween(x) {
    return function (src) {
        eval(src);
        return function () { return x; };
    };
}
out.push(evalBetween("outer")("")(), evalBetween("outer")("var x = 'evaled'")());
out.push(usesEval("hidden + g1"));

// A `with` between them, too.
function withBetween(x, o) {
    with (o) { return function () { return function () { return x + "," + g1; }; }; }
}
out.push(withBetween("outer", {})()(), withBetween("outer", { x: "with", g1: "with-g" })()());

// A function expression's own name, a catch parameter and a class.
var named = function self(n) { return function () { return n == 0 ? typeof self : self(n - 1)(); }; };
out.push(named(2)());
function catcher() {
    try { throw "caught"; } catch (e) { return function () { return function () { return e; }; }; }
}
out.push(catcher()()());
function classy() {
    class K { static v() { return "K"; } }
    return function () { return function () { return K.v(); }; };
}
out.push(classy()()());

// A loop makes a closure per iteration over a binding two functions out.
function perIteration(n) {
    var fs = [];
    for (let i = 0; i < n; i++) {
        fs.push(function () { return function () { return i * n; }; });
    }
    return fs.map(function (f) { return f()(); }).join(",");
}
out.push(perIteration(4));

// A script global assigned and incremented from nested functions, hot.
var hits = 0, total = 0;
function bump(k) { return (function () { hits++; total += k; return hits; })(); }
for (var i = 0; i < 2000; i++) bump(i);
out.push(hits, total);

var expected = [
    "global-var,global-fn,global-let",
    "1",
    "undefined:",
    "string:late",
    "ReferenceError",
    "1/3/8/10/5",
    "1/4/15/10/7",
    "100/102/103/10/1",
    "undefined:undefined",
    "mid",
    "outer",
    "evaled",
    "localglobal-var",
    "outer,global-var",
    "with,with-g",
    "function",
    "caught",
    "K",
    "0,4,8,12",
    "2000",
    "1999000"
];
for (var k = 0; k < expected.length; k++) {
    if (String(out[k]) !== expected[k]) throw new Error("case " + k + ": expected " + expected[k] + ", got " + out[k]);
}
if (out.length !== expected.length) throw new Error("expected " + expected.length + " results, got " + out.length);
print("OK");

// Callees that read variables through the scope cache (GETVAR) inlined into a hot caller: a global
// lexical binding, an eval-introduced binding, a binding in a scope the callee closure captured.
// The cache is keyed by the scope chain the callee runs with, which is its closure's, not the
// caller's; closures of one function with different scopes run through one call site. Values are
// numbers (typed loads), objects, functions, bindings in their TDZ and bindings that change between
// calls. scripts/opt_exit_check.sh forces an exit at every point.
var out = [];
function show(label, v) { out.push(label + "=" + v); }

let gnum = 3, gflt = 0.5;
const gobj = { a: 4, b: 5.5 };
let gfn = function (x) { return x + 1; };
let gstr = "s";

function readNum(x) { return x + gnum + gflt; }
function readObj(x) { return gobj.a * x + gobj.b; }
function readFn(x) { return gfn(x) + 1; }
function readStr() { return gstr + gnum; }
function readTdz() { return later; }
function mkDyn(k) { eval("var q = k"); return function (x) { return x + q + gnum; }; }
function mkDynObj(o) { eval("var r = o"); return function (x) { return r.a + x; }; }
function mkLet(v) { { let blk = v; return function (x) { return x * blk; }; } }
var dyns = [mkDyn(1), mkDyn(20), mkDyn(300)];
var dynObjs = [mkDynObj({ a: 1 }), mkDynObj({ a: 2.5 })];
var blks = [mkLet(2), mkLet(3), mkLet(0.5)];

// Callees run once, so that the call sites record them before the callees tier up themselves.
readNum(1); readObj(1); readFn(1); readStr();
for (var w = 0; w < 3; w++) { dyns[w](1); blks[w](1); }
dynObjs[0](1); dynObjs[1](1);

function run1(n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += readNum(i) + readObj(i) + readFn(i);
    return s;
}
for (var k = 0; k < 3000; k++) run1(10);
show("globals", run1(300));

function run2(n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += dyns[i % 3](i);
    return s;
}
for (var k = 0; k < 3000; k++) run2(10);
show("scopes", run2(300));

function run3(n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += dynObjs[i & 1](i) + blks[i % 3](i);
    return s;
}
for (var k = 0; k < 3000; k++) run3(10);
show("objects", run3(300));

// A binding that changes between calls, to another kind of value too.
function run4(n) {
    var s = "";
    for (var i = 0; i < n; i++) {
        if (i === 100) gnum = 1.5;
        if (i === 150) gnum = 7;
        if (i === 200) gstr = 12;
        s = readStr();
    }
    return s + "|" + readNum(1);
}
for (var k = 0; k < 3000; k++) { gnum = 3; gstr = "s"; run4(10); }
gnum = 3; gstr = "s";
show("changes", run4(300));
gnum = 3; gstr = "s";

// A function value replaced by another.
function run5(n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        if (i === 120) gfn = function (x) { return x * 2; };
        s += readFn(i);
    }
    return s;
}
for (var k = 0; k < 3000; k++) run5(10);
gfn = function (x) { return x + 1; };
show("fn", run5(300));
gfn = function (x) { return x + 1; };

// TDZ: the binding is read before its declaration runs, once the call site is hot.
function run6(n) {
    var s = 0, t = "";
    for (var i = 0; i < n; i++) {
        if (i === 90) { try { s += readTdz(); } catch (e) { t = e.constructor.name; } }
        s += readNum(i);
    }
    return s + t;
}
for (var k = 0; k < 3000; k++) { try { run6(10); } catch (e) {} }
show("tdz", run6(200));
let later = 9;
show("after", readTdz());

// A callee whose closure is not the one the site saw: the guard exits.
function run7(fs, n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += fs[i % fs.length](i);
    return s;
}
var other = function (x) { return x - gnum; };
for (var k = 0; k < 3000; k++) run7([dyns[0], dyns[1]], 10);
show("guard", run7([dyns[0], other, dyns[2]], 300));

print(out.join("\n"));

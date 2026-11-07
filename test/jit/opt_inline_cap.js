// Callees that read captured variables (GETCAP) inlined into a hot caller: the capture is read from
// the callee closure the call's guard checked, not from the caller's. Closures of one function with
// different environments run through the same call site; captures are numbers (typed loads),
// objects (receivers of further reads), values the callee window keeps, cells that change between
// calls, and let bindings that are uninitialised when read. scripts/opt_exit_check.sh forces an exit
// at every point, which materializes the callee frame.
var out = [];
function show(label, v) { out.push(label + "=" + v); }

// Factories: every closure of one function has its own environment.
function mkAdd(k) { return function (x) { return x + k; }; }
function mkScale(k, m) { return function (x) { return x * k + m; }; }
function mkObj(o) { return function (x) { return o.a + o.b * x; }; }
function mkNested(o) { return function (x) { return o.p.x + o.p.y + x; }; }
function mkCell(start) {
    var n = start;
    return { get: function (x) { return n + x; }, set: function (v) { n = v; }, inc: function () { n++; } };
}
function mkWin(o) { return function () { var t = o; return t; }; }

var adders = [mkAdd(1), mkAdd(2), mkAdd(3)];
var scalers = [mkScale(2, 1), mkScale(3, 0.5), mkScale(4, 2)];
var objs = [mkObj({ a: 1, b: 2 }), mkObj({ a: 10, b: 20 }), mkObj({ a: 0.5, b: 0.25 })];
var nests = [mkNested({ p: { x: 1, y: 2 } }), mkNested({ p: { x: 3, y: 4.5 } })];
var cells = [mkCell(0), mkCell(100)];
var wins = [mkWin({ q: 1 }), mkWin({ q: 2 })];

// Callees run once, so that the call sites record them before the callees tier up themselves.
for (var w = 0; w < 3; w++) {
    adders[w](1); scalers[w](1); objs[w](1);
}
nests[0](1); nests[1](1); cells[0].get(1); cells[1].get(1); wins[0](); wins[1]();

function run1(n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        var f = adders[i % 3];
        var g = scalers[(i + 1) % 3];
        s += f(i) + g(i);
    }
    return s;
}
for (var k = 0; k < 3000; k++) run1(10);
show("numbers", run1(300));

function run2(n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        var f = objs[i % 3];
        var g = nests[i & 1];
        s += f(i) + g(i);
    }
    return s;
}
for (var k = 0; k < 3000; k++) run2(10);
show("objects", run2(300));

function run3(n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        var c = cells[i & 1];
        if (i % 7 == 0) c.set(i);
        if (i % 5 == 0) c.inc();
        s += c.get(i);
    }
    return s;
}
for (var k = 0; k < 3000; k++) run3(10);
show("cells", run3(300));

function run4(n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        var f = wins[i & 1];
        s += f().q;
    }
    return s;
}
for (var k = 0; k < 3000; k++) run4(10);
show("window", run4(300));

// A let binding read before it is initialised: the callee throws a ReferenceError.
function mkTdz(early) {
    var f = function () { return v + 1; };
    if (early) { try { return f(); } catch (e) { return -1; } }
    let v = 5;
    return f;
}
var tz = mkTdz(false);
function run5(f, n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += f();
    return s;
}
for (var k = 0; k < 3000; k++) run5(tz, 10);
show("tdz", run5(tz, 100) + mkTdz(true));

// A closure whose capture is a number at first and an object later: the typed load leaves for the
// baseline code.
function mkMixed() {
    var v = 1;
    return { get: function (x) { return v + x; }, set: function (n) { v = n; } };
}
var mx = mkMixed();
mx.get(1);
function run6(n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += mx.get(i);
    return s;
}
for (var k = 0; k < 3000; k++) run6(10);
show("mixed1", run6(100));
mx.set(2.5);
show("mixed2", run6(100));
mx.set("a");
show("mixed3", run6(5));
mx.set({ valueOf: function () { return 7; } });
show("mixed4", run6(5));

// The same callee called with a closure of another function at the site: the guard leaves.
var other = function (x) { return x - 1; };
function run7(fs, n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += fs[i % fs.length](i);
    return s;
}
for (var k = 0; k < 3000; k++) run7([adders[0], adders[1]], 10);
show("guard", run7([adders[0], other, adders[2]], 300));

print(out.join("\n"));

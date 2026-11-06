// Inlined bodies that hold more than the straight numeric core: an instruction that has never run
// is an unconditional exit to the callee's baseline code at that instruction, and the equality
// branches, global reads, `this` loads and calls of a body.
//
// The callers add a double (0.5) so that they carry operand feedback and are optimized without
// --opt-always; the callees are called in a loop of their own first so that they have baseline
// code, which an exit from their inlined body continues in.
var N = 1200;
var out = [];
function show(label, v) { out.push(label + "=" + v); }

function Pt(x, y) { this.x = x; this.y = y; }
// Cold field reads and writes in branches the warm-up never takes.
Pt.prototype.coldRead = function (a) { if (a > 100000) return this.x + a; return a + 1; };
Pt.prototype.coldWrite = function (a) { if (a > 100000) { this.y = a; return a; } return a + 2; };
Pt.prototype.coldElse = function (a) { if (a < 100000) return a - 1; return this.y - a; };
Pt.prototype.coldNested = function (a) {
    if (a > 10) {
        if (a > 100000) return this.x * a;
        return a;
    }
    return a + this.y;
};
Pt.prototype.coldBoth = function (a) {
    var r;
    if (a > 100000) r = this.x; else r = a;
    return r + 1;
};
function warmPt(p) {
    for (var i = 0; i < 3000; i++) { p.coldRead(5); p.coldWrite(5); p.coldElse(5); p.coldNested(50); p.coldBoth(5); }
    for (var i = 0; i < 3000; i++) p.coldNested(5);
}
var p0 = new Pt(7, 9);
warmPt(p0);

function drive(p, m, lim) {
    var s = 0.5;
    for (var i = 0; i < lim; i++) s = p[m](i) + s;
    return s;
}
function callRead(p, n, big) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = p.coldRead(i * big) + s;
    return s;
}
function callWrite(p, n, big) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = p.coldWrite(i * big) + s;
    return s;
}
function callElse(p, n, big) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = p.coldElse(i * big) + s;
    return s;
}
function callNested(p, n, big) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = p.coldNested(i * big) + s;
    return s;
}
function callBoth(p, n, big) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = p.coldBoth(i * big) + s;
    return s;
}
// The cold branch is never taken while the caller is optimized, then it is.
for (var k = 0; k < N; k++) { callRead(p0, 50, 1); callWrite(p0, 50, 1); callElse(p0, 50, 1); callNested(p0, 50, 1); callBoth(p0, 50, 1); }
show("readHot", callRead(p0, 50, 1));
show("writeHot", callWrite(p0, 50, 1));
show("elseHot", callElse(p0, 50, 1));
show("nestedHot", callNested(p0, 50, 1));
show("bothHot", callBoth(p0, 50, 1));
// Each call on its way into the cold branch exits to the callee's baseline code and goes on.
show("readCold", callRead(p0, 50, 5000));
show("writeCold", callWrite(p0, 50, 5000));
show("writeAfter", p0.y);
show("elseCold", callElse(p0, 50, 5000));
show("nestedCold", callNested(p0, 50, 5000));
show("bothCold", callBoth(p0, 50, 5000));
// Once the cold branch has run, a new optimization takes its cache.
for (var k = 0; k < N; k++) { callRead(p0, 50, 5000); callWrite(p0, 50, 5000); callBoth(p0, 50, 5000); }
show("readWarm", callRead(p0, 50, 5000));
show("bothWarm", callBoth(p0, 50, 5000));
// A receiver of another shape in the cold branch.
var q = new Pt(1.5, 2);
q.extra = 3;
show("readOther", callRead(q, 50, 5000));
show("otherString", callRead(new Pt("s", 1), 50, 5000));

// --- Equality branches in a flat body ---
function same(a, b) { if (a === b) return 1; return 0; }
function differ(a, b) { if (a !== b) return 3; return 4; }
function loose(a, b) { if (a == b) return 5; return 6; }
function looseNot(a, b) { if (a != b) return 7; return 8; }
function isNull(a, b) { if (a == null) return 9; return a + b; }
function notNull(a, b) { if (a != null) return a + b; return 10; }
function eqImm(a, b) { if (a === 3) return b; return a + b; }
function nested(a, b) {
    if (a === b) { if (a == 0) return 11; return 12; }
    if (b != null) return a + b;
    return 13;
}
var objA = { v: 1 }, objB = { v: 2 };
function warmEq(f, a, b) { for (var i = 0; i < 3000; i++) f(a, b); }
var eqs = [same, differ, loose, looseNot, isNull, notNull, eqImm, nested];
for (var e = 0; e < eqs.length; e++) { warmEq(eqs[e], 1, 2); warmEq(eqs[e], 2, 2); }
// One driver per callee, so that each call site has a single target.
var eqNames = ["same", "differ", "loose", "looseNot", "isNull", "notNull", "eqImm", "nested"];
var drivers = eqNames.map(function (nm) {
    return new Function(nm, "vals", "n", "var s = 0.5; for (var i = 0; i < n; i++) { var a = vals[i % vals.length], b = vals[(i * 7 + 1) % vals.length]; var r = " + nm + "(a, b); s = (typeof r === 'number' ? r : 100) + s; } return s;");
});
var nums = [0, 1, 2, 3, 3, 4, 5, 8];
var mixed = [0, 1, 2, 3, 3, 4, 5, 8, 2.5, "3", null, undefined, objA, objB, objA, true, NaN, -0];
for (var e = 0; e < eqs.length; e++) {
    for (var k = 0; k < N; k++) drivers[e](eqs[e], nums, 40);
    show("eqNums" + e, drivers[e](eqs[e], nums, 200));
    show("eqMixed" + e, drivers[e](eqs[e], mixed, 200));
    show("eqObjs" + e, drivers[e](eqs[e], [objA, objB, objA, 1, 2], 100));
}

// --- Global reads and `this` in an inlined body ---
var SCALE = 3;
var HALF = 0.5;
var gObj = { k: 4 };
var gStr = "g";
function Gm(v) { this.v = v; }
Gm.prototype.scaled = function (a) { if (a > 5) return a * SCALE; return a + SCALE; };
Gm.prototype.half = function (a) { if (a < 0) return 0; return a * HALF; };
Gm.prototype.self = function (a) { var t = this; if (a > 5) return t.v + a; return a; };
Gm.prototype.selfRet = function (a) { if (a > 5) return this; return this.v; };
Gm.prototype.objRead = function (a) { if (a > 5) return gObj.k + a; return a; };
Gm.prototype.coldGlobal = function (a) { if (a > 100000) return SCALE + a; return a + 1; };
Gm.prototype.strGlobal = function (a) { if (a > 5) return gStr; return a; };
var gm = new Gm(2);
var gnames = ["scaled", "half", "self", "selfRet", "objRead", "coldGlobal", "strGlobal"];
for (var e = 0; e < gnames.length; e++) for (var i = 0; i < 3000; i++) { gm[gnames[e]](i & 7); gm[gnames[e]](2); }
var gdrivers = gnames.map(function (nm) {
    return new Function("o", "n", "m", "var s = 0.5; for (var i = 0; i < n; i++) { var r = o." + nm + "((i * m) & 255); s = (typeof r === 'number' ? r : (typeof r === 'string' ? 77 : r.v)) + s; } return s;");
});
for (var e = 0; e < gnames.length; e++) {
    for (var k = 0; k < N; k++) gdrivers[e](gm, 40, 1);
    show("glob" + gnames[e], gdrivers[e](gm, 200, 1));
    show("globOther" + gnames[e], gdrivers[e](new Gm(1.5), 200, 3));
}
// The globals change under the optimized code.
SCALE = 4.5;
HALF = 2;
gObj = { k: 9 };
for (var e = 0; e < gnames.length; e++) show("globChanged" + gnames[e], gdrivers[e](gm, 200, 1));
SCALE = "s";
show("globString", gdrivers[0](gm, 50, 1));
SCALE = 3;
var big = new Gm(1);
function viaBig(n) { var s = 0.5; for (var i = 0; i < n; i++) s = big.coldGlobal(i * 1000) + s; return s; }
for (var k = 0; k < N; k++) viaBig(50);
show("coldGlobalHot", viaBig(300));

print(out.join("\n"));

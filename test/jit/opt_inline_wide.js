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

print(out.join("\n"));

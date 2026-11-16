// An inlined body with a call in a branch that has never run: the body is still inlined, and the
// first time the branch runs the code leaves for the baseline, which makes the call.

function denorm(x, a) { return x / a.length; }
function Attr(n) { this.array = new Float32Array(n); this.itemSize = 3; this.normalized = false; }
Attr.prototype.getX = function (i) {
    var x = this.array[i * this.itemSize];
    if (this.normalized) x = denorm(x, this.array);
    return x;
};
function run(a) { var s = 0; for (var i = 0; i < 100; i++) s += a.getX(i); return s; }

var a = new Attr(300), t = 0;
for (var i = 0; i < 300; i++) a.array[i] = i;
for (var k = 0; k < 20000; k++) t += run(a);
console.log(t);
a.normalized = true;
console.log(run(a));
t = 0;
for (var k = 0; k < 20000; k++) t += run(a);
console.log(t);
a.normalized = false;
console.log(run(a));

// The cold call throws when it first runs.
function fail() { throw new Error("cold"); }
function check(o) { if (o.bad) fail(); return o.v; }
function total(o) { var s = 0; for (var i = 0; i < 50; i++) s += check(o); return s; }
var o = { v: 2, bad: false }, u = 0;
for (var k = 0; k < 20000; k++) u += total(o);
o.bad = true;
try { total(o); } catch (e) { console.log(u, e.message); }

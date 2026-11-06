// An optimized body whose last exit stub belongs to an inlined callee: the code that follows a
// native call's return (it re-points the call view at the function being compiled) must not take
// the callee's code, constants and caches, or the next call reads the wrong inline caches.
var out = [];
function Vec(x, y) { this.x = x; this.y = y; }
Vec.prototype.getX = function (a, b) { return this.x; };
Vec.prototype.getY = function (a, b) { return this.y; };
function Box(v) { this.v = v; this.sum = 0; }
var N = 3000;

// Calls that stay calls: too long to inline.
function big(a, b) {
    var t = a + b;
    if (t > 100000) t = t - 100000;
    var u = 0;
    for (var i = 0; i < 2; i++) u += t;
    return u;
}
function plain(a, b) { var s = a; for (var i = 0; i < 2; i++) s += b; return s; }

function viaEnv(a, b) { return (function () { return a - b; })(); }

function work(o, i) {
    var s = 0.5;
    s += big(i, 1) + plain(i, 2);
    s += plain(s, 1) * 0 + big(s, 2) * 0;
    s += Math.abs(i - 7) + Math.max(i, 3) + "ab".charCodeAt(1) + viaEnv(i, 2) + o.v.getY(i, 1);
    s += 1.5;
    sink(o.v.getX(1, 2), s);
    return s;
}
function sink(a, b) { return a; }
var b = new Box(new Vec(3, 4));
for (var i = 0; i < 3000; i++) b.v.getX(1, 2);
var total = 0;
for (var k = 0; k < N * 30; k++) total += work(b, k & 63);
out.push("work=" + total);
print(out.join("\n"));

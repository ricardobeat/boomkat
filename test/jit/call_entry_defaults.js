// Call entries of functions with default parameter values, whose parameters outnumber
// Function.length, and of a rest parameter read only for its length, called with every count of
// arguments: the entry starts the parameters a call leaves out undefined and keeps those it passes.
var out = [];
function log(x) { out.push(String(x)); }

function two(a, b = 10) { return a + b; }
function three(a, b = a + 1, c = b * 2) { return a * 100 + b * 10 + c; }
function lateDefault(a = 1, b) { return String(a) + "/" + String(b); }
function closes(a, f = () => a * 2) { return f(); }
function many(a, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8, i = 9, j = 10) { return a + b + c + d + e + f + g + h + i + j; }
function withArgs(a, b = 5) { return arguments.length + ":" + a + ":" + b; }
function restLen(a, ...r) { return r.length; }
function restOnly(...r) { return r.length; }

class Vec {
    constructor(x = 0, y = 0, z = 0) { this.x = x; this.y = y; this.z = z; }
    sum() { return this.x + this.y + this.z; }
    scaled(k = 2) { return new Vec(this.x * k, this.y * k, this.z * k); }
}
function Old(a, b = "b") { this.s = a + b; }

var s = 0, t = "";
for (var i = 0; i < 600; i++) {
    s += two(i) + two(i, 1) + two(i, undefined) + two(i, 1, 99);
    s += three(1) + three(1, 2) + three(1, 2, 3) + three(1, undefined, 3);
    s += closes(i) + closes(i, () => 1);
    s += many(1) + many(1, 1, 1, 1, 1, 1, 1, 1, 1, 1) + many(1, undefined, 0);
    s += restLen(1) + restLen(1, 2) + restLen(1, 2, 3, 4, 5) + restOnly() + restOnly(1, 2, 3);
    s += new Vec().sum() + new Vec(1).sum() + new Vec(1, 2).sum() + new Vec(1, 2, 3, 4).sum();
    s += new Vec(i, 1, 1).scaled().sum() + new Vec(1, 1, 1).scaled(3).sum();
    if ((i & 63) == 0) t += lateDefault() + lateDefault(undefined, 2) + lateDefault(3) + withArgs(1) + withArgs(1, 2, 3) + new Old("a").s + new Old("a", "c").s + ",";
}
log(s);
log(t);
log(two.length + " " + three.length + " " + many.length + " " + restLen.length + " " + Vec.length);

// A default that throws, and one that reads a parameter in its TDZ.
function throwing(a, b = (() => { throw new Error("default " + a); })()) { return b; }
function tdz(a = b, b = 1) { return a; }
for (var i = 0; i < 300; i++) throwing(i, 1);
try { throwing(7); } catch (e) { log(e.message); }
for (var i = 0; i < 300; i++) tdz(1);
try { tdz(); } catch (e) { log(e instanceof ReferenceError); }

// Defaults through method calls whose receivers change shape, and a deep recursion.
function depth(n, acc = 0) { return n == 0 ? acc : depth(n - 1, acc + 1); }
log(depth(3000));
var objs = [{ m(a, b = 1) { return a + b; } }, { k: 1, m(a, b = 2) { return a * b; } }];
var u = 0;
for (var i = 0; i < 1000; i++) u += objs[i & 1].m(i) + objs[i & 1].m(i, 3);
log(u);

print(out.join("\n"));

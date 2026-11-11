// `new` of a constructor that is not a straight run of field stores, entered from generated code
// through the callee's call entry: the frame's `this`, new.target, argument counts, the result
// rules, a prototype replaced between calls, several constructors at one site, a throw out of
// the body and constructors that build other objects.
var out = [];
function helper(x) { return x * 2; }
function Vec(x, y) { if (y === undefined) y = -1; this.x = helper(x); this.y = y; }
Vec.prototype.sum = function () { return this.x + this.y; };
function Node(v, next) { this.v = v; this.next = next ? next : null; this.len = next ? next.len + 1 : 1; }
function Tagged() { this.t = new.target === Tagged ? "new" : typeof new.target; }
function Blind(a) { for (var i = 0; i < 2; i++) a += i; }
function Boxed(a) { this.a = a; if (a % 3 === 0) return { boxed: a }; if (a % 3 === 1) return a; }
function Thrower(a) { this.a = a; if (a === 1234) throw new Error("ctor " + a); }
function Outer(a) { this.inner = new Vec(a, a + 1); this.list = new Node(a, new Node(a + 1)); }

function run(n) {
    var acc = 0, last = "";
    for (var i = 0; i < n; i++) {
        var v = new Vec(i, i + 1), w = new Vec(i), z = new Vec(i, 1, 2, 3);
        var l = new Node(i, new Node(i + 1, new Node(i + 2)));
        var t = new Tagged(), b = new Blind(i), x = new Boxed(i), o = new Outer(i);
        acc += v.sum() + w.sum() + z.sum() + l.len + l.next.v + o.inner.sum() + o.list.len;
        if (!(v instanceof Vec) || !(b instanceof Blind) || Object.keys(b).length !== 0) throw new Error("bad " + i);
        last = [t.t, x instanceof Boxed, x.boxed, x.a, o.list.next.v].join();
    }
    return acc + ":" + last;
}
for (var k = 0; k < 30; k++) out.push(run(150 + k));

// One site, several constructors, and a prototype swapped while the site is hot.
function A(v) { this.k = "a" + helper(v); }
function B(v) { this.k = "b" + helper(v); }
function C(v) { this.k = "c" + helper(v); }
var ctors = [A, B, C], protoLog = [];
function make(c, v) { return new c(v); }
for (var i = 0; i < 3000; i++) {
    if (i === 1500) A.prototype = { swapped: true };
    var m = make(ctors[i % 3], i);
    if (i % 499 === 0) protoLog.push(m.k + (m.swapped ? "!" : "") + (m instanceof ctors[i % 3]));
}
out.push(protoLog.join("|"));

// A throw leaves the constructor's frame and the caller goes on.
var caught = 0, built = 0;
for (var i = 0; i < 3000; i++) {
    try { built += new Thrower(i).a; } catch (e) { caught += e.message.length; }
}
out.push(built + ":" + caught);

// The same function called and constructed from one function; new.target tells them apart.
function Dual(v) { if (!new.target) return "call" + helper(v); this.v = helper(v); }
var dual = [];
for (var i = 0; i < 3000; i++) {
    var d = i & 1 ? new Dual(i) : Dual(i);
    if (i % 601 === 0 || i % 601 === 1) dual.push(typeof d === "string" ? d : d.v);
}
out.push(dual.join("|"));
// A constructor that outgrows the inline slots once its site is hot, and a class constructor.
function Grow(n, wide) { this.a = helper(n); if (wide) { this.b = 1; this.c = 2; this.d = 3; this.e = 4; this.f = n; } }
class Point { constructor(x) { this.x = helper(x); this.tag = new.target === Point; } }
var grown = [];
for (var i = 0; i < 4000; i++) {
    var g = new Grow(i, i >= 2000), p = new Point(i);
    if (i % 997 === 0) grown.push(Object.keys(g).length + ":" + (g.f === undefined ? g.a : g.f) + ":" + p.x + p.tag);
}
out.push(grown.join("|"));
console.log(out.join("\n"));

// A base constructor's frame popped by the baseline's inline return: the result is the new
// object unless the body returned an object, whatever primitive it returned instead, and with
// string registers live in the frame. Hot enough for native calls between generated frames.
var out = [];
function P(x) { this.x = x; this.s = "p" + x; }
function R(x) { this.x = x; return x; }
function S(x) { var t = "s" + x; this.t = t; return t; }
function O(x) { this.x = x; return { other: x }; }
function N(x) { this.x = x; return null; }
function U(x) { if (x & 1) return; this.y = x; }
function F(x) { this.x = x; return function () { return x; }; }
function T() { "use strict"; this.v = typeof this; }

function run(n) {
    var sum = 0, last;
    for (var i = 0; i < n; i++) {
        var p = new P(i), r = new R(i), s = new S(i), o = new O(i), z = new N(i), u = new U(i), f = new F(i), t = new T();
        sum += p.x + r.x + s.t.length + o.other + z.x + (u.y === undefined ? 1 : u.y) + f() + (t.v === "object" ? 1 : 0);
        if (!(r instanceof R) || !(s instanceof S) || o instanceof O || !(z instanceof N) || f instanceof F) throw new Error("bad result " + i);
        last = [p.s, typeof r, s.t, o.other, z.x, u.y, typeof f, t.v].join(",");
    }
    return sum + ":" + last;
}
for (var k = 0; k < 30; k++) out.push(run(200));

// Constructors entered through a call site that also calls them plainly.
function both(x) { if (!new.target) return "plain " + x; this.v = x; }
var acc = [];
for (var i = 0; i < 2000; i++) {
    var b = i % 3 ? new both(i) : both(i);
    if (i % 500 === 0) acc.push(typeof b === "string" ? b : b.v);
}
out.push(acc.join("|"));

// Reflect.construct with another new.target keeps that target's prototype.
function Base(x) { this.x = x; }
function Other() {}
var rc = 0;
for (var i = 0; i < 2000; i++) {
    var v = Reflect.construct(Base, [i], Other);
    if (Object.getPrototypeOf(v) === Other.prototype && v.x === i) rc++;
}
out.push(rc);
console.log(out.join("\n"));

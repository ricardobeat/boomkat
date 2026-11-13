// LDTHIS in the optimized code: a sloppy function's `this` is an object, read from the frame's
// record wherever it is used and stored to the window only where something reads it there. A strict
// function's may be a primitive, which keeps its published copy. Each use is checked: returned,
// stored into a field, compared, joined with another object, passed as a receiver to an inlined
// and to a real call, kept across a loop and across a call.
var out = [];
function Box(v) { this.v = v; this.peer = null; }
Box.prototype.get = function () { return this.v; };
// A loop keeps it from being inlined: a real call.
Box.prototype.slow = function (k) { for (var i = 0; i < 1; i++) k = k + this.v; return k; };
Box.prototype.self = function () { var t = this; return t; };
Box.prototype.link = function (o) { var t = this; o.peer = t; return t.v; };
Box.prototype.pick = function (o, k) { var t = this; var r = (k & 1) ? t : o; return r.get(); };
Box.prototype.same = function (o) { var t = this; return t === o ? 1 : 0; };
Box.prototype.calls = function (k) { var t = this; var s = t.slow(k); return s + t.get() + t.v; };
Box.prototype.loop = function (n) {
    var t = this, s = 0;
    for (var i = 0; i < n; i++) { s += t.get(); if (i == 2) t = t.peer || t; }
    return s;
};
String.prototype.sloppyThis = function () { var t = this; return typeof t + t.length; };
String.prototype.strictThis = function () { "use strict"; var t = this; return typeof t + t.length; };
Number.prototype.strictNum = function () { "use strict"; var t = this; return t + 1; };

var a = new Box(3), b = new Box(5);
function run(n) {
    var acc = 0;
    for (var r = 0; r < n; r++) {
        acc += a.self().v + a.link(b) + b.link(a) + a.pick(b, r) + a.same(r & 1 ? a : b);
        acc += a.calls(r & 3) + b.loop(4);
    }
    return acc;
}
function prims(n) {
    var strs = "";
    for (var r = 0; r < n; r++) {
        var s = "abc".sloppyThis() + "de".strictThis() + (r & 7).strictNum();
        if ((r & 1023) == 0) strs += s;
    }
    return strs;
}
var acc = 0;
for (var k = 0; k < 6; k++) acc += run(1000);
// Called from here, each method is optimized on its own too.
for (var r = 0; r < 3000; r++) acc += a.self().v + a.link(b) + a.pick(b, r) + a.same(b);
out.push(acc, prims(6000), a.peer === b, b.peer === a);
for (var r = 0; r < 3000; r++) out[1] += r == 2999 ? "abc".sloppyThis() + "de".strictThis() + (5).strictNum() : "";
console.log(out.join(" "));

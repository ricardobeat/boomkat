// Allocation sinking: inlined `new` objects that never escape are not allocated, and every exit
// that can see one allocates it with the fields it has there. Each function below runs often
// enough to be optimized, then keeps running under the guards that fail after warmup.
var out = [];
function show(name, v) { out.push(name + "=" + v); }

// Plain constructor with number fields computed in the caller.
function P(x, y) { this.x = x; this.y = y; }
function plain(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { var a = i * 0.5, b = i + 1; var p = new P(a, b); s += p.x * p.y; }
    return s;
}

// Class.create style: a forwarding constructor, an inherited `initialize`, branches in the body
// and prototype defaults the adds shadow.
var Class = { create: function () { return function () { this.initialize.apply(this, arguments); }; } };
var Color = Class.create();
Color.prototype = {
    red: 0.0, green: 0.0, blue: 0.0,
    initialize: function (r, g, b) {
        if (!r) r = 0.0;
        if (!g) g = 0.0;
        if (!b) b = 0.0;
        this.red = r; this.green = g; this.blue = b;
    },
    brightness: function () { return this.red * 0.3 + this.green * 0.59 + this.blue * 0.11; },
};
var Vec = Class.create();
Vec.prototype = {
    initialize: function (x, y, z) { this.x = (x ? x : 0); this.y = (y ? y : 0); this.z = (z ? z : 0); },
};
function colors(n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        var f = i * 0.25;
        var c = new Color(f, f + 1, i & 1 ? f * 2 : 0);
        s += c.red + c.green * 2 + c.blue * 3;
        var v = new Vec(f, 0, f - 1);
        s += v.x - v.y + v.z;
    }
    return s;
}

// A field overwritten after the constructor, and an int field read where a double is expected.
function overwrite(n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        var p = new P(i | 0, 2);
        p.x = p.x + 0.5;
        p.y = p.y * i;
        s += p.x + p.y;
    }
    return s;
}

// Exits inside the constructor body after some fields are added: int overflow of a field value.
function Big(a, b) { this.a = a; this.s = (a + b) | 0; this.m = a * b; this.t = this.m + 1; }
function overflow(n, k) {
    var s = 0;
    for (var i = 0; i < n; i++) { var o = new Big(i + k, i * k); s += o.a + o.s + (o.m % 1000) + (o.t % 7); }
    return s;
}

// Escapes of every kind: the object is allocated as before.
var keep = [];
var holder = { o: null };
function sink_none(o) { return o.x; }
function escapes(n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        var a = new P(i, 1);
        if (i % 3 == 0) keep.push(a);
        var b = new P(i, 2);
        holder.o = b;
        var c = new P(i, 3);
        s += sink_none(c);
        var d = new P(i, 4);
        var get = function () { return d.y; };
        s += get();
        var e = new P(i, 5);
        s += e === holder.o ? 100 : 1;
        var f = new P(i, 6);
        s += typeof f == "object" ? 1 : 0;
    }
    if (keep.length > 50) keep.length = 0;
    return s + holder.o.y;
}
function returned(i) { return new P(i, i + 1); }
function returns(n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += returned(i).y;
    return s;
}

// The object seen by an exception: a field value whose computation throws inside the body.
function Thrower(a) { this.a = a; this.b = a.v.w; }
function throws(n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        try {
            var t = new Thrower(i < n - 1 || n < 50 ? { v: { w: i } } : { v: null });
            s += t.a.v.w + t.b;
        } catch (e) {
            s += 1000;
        }
    }
    return s;
}

// A prototype read whose value changes, and prototype changes that invalidate a validated site.
function Q(x) { this.x = x; this.base = this.k; }
Q.prototype.k = 10;
function proto(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { var q = new Q(i); s += q.x + q.base; }
    return s;
}

var fns = [plain, colors, overwrite, function (n) { return overflow(n, 3); }, escapes, returns, throws, proto];
var labels = ["plain", "colors", "overwrite", "overflow", "escapes", "returns", "throws", "proto"];
var sums = [0, 0, 0, 0, 0, 0, 0, 0];
for (var r = 0; r < 600; r++) {
    for (var j = 0; j < fns.length; j++) sums[j] += fns[j](20);
}
for (var j = 0; j < fns.length; j++) show(labels[j], sums[j]);

// After warmup: int overflow in the body.
show("overflow big", overflow(20, 0x3fffffff));
// The prototype's default read changes value, then gets a setter: the adds must call it.
Q.prototype.k = 20;
show("proto value", proto(20));
var seen = 0;
Object.defineProperty(P.prototype, "y", { set: function (v) { seen += v; }, get: function () { return 7; }, configurable: true });
show("setter", plain(20) + ":" + seen);
delete P.prototype.y;
show("setter gone", plain(20));
// The constructor's prototype replaced: a read of the inherited key comes from the new one.
Q.prototype = { k: 5 };
show("proto replaced", proto(20));
Object.prototype.x = 1;
show("object proto", plain(20) + ":" + colors(4));
delete Object.prototype.x;
Object.defineProperty(Object.prototype, "red", { set: function (v) { seen += 1; }, configurable: true });
show("object setter", colors(10) + ":" + seen);
delete Object.prototype.red;
show("after", colors(10) + ":" + throws(60));
print(out.join("\n"));

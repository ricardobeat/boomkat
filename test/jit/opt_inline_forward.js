// Forwarding constructors and methods (`f.apply(this, arguments)`) inlined with the function they
// forward to: argument counts, receivers, guards that fail after warmup and exits from every level.
var out = [];
function show(name, v) { out.push(name + "=" + v); }

// Class.create's constructor, with the forwarded function an own property of the class (so its
// `apply` read is a plain field read) and an own `apply` too.
function Init3(x, y, z) { this.x = x; this.y = y; this.z = z; }
Init3.apply = Function.prototype.apply;
function V() { V.init.apply(this, arguments); }
V.init = Init3;
function makeV(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { var v = new V(i, 2, 3); s += v.x + v.y * v.z; }
    return s;
}

// The forwarded function's `apply` inherited from Function.prototype.
function Init2(a, b) { this.a = a; this.b = b; }
function W() { W.init.apply(this, arguments); }
W.init = Init2;
function makeW(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { var w = new W(i, i + 1); s += w.a * 2 + w.b; }
    return s;
}

// Fewer arguments than the forwarded function's formals: the rest read undefined.
function makeShort(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { var v = new V(i); s += v.x + (v.y === undefined ? 1 : 100) + (v.z === undefined ? 1 : 100); }
    return s;
}

// More arguments than its formals: the surplus is dropped.
function makeLong(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { var v = new V(i, 1, 2, 3, 4, 5); s += v.x + v.y + v.z + (v.w === undefined ? 0 : 1000); }
    return s;
}

// A forwarding method, called with a receiver.
function Adder(k) { this.k = k; }
function addInto(x, y) { var k = (this.k + x * y) & 4095; this.k = k; return k; }
addInto.apply = Function.prototype.apply;
Adder.prototype.add = function () { return Adder.impl.apply(this, arguments); };
Adder.impl = addInto;
function runAdder(n) {
    var a = new Adder(1);
    var s = 0;
    for (var i = 0; i < n; i++) s += a.add(i & 7, 3) & 1023;
    return s + ":" + a.k;
}

// `arguments` read other than to forward it: the forwarding body keeps its object.
function L() { L.init.apply(this, arguments); this.n = arguments.length; }
L.init = Init3;
function makeL(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { var v = new L(i, 1); s += v.x + v.y + v.n + (v.z === undefined ? 7 : 0); }
    return s;
}

// `arguments` written before it is forwarded.
function M() { arguments[0] = 99; M.init.apply(this, arguments); }
M.init = Init3;
function makeM(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { var v = new M(i, 1, 2); s += v.x + v.y + v.z; }
    return s;
}

// A class constructor forwarding to a function.
class K {
    constructor() { K.init.apply(this, arguments); }
}
K.init = Init2;
function makeK(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { var k = new K(i, 5); s += k.a + k.b; }
    return s;
}

// A super constructor through call with explicit arguments.
function Base(a, b) { this.a = a; this.b = b; }
function Derived(a, b, c) { Base.call(this, a, b); this.c = c; }
function makeD(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { var d = new Derived(i, 2, 3); s += d.a + d.b * d.c; }
    return s;
}

// A method that builds through the forwarding constructor: three levels of inlined bodies.
Init3.prototype = V.prototype;
V.prototype.plus = function (w) { return new V(this.x + w.x, this.y + w.y, this.z * w.z); };
function makePlus(n) {
    var a = new V(1, 2, 3);
    var s = 0;
    for (var i = 0; i < n; i++) { var b = a.plus(new V(i, 1, 2)); s += b.x + b.y + b.z; }
    return s;
}

// Many short calls: each function is optimized after enough entries, with its feedback.
var sums = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
var fns = [makeV, makeW, makeShort, makeLong, runAdder, makeL, makeM, makeK, makeD, makePlus];
var labels = ["own apply", "inherited apply", "short", "long", "method", "arguments.length", "arguments written", "class", "call", "plus"];
for (var r = 0; r < 1500; r++) {
    for (var j = 0; j < fns.length; j++) {
        var v = fns[j](10);
        sums[j] = typeof v === "number" ? sums[j] + v : v;
    }
}
for (var j = 0; j < fns.length; j++) show(labels[j], sums[j]);

// The forwarded function replaced after warmup: the guard leaves, the new one runs.
show("before replace", makeV(10));
V.init = function (x, y, z) { this.x = -x; this.y = y + 1; this.z = z; };
V.init.apply = Function.prototype.apply;
show("after replace", makeV(10));
// Its `apply` replaced: no longer the builtin.
V.init.apply = function (self, args) { self.x = 1000; self.y = args.length; self.z = 1; };
show("apply replaced", makeV(10));
V.init.apply = Function.prototype.apply;

// A forwarding method whose receiver changes kind after warmup.
function P() { return P.init.apply(this, arguments); }
P.init = function (x) { return typeof this + ":" + x; };
P.init.apply = Function.prototype.apply;
var holder = { p: P };
function callP(n) {
    var s = "";
    for (var i = 0; i < n; i++) s = holder.p(i);
    return s;
}
for (var r = 0; r < 1500; r++) callP(10);
show("receiver", callP(10));
holder = { p: P, q: 1 };
show("other receiver", callP(10));
Number.prototype.p = P;
holder = 7;
show("primitive receiver", callP(10));

// Exceptions thrown inside the forwarded body after it ran inlined.
var throwAt = 1e9;
function Thrower(x) { if (x > throwAt) throw new Error("big " + x); this.x = x; }
Thrower.apply = Function.prototype.apply;
function T() { T.init.apply(this, arguments); }
T.init = Thrower;
function makeT(n) {
    var s = 0;
    try {
        for (var i = 0; i < n; i++) s += new T(i).x;
    } catch (err) {
        return s + " " + err.message;
    }
    return s;
}
var nt = 0;
for (var r = 0; r < 1500; r++) nt += makeT(10);
show("no throw", nt);
throwAt = 5;
show("throw", makeT(10));

// A getter for the forwarded function.
var getterCount = 0;
function G() { G.init.apply(this, arguments); }
Object.defineProperty(G, "init", { get: function () { getterCount++; return Init2; } });
function makeG(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { var g = new G(i, 1); s += g.a + g.b; }
    return s;
}
var gs = 0;
for (var r = 0; r < 1500; r++) gs += makeG(10);
show("getter", gs + " " + getterCount);

print(out.join("\n"));

// Methods and data read from the prototype chain inside inlined callees (`this.dot(...)`): chains of
// one to three links, a method shadowed on the instance after warmup, the prototype replaced or
// mutated, getters on the prototype, receivers of other shapes, and GC pressure.
var out = [];
function show(label, v) { out.push(label + "=" + (Object.is(v, -0) ? "-0" : String(v))); }

function A(x) { this.x = x; }
A.prototype.dbl = function () { return this.x * 2; };
A.prototype.k = 10;
function B(x) { A.call(this, x); }
B.prototype = Object.create(A.prototype);
B.prototype.inc = function () { return this.x + 1; };
function C(x) { B.call(this, x); }
C.prototype = Object.create(B.prototype);
C.prototype.neg = function () { return -this.x; };
function D(x) { C.call(this, x); }
D.prototype = Object.create(C.prototype);

// One callee per chain depth: the method is read from the prototype, then called (inlined in turn).
function m1(o) { return o.dbl() + 1; }
function m2(o) { return o.inc() + 1; }
function m3(o) { return o.neg() + 1; }
function m4(o) { return o.dbl() + o.inc() + o.neg(); }
function data(o) { return o.k + o.x; }
function caller(o) { return m1(o) + m2(o) + m3(o) + m4(o) + data(o); }

var a = new A(3), b = new B(3), c = new C(3), d = new D(3);
function viaA(o) { return m1(o) + data(o); }
function viaB(o) { return m1(o) + m2(o) + data(o); }
function viaC(o) { return m1(o) + m2(o) + m3(o) + data(o); }
var acc = 0;
for (var i = 0; i < 6000; i++) { acc += viaA(a) + viaB(b) + viaC(c) + caller(d); }
show("warm", acc);

// A method shadowed on the instance after warmup.
d.dbl = function () { return 1000; };
show("shadow", caller(d));
show("shadowOthers", caller(new D(3)));
delete d.dbl;
show("unshadow", caller(d));

// The prototype method replaced, then another property added to an intermediate prototype.
A.prototype.dbl = function () { return this.x * 3; };
show("replaced", caller(d));
B.prototype.dbl = function () { return this.x * 5; };
show("shadowInProto", caller(d));
delete B.prototype.dbl;
show("unshadowProto", caller(d));

// The prototype replaced with another object.
Object.setPrototypeOf(d, { dbl: function () { return 7; }, inc: function () { return 8; }, neg: function () { return 9; }, k: 1 });
show("setproto", caller(d));
Object.setPrototypeOf(d, D.prototype);
show("restored", caller(d));
D.prototype = { dbl: function () { return 11; }, inc: function () { return 12; }, neg: function () { return 13; }, k: 2 };
show("newctorproto", caller(new D(3)));

// Getters on the prototype, and data turned into an accessor.
var G = { get k() { return 99; }, dbl: function () { return 1; }, inc: function () { return 2; }, neg: function () { return 3; } };
var g = Object.create(G); g.x = 4;
show("getter", caller(g));
A.prototype.k = 10;
Object.defineProperty(A.prototype, "k", { get: function () { return 55; }, configurable: true });
show("dataToAccessor", caller(c));
Object.defineProperty(A.prototype, "k", { value: 10, writable: true, configurable: true });
show("accessorToData", caller(c));

// A method deleted: the call then throws a TypeError.
var del = new B(1);
var saved = A.prototype.dbl;
delete A.prototype.dbl;
try { show("deleted", m1(del)); } catch (e) { show("deleted", e.name); }
A.prototype.dbl = saved;
show("restoredMethod", m1(del));

// Receivers of other kinds through the same sites: arrays, strings, functions, proxies.
Array.prototype.dbl = function () { return this.length * 2; };
Array.prototype.inc = function () { return this.length + 1; };
Array.prototype.neg = function () { return -this.length; };
Array.prototype.k = 4;
Array.prototype.x = 1;
show("array", caller([1, 2, 3]));
String.prototype.dbl = function () { return 2; };
show("string", m1("abc"));
show("fn", (function () { Function.prototype.dbl = function () { return 6; }; return m1(function () {}); })());
var px = new Proxy({}, { get: function (t, k) { return k === "dbl" ? function () { return 77; } : undefined; } });
show("proxy", m1(px));
delete Array.prototype.dbl; delete Array.prototype.inc; delete Array.prototype.neg; delete Array.prototype.k; delete Array.prototype.x;
delete String.prototype.dbl; delete Function.prototype.dbl;

// Objects of varying shape sharing a prototype, each with a different extra field order.
var P = { f: function () { return this.v; }, w: 3 };
function readf(o) { return o.f() + o.w; }
function mk(n) { var o = Object.create(P); if (n & 1) o.a = 1; if (n & 2) o.b = 2; o.v = n; return o; }
var s = 0;
for (var i = 0; i < 4000; i++) s += readf(mk(i & 3));
show("shapes", s);
P.w = 5;
show("shapesAfterWrite", readf(mk(1)));
P.f = function () { return -1; };
show("shapesAfterMethod", readf(mk(2)));

// Allocation pressure while the optimized code runs.
var keep = [];
var t = 0;
for (var i = 0; i < 20000; i++) { var o = new D(i & 7); keep[i & 63] = { o: o, s: "k" + i }; t += caller(o) & 255; }
show("gc", t);

print(out.join("\n"));

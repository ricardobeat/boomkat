// A method run in register mode reads and writes its own receiver, not its caller's, and a
// function called without a receiver sees the global object.
function P(v, o) { this.v = v; this.o = o; }
P.prototype.get = function () { return this.v; };
P.prototype.put = function (x) { this.v = x; return 0; };
P.prototype.pair = function () { return this.v * 10 + this.o.get(); };
P.prototype.swap = function (x) { return this.o.put(x) + this.v; };
var a = new P(1, null), b = new P(2, a), r = 0;
for (var k = 0; k < 100000; k++) r += b.pair();
print(r);
r = 0;
for (var k = 0; k < 100000; k++) r += b.swap(k & 7);
print(r, a.v, b.v);

var v = 7;
function g() { return this.v; }
function h(o) { var t = o; return g() + 1; }
function run() { var s = 0; for (var i = 0; i < 3000; i++) s += h({ v: 100 }); return s; }
for (var k = 0; k < 30; k++) r = run();
print(r);

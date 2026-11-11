// An inlined method call proven by the function object in its slot: the slot overwritten with
// another closure of the same code, another function, an accessor; the prototype replaced; and
// methods that die between calls.
function A(v) { this.v = v; }
A.prototype.get = function () { return this.v; };
function sum(o, n) { var s = 0; for (var i = 0; i < n; i++) s += o.get(); return s; }
var a = new A(3);
var r = [];
for (var k = 0; k < 40; k++) r.push(sum(a, 2000));
// Same code, another closure in the slot.
function mk(d) { return function () { return this.v + d; }; }
A.prototype.get = mk(1);
for (var k = 0; k < 40; k++) r.push(sum(a, 2000));
A.prototype.get = mk(2);
for (var k = 0; k < 40; k++) r.push(sum(a, 2000));
// A different function entirely, then an accessor, then an own property shadowing it.
A.prototype.get = function () { return 7; };
for (var k = 0; k < 40; k++) r.push(sum(a, 2000));
Object.defineProperty(A.prototype, "get", { get: function () { return function () { return 9; }; }, configurable: true });
for (var k = 0; k < 40; k++) r.push(sum(a, 2000));
a.get = function () { return 11; };
for (var k = 0; k < 40; k++) r.push(sum(a, 2000));
// A property added to the method itself, and the prototype swapped under the receiver.
var b = new A(5);
A.prototype = { get: mk(100) };
for (var k = 0; k < 40; k++) r.push(sum(b, 2000));
Object.setPrototypeOf(b, { get: mk(1000) });
for (var k = 0; k < 40; k++) r.push(sum(b, 2000));
// Methods that die and are reallocated between calls.
function churn() { var p = { get: mk(4) }; var o = Object.create(p); o.v = 1; return sum(o, 3000); }
var t = 0; for (var k = 0; k < 400; k++) t += churn();
r.push(t);
var h = 0; for (var k = 0; k < r.length; k++) h = (h * 31 + r[k]) % 1000000007;
print(h, r[0], r[45], r[85], r[125], r[165], r[205], r[245], r[285], t);

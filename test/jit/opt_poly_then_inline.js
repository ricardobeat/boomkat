// A polymorphic call inlined case by case, then a monomorphic call whose body is lowered in place:
// that body's instructions are numbered by its own bytecode, which must not be taken for the
// positions of the first call's case tests in the spliced graph.
function A() { this.v = 1; this.p = 2; this.q = 3; }
A.prototype.get = function () { return this.v; };
function B() { this.v = 10; this.p = 20; this.q = 30; }
B.prototype.get = function () { return this.v * 2; };
function sum() { return this.p + this.q; }
A.prototype.sum = sum;
B.prototype.sum = sum;
function call(o) { return o.get() + o.sum(); }
var a = new A(), b = new B(), t = 0;
for (var i = 0; i < 20000; i++) t += call(i & 1 ? a : b);
print(t);

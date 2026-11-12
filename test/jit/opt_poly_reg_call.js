// Polymorphic calls whose callees are too big to inline, entered as register calls of the function
// the callee holds: methods of up to four classes, plain calls through a variable, a fifth target
// that arrives after the compile, a callee that throws, and recursion through the call.
function big(o, n) {
  var s = 0;
  for (var i = 0; i < n; i++) s += (o.v + i) & 7;
  return s;
}
function A(v) { this.v = v; }
A.prototype.run = function (n) { var s = big(this, n); for (var j = 0; j < 2; j++) s += j; return s + 1; };
function B(v) { this.v = v; }
B.prototype.run = function (n) { var s = big(this, n); for (var j = 0; j < 3; j++) s -= j; return s + 2; };
function C(v) { this.v = v; }
C.prototype.run = function (n) { var t = 0; while (t < n) t += 2; return t + this.v * 3; };
function D(v) { this.v = v; }
D.prototype.run = function (n) { if (n === 13 && this.v === 99) throw new Error("thirteen"); var s = 0; for (var j = 0; j < n; j++) s ^= j; return s; };
function E(v) { this.v = v; }
E.prototype.run = function (n) { var s = 0; for (var j = 0; j < n; j++) s += this.v; return s; };

var objs = [new A(1), new B(2), new C(3), new D(4)];
function drive(list, rounds) {
  var total = 0;
  for (var r = 0; r < rounds; r++) {
    for (var k = 0; k < list.length; k++) total += list[k].run(r % 17);
  }
  return total;
}
var out = [];
// Many entries make the drivers hot; their loops alone would credit the callees' loops.
function rounds(list, times, each) {
  var t = 0;
  for (var q = 0; q < times; q++) t += drive(list, each);
  return t;
}
out.push(rounds(objs, 3000, 2));
// A throw out of a callee, through the call, to a caller of the caller.
objs[3].v = 99;
try { drive(objs, 50); } catch (e) { out.push(e.message); }
objs[3].v = 4;
// A fifth class at the same call.
objs.push(new E(5));
out.push(rounds(objs, 2000, 2));

// Plain calls through a variable holding one of two functions.
function f1(x) { var s = 0; for (var i = 0; i < 3; i++) s += x; return s; }
function f2(x) { var s = 1; for (var i = 0; i < 2; i++) s *= x; return s; }
function plain(n) {
  var t = 0;
  for (var i = 0; i < n; i++) {
    var g = i & 1 ? f1 : f2;
    t += g(i & 15);
  }
  return t;
}
var pt = 0;
for (var q = 0; q < 3000; q++) pt += plain(8);
out.push(pt);

// Recursion through a polymorphic call.
function Leaf() {}
Leaf.prototype.depth = function (n) { var d = 0; for (var i = 0; i < 2; i++) d += i; return d; };
function Node(next) { this.next = next; }
Node.prototype.depth = function (n) { var x = 0; for (var i = 0; i < 1; i++) x += i; return 1 + x + this.next.depth(n + 1); };
var chain = new Leaf();
for (var c = 0; c < 50; c++) chain = new Node(chain);
var deep = 0;
for (var r = 0; r < 3000; r++) deep += chain.depth(0);
out.push(deep);
print(out.join(" "));

// `new F(a, b)` with F a global constructor the optimized code holds as a constant, its object
// allocated inline with F's prototype: a new `prototype`, a rebinding of F, constructors that return
// objects, derived constructors and new.target take effect at once, also from a callee while the
// code is on the stack.
var log = [];
function check(name, got, want) { if (got !== want) log.push(name + ": " + got + " != " + want); }

function Pair(car, cdr) { this.car = car; this.cdr = cdr; }
function Pair2(car, cdr) { this.car = car; this.cdr = cdr; }
function Other(car, cdr) { this.car = cdr; this.cdr = car; }
function cons(a, b) { return new Pair(a, b); }
function build(n, at, act) {
  var l = null;
  for (var i = 0; i < n; i++) {
    if (i === at) act();
    l = cons(i, l);
  }
  return l;
}
function sum(l) { var s = 0, k = 0; while (l !== null && k < 3) { s += l.car instanceof Object ? 1000 : l.car; l = l.cdr; k++; } return s; }
for (var k = 0; k < 40; k++) build(200, -1, null);
var l = build(4000, -1, null);
check("plain", sum(l), 3999 + 3998 + 3997);
check("proto", Object.getPrototypeOf(l), Pair.prototype);

// A new prototype object, from a callee.
function cons2(a, b) { return new Pair2(a, b); }
function build2(n, at, act) {
  var l = null;
  for (var i = 0; i < n; i++) {
    if (i === at) act();
    l = cons2(i, l);
  }
  return l;
}
for (var k = 0; k < 40; k++) build2(200, -1, null);
var np = { tag: "new" };
l = build2(4000, 2000, function () { Pair2.prototype = np; });
check("new prototype", Object.getPrototypeOf(l), np);
var mid = l;
for (var k = 0; k < 2000; k++) mid = mid.cdr;
check("old prototype", Object.getPrototypeOf(mid) !== np && mid instanceof Object, true);

// The global rebound to another constructor.
var Ctor = Pair;
function make(n, at, act) {
  var l = null;
  for (var i = 0; i < n; i++) {
    if (i === at) act();
    l = new Ctor(i, l);
  }
  return l;
}
for (var k = 0; k < 40; k++) make(200, -1, null);
l = make(4000, 2000, function () { Ctor = Other; });
check("rebound", l instanceof Other && typeof l.car === "object", true);

// A constructor returning an object, and one returning a primitive.
function Boxed(x) { this.x = x; return { boxed: x }; }
function Prim(x) { this.x = x; return 7; }
function boxes(n) { var s = 0; for (var i = 0; i < n; i++) { var b = new Boxed(i); var p = new Prim(i); s += b.boxed + p.x + (b instanceof Boxed ? 100000 : 0); } return s; }
check("return object", boxes(4000), 2 * (4000 * 3999 / 2));

// A derived constructor and new.target.
class Base { constructor(v) { this.v = v; this.t = new.target === Derived ? 1 : 0; } }
class Derived extends Base { constructor(v) { super(v); this.w = v + 1; } }
function NT() { this.nt = new.target === NT; }
function derived(n) { var s = 0; for (var i = 0; i < n; i++) { var d = new Derived(i); var t = new NT(); s += d.v + d.w + d.t + (t.nt ? 1 : 0) + (d instanceof Base ? 1 : 0); } return s; }
check("derived", derived(4000), 2 * (4000 * 3999 / 2) + 4000 * 4);

// The prototype's chain given a setter for a field the constructor adds.
function Field(x) { this.x = x; }
function fields(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); var f = new Field(i); s += f.hasOwnProperty("x") ? 1 : 0; } return s; }
for (var k = 0; k < 40; k++) fields(200, -1, null);
var seen = 0;
check("setter", fields(4000, 2000, function () { Object.defineProperty(Object.prototype, "x", { set: function (v) { seen++; }, configurable: true }); }), 2000);
delete Object.prototype.x;
check("setter calls", seen, 2000);

print(log.length === 0 ? "new_watch ok" : "new_watch FAIL\n" + log.join("\n"));

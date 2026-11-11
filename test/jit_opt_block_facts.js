// Shape facts carried across a straight-line block edge in optimized code:
// the second read of `t.state` skips its guards only while nothing between
// can change the object.
function T(s) { this.state = s; this.n = 0; }
T.prototype.held = function () { return (this.state & 2) != 0 || this.state == 5; };
function U(s) { this.n = 0; this.state = s; }
U.prototype.held = T.prototype.held;
function probe(t, flip) {
  var a = t.state;
  if (flip) { a += t.state; } else { a -= t.state; }
  if (t.held()) a += 100;
  return a + t.n;
}
function run(n) {
  var objs = [new T(1), new T(2), new T(5), new T(4)];
  var sum = 0;
  for (var i = 0; i < n; i++) sum += probe(objs[i & 3], (i & 1) == 0);
  return sum;
}
console.log(run(200000));
// Another shape and a non-int field at the same sites afterwards.
var u = new U(2), v = new T(1.5), w = { state: "x", n: 1, held: function () { return true; } };
console.log(probe(u, true), probe(v, false), probe(w, true), run(1000));

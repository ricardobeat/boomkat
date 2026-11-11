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
// A fact that reaches a join from both arms holds after it; one that an arm ended (a call that
// reshapes the receiver, a store that rebinds the register) does not.
function P(a, b) { this.a = a; this.b = b; }
function grow(p) { if (p.extra === undefined && p.a > 90) p.extra = 1; }
function join(p, q, k) {
  var s = p.a;
  if (k & 1) s += p.b; else s -= q.b;
  s += p.a + p.b;
  if (k & 2) grow(p); else s += q.a;
  s += p.b + p.a;
  var r = p;
  if (k & 4) r = q; else s += r.b;
  return s + r.a + r.b;
}
function run2(n) {
  var ps = [new P(1, 2), new P(3, 4), new P(95, 6), new P(7, 8)], t = 0;
  for (var i = 0; i < n; i++) t = (t + join(ps[i & 3], ps[(i >> 2) & 3], i >> 4)) | 0;
  return t;
}
console.log(run2(300000));
var odd = { b: 5, a: 1 };
console.log(join(odd, new P(1, 2), 0), join(new P(1, 2), odd, 7), run2(4000));

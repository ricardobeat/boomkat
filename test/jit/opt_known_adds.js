// An inlined constructor's adds to the object it builds are stores into known slots
// (OptBuild.add_known): its NEW_OBJECT validates the keys against the prototype chain, so a setter
// or read-only property that appears there later, a replaced prototype, another closure of the
// constructor, string values, an add on one path only, a call that sees the object half-built, a
// nested `new` and more properties than the inline capacity all behave as in the interpreter.
function P(x, y) { this.x = x; this.y = y; }
function Q(s, k) { this.s = s; this.t = s + k; this.n = k; }
function R(f) { this.a = 1; if (f) this.b = 2; this.c = 3; }
var seen = 0;
function peek(o) { seen += o.a | 0; return o; }
function S(v) { this.a = v; peek(this); this.b = v + 1; }
function T(v) { this.p = new P(v, v + 1); this.q = v; }
function W(v) { this.a = v; this.b = v; this.c = v; this.d = v; this.e = v; this.f = v; this.g = v; this.h = v; this.i = v; this.j = v; }
function make(k) {
  return function C(v) { this.u = v; this.w = k; };
}
var C1 = make(1), C2 = make(2);

function sum(o) { var s = 0; for (var k in o) s += typeof o[k] == "number" ? o[k] : o[k].length; return s; }
var out = [];
var total = 0;
var setterHits = 0;
for (var i = 0; i < 40000; i++) {
  if (i === 20000) Object.defineProperty(P.prototype, "y", { set: function (v) { setterHits++; }, get: function () { return -1; }, configurable: true });
  if (i === 25000) delete P.prototype.y;
  if (i === 27000) Object.defineProperty(P.prototype, "x", { value: 9, writable: false, configurable: true });
  if (i === 29000) delete P.prototype.x;
  if (i === 31000) P.prototype = { z: 5 };
  var p = new P(i, 2);
  var q = new Q("k" + (i & 7), i & 3);
  var r = new R(i & 1);
  var s = new S(i);
  var t = new T(i & 15);
  var w = new W(i & 3);
  var c = (i & 1 ? new C1(i) : new C2(i));
  total = (total + p.x + p.y + (p.z | 0) + q.t.length + q.n + sum(r) + s.b + t.p.y + t.q + sum(w) + c.u + c.w) | 0;
  if ((i % 5000) === 0) out.push(JSON.stringify([p, q, r, s, t, w, c]) + Object.keys(p).join());
}
print(total, setterHits, seen, out.join("\n"));

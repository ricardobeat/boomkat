// A field store of an object-typed value from optimized code over an object, null, a string, a
// number and undefined in the slot.
function H() { this.cur = null; this.alt = null; this.n = 0; }
function N(v) { this.v = v; this.next = null; }
H.prototype.step = function (x) { var o = this.cur; this.cur = x; this.alt = o; this.n = this.n + 1; return o; };
function run(h, vals, n) { var c = 0; for (var i = 0; i < n; i++) { var o = h.step(vals[i % vals.length]); if (o !== null && o !== undefined && o.v !== undefined) c += o.v | 0; } return c; }
var a = new N(1), b = new N(2), h = new H();
var r = [];
r.push(run(h, [a, b, null], 60000));
// The slot then holds a string, a number, a symbol-keyed thing and undefined before an object replaces it.
var mixed = [a, "str" + r.length, b, 3.5, null, undefined, a, "x".repeat(40), b, 7];
h.cur = "seed" + r.length;
r.push(run(h, mixed, 60000));
h.cur = { v: "s" };
r.push(run(h, mixed, 60000), typeof h.cur, typeof h.alt, h.n);
print(r.join(" "));

// Strings read into registers by optimized code (VALUE nodes from counted holders): through
// inlined getters into field, element and constructor stores and a sunk object, compared, typed,
// and kept across an overwrite of the field that held them and a collection.
function Box(s) { this.s = s; this.n = 1; }
Box.prototype.get = function () { return this.s; };
function Pair(a, b) { this.a = a; this.b = b; }
function step(src, dst, arr, i) {
  var v = src.get();
  dst.s = v;
  arr[i & 7] = src.get();
  var p = new Pair(src.get(), dst.get());
  src.s = "x" + i;
  var t = typeof v;
  return (v === dst.s ? 1 : 0) + (p.a === v ? 2 : 0) + (p.b === v ? 4 : 0) + (t === "string" ? 8 : 0) + v.length;
}
var out = [];
var arr = [0, 0, 0, 0, 0, 0, 0, 0];
var total = 0;
for (var q = 0; q < 20000; q++) {
  var src = new Box("s" + (q % 97));
  var dst = new Box(q % 5 === 0 ? 7 : "d");
  total += step(src, dst, arr, q);
  if (q % 4000 === 0) { var junk = []; for (var k = 0; k < 2000; k++) junk.push({ k: "j" + k }); }
}
out.push(total, arr.join(","));
function sunk(o) {
  var p = new Pair(o.get(), o.s);
  return p.a + p.b;
}
var s2 = "";
for (var q = 0; q < 5000; q++) s2 = sunk(new Box("z" + (q & 3)));
out.push(s2, sunk(new Box(5)), sunk(new Box(null)));
print(out.join(" "));

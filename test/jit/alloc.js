// Allocation ops (NEWOBJ, NEWOBJ_SHAPE, NEWARR, NEWARR_CONST) in hot code:
// shapes, array literals of each size, objects kept live across collections
// and results used as prototypes and arguments.
var bad = [];
function check(name, ok) { if (!ok) bad.push(name); }
function leaf(t) { return { array: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], string: "S " + t }; }
function empty() { return {}; }
function mixed(i) { return { a: i, b: [i, i + 1], c: {}, d: [] }; }
function big(n) { var a = []; for (var i = 0; i < n; i++) a.push(i); return a; }
function lit() { return [1, 2.5, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]; }
var keep = [];
for (var r = 0; r < 20000; r++) {
  var l = leaf(r);
  if (l.string !== "S " + r || l.array.length !== 10 || l.array[9] !== 9 || Object.keys(l).join() !== "array,string") { check("leaf " + r, false); break; }
  var m = mixed(r);
  if (m.a !== r || m.b[1] !== r + 1 || m.d.length !== 0 || Object.getPrototypeOf(m.c) !== Object.prototype) { check("mixed " + r, false); break; }
  var e = empty();
  e.x = r;
  if (e.x !== r || Object.keys(e).length !== 1) { check("empty " + r, false); break; }
  var q = lit();
  q[0] = r;
  if (q.length !== 20 || lit()[0] !== 1 || q[1] !== 2.5) { check("lit " + r, false); break; }
  if (r % 50 === 0) { var b = big(r % 40); if (b.length !== r % 40 || (b.length && b[b.length - 1] !== b.length - 1)) { check("big " + r, false); break; } }
  if (r % 7 === 0) keep.push(l, m);
  if (keep.length > 2000) keep = keep.slice(1000);
}
for (var k = 0; k < keep.length; k += 2) {
  if (keep[k].array[5] !== 5 || keep[k + 1].b.length !== 2) { check("kept " + k, false); break; }
}
if (bad.length) throw new Error("alloc: " + bad.join(", "));
print("ok");

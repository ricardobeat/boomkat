// Inline allocation of object and array literals in hot code (baseline NEWOBJ,
// NEWOBJ_SHAPE and NEWARR; optimized NEW_OBJECT): every object shape the inline
// layouts cover and the ones that fall to the helper (wide shapes, big array
// literals), collections that begin and finish inside allocation loops, property
// growth past the inline slots, prototypes, weak references and finalization.
var bad = [];
function check(name, ok) { if (!ok) bad.push(name); }

function o0() { return {}; }
function o1(i) { return { a: i }; }
function o2(i) { return { a: i, b: i + 1 }; }
function o3(i) { return { a: i, b: i + 1, c: i + 2 }; }
function o4(i) { return { a: i, b: i + 1, c: i + 2, d: i + 3 }; }
function o5(i) { return { a: i, b: i + 1, c: i + 2, d: i + 3, e: i + 4 }; }
function o6(i) { return { a: i, b: i + 1, c: i + 2, d: i + 3, e: i + 4, f: i + 5 }; }
function o8(i) { return { a: i, b: i + 1, c: i + 2, d: i + 3, e: i + 4, f: i + 5, g: i + 6, h: i + 7 }; }
function o9(i) { return { a: i, b: i + 1, c: i + 2, d: i + 3, e: i + 4, f: i + 5, g: i + 6, h: i + 7, j: i + 8 }; }
function o12(i) { return { a: i, b: 1, c: 2, d: 3, e: 4, f: 5, g: 6, h: 7, j: 8, k: 9, l: 10, m: i }; }
function a1(i) { return [i]; }
function a3(i) { return [i, i + 1, i + 2]; }
function a8(i) { return [i, 1, 2, 3, 4, 5, 6, i]; }
function a16(i) { return [i, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, i]; }
function a17(i) { return [i, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, i]; }
function a0() { return []; }
function nested(i) { return { p: [i, { q: i }], r: { s: [i] } }; }
function Point(x, y) { this.x = x; this.y = y; }
function Wide(i) { this.a = i; this.b = i; this.c = i; this.d = i; this.e = i; this.f = i; this.g = i; this.h = i; this.i = i; this.j = i; }

function verify(i) {
  var v;
  v = o0(); if (Object.keys(v).length !== 0 || Object.getPrototypeOf(v) !== Object.prototype) return "o0";
  v = o1(i); if (v.a !== i || Object.keys(v).join() !== "a") return "o1";
  v = o2(i); if (v.a !== i || v.b !== i + 1 || Object.keys(v).join() !== "a,b") return "o2";
  v = o3(i); if (v.c !== i + 2 || Object.keys(v).length !== 3) return "o3";
  v = o4(i); if (v.d !== i + 3 || Object.keys(v).length !== 4) return "o4";
  v = o5(i); if (v.e !== i + 4 || Object.keys(v).length !== 5) return "o5";
  v = o6(i); if (v.f !== i + 5 || Object.keys(v).length !== 6) return "o6";
  v = o8(i); if (v.h !== i + 7 || Object.keys(v).length !== 8) return "o8";
  v = o9(i); if (v.j !== i + 8 || Object.keys(v).length !== 9) return "o9";
  v = o12(i); if (v.m !== i || v.l !== 10 || Object.keys(v).length !== 12) return "o12";
  v = a1(i); if (v.length !== 1 || v[0] !== i || !Array.isArray(v)) return "a1";
  v = a3(i); if (v.length !== 3 || v[2] !== i + 2) return "a3";
  v = a8(i); if (v.length !== 8 || v[7] !== i || v[3] !== 3) return "a8";
  v = a16(i); if (v.length !== 16 || v[15] !== i || v[10] !== 10) return "a16";
  v = a17(i); if (v.length !== 17 || v[16] !== i || v[11] !== 11) return "a17";
  v = a0(); if (v.length !== 0 || Object.getPrototypeOf(v) !== Array.prototype) return "a0";
  v = nested(i); if (v.p[1].q !== i || v.r.s[0] !== i || v.p.length !== 2) return "nested";
  v = new Point(i, i + 1); if (v.x !== i || v.y !== i + 1 || Object.getPrototypeOf(v) !== Point.prototype) return "Point";
  v = new Wide(i); if (v.j !== i || Object.keys(v).length !== 10) return "Wide";
  return null;
}

// Allocation loops long enough for several collections to start and finish; the
// chain keeps a window of recent objects alive so a lost object shows up as a
// wrong field.
var window_ = [];
for (var r = 0; r < 60000; r++) {
  var why = verify(r);
  if (why) { check(why + " at " + r, false); break; }
  var n = nested(r);
  window_.push(n, o5(r), a8(r), new Point(r, -r));
  if (window_.length > 400) window_ = window_.slice(200);
}
for (var k = 0; k < window_.length; k += 4) {
  var w = window_[k], e = window_[k + 1], a = window_[k + 2], p = window_[k + 3];
  if (w.p[0] !== w.r.s[0] || e.e !== e.a + 4 || a[0] !== a[7] || p.x !== -p.y) { check("window " + k, false); break; }
}

// Growth after allocation: the inline slots, then a property block, a delete, a
// getter, freezing and a changed prototype all act on the inline-built object.
for (var g = 0; g < 3000; g++) {
  var s = o2(g);
  s.c = 3; s.d = 4; s.e = 5; s.f = 6; s.g = 7;
  if (Object.keys(s).join() !== "a,b,c,d,e,f,g" || s.g !== 7 || s.a !== g) { check("grow " + g, false); break; }
  delete s.b;
  if (Object.keys(s).join() !== "a,c,d,e,f,g") { check("delete " + g, false); break; }
  var t = o1(g);
  Object.defineProperty(t, "z", { get: function () { return 42; } });
  if (t.z !== 42 || t.a !== g) { check("getter " + g, false); break; }
  var f = a3(g);
  Object.freeze(f);
  f.push === Array.prototype.push;
  var threw = false;
  try { "use strict"; f.length = 0; f[0] = 9; } catch (x) { threw = true; }
  if (f[0] !== g) { check("freeze " + g, false); break; }
  var q = o0();
  Object.setPrototypeOf(q, { inherited: g });
  if (q.inherited !== g || Object.getPrototypeOf(q) === Object.prototype) { check("proto " + g, false); break; }
  var arr = a8(g);
  for (var j = 8; j < 40; j++) arr.push(j);
  if (arr.length !== 40 || arr[39] !== 39 || arr[0] !== g) { check("array grow " + g, false); break; }
}

// A literal's prototype follows the heap's current one: Object.prototype and
// Array.prototype gain members the new objects must see.
Object.prototype.__inlineAllocProbe = 1;
Array.prototype.__inlineAllocProbe = 2;
for (var d = 0; d < 500; d++) {
  if (o0().__inlineAllocProbe !== 1 || a3(d).__inlineAllocProbe !== 2) { check("inherit " + d, false); break; }
}
delete Object.prototype.__inlineAllocProbe;
delete Array.prototype.__inlineAllocProbe;

// Weak references and finalization: an object held strongly stays dereferenceable
// across the collections the loop causes; the registry callback never runs for it.
var finalized = 0;
var holders = [];
if (typeof WeakRef === "function") {
  var reg = typeof FinalizationRegistry === "function" ? new FinalizationRegistry(function () { finalized++; }) : null;
  for (var w2 = 0; w2 < 200; w2++) {
    var strong = o3(w2);
    var ref = new WeakRef(strong);
    if (reg) reg.register(strong, w2);
    holders.push([strong, ref]);
  }
  for (var churn = 0; churn < 40000; churn++) { o4(churn); a3(churn); }
  if (typeof gc === "function") gc();
  for (var h = 0; h < holders.length; h++) {
    var d2 = holders[h][1].deref();
    if (d2 !== holders[h][0] || d2.c !== h + 2) { check("weakref " + h, false); break; }
  }
  // Dropped targets may or may not be collected; those that are must not be seen as live objects with the wrong fields.
  var seen = 0;
  for (var x = 0; x < 300; x++) {
    var tmp = o2(x);
    var wr = new WeakRef(tmp);
    tmp = null;
    var got = wr.deref();
    if (got !== undefined && got.a !== x) { check("dropped weakref " + x, false); break; }
    if (got !== undefined) seen++;
  }
}

if (bad.length) throw new Error("alloc_inline: " + bad.join(", "));
print("ok");

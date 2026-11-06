// Named stores whose site entry fits another receiver shape: overwrites and
// adds on several shapes through one site, inherited writable, readonly and
// setter properties, growth past capacity, heap values into counted slots,
// frozen and non-extensible receivers, proxies, arrays, GC pressure.
var bad = [];
function check(name, ok) { if (!ok) bad.push(name); }
function setL(o, v) { o.left = v; }
function setK(o, v) { o.key = v; }
function Node(k) { this.key = k; }
Node.prototype.left = null;
Node.prototype.right = null;
var shapes = [
  function () { return new Node(1); },
  function () { var n = new Node(1); n.left = 1; return n; },
  function () { var n = new Node(1); n.right = 2; return n; },
  function () { var n = new Node(1); n.right = 2; n.left = 3; return n; },
  function () { var n = new Node(1); n.left = 3; n.right = 2; return n; },
  function () { return { key: 1, left: 0 }; },
  function () { return { left: 5 }; },
];
var vals = [1, 2.5, "str" + 1, { k: 1 }, null, undefined, [1], true];
for (var r = 0; r < 20000; r++) {
  var o = shapes[r % shapes.length](), v = vals[r % vals.length], w = vals[(r * 3 + 1) % vals.length];
  setL(o, v);
  setK(o, w);
  if (o.left !== v || o.key !== w || !o.hasOwnProperty("left")) { check("shapes " + r, false); break; }
}
// Properties added keep their order and the prototype's value stays.
var n = new Node(1); setL(n, "x");
check("order", Object.keys(n).join() === "key,left" && Node.prototype.left === null);
// Large objects grow past their capacity through the lookup path.
function setN(o, i, v) { o["p" + i] = v; }
function setP5(o, v) { o.p5 = v; }
for (var r = 0; r < 3000; r++) {
  var b = {}; for (var i = 0; i < 20; i++) b["q" + i] = i;
  if (r % 2) b.p0 = 0;
  setP5(b, r);
  if (b.p5 !== r || Object.keys(b).length !== 21 + (r % 2)) { check("grow " + r, false); break; }
}
// Readonly and setter properties on the chain, appearing late.
var base = { left: null }, got = [];
function Kid() {}
Kid.prototype = base;
for (var r = 0; r < 3000; r++) { var kd = new Kid(); if (r & 1) kd.z = 1; setL(kd, r); }
Object.defineProperty(base, "left", { set(v) { got.push(v); }, configurable: true });
var k1 = new Kid(); k1.z = 1; setL(k1, 5);
check("setter", got.length === 1 && got[0] === 5 && !k1.hasOwnProperty("left"));
Object.defineProperty(base, "left", { value: 1, writable: false, configurable: true });
var k2 = new Kid(); k2.z = 1; setL(k2, 6);
check("readonly", k2.left === 1 && !k2.hasOwnProperty("left"));
// Own readonly and accessor on a receiver of another shape.
var ro = Object.defineProperty({ q: 1 }, "key", { value: 1, writable: false });
setK(ro, 9);
check("own readonly", ro.key === 1);
var acc = { q: 1, set key(v) { got.push("k" + v); } };
setK(acc, 4);
check("own setter", got[got.length - 1] === "k4");
// Frozen, sealed, non-extensible, proxy, array, function receivers.
var fr = Object.freeze({ key: 1, q: 1 }); setK(fr, 3); check("frozen", fr.key === 1);
var ne = Object.preventExtensions({ q: 1 }); setL(ne, 2); check("nonext", !("left" in ne));
var sl = Object.seal({ q: 1, key: 1 }); setK(sl, 8); setL(sl, 8); check("sealed", sl.key === 8 && !("left" in sl));
var log = [], px = new Proxy({}, { set(t, k, v) { log.push(k); t[k] = v; return true; } });
setL(px, 1); setK(px, 2); check("proxy", log.join() === "left,key");
var arr = []; setL(arr, 1); setK(arr, 2); check("array", arr.left === 1 && arr.key === 2 && arr.length === 0);
// GC pressure with heap values replacing heap values.
var keep = [];
for (var r = 0; r < 20000; r++) {
  var g = shapes[r % shapes.length]();
  setL(g, { r: r, s: "s" + r }); setK(g, [r]); setL(g, "t" + r); setK(g, { k: r });
  if (r % 50 === 0) keep.push(g);
}
var ok = true;
for (var i = 0; i < keep.length; i++) if (keep[i].left !== "t" + (i * 50) || keep[i].key.k !== i * 50) ok = false;
check("gc", ok);
// A prototype used as a receiver after the site is hot.
var p = { z: 1 }, c = Object.create(p);
for (var r = 0; r < 100; r++) setL(shapes[r % 7](), r);
setL(p, 7); check("observed", c.left === 7);
if (bad.length) throw new Error("failed: " + bad.join(", "));
print("ok");

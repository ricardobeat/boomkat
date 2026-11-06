// Named stores that add a property: values of each class, growth past the
// inline capacity, hash-table receivers, a receiver used as a prototype after
// the site is hot, non-extensible receivers, a setter or readonly property on
// the chain appearing late, proxies, arrays and stores under GC pressure.
var bad = [];
function check(name, ok) { if (!ok) bad.push(name); }
function P(v, o) { this.a = v; this.b = v; this.c = o; }
var vals = [1, 2.5, "s", { k: 1 }, null, undefined, true, -0, 2 ** 40, [1]];
for (var r = 0; r < 3000; r++) {
  var v = vals[r % vals.length], o = { r: r };
  var p = new P(v, o);
  if (p.a !== v || p.b !== v || p.c !== o || Object.keys(p).join() !== "a,b,c") { check("ctor " + r, false); break; }
}
function Big(n) { this.p0 = n; this.p1 = n + 1; this.p2 = n + 2; this.p3 = n + 3; this.p4 = n + 4;
  this.p5 = n + 5; this.p6 = n + 6; this.p7 = n + 7; this.p8 = n + 8; this.p9 = n + 9; this.p10 = n + 10; this.p11 = n + 11; }
for (var r = 0; r < 3000; r++) {
  var b = new Big(r), s = 0;
  for (var k in b) s += b[k];
  if (s !== 12 * r + 66) { check("grow " + r, false); break; }
}
function setA(o, v) { o.a = v; }
function mk() { return {}; }
for (var r = 0; r < 3000; r++) setA(mk(), r);
// Hash-table receiver.
var h = {};
for (var i = 0; i < 400; i++) h["k" + i] = i;
for (var r = 0; r < 3; r++) { delete h.a; setA(h, r); }
check("hash", h.a === 2 && h.k399 === 399);
// A receiver used as a prototype after the site is hot.
var proto = {};
var kid = Object.create(proto);
check("proto before", kid.a === undefined);
setA(proto, 7);
check("proto after", kid.a === 7);
for (var r = 0; r < 50; r++) { var pr = {}, ch = Object.create(pr); setA(pr, r); check("protos " + r, ch.a === r); }
// Non-extensible, sealed, frozen.
function tryStore(o, v) { try { setA(o, v); } catch (e) { return "throw"; } return o.a; }
var ne = Object.preventExtensions({}), fr = Object.freeze({});
check("nonext", tryStore(ne, 1) === undefined && !("a" in ne));
check("frozen", tryStore(fr, 1) === undefined && !("a" in fr));
// A setter or readonly property on the chain appearing after the site is hot.
var base = {}, got = [];
function Kid() {}
Kid.prototype = base;
function addA(o, v) { o.a = v; }
for (var r = 0; r < 3000; r++) addA(new Kid(), r);
Object.defineProperty(base, "a", { set(v) { got.push(v); }, configurable: true });
var k1 = new Kid(); addA(k1, 5);
check("setter", got.length === 1 && got[0] === 5 && !k1.hasOwnProperty("a"));
Object.defineProperty(base, "a", { value: 1, writable: false, configurable: true });
var k2 = new Kid(); addA(k2, 6);
check("readonly", k2.a === 1 && !k2.hasOwnProperty("a"));
delete base.a;
var k3 = new Kid(); addA(k3, 8);
check("restored", k3.a === 8 && k3.hasOwnProperty("a"));
var other = { z: 1 };
var k4 = new Kid(); Object.setPrototypeOf(k4, other); addA(k4, 9);
check("setproto", k4.a === 9);
Object.defineProperty(Object.prototype, "a", { set(v) { got.push("op" + v); }, configurable: true });
var k5 = new Kid(); addA(k5, 3);
delete Object.prototype.a;
check("objproto", got[got.length - 1] === "op3" && !k5.hasOwnProperty("a"));
// Proxy and array receivers.
var log = [];
var px = new Proxy({}, { set(t, k, v) { log.push(k); t[k] = v; return true; } });
for (var r = 0; r < 100; r++) addA(px, r);
check("proxy", log.length === 100);
for (var r = 0; r < 3000; r++) { var arr = [r]; addA(arr, r); if (arr.a !== r || arr.length !== 1) { check("array", false); break; } }
// Under GC pressure: fresh objects stored into fresh objects.
function holder(i) { var o = {}; o.a = { i: i }; o.b = "s" + i; o.c = [i]; return o; }
var keep = [];
for (var r = 0; r < 60000; r++) {
  var o = holder(r);
  if (r % 100 === 0) keep.push(o);
  if (o.a.i !== r) { check("gc " + r, false); break; }
}
for (var i = 0; i < keep.length; i++) if (keep[i].a.i !== i * 100 || keep[i].b !== "s" + i * 100 || keep[i].c[0] !== i * 100) { check("gc keep " + i, false); break; }
print(bad.length === 0 ? "put_absent ok" : "put_absent FAIL " + bad.join(","));

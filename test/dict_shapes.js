// Dictionary shapes: an object past SHAPE_SOLITARY_MIN_PROPS takes new keys in place, so inline caches that prove a key absent must not describe it.
var o = {};
for (var i = 0; i < 300; i++) o["k" + i] = i;
function rd(x) { return x.k5; }
var s = 0; for (var i = 0; i < 100; i++) s += rd(o);
if (s !== 500) throw new Error("own read " + s);
// proto-resolved IC with dict receiver
var proto = { v: "proto" };
var r = Object.create(proto);
for (var i = 0; i < 100; i++) r["p" + i] = i;
function getv(x) { return x.v; }
for (var i = 0; i < 50; i++) if (getv(r) !== "proto") throw new Error("proto read");
r.v = "own";
if (getv(r) !== "own") throw new Error("dict receiver shadow stale: " + getv(r));
// dict object as prototype
var dp = {};
for (var i = 0; i < 100; i++) dp["d" + i] = i;
var c = Object.create(dp);
function getd(x) { return x.late; }
for (var i = 0; i < 50; i++) if (getd(c) !== undefined) throw new Error("absent");
dp.late = 42;
if (getd(c) !== 42) throw new Error("dict proto late: " + getd(c));
var base = { late: "base" };
var dp2 = Object.create(base);
for (var i = 0; i < 100; i++) dp2["e" + i] = i;
var c2 = Object.create(dp2);
for (var i = 0; i < 50; i++) if (getd(c2) !== "base") throw new Error("chain");
dp2.late = "mid";
if (getd(c2) !== "mid") throw new Error("mid shadow: " + getd(c2));
// absent put through dict proto with setter
var dp3 = {};
for (var i = 0; i < 100; i++) dp3["f" + i] = i;
var c3 = Object.create(dp3);
function setz(x, v) { x.z = v; }
for (var i = 0; i < 20; i++) { var t = Object.create(dp3); setz(t, 1); if (!t.hasOwnProperty("z")) throw new Error("own z"); }
var hit = 0;
Object.defineProperty(dp3, "z", { set: function (v) { hit++; }, configurable: true });
var t = Object.create(dp3); setz(t, 5);
if (hit !== 1 || t.hasOwnProperty("z")) throw new Error("setter via dict proto " + hit);
// delete then keep adding
var d = {};
for (var i = 0; i < 200; i++) d["x" + i] = i;
delete d.x10; delete d.x150;
for (var i = 200; i < 400; i++) d["x" + i] = i;
if (Object.keys(d).length !== 398) throw new Error("keys " + Object.keys(d).length);
var ks = Object.keys(d); if (ks[0] !== "x0" || ks[10] !== "x11" || ks[397] !== "x399") throw new Error("order");
if (d.x399 !== 399 || d.x10 !== undefined || d.x151 !== 151) throw new Error("vals");
// defineProperty flags on dict
var f = {};
for (var i = 0; i < 100; i++) f["y" + i] = i;
Object.defineProperty(f, "y3", { writable: false });
f.y3 = 99; if (f.y3 !== 3) throw new Error("ro");
for (var i = 100; i < 200; i++) f["y" + i] = i;
if (f.y3 !== 3 || f.y199 !== 199) throw new Error("after");
Object.freeze(f); f.y1 = 7; if (f.y1 !== 1) throw new Error("frozen");
// global object growth
for (var i = 0; i < 200; i++) this["gv" + i] = i;
function rg() { return gv5 + gv199; }
var gs = 0; for (var i = 0; i < 100; i++) gs += rg();
if (gs !== 20400) throw new Error("global " + gs);
this.gv5 = 100; if (rg() !== 299) throw new Error("global store");
for (var i = 0; i < 300; i++) this["gw" + i] = i;
if (rg() !== 299) throw new Error("global after growth");
print("ok");

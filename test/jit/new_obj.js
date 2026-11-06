// NEW_OBJ of a simple constructor: initializers, prototype changes, the
// constructor rebound to other kinds of callee, and allocation under GC.
function P(x, y) { this.x = x; this.y = y; }
function Q(x, y) { this.x = x + 1; this.y = y; }
var C = P;
var fails = [];
function check(c, v) { if (!v) fails.push(c); }
var protoA = { tag: "a" };
P.prototype = protoA;
function mk(i) { return new C(i, i * 2); }
for (var i = 0; i < 3000; i++) { var o = mk(i); if (o.x !== i || o.y !== i * 2 || o.tag !== "a") { check("init" + i, false); break; } }
P.prototype = { tag: "b" };
check("proto replaced", mk(1).tag === "b" && !(mk(1) instanceof Object && Object.getPrototypeOf(mk(1)) === protoA));
for (var i = 0; i < 100; i++) mk(i);
P.prototype.extra = 7;
check("proto mutated", mk(2).extra === 7);
C = Q;
check("rebound fn", mk(4).x === 5);
C = function (a) { this.a = a; };
check("fresh fn", mk(3).a === 3);
C = P;
for (var i = 0; i < 100; i++) mk(i);
C = (a) => a;
var t1 = false; try { mk(1); } catch (e) { t1 = e instanceof TypeError; }
check("arrow", t1);
C = class { constructor(a) { this.a = a; } };
check("class", mk(9).a === 9);
C = class extends P { constructor(a, b) { super(a, b); this.z = 1; } };
check("derived", mk(5).z === 1 && mk(5).x === 5);
C = 5;
var t2 = false; try { mk(1); } catch (e) { t2 = e instanceof TypeError; }
check("non-ctor", t2);
C = P;
var keep = [];
for (var i = 0; i < 200000; i++) { var o = mk(i); if (i % 1000 === 0) keep.push(o); }
var ok = true;
for (var j = 0; j < keep.length; j++) if (keep[j].x !== j * 1000 || keep[j].y !== j * 2000) ok = false;
check("gc", ok);
print(fails.length === 0 ? "new_obj ok" : "new_obj FAIL " + fails.join(","));

// Property reads and writes whose inline guards miss: string receivers,
// shape-polymorphic and inherited reads to depth 3, absent keys, accessors,
// computed string keys, prototype mutation after caching, and counted stores
// of heap values over string, object and number slots.
var bad = [];
function check(name, ok) { if (!ok) bad.push(name); }
function A() { this.x = 1; } A.prototype.m = function () { return 7; };
function B() { A.call(this); this.y = 2; } B.prototype = Object.create(A.prototype);
function C() { B.call(this); this.z = 3; } C.prototype = Object.create(B.prototype);
function D() { C.call(this); } D.prototype = Object.create(C.prototype);
var objs = [new A(), new B(), new C(), new D(), { m: 1 }, Object.create(null)];
Object.defineProperty(objs[1], "g", { get: function () { return 42; } });
function rd(v) { return v.m; }
function rq(v) { return v.nothing; }
function rg(v) { return v.g; }
var s = 0, u = 0, g = 0;
for (var k = 0; k < 20000; k++) {
  var v = objs[k % 5], r = rd(v);
  s += typeof r === "function" ? r.call(v) : r;
  if (rq(v) === undefined) u++;
  g += rg(objs[1]);
}
check("chain", s === 20000 / 5 * (7 * 4 + 1) && u === 20000 && g === 42 * 20000);
A.prototype.nothing = 3;
var t = 0;
for (var k = 0; k < 10; k++) t += rq(objs[k % 4]);
check("late proto", t === 30);
Object.setPrototypeOf(objs[3], { nothing: 100, m: 5 });
check("setproto", rq(objs[3]) === 100 && rd(objs[3]) === 5);
// String receivers.
function len(x) { return x.length; }
function up(x) { return x.toUpperCase(); }
var n = 0;
for (var k = 0; k < 5000; k++) { n += len("abc") + up("ab").length; }
check("string", n === 5000 * 5);
String.prototype.extra = function () { return this.length; };
function ex(x) { return x.extra(); }
for (var k = 0; k < 2000; k++) ex("abcd");
check("string ext", ex("abcd") === 4);
String.prototype.extra = function () { return -1; };
check("string override", ex("abcd") === -1);
Object.defineProperty(String.prototype, "acc", { get: function () { "use strict"; return typeof this; }, configurable: true });
function ac(x) { return x.acc; }
for (var k = 0; k < 2000; k++) ac("q");
check("string accessor", ac("q") === "string");
// Computed string keys against one site.
var m = { a: 1, b: 2, c: 3 }, q = Object.create({ inh: 9 });
q.own = 5;
var keys = ["a", "b", "c", "zz", "inh", "own", "toString", "length"];
var tot = 0, und = 0;
for (var i = 0; i < 20000; i++) {
  var key = keys[i % keys.length], x = m[key], y = q[key];
  if (x === undefined) und++; else if (typeof x === "number") tot += x;
  if (y === undefined) und += 2; else if (typeof y === "number") tot += y;
}
check("keyed", tot === 2500 * (6 + 14) && und === 2500 * 14);
// Counted heap-value stores over every old slot class.
function F(v) { this.f = v; }
function put(o, v) { o.f = v; }
var vals = ["s" + 1, { k: 1 }, 5, "t" + 2, [1], 2.5, "u" + 3];
var holder = { f: "init" + 0 };
for (var r = 0; r < 20000; r++) {
  var v = vals[r % vals.length];
  put(holder, v);
  var f = new F(v);
  if (holder.f !== v || f.f !== v) { check("store " + r, false); break; }
  if (r % 500 === 0) { var junk = []; for (var j = 0; j < 200; j++) junk.push({ j: "x" + j }); }
}
if (typeof gc === "function") gc();
check("store end", holder.f === vals[19999 % 7]);
if (bad.length) throw new Error("props_relay: " + bad.join(", "));
print("ok");

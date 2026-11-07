// `Super.call(this, a, b)` inlined (OptBuild.call_window): constructor chains of depth 1 to 3, a
// `this` passed through, methods run on other receivers, primitive `this` for sloppy and strict
// callees, argument counts that differ from the formals, and the callee or Function.prototype.call
// replaced once the code is hot. scripts/opt_exit_check.sh forces an exit at every level.
var out = [];
function show(label, v) { out.push(label + "=" + JSON.stringify(v)); }

function A(a, b) { this.a = a; this.b = b; }
function B(a, b) { A.call(this, a, b); this.c = a + b; }
function C(a, b) { B.call(this, a, b); this.d = a * b; }
function D(a, b) { C.call(this, b, a); this.e = this.a - this.b; }
function B1(a, b) { A.call(this, a); this.c = 1; }
function B3(a) { A.call(this, a, a + 1, a + 2, a + 3); this.c = 2; }
function Bv(a, b) { A.call(this, 0.5 * a, b); this.c = 3; }

var mkSource = "var s = 0; for (var i = 0; i < n; i++) { var o = new ctor(i, 2);"
    + " s += (o.a || 0) + (o.b || 0) + (o.c || 0) + (o.d || 0) + (o.e || 0); } return s;";
// One function (and so one call site) per constructor.
function mkFor() { return new Function("ctor", "n", mkSource); }
var mk = mkFor();
var ctors = [B, C, D, B1, B3, Bv];
for (var k = 0; k < ctors.length; k++) {
    var f = ctors[k];
    var mk1 = mkFor();
    for (var w = 0; w < 3000; w++) mk1(f, 10);
    show("ctor" + k, mk1(f, 300));
    show("shape" + k, Object.keys(new f(1, 2)));
}

// this passed through, and methods run on another receiver.
function Counter() { this.n = 0; }
Counter.prototype.add = function (x) { this.n += x; return this.n; };
function Box(v) { this.v = v; }
Box.prototype.get = function () { return this.v; };
Box.prototype.sum = function (x, y) { return this.v + x + y; };
function viaCall(c, b, i) { return Counter.prototype.add.call(c, i) + Box.prototype.sum.call(b, i, 1) + Box.prototype.get.call(b); }
var cnt = new Counter(), bx = new Box(10), bx2 = new Box(0.5);
for (var w = 0; w < 3000; w++) viaCall(cnt, bx, 1);
function runv(n) { var s = 0; for (var i = 0; i < n; i++) s += viaCall(cnt, i & 1 ? bx : bx2, i); return s; }
for (var w = 0; w < 3000; w++) runv(10);
cnt.n = 0;
show("methods", runv(200));

// Primitive and missing `this`: sloppy callees box it, strict ones keep it.
function sloppyThis() { return typeof this; }
function strictThis() { "use strict"; return typeof this; }
function ignoresThis(x) { return x + 1; }
function runThis(t, n) {
    var s = "";
    for (var i = 0; i < n; i++) s = sloppyThis.call(t) + strictThis.call(t) + ignoresThis.call(t, i);
    return s;
}
var thisVals = [{}, 1, "s", undefined, null, true];
for (var k = 0; k < thisVals.length; k++) {
    for (var w = 0; w < 3000; w++) runThis(thisVals[k], 10);
    show("this" + k, runThis(thisVals[k], 50));
}
// Hot with an object, then another kind of receiver.
for (var w = 0; w < 3000; w++) runThis({}, 10);
show("thisSwitch", [runThis(5, 20), runThis(undefined, 20), runThis({}, 20)]);

// Argument counts that differ from the formals: fewer, more, none besides `this`.
function two(a, b) { return [a, b, arguments.length]; }
function lean2(a, b) { return (a === undefined ? 100 : a) + (b === undefined ? 1000 : b); }
function runArgs(n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += lean2.call(null) + lean2.call(null, i) + lean2.call(null, i, 1) + lean2.call(null, i, 1, 2, 3, 4);
    return s;
}
for (var w = 0; w < 3000; w++) runArgs(10);
show("args", runArgs(100));
show("arguments", two.call(null, 1, 2, 3));

// The callee replaced after the site is hot, and Function.prototype.call itself.
var target = A;
function Wrap(a, b) { target.call(this, a, b); this.w = 1; }
for (var w = 0; w < 3000; w++) mk(Wrap, 10);
target = function (a, b) { this.a = b; this.b = a; };
show("swapped", [mk(Wrap, 100), new Wrap(3, 4)]);
target = A;
var realCall = Function.prototype.call;
for (var w = 0; w < 3000; w++) mk(Wrap, 10);
var calls = 0;
Function.prototype.call = function () { calls++; return realCall.apply(this, arguments); };
show("patched", [mk(Wrap, 100), calls]);
Function.prototype.call = realCall;
show("restored", mk(Wrap, 100));

// An exception from the inlined callee, after fields were added.
function Thrower(a) { this.a = a; if (a === 77) throw new Error("boom"); }
function Catcher(a) { Thrower.call(this, a); this.b = 1; }
for (var w = 0; w < 3000; w++) { try { new Catcher(1); } catch (e) {} }
var msgs = [];
for (var i = 75; i < 80; i++) { try { new Catcher(i); msgs.push("ok" + i); } catch (e) { msgs.push(e.message); } }
show("throw", msgs);

print(out.join("\n"));

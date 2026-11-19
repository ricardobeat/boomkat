// Call sites that have only met one callee (Asm.emit_mono_guard), returns popped inline
// (Asm.emit_site_return) and inherited reads replayed from a prototype epoch, each warmed up
// and then given what the fast path must refuse.
var out = [];
function log(x) { out.push(String(x)); }

function P(v) { this.v = v; }
P.prototype.get = function () { return this.v; };
P.prototype.self = function () { return this; };
P.prototype.str = function () { return "s" + this.v; };
P.prototype.obj = function () { return { w: this.v }; };
P.prototype.none = function () { };

function callGet(o) { return o.get(); }
function callSelf(o) { return o.self(); }
function callStr(o) { return o.str(); }
function callObj(o) { return o.obj().w; }
function callNone(o) { return o.none(); }

var p = new P(3);
var s = 0;
for (var i = 0; i < 400; i++) {
    s += callGet(p) + callObj(p);
    if (callSelf(p) !== p || callStr(p) !== "s3" || callNone(p) !== undefined) s = -1e9;
}
log(s);

// Another function in the slot: the guard's comparison of the compiled function misses.
P.prototype.get = function () { return this.v * 10; };
log(callGet(p));
// An own property shadows the inherited one: the epoch read misses.
p.get = function () { return -1; };
log(callGet(p));
delete p.get;
log(callGet(p));

// A primitive receiver of a function that reads `this`, sloppy and strict.
function plain() { return typeof this; }
function strict() { "use strict"; return typeof this; }
function callOn(f, x) { return f.call(x); }
Number.prototype.kind = plain;
String.prototype.kind = strict;
function kindOf(x) { return x.kind(); }
var o = { kind: plain };
for (var i = 0; i < 300; i++) kindOf(o);
log(kindOf(o) + " " + kindOf(5) + " " + kindOf("x"));

// Closures of one function with different scopes pass the guard alike.
function make(k) { return function (x) { return x + k; }; }
var add1 = make(1), add2 = make(2);
var holder = { f: add1 };
function viaHolder(h, x) { return h.f(x); }
var t = 0;
for (var i = 0; i < 300; i++) t += viaHolder(holder, i);
holder.f = add2;
log(t + " " + viaHolder(holder, 10));

// A callee in a `with` scope: the scope test sends it to the subroutine.
var w = { z: 7 };
var inWith;
with (w) { inWith = function () { return z; }; }
holder.f = inWith;
log(viaHolder(holder, 0));

// A function, then a non-function, then a proxy of the function in the callee's register.
function callIt(f) { return f(2); }
function sq(x) { return x * x; }
for (var i = 0; i < 300; i++) callIt(sq);
try { callIt(5); } catch (e) { log(e instanceof TypeError); }
log(callIt(new Proxy(sq, {})));
log(callIt(sq.bind(null)));

// Returns from frames that hold a catcher or for-in state, and a constructor's result.
function withTry(o) { try { return o.v; } catch (e) { return 0; } }
function withForIn(o) { for (var k in o) return k; return ""; }
function C(v) { this.v = v; }
function D(v) { this.v = v; return { v: v + 1 }; }
var u = 0;
for (var i = 0; i < 300; i++) u += withTry(p) + withForIn(p).length + new C(i).v + new D(i).v;
log(u);

// A prototype mutation after warm-up changes the epoch.
function Q() { }
Q.prototype.val = 1;
function readVal(q) { return q.val; }
var q = new Q();
var r = 0;
for (var i = 0; i < 300; i++) r += readVal(q);
Q.prototype.val = 2;
r += readVal(q);
Object.setPrototypeOf(Q.prototype, { val2: 0 });
Object.defineProperty(Q.prototype, "val", { get: function () { return 100; } });
r += readVal(q);
log(r);

print(out.join("\n"));

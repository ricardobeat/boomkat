// Derived constructors whose super() baseline code completes in place (vm::jit_super_simple), whose
// construction goes straight to its thunk, and whose return the threaded fast return takes. Each
// is warmed up, then given what must leave those paths: fields, brands, arrows, a repeated super(),
// returns before super() or of a primitive, another new.target, a changed prototype or superclass,
// and a superclass that is not simple.
var out = [];
function log(x) { out.push(String(x)); }
function err(f) { try { f(); return "no throw"; } catch (e) { return e.constructor.name; } }

class V { constructor(x, y, z) { this.x = x; this.y = y; this.z = z; } }
class W extends V { constructor(x) { super(x, 1, 2); } }
class W2 extends V { constructor(a, b) { super(a); } }
class X extends W { constructor(x) { super(x * 2); } }
function Old(a, b) { this.a = a; this.b = b; }
class FromOld extends Old { constructor(a) { super(a, "b"); } }

var s = 0;
for (var i = 0; i < 1000; i++) {
    var w = new W(i), w2 = new W2(i, 5), x = new X(i), fo = new FromOld(i);
    s += w.x + w.y + w.z + w2.x + (w2.y === undefined ? 1 : 0) + x.x + x.y + fo.a;
    if (!(w instanceof W) || !(w instanceof V) || !(x instanceof X) || Object.getPrototypeOf(fo) !== FromOld.prototype) s = -1e9;
}
log(s + " " + Object.keys(new W(3)).join() + " " + JSON.stringify(new X(4)) + " " + JSON.stringify(new FromOld(1)));

// Fields, a brand and accessors of the derived class, and fields of the base.
class WF extends V { f = 7; constructor(x) { super(x, 0, 0); this.g = this.f + 1; } }
class WP extends V { #p = 3; m() { return this.#p; } constructor(x) { super(x); } }
class WB extends V { #m() { return 9; } n() { return this.#m(); } constructor(x) { super(x); } }
class VF { h = 1; constructor(x) { this.x = x; } }
class WVF extends VF { constructor(x) { super(x); } }
var t = 0;
for (var i = 0; i < 600; i++) t += new WF(i).g + new WP(i).m() + new WB(i).n() + new WVF(i).h + new WF(i).x;
log(t + " " + JSON.stringify(new WF(2)));

// super() through an arrow, twice, and not at all; this before super(); returns of every kind.
class Arrow extends V { constructor(x) { var f = () => super(x, x, x); f(); this.k = this.x + 1; } }
class Twice extends V { constructor(x) { super(x); if (x === -13) super(x); } }
class Never extends V { constructor(x) { if (x !== -13) super(x); } }
class Early extends V { constructor(x) { if (x === -13) this.q = 1; super(x); } }
class RetObj extends V { constructor(x) { super(x); if (x === -13) return { other: x }; } }
class RetPrim extends V { constructor(x) { super(x); if (x === -13) return 5; } }
class RetUndef extends V { constructor(x) { super(x); return undefined; } }
class RetBefore extends V { constructor(x) { if (x === -13) return { early: 1 }; super(x); } }
var u = 0;
for (var i = 0; i < 400; i++) {
    u += new Arrow(i).k + new Twice(i).x + new Never(i).x + new Early(i).x + new RetObj(i).x + new RetPrim(i).x;
    u += new RetUndef(i).y === undefined ? 1 : 0;
    u += new RetBefore(i).x;
}
log(u);
log([err(() => new Twice(-13)), err(() => new Never(-13)), err(() => new Early(-13)), err(() => new RetPrim(-13))].join(" "));
log(JSON.stringify(new RetObj(-13)) + " " + JSON.stringify(new RetBefore(-13)) + " " + new Arrow(-13).k);

// Another new.target, whose prototype decides the object's.
function NT() {}
NT.prototype = { tag: "nt" };
var r1 = Reflect.construct(W, [1], NT), r2 = Reflect.construct(X, [2], W2);
log(r1.tag + " " + (r1 instanceof W) + " " + r1.x + " " + (r2 instanceof W2) + " " + r2.x);
NT.prototype = { tag: "nt2" };
log(Reflect.construct(W, [1], NT).tag);
var pnt = new Proxy(NT, { get(t, k, r) { return k === "prototype" ? { tag: "proxied" } : Reflect.get(t, k, r); } });
log(Reflect.construct(W, [5], pnt).tag);

// A setter on the base's prototype after warm-up, and a superclass swapped under the class.
Object.defineProperty(V.prototype, "y", { set(v) { this._y = v * 10; }, get() { return this._y; }, configurable: true });
var nw = new W(1);
log(nw.y + " " + Object.keys(nw).join());
delete V.prototype.y;
class Other { constructor(x) { this.other = x; } }
Object.setPrototypeOf(W, Other);
log(JSON.stringify(new W(8)) + " " + (new W(8) instanceof V));
Object.setPrototypeOf(W, V);
log(JSON.stringify(new W(9)));

// Builtin superclasses.
class MyArr extends Array { constructor(n) { super(n); this.tag = "a"; } }
class MyErr extends Error { constructor(m) { super(m); this.kind = "e"; } }
class MyMap extends Map { constructor() { super([[1, 2]]); } }
var b = 0;
for (var i = 0; i < 300; i++) b += new MyArr(3).length + new MyErr("m").message.length + new MyMap().get(1);
log(b + " " + new MyArr(2).tag + " " + (new MyErr("x") instanceof Error));

// Allocation pressure: derived objects kept alive across collections.
var keep = [];
for (var i = 0; i < 20000; i++) { var o = new X(i); if ((i & 63) === 0) keep.push(o); }
var ks = 0;
for (var o of keep) ks += o.x + o.y + o.z;
log(keep.length + " " + ks);

print(out.join("\n"));

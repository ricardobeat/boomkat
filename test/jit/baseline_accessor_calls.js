// Getters and setters baseline code calls natively (Asm.emit_getter_call, Asm.emit_setter_call):
// a read into its own receiver's register or the frame's last one, whose receiver the call keeps in
// a scratch slot, and an inherited setter staged past the frame. Each is warmed up and then given
// what the call must refuse or survive.
var out = [];
function log(x) { out.push(String(x)); }

class V {
    constructor(x) { this._x = x; this.n = 0; }
    get x() { return this._x; }
    set x(v) { this._x = v; this.n++; }
    get boom() { if (this._x === 13) throw new Error("get " + this._x); return this._x; }
    set boom(v) { if (v === 13) throw new Error("set " + v); this._x = v; }
    get fresh() { return { v: this._x }; }
    set many(v) { this._x = arguments.length + v; }
    set dflt(v = 5) { this._x = v; }
    get onlyGet() { return 1; }
    set onlySet(v) { this._x = v; }
}

// The read's register is its receiver's, and the last of the frame.
function readSelf(o) { return o.x; }
function readSum(o) { var s = 0; for (var i = 0; i < 3; i++) s += o.x; return s; }
function readFresh(o) { return o.fresh.v; }
function write(o, v) { o.x = v; return o.n; }
function writeMany(o, v) { o.many = v; return o._x; }
function writeDflt(o, v) { o.dflt = v; return o._x; }
function readOnlySet(o) { return o.onlySet; }
function writeOnlyGet(o) { o.onlyGet = 9; return o.onlyGet; }
function writeOnlyGetStrict(o) { "use strict"; o.onlyGet = 9; return o.onlyGet; }

var v = new V(2);
var s = 0;
for (var i = 0; i < 500; i++) {
    s += readSelf(v) + readSum(v) + readFresh(v);
    s += write(v, i & 7) + writeMany(v, 1) + writeDflt(v, undefined) + writeDflt(v, 3);
    if (readOnlySet(v) !== undefined || writeOnlyGet(v) !== 1) s = -1e9;
    v._x = 2;
}
log(s);
log(v.n);
try { writeOnlyGetStrict(v); log("no throw"); } catch (e) { log(e instanceof TypeError); }

// A throw from the getter and the setter, caught by the caller.
function tryGet(o) { try { return o.boom; } catch (e) { return e.message; } }
function trySet(o, x) { try { o.boom = x; return o._x; } catch (e) { return e.message; } }
var w = new V(1);
for (var i = 0; i < 300; i++) { tryGet(w); trySet(w, i & 3); }
w._x = 13;
log(tryGet(w));
log(trySet(w, 13));
log(trySet(w, 4));

// The accessor replaced: a bound function, a builtin and nothing at all.
function readA(o) { return o.a; }
function writeA(o, x) { o.a = x; return o.seen; }
function A() { this.seen = 0; }
Object.defineProperty(A.prototype, "a", {
    get: function () { return this.seen + 1; },
    set: function (x) { this.seen = x; },
    configurable: true,
});
var a = new A();
for (var i = 0; i < 300; i++) { readA(a); writeA(a, i); }
log(readA(a) + " " + writeA(a, 7));
var host = { seen: 100 };
Object.defineProperty(A.prototype, "a", {
    get: function () { return this.seen; }.bind(host),
    set: function (x) { this.seen = x * 2; }.bind(host),
    configurable: true,
});
log(readA(a) + " " + writeA(a, 7) + " " + host.seen);
Object.defineProperty(A.prototype, "a", {
    get: Object.getOwnPropertyDescriptor(Map.prototype, "size").get,
    configurable: true,
});
try { log(readA(a)); } catch (e) { log(e instanceof TypeError); }
Object.defineProperty(A.prototype, "a", { get: undefined, set: undefined, configurable: true });
log(readA(a) + " " + writeA(a, 5));
// An own data property shadows it, then the prototype changes under the epoch.
a.a = 3;
log(readA(a));
Object.setPrototypeOf(a, { get a() { return "proto"; }, set a(x) { this.other = x; } });
delete a.a;
log(readA(a) + " " + (writeA(a, 6), a.other));

// A primitive receiver of a getter on String.prototype, sloppy and strict.
Object.defineProperty(String.prototype, "kind", {
    get: function () { return typeof this; }, configurable: true,
});
Object.defineProperty(String.prototype, "kindStrict", {
    get: function () { "use strict"; return typeof this; }, configurable: true,
});
function kind(x) { return x.kind; }
function kindStrict(x) { return x.kindStrict; }
for (var i = 0; i < 300; i++) { kind("a"); kindStrict("b"); }
log(kind("x") + " " + kindStrict("y"));
delete String.prototype.kind;
delete String.prototype.kindStrict;

// Allocation in the accessors under a deep chain of reads, so that a collection runs while
// receivers sit in the scratch slots.
class Node {
    constructor(next, v) { this._next = next; this._v = v; }
    get next() { return this._next; }
    get v() { var junk = []; for (var k = 0; k < 4; k++) junk.push({ k: k }); return this._v + junk.length - 4; }
    set v(x) { this._v = { boxed: x }.boxed; }
}
var list = null;
for (var i = 0; i < 200; i++) list = new Node(list, i);
function walk(n) { var t = 0; while (n) { t += n.v; n = n.next; } return t; }
function bump(n) { while (n) { n.v = n.v + 1; n = n.next; } }
var total = 0;
for (var r = 0; r < 30; r++) { bump(list); total += walk(list); }
log(total);

// Private accessors keep PrivateSet's and PrivateGet's checks.
class Priv {
    #v = 0;
    get #p() { return this.#v; }
    set #p(x) { this.#v = x; }
    bump() { this.#p = this.#p + 1; return this.#p; }
    static poke(o) { try { o.#p = 1; return "set"; } catch (e) { return e.constructor.name; } }
}
var pv = new Priv();
for (var i = 0; i < 300; i++) pv.bump();
log(pv.bump() + " " + Priv.poke(pv) + " " + Priv.poke({}));

// Recursion through a getter.
var deep = { get d() { return this.k > 0 ? (this.k--, 1 + this.d) : 0; }, k: 0 };
function depth(o, k) { o.k = k; return o.d; }
for (var i = 0; i < 200; i++) depth(deep, 5);
log(depth(deep, 2000));

print(out.join("\n"));

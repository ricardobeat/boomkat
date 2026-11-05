// Property, global and capture access in the baseline tier: cache hits run
// inline, and every other shape of access must give the interpreter's result.
var out = [];
function log(x) { out.push(String(x)); }
var collect = typeof __gc === "function" ? __gc : function () {
    var junk = [];
    for (var i = 0; i < 20000; i++) junk.push({ i: i, s: "s" + i });
    return junk.length;
};

// Monomorphic, polymorphic and megamorphic reads.
function getX(o) { return o.x; }
function P(x) { this.x = x; this.y = x * 2; }
var mono = 0;
for (var i = 0; i < 200; i++) mono += getX(new P(i));
log("mono " + mono);
var shapes = [{ x: 1 }, { a: 0, x: 2 }, { b: 0, c: 0, x: 3 }];
var poly = 0;
for (var i = 0; i < 300; i++) poly += getX(shapes[i % 3]);
log("poly " + poly);
var mega = [];
for (var k = 0; k < 20; k++) {
    var o = {};
    o["p" + k] = k;
    o.x = k;
    mega.push(o);
}
var m = 0;
for (var i = 0; i < 400; i++) m += getX(mega[i % 20]);
log("mega " + m);
log("missing " + getX({}) + " " + getX(Object.create(null)));

// Prototype-chain reads: one link, several links, shadowing and a repointed
// prototype.
function Base() {}
Base.prototype.k = "base";
function Mid() {}
Mid.prototype = Object.create(Base.prototype);
Mid.prototype.j = "mid";
function getK(o) { return o.k; }
function getJ(o) { return o.j; }
var b = new Base(), md = new Mid();
var chain = "";
for (var i = 0; i < 50; i++) chain = getK(b) + getK(md) + getJ(md);
log("chain " + chain);
md.k = "own";
log("shadow " + getK(md) + " " + getK(new Mid()));
Object.setPrototypeOf(b, { k: "repointed" });
log("repoint " + getK(b));
Base.prototype.k = "changed";
log("proto store " + getK(new Base()) + " " + getK(new Mid()));

// Accessors, on the object and inherited.
var acc = { get x() { return "getter"; } };
var accChild = Object.create(acc);
var a1 = "";
for (var i = 0; i < 30; i++) a1 = getX(acc) + getX(accChild) + getX({ x: i });
log("accessor " + a1);

// Proxies never use the cache.
var trapped = new Proxy({ x: 5 }, { get: function (t, k) { return k === "x" ? 99 : t[k]; } });
var px = 0;
for (var i = 0; i < 20; i++) px += getX(i % 2 ? trapped : { x: 1 });
log("proxy " + px);

// Shape changes between reads: delete, add, redefine.
function readY(o) { return o.y; }
var sh = { x: 1, y: 2 };
var shs = [];
for (var i = 0; i < 40; i++) {
    if (i === 10) delete sh.y;
    if (i === 20) sh.y = "re-added";
    if (i === 30) Object.defineProperty(sh, "y", { get: function () { return "redefined"; } });
    shs.push(readY(sh));
}
log("shape " + shs.join(","));

// Array and string length, and lengths that change.
function len(o) { return o.length; }
var arr = [1, 2, 3], ls = [];
for (var i = 0; i < 10; i++) { arr.push(i); ls.push(len(arr) + len("abc" + i) + len({ length: i })); }
log("length " + ls.join(","));
arr.length = 1;
log("after truncate " + len(arr) + " " + len("") + " " + len(function (a, b) {}) + " " + len(new String("xyz")));
try { len(null); } catch (e) { log("length of null " + (e instanceof TypeError)); }
var symLen = Symbol("s");
log("symbol prop " + len(Object(symLen)));

// Computed keys.
function getC(o, k) { return o[k]; }
var ck = { alpha: 1, beta: "two" }, cks = [];
for (var i = 0; i < 20; i++) cks.push(getC(ck, i % 2 ? "alpha" : "beta"));
log("computed " + cks.slice(0, 4).join(",") + " " + getC([7, 8], 1) + " " + getC("str", 0) + " " + getC(ck, "gamma"));
var dyn = "al" + "pha";
log("non-interned key " + getC(ck, dyn));

// Stores: frozen, non-writable, setters on the prototype, adds.
function setX(o, v) { o.x = v; return o.x; }
var plain = { x: 0 };
for (var i = 0; i < 50; i++) setX(plain, i);
log("store " + plain.x);
var frozen = Object.freeze({ x: 1 });
log("frozen " + setX(frozen, 2));
var ro = {};
Object.defineProperty(ro, "x", { value: "ro", writable: false });
log("readonly " + setX(ro, "w"));
(function () {
    "use strict";
    try { frozen.x = 3; } catch (e) { log("strict frozen " + (e instanceof TypeError)); }
})();
var setterLog = [];
var withSetter = Object.create({ set x(v) { setterLog.push(v); }, get x() { return "via getter"; } });
log("setter " + setX(withSetter, 1) + " " + setterLog.join(","));
var fresh = [];
for (var i = 0; i < 5; i++) fresh.push(setX({}, i));
log("adds " + fresh.join(","));

// Counted slots: strings, objects and numbers over each other.
var slot = { v: 0 };
var kinds = [1, "str" + 1, { o: 1 }, 2.5, "s2", null, undefined, true, 10n, { o: 2 }, "last"];
var seen = [];
for (var r = 0; r < 5; r++) {
    for (var i = 0; i < kinds.length; i++) {
        setX(slot, kinds[i]);
        slot.v = kinds[(i + 3) % kinds.length];
        seen.push(typeof slot.x + typeof slot.v);
    }
}
log("kinds " + seen.slice(0, kinds.length).join(","));

// Stores while the collector runs, so the write barrier keeps new objects.
function Node(n) { this.next = null; this.val = n; }
var head = new Node(0), tail = head;
for (var i = 1; i < 3000; i++) {
    var nd = new Node(i);
    tail.next = nd;
    tail = nd;
    if (i % 500 === 0) collect();
    nd.val = { boxed: i };
}
var sum = 0;
for (var n = head; n !== null; n = n.next) sum += typeof n.val === "object" ? n.val.boxed : n.val;
log("barrier " + sum);

// `this` reads and writes.
function Counter() { this.n = 0; this.label = "c"; }
Counter.prototype.bump = function () { this.n = this.n + 1; return this.n; };
Counter.prototype.rename = function (s) { this.label = s; return this.label; };
var cnt = new Counter(), last;
for (var i = 0; i < 100; i++) last = cnt.bump();
log("this " + last + " " + cnt.rename("x" + last) + " " + cnt.rename(5));
var bumpOther = Counter.prototype.bump;
log("this other " + bumpOther.call({ n: 41 }) + " " + bumpOther.call(Object.freeze({ n: 1 })));

// Globals defined, deleted and redefined between reads.
var gv = 1;
globalThis.gdyn = 10;
function readGlobals() { return gv + (typeof gdyn === "undefined" ? 0 : gdyn); }
var gs = [];
for (var i = 0; i < 30; i++) {
    if (i === 10) delete globalThis.gdyn;
    if (i === 20) globalThis.gdyn = "s";
    gv = i % 3 === 0 ? { valueOf: function () { return 100; } } : i;
    gs.push(readGlobals());
}
log("globals " + gs.join(","));
function readMissing() { try { return notDefinedAnywhere; } catch (e) { return e.name; } }
log("unresolvable " + readMissing());
function readTdz() { try { return lateLet; } catch (e) { return e.name; } }
log("tdz " + readTdz());
let lateLet = "ready";
log("after tdz " + readTdz());

// Captures read and written across many calls.
function makeAcc() {
    var total = 0, name = "acc", obj = { n: 0 };
    return {
        add: function (x) { total = total + x; obj.n++; return total; },
        rename: function (s) { name = s; return name; },
        swap: function (v) { var o = obj; obj = v; return o; },
        get: function () { return name + ":" + total + ":" + obj.n; },
    };
}
var ac = makeAcc();
for (var i = 0; i < 500; i++) ac.add(i);
log("captures " + ac.get() + " " + ac.rename("n" + 1) + " " + ac.rename(7) + " " + ac.swap({ n: 3 }).n + " " + ac.get());
function capLoop() {
    let x = 0;
    const fs = [];
    for (let i = 0; i < 5; i++) fs.push(function () { x += i; return x; });
    for (let r = 0; r < 20; r++) fs[r % 5]();
    return x;
}
log("cell captures " + capLoop());
function capTdz() {
    var f = function () { return later; };
    try { f(); } catch (e) { log("capture tdz " + e.name); }
    let later = 1;
    return f();
}
log("capture after tdz " + capTdz());
function constCap() {
    const k = 1;
    var f = function () { try { k = 2; } catch (e) { return e.name; } };
    return f() + " " + k;
}
log("const capture " + constCap());

// Variable access through scopes.
function scoped() {
    var v = 1;
    var r = [];
    for (var i = 0; i < 10; i++) {
        v = v + i;
        r.push(eval("v"));
    }
    return r.join(",");
}
log("scoped " + scoped());

// A constant-key site switched to the cached form, then missed and
// downgraded, then warmed again.
function site(o) { return o.q; }
var qa = { q: "a" }, qb = { z: 0, q: "b" }, qs = [];
for (var i = 0; i < 12; i++) qs.push(site(i < 4 || i > 8 ? qa : qb));
log("rewrite " + qs.join(""));

// Register moves of objects and other values.
function moves(a) {
    var b = a, c = b, d = c;
    return d;
}
var mv = [];
for (var i = 0; i < 10; i++) mv.push(typeof moves(kinds[i]));
log("moves " + mv.join(","));

log(out.length + 1 + " lines");
console.log(out.join("\n"));

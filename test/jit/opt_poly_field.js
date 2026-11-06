// Polymorphic LOAD_FIELD and STORE_FIELD in the optimizing tier: sites that see 2, 3, 4 and 5
// receiver shapes (key orders, extra keys, subclasses), shapes gained mid-loop, shape ids recycled
// by deleting and a big allocation between phases, frozen receivers, proxies and arrays.
var out = [];
var N = 600;

function mk(k) {
    switch (k) {
        case 0: return { x: 1, y: 2 };
        case 1: return { y: 5, x: 3 };
        case 2: return { a: 1, x: 7, y: 1 };
        case 3: return { x: 2, y: 9, z: 1 };
        default: return { p: 1, q: 2, x: 4, y: 3 };
    }
}

function readX(o) { return o.x; }
function sum(objs, n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        var o = objs[i % objs.length];
        s += o.x + o.y;
    }
    return s;
}
function writeX(objs, n) {
    for (var i = 0; i < n; i++) {
        var o = objs[i % objs.length];
        o.x = i + 0.5;
    }
    var s = 0;
    for (var j = 0; j < objs.length; j++) s += objs[j].x;
    return s;
}
for (var shapes = 1; shapes <= 5; shapes++) {
    var objs = [];
    for (var k = 0; k < shapes; k++) objs.push(mk(k));
    out.push("sum" + shapes + "=" + sum(objs, N));
    out.push("sum" + shapes + "b=" + sum(objs, N));
    out.push("write" + shapes + "=" + writeX(objs, N));
    out.push("write" + shapes + "b=" + writeX(objs, N));
}

// Classes: subclasses add fields, so instances have different shapes.
class A { constructor() { this.v = 1; this.w = 2; } get2() { return this.v + this.w; } set(n) { this.v = n; } }
class B extends A { constructor() { super(); this.extra = 3; } }
class C extends A { constructor() { super(); this.c = 4; this.d = 5; } }
class D extends B { constructor() { super(); this.dd = 6; } }
function callAll(objs, n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        var o = objs[i % objs.length];
        s += o.get2();
        o.set(i);
    }
    return s;
}
var fam = [new A(), new B(), new C(), new D()];
out.push("fam=" + callAll(fam, N), "fam2=" + callAll(fam, N));

// A receiver gains a property mid-loop: a new shape appears at a hot site.
function gain(n) {
    var a = { x: 1, y: 2 }, b = { y: 1, x: 3 }, s = 0;
    for (var i = 0; i < n; i++) {
        var o = (i & 1) ? a : b;
        s += o.x;
        o.x = i;
        if (i == 150) a.z = 1;
        if (i == 250) b.w = 1;
        if (i == 350) delete a.y;
    }
    return s + a.x + b.x;
}
out.push("gain=" + gain(N), "gain2=" + gain(N));

// Shape ids recycled: delete the keys, allocate a lot, make new shapes and use the same sites.
function churn() {
    var s = 0;
    for (var round = 0; round < 4; round++) {
        var objs = [];
        for (var k = 0; k < 4; k++) {
            var o = {};
            o["key" + round + "_" + k] = 1;
            o.x = k + round;
            o.y = k * round;
            objs.push(o);
        }
        s += sum(objs, 200) + writeX(objs, 200);
        var junk = [];
        for (var j = 0; j < 20000; j++) junk.push({ ["g" + (j % 50)]: j, x: 1 });
        junk = null;
    }
    return s;
}
out.push("churn=" + churn(), "churn2=" + churn());

// A frozen receiver in the mix: its store must not land and its read still works.
function mixFrozen(n) {
    var objs = [{ x: 1, y: 1 }, Object.freeze({ x: 5, y: 1 }), { y: 2, x: 2 }, Object.freeze({ y: 3, x: 6, z: 1 })];
    var s = 0;
    for (var i = 0; i < n; i++) {
        var o = objs[i % 4];
        o.x = o.x + 1;
        s += o.x;
    }
    return s;
}
out.push("frozen=" + mixFrozen(N), "frozen2=" + mixFrozen(N));

// A property made readonly on one shape family.
function mixReadonly(n) {
    var a = { x: 1 }, b = { x: 2, y: 1 }, c = { y: 1, x: 3 };
    var s = 0;
    for (var i = 0; i < n; i++) {
        var o = i % 3 == 0 ? a : (i % 3 == 1 ? b : c);
        o.x = i;
        s += o.x;
        if (i == 300) Object.defineProperty(b, "x", { writable: false, value: 77 });
    }
    return s;
}
out.push("readonly=" + mixReadonly(N), "readonly2=" + mixReadonly(N));

// Proxies, arrays, accessors and strings among plain objects at one site.
function exotic(n) {
    var objs = [{ x: 1 }, { y: 0, x: 2 }, new Proxy({ x: 3 }, {}), [1, 2], { get x() { return 9; } }, "str", 7, { q: 1, w: 1, x: 5 }];
    objs[3].x = 11;
    var s = 0;
    for (var i = 0; i < n; i++) {
        var o = objs[i % objs.length];
        var v = o.x;
        s += v === undefined ? 1 : v;
    }
    return s;
}
out.push("exotic=" + exotic(N), "exotic2=" + exotic(N));
function exoticStore(n) {
    var objs = [{ x: 1 }, { y: 0, x: 2 }, new Proxy({ x: 3 }, { set(t, k, v) { t[k] = v + 1; return true; } }), [1, 2], { set x(v) { this.q = v; } }, { q: 1, w: 1, x: 5 }];
    var s = 0;
    for (var i = 0; i < n; i++) {
        var o = objs[i % objs.length];
        o.x = i;
    }
    for (var j = 0; j < objs.length; j++) s += (objs[j].x | 0) + (objs[j].q | 0);
    return s;
}
out.push("exoticStore=" + exoticStore(N), "exoticStore2=" + exoticStore(N));

// Numeric-typed loads over shapes that put the property at different slots.
function fsum(objs, n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) {
        var o = objs[i % objs.length];
        s = s + o.x * 0.5;
    }
    return s;
}
var fobjs = [{ x: 1.5, y: 1 }, { y: 1, x: 2.5 }, { a: 1, b: 2, x: 3.5 }];
out.push("fsum=" + fsum(fobjs, N), "fsum2=" + fsum(fobjs, N));
out.push("readX=" + readX(fobjs[0]) + readX(fobjs[2]));

// this-based access across shapes.
function Pt(a) { if (a & 1) this.u = 1; this.x = a; this.y = 2; }
Pt.prototype.get = function () { return this.x + this.y; };
Pt.prototype.put = function (v) { this.x = v; };
function thisSites(n) {
    var s = 0;
    var pts = [new Pt(0), new Pt(1), new Pt(2)];
    pts[2].t = 1;
    for (var i = 0; i < n; i++) {
        var p = pts[i % 3];
        s += p.get();
        p.put(i);
    }
    return s;
}
out.push("this=" + thisSites(N), "this2=" + thisSites(N));
// Non-plain receivers that keep own data properties by shape: functions, arrays, String and Date
// objects, class instances, at read sites that also see plain objects.
function nonPlain(n) {
    var f = function () {}; f.x = 21;
    var a = [1, 2]; a.x = 22;
    var so = new String("ab"); so.x = 23;
    var d = new Date(0); d.x = 24;
    var e = new Error("e"); e.x = 25;
    var objs = [{ x: 1 }, f, a, so, d, e, { y: 1, x: 2 }, f];
    var s = 0;
    for (var i = 0; i < n; i++) {
        var o = objs[i % objs.length];
        s += o.x;
    }
    for (var j = 0; j < n; j++) {
        var o2 = objs[j % objs.length];
        o2.x = j;
    }
    for (var k = 0; k < objs.length; k++) s += objs[k].x;
    return s;
}
out.push("nonPlain=" + nonPlain(N), "nonPlain2=" + nonPlain(N));
print(out.join("\n"));

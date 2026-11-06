// Object values the optimizing tier keeps in registers between property reads: reuse as a
// receiver, publication before anything that can collect, exits with such values live, stores of
// them into other objects, and loaded values that stop being objects.
// A live heap large enough that collections mark incrementally across many iterations.
var ballast = [];
for (var i = 0; i < 60000; i++) ballast.push({ i: i, next: ballast.length ? ballast[ballast.length - 1] : null });
function check(name, got, want) {
    if (got !== want) { print("FAIL " + name + ": " + got + " != " + want); }
}

// this.a.b.c chain.
function Chain() { this.a = { b: { c: 3 } }; this.n = 0; }
Chain.prototype.run = function (k) {
    var s = 0;
    for (var i = 0; i < k; i++) { s += this.a.b.c; this.n = this.n + 1; }
    return s;
};
var ch = new Chain();
check("chain", ch.run(3000), 9000);

// Object temporaries live across a call that allocates (the collector must see them).
function churn(n) { var a = []; for (var i = 0; i < n; i++) a.push({ i: i, s: "x" + i }); return a.length; }
function across(o) {
    var p = o.next;
    var q = p.next;
    var k = churn(20);
    return p.v + q.v + k;
}
var l3 = { v: 3, next: null }, l2 = { v: 2, next: l3 }, l1 = { v: 1, next: l2 }, l0 = { v: 0, next: l1 };
var tot = 0;
for (var i = 0; i < 4000; i++) tot += across(l0);
check("across", tot, 4000 * 23);

// Fresh objects only reachable from a field read: a collection in between would free them.
function fresh(o) {
    o.tmp = { v: 7, inner: { w: 5 } };
    var t = o.tmp;
    var x = t.inner;
    churn(50);
    return x.w + t.v;
}
var holder = {};
var ft = 0;
for (var i = 0; i < 3000; i++) ft += fresh(holder);
check("fresh", ft, 3000 * 12);

// Store of an object read from a field into another object (barriers under incremental marking).
function link(a, b) {
    var t = a.next;
    b.link = t;
    var u = b.link;
    return u.v;
}
var A = { next: null, v: 0 }, B = { link: null };
var lk = 0;
for (var i = 0; i < 6000; i++) {
    A.next = { v: i, pad: [i, i + 1] };
    lk += link(A, B);
    if (i % 7 == 0) churn(30);
}
check("link", lk, 6000 * 5999 / 2);

// Loaded values that stop being objects: null, number, string, undefined.
function inner(o) { var p = o.p; return p.q; }
var vals = [{ q: 1 }, { q: 2 }, null, 5, "str", undefined, { q: 3 }];
var got = 0, thrown = 0;
for (var r = 0; r < 3000; r++) {
    var v = vals[r % vals.length];
    try { var g = inner({ p: v }); if (g !== undefined) got += g; } catch (e) { thrown++; }
}
print("stopped", got, thrown);

// Shape changes of the intermediate object mid-loop.
function shapes(o, k) {
    var s = 0;
    for (var i = 0; i < k; i++) {
        var p = o.p;
        s += p.x;
        if (i == 700) { delete p.x; p.y = 1; p.x = 10; }
        if (i == 1400) o.p = { z: 0, x: 100 };
    }
    return s;
}
print("shapes", shapes({ p: { x: 1 } }, 2000));

// Tests of such values: truth, equality with null and with each other, numeric use.
function tests(o) {
    var p = o.p, q = o.q, n = 0;
    if (p) n += 1;
    if (q) n += 10;
    if (p === q) n += 100;
    if (p == null) n += 1000;
    if (q !== null) n += 10000;
    return n + (p ? p.k : 0);
}
var sh = { k: 5 };
var tt = 0;
for (var i = 0; i < 3000; i++) tt += tests(i % 3 == 0 ? { p: sh, q: sh } : (i % 3 == 1 ? { p: null, q: sh } : { p: sh, q: null }));
print("tests", tt);
function num(o) { var p = o.p; return p * 2; }
var nm = 0;
for (var i = 0; i < 3000; i++) { var z = num({ p: i % 5 == 0 ? {} : i }); if (z === z) nm += z; }
print("num", nm);

// Copies of an object register, passed to calls and returned.
function id(x) { return x; }
function copy(o) { var p = o.p; var q = p; var r = id(q); return r.v + p.v; }
var cp = 0, cobj = { p: { v: 4 } };
for (var i = 0; i < 4000; i++) cp += copy(cobj);
check("copy", cp, 4000 * 8);

// Objects in a loop: the register crosses a block join.
function walk(h) {
    var s = 0;
    for (var p = h; p !== null; p = p.next) { var q = p.next; if (q !== null) s += q.v; s += p.v; }
    return s;
}
var wsum = 0;
for (var i = 0; i < 2000; i++) wsum += walk(l0);
check("walk", wsum, 2000 * (0 + 1 + 1 + 2 + 2 + 3 + 3));

// Constants loaded into registers around object reads, and a register copied from a read that is
// then reassigned before use.
function consts(o, n) {
    var a = null, b = undefined, c = true, d = false, h = o;
    var s = 0;
    while (h !== null) { s += h.v; a = h.next; h = a; if (a === null) b = 7; c = !c; }
    return s + (b === 7 ? 100 : 0) + (a === null ? 1000 : 0) + (c ? 1 : 0) + (d ? 5 : 0);
}
var cs = 0;
for (var i = 0; i < 4000; i++) cs += consts(l0, i);
print("consts", cs);
var wlast = 0;
for (var i = 0; i < 4000; i++) { var junk = new Array(50); wlast += walk(i % 7 == 0 ? { v: 1, next: { v: 2, next: null } } : l0); }
print("wlast", wlast);
print("done");

// Named property overwrites in the optimizing tier: own writable data properties by shape, a
// numeric value stored unpublished, shape changes and readonly properties mid-loop, receivers
// of other classes, and object values.
var out = [];

function setN(o, n) {
    for (var i = 0; i < n; i++) o.v = i * 0.5 + 1;
    return o.v;
}
out.push(setN({ v: 0, w: 1 }, 500), setN({ v: 0 }, 500));

// The shape changes mid-loop: the guard misses and the baseline redoes the store.
function churn(n) {
    var o = { v: 1, w: 2 }, s = 0;
    for (var i = 0; i < n; i++) {
        o.v = i + 1;
        s += o.v;
        if (i == 100) o.z = 3;
        if (i == 200) delete o.w;
        if (i == 300) o = { w: 1, v: 4 };
        if (i == 400) o = { v: 7, extra: 1, more: 2 };
    }
    return s + o.v;
}
out.push(churn(500), churn(500));

// A property that becomes readonly or frozen in the loop: the store must not land.
function frozen(n) {
    var o = { v: 0 }, s = 0;
    for (var i = 0; i < n; i++) {
        o.v = i;
        if (i == 150) Object.defineProperty(o, "v", { writable: false });
        s += o.v;
    }
    return s;
}
out.push(frozen(300));
function frozen2(n) {
    var o = { v: 0, u: 0 }, s = 0;
    for (var i = 0; i < n; i++) {
        o.v = i + 0.5;
        if (i == 120) Object.freeze(o);
        s += o.v;
    }
    return s;
}
out.push(frozen2(300));
function strictSet(o) { "use strict"; o.v = 5; return o.v; }
var ro = Object.freeze({ v: 1 });
var thrown = 0;
for (var i = 0; i < 300; i++) {
    try { strictSet(ro); } catch (e) { thrown++; }
}
out.push(thrown, strictSet({ v: 1 }));

// this stores, values of every kind, other receivers at one site.
function C(a) { this.a = a; this.b = 0; }
C.prototype.bump = function (n) {
    for (var i = 0; i < n; i++) { this.a = this.a + 1; this.b = this.a * 0.25; }
    return this.a + this.b;
};
C.prototype.setAny = function (x) { this.b = x; return this.b; };
out.push(new C(1).bump(400), new C(2).bump(400));
var kinds = [1, 2.5, "s", null, undefined, {}, [1], true, function () {}];
var c = new C(0), kc = 0;
for (var i = 0; i < 900; i++) { var r = c.setAny(kinds[i % kinds.length]); if (r === kinds[i % kinds.length]) kc++; }
out.push(kc);
function put(o, x) { o.p = x; return o.p; }
var recv = [{ p: 1 }, { q: 1, p: 2 }, [1], "str", 5, { set p(v) { out.length += 0; } }, Object.create({ p: 1 }), new Proxy({ p: 1 }, {}), { p: 1 }];
var res = 0;
for (var i = 0; i < 1800; i++) {
    try { var rr = put(recv[i % recv.length], i); if (rr === i) res++; } catch (e) { res += 1000; }
}
out.push(res);

var line = out.join("|");
var expected = "250.5|250.5|125750|125750|33675|28890|300|5|501.25|502.5|900|1200";
print(line === expected ? "opt_store_field ok" : "opt_store_field FAIL\n" + line + "\n" + expected);

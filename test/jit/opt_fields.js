// Named property reads in the optimizing tier: own data properties by shape, typed uses of the
// value, receivers of other shapes and classes, accessors, inherited properties, and shape ids
// recycled while optimized code holds them.
var out = [];

function sumX(list, n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += list[i % list.length].x * 2;
    return s;
}
function P(x, y) { this.x = x; this.y = y; }
P.prototype.dot = function (o) { return this.x * o.x + this.y * o.y; };
P.prototype.sum = function (n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += this.x + this.y * 0.5;
    return s;
};
var pts = [new P(1, 2), new P(3, 4), new P(5, 6)];
out.push(sumX(pts, 300));
out.push(pts[0].dot(pts[1]), pts[1].sum(100), pts[2].sum(100));

// Other shapes, classes and values at the same site.
var mixed = [new P(1, 2), { x: 10 }, { y: 1, x: 20 }, [1, 2], "str", 7, null, { x: "s" }, { x: undefined }, { get x() { return 5; } }, Object.create({ x: 40 }), new Proxy({ x: 3 }, {}), function () {}];
function readX(o) { return o.x; }
function loop(list, n) {
    var r = [];
    for (var i = 0; i < n; i++) {
        try { r.push(readX(list[i % list.length])); } catch (e) { r.push("E"); }
    }
    return r.join(",");
}
out.push(loop(mixed, 400).slice(0, 60), loop(mixed, 4000).length);

// Numbers read through a field in arithmetic, with the field changing kind.
function addFields(o, n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += o.v + o.w;
    return s;
}
var f = { v: 1, w: 2 };
out.push(addFields(f, 100));
f.v = 1.5;
out.push(addFields(f, 100));
f.w = "3";
out.push(addFields(f, 5));
f.w = 2147483647;
f.v = 2147483647;
out.push(addFields(f, 5));

// A property added and removed: same object, other shape.
function readV(o) { return o.v; }
function churn(n) {
    var o = { v: 1, w: 2 }, s = 0;
    for (var i = 0; i < n; i++) {
        s += readV(o);
        if (i == 50) o.z = 3;
        if (i == 100) delete o.v;
        if (i == 150) o.v = 9;
        if (i == 200) o = { w: 1, v: 4 };
    }
    return s;
}
out.push(churn(300), churn(300));

// Shape ids reused while hot code reads.
var hot = { a: 1, b: 2, c: 3 };
function readB(o) { return o.b; }
function hotLoop() {
    var s = 0;
    for (var i = 0; i < 2000; i++) s += readB(hot);
    return s;
}
var total = 0;
for (var round = 0; round < 30; round++) {
    var junk = [];
    for (var k = 0; k < 3000; k++) {
        var o = {};
        o["p" + ((round * 3000 + k) % 5000)] = k;
        o.b = k;
        junk.push(o);
    }
    junk = null;
    total += hotLoop() + readB({ b: round }) + (readB({ a: 1, b: 100 + round }) | 0);
    if (round % 10 == 5 && typeof gc === "function") gc();
}
out.push(total);

var line = out.join("|");
var expected = "1800|11|500|800|1,10,20,,,,E,s,,5,40,3,,1,10,20,,,,E,s,,5,40,3,,1,10,20,,,,E|7383|300|350|01.531.531.531.531.53|21474836470|NaN|NaN|123870";
print(line === expected ? "opt_fields ok" : "opt_fields FAIL\n" + line + "\n" + expected);

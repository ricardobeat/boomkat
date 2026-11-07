// Branching callees nested in inlined bodies, spliced into the caller's graph at every depth: plain
// calls, method calls and constructors, returns of numbers and objects, exits from every level, and
// a method replaced after warmup.
var out = [];
function show(name, v) { out.push(name + "=" + v); }

function clamp(x) {
    if (x < 0) return 0;
    if (x > 100) return 100;
    return x;
}
function scale(x, k) { return clamp(x * k) + 1; }
function twice(x) { return scale(x, 2) + scale(x, 3); }

function plain(n) {
    var s = 0;
    for (var i = -20; i < n; i++) s += twice(i);
    return s;
}

// A branching method nested in a straight-line method.
function Acc(v) { this.v = v; }
Acc.prototype.pick = function (x) { if (x & 1) return this.v + x; return this.v - x; };
Acc.prototype.step = function (x) { return this.pick(x) * 2; };
function methods(n) {
    var a = new Acc(5);
    var s = 0;
    for (var i = 0; i < n; i++) s += a.step(i);
    return s;
}

// A branching constructor nested in an inlined call, and one returning nothing on every path.
function P(x, y) {
    if (x > y) { this.lo = y; this.hi = x; } else { this.lo = x; this.hi = y; }
}
function mk(x, y) { return new P(x, y); }
function span(x, y) { var p = mk(x, y); return p.hi - p.lo; }
function ctors(n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += span(i, 10);
    return s;
}

// A branching body returning an object or a number.
var box = { v: 7 };
function choose(f) { if (f) return box; return 3; }
function viaChoose(f) { var r = choose(f); return typeof r === "object" ? r.v : r; }
function objects(n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += viaChoose(i & 1);
    return s;
}

// Three levels, the innermost branching.
function lvl3(x) { if (x === 3) return 30; return x; }
function lvl2(x) { return lvl3(x) + 1; }
function lvl1(x) { return lvl2(x) * 2; }
function deep(n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += lvl1(i & 7);
    return s;
}

var a = 0, b = 0, c = 0, d = 0, e = 0;
for (var k = 0; k < 2000; k++) {
    a += plain(30);
    b += methods(20);
    c += ctors(20);
    d += objects(10);
    e += deep(16);
}
show("plain", a);
show("methods", b);
show("ctors", c);
show("objects", d);
show("deep", e);

// Values never seen in warmup.
show("plain double", twice(0.5) + " " + twice(70.25));
show("methods double", methods(3) + " " + new Acc(0.5).step(3));

// The nested method replaced after warmup.
Acc.prototype.pick = function (x) { return x * 100; };
show("replaced", methods(20));
lvl3 = function (x) { return -x; };
show("rebound", deep(16));

print(out.join("\n"));

// Calls inside inlined bodies inlined in turn, up to three deep: static methods reached through a
// captured object (GETCAP + GETPROPC + CALL) and receivers' methods held as own fields. Callee and
// receiver registers of the inner calls often lie beyond the caller's frame, where they live in
// machine registers only. scripts/opt_exit_check.sh forces an exit at every point of the outer,
// middle and inner bodies (inline/, inline2/, inline3/), which publishes every enclosing frame.
var out = [];
function show(label, v) { out.push(label + "=" + v); }

var M = (function () {
    var M = {};
    M.dot = function (a, b) { return a.x * b.x + a.y * b.y; };
    M.len2 = function (a) { return M.dot(a, a); };
    M.cross = function (a, b) { return a.x * b.y - a.y * b.x; };
    M.mix = function (a, b) { return M.len2(a) + M.cross(a, b) * 2; };
    M.deep = function (a, b) { return M.mix(a, b) - M.dot(b, b); };
    M.deeper = function (a, b) { return M.deep(a, b) + 1; };
    M.leaf = function (o) { return o.v * 3; };
    M.step = function (o) { return M.leaf(o) + o.v; };
    return M;
})();

function V(x, y) { this.x = x; this.y = y; }

// Each callee runs once from its own call sites before anything tiers up.
var a = new V(1, 2), b = new V(3, 4);
M.deeper(a, b); M.deep(a, b); M.mix(a, b); M.len2(a);

// Two deep: len2 -> dot.
function two(p, n) { var s = 0; for (var i = 0; i < n; i++) s += M.len2(p) + i; return s; }
// Three deep: mix -> len2 -> dot, and mix -> cross.
function three(p, q, n) { var s = 0; for (var i = 0; i < n; i++) s += M.mix(p, q); return s; }
// Four and five deep: deep -> mix -> len2 -> dot is one level too many, and deeper -> deep more;
// the bodies themselves still inline what fits.
function four(p, q, n) { var s = 0; for (var i = 0; i < n; i++) s += M.deep(p, q) + M.deeper(q, p); return s; }
// A caller with few registers: every window of the chain lies beyond its frame.
function few(p) { return M.mix(p, p); }

// The call sites of the loops record their callees in the interpreter, before the loops get hot.
two(a, 1); three(a, b, 1); four(a, b, 1); few(a);
var t2 = 0, t3 = 0, t4 = 0, tf = 0;
for (var k = 0; k < 1500; k++) {
    t2 += two(a, 20);
    t3 += three(a, b, 20);
    t4 += four(b, a, 20);
    tf += few(k & 1 ? a : b);
}
show("two", t2);
show("three", t3);
show("four", t4);
show("few", tf);

// Doubles and new shapes reaching the inner bodies: exits from two and three levels down.
var d = new V(1.5, 2.25);
var e = { y: 7, x: 0.5 };
show("twoDouble", two(d, 30));
show("threeShape", three(e, d, 30));
show("fewShape", few(e) + few(d));

// One call site of a middle body reaching a different callee: its guard leaves for the middle
// body's baseline code, which makes the call.
var dot0 = M.dot;
M.dot = function (p, q) { return p.x * q.x + p.y * q.y + 1000; };
show("swapped", two(a, 10) + three(a, b, 10));
M.dot = dot0;
show("restored", two(a, 10) + three(a, b, 10));

// A throw from an inner body's baseline code after an exit published its frames: caught here.
function stepAll(list, n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += M.step(list[i & 3]);
    return s;
}
var objs = [{ v: 1 }, { v: 2 }, { v: 3 }, { v: 4 }];
var ts = stepAll(objs, 1);
for (var k2 = 0; k2 < 400; k2++) ts += stepAll(objs, 16);
show("step", ts);
var holder = { get v() { throw new Error("from getter"); } };
try {
    stepAll([objs[0], objs[1], holder, objs[3]], 8);
    show("caught", "no");
} catch (err) {
    show("caught", err.message);
}
M.leaf = function (o) { return o.w.z; };
try {
    stepAll([{ v: 1, w: null }, { v: 1, w: null }, { v: 1, w: null }, { v: 1, w: null }], 4);
    show("caught2", "no");
} catch (err) {
    show("caught2", err instanceof TypeError);
}

// A body that calls itself through its call site is not inlined into itself.
var R = {};
R.f = function (o) { return o.v + R.h(o.n); };
R.h = R.f;
var chain = { v: 1, n: { v: 2, n: { v: 3, n: undefined } } };
var rec = 0;
try { R.f(chain); } catch (err) { rec = 0; }
for (var k3 = 0; k3 < 300; k3++) {
    try { rec += R.f(chain); } catch (err) { rec += 1; }
}
show("recursive", rec);

print(out.join("\n"));

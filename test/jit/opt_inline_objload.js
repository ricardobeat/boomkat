// Callees that load object values (the receivers of further property reads) into temporaries of
// their own window, which lies beyond the caller's frame when the caller has few registers. Such a
// value lives only in a machine register in the optimized caller and is stored in the window by the
// exit stubs, which publish the callee's frame at once. Exits are forced at every point by
// scripts/opt_exit_check.sh; here the shapes change at the end of the run, and the callers allocate
// so that the collector runs while the loop is hot.
var out = [];
function show(label, v) { out.push(label + "=" + v); }
// Callees run once, so that the call sites record them before the callees tier up themselves.
function warm(f, a, b) { f(a, b); }

function mk(i) { return { a: { b: i, c: i + 1, d: { e: i * 2 } }, p: { x: i, y: i + 0.5 }, q: { x: 1, y: 2 } }; }

// Straight-line callees.
function chain2(o) { return o.a.b; }
function chain3(o) { return o.a.d.e; }
function two(o) { return o.a.b + o.a.c; }
function vec(o) { return o.p.x * o.q.x + o.p.y * o.q.y; }
var warm_o = mk(3);
warm(chain2, warm_o);
warm(chain3, warm_o);
warm(two, warm_o);
warm(vec, warm_o);

function run1(o, n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = s + chain2(o) + chain3(o) + two(o) + vec(o);
    return s;
}
for (var k = 0; k < 3000; k++) run1(warm_o, 10);
show("straight", run1(mk(5), 100));

// Flat callees: an object load before and after a branch.
function pick(o, c) {
    var t = o.a.b;
    if (c) { t = t + o.p.x; }
    return t + o.a.c;
}
function pick2(o, c) {
    var r = c ? o.p.x : o.q.x;
    return r + o.a.d.e;
}
warm(pick, warm_o, true);
warm(pick, warm_o, false);
warm(pick2, warm_o, true);
warm(pick2, warm_o, false);

function run2(o, n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = s + pick(o, i & 1) + pick2(o, (i & 2) != 0);
    return s;
}
for (var k = 0; k < 3000; k++) run2(warm_o, 10);
show("flat", run2(mk(7), 100));

// A method reading this.a.b.
function Box(v) { this.a = { b: v, c: { d: v + 1 } }; }
Box.prototype.get = function () { return this.a.c.d + this.a.b; };
var bx = new Box(4);
bx.get();
function run3(b, n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = s + b.get();
    return s;
}
for (var k = 0; k < 3000; k++) run3(bx, 20);
show("method", run3(new Box(9), 100));

// Allocation in the caller around the loop: the collector runs with the optimized body hot.
function run4(o, n) {
    var s = 0.5, keep = [];
    for (var i = 0; i < n; i++) {
        var t = { v: [i, i + 1], w: "s" + i };
        s = s + chain3(o) + two(o) + t.v[1];
        if ((i & 63) == 0) keep.push(t);
    }
    return s + keep.length;
}
for (var k = 0; k < 3000; k++) run4(warm_o, 10);
var total = 0;
for (var k = 0; k < 30; k++) total += run4(mk(k), 3000);
show("gc", total);

// The shapes change after the code is hot: the loads exit from inside the inlined bodies.
var odd = { a: { c: 4, b: 3, d: { e: 5 } }, p: { y: 1, x: 2 }, q: { y: 3, x: 4 }, z: 1 };
show("shape", run1(odd, 50) + run2(odd, 50));
var odd2 = { a: { b: 1, c: 2, d: null }, p: { x: 1, y: 2 }, q: { x: 3, y: 4 } };
var msg = "none";
try { run4(odd2, 10); } catch (e) { msg = e instanceof TypeError ? "TypeError" : String(e); }
show("null", msg);
var odd3 = { a: null, p: { x: 1, y: 2 }, q: { x: 3, y: 4 } };
msg = "none";
try { run1(odd3, 10); } catch (e) { msg = e instanceof TypeError ? "TypeError" : String(e); }
show("null2", msg);

// An object that must be stored where two paths join stays a call: it cannot live in a register.
function sel(o, c) { var q = c ? o.p : o.q; return q.x; }
sel(warm_o, true);
sel(warm_o, false);
function run5(o, n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = sel(o, i & 1) + s;
    return s;
}
for (var k = 0; k < 3000; k++) run5(warm_o, 10);
show("join", run5(mk(5), 100));

print(out.join("\n"));

// Calls the optimizing tier replaces by a callee with forward branches and several returns: an
// early return, a ternary, an if/else that merges a local, nested conditions and a return of
// undefined. The callee's blocks are built into the caller's graph, so the returns merge by a phi
// and an exit from inside a branch publishes the callee's frame and continues in its baseline code.
//
// The callers add a double (0.5) so that they carry operand feedback and are optimized without
// --opt-always; the callees are called in a loop of their own first so that they have baseline
// code, which an exit from their inlined body continues in.
var N = 1200;
var out = [];
function show(label, v) { out.push(label + "=" + v); }

function warm(f, a, b) {
    for (var i = 0; i < 3000; i++) f(a, b);
}

// An early return.
function clampHi(a) { if (a > 100) return 100; return a; }
// A ternary.
function absv(a) { return a < 0 ? 0 - a : a; }
// An if/else merging a local.
function dist(a, b) {
    var r;
    if (a > b) { r = a - b; } else { r = b - a; }
    return r;
}
// Nested conditions with constant returns.
function sign(a) {
    if (a < 0) return -1;
    if (a > 0) return 1;
    return 0;
}
// A branch that is taken late, and a return of the argument itself.
function late(a, b) {
    if (a > 1000000) return a + b;
    return a;
}
// A return of undefined on one path.
function maybe(a) {
    if (a > 5) return;
    return a + 1;
}
// A constant compare against an immediate and a join before the return.
function step(a) {
    var r = a;
    if (a > 10) r = a - 10;
    r = r + 1;
    return r;
}
warm(clampHi, 1);
warm(absv, 1);
warm(dist, 1, 2);
warm(sign, 1);
warm(late, 1, 2);
warm(maybe, 1);
warm(step, 1);
warm(dist, 3, 2);
warm(absv, -2);
warm(clampHi, 500);
warm(sign, -3);
warm(sign, 0);
warm(step, 30);

function sumClamp(n, x) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = clampHi(i * x) + s;
    return s;
}
for (var k = 0; k < N; k++) sumClamp(50, 3);
show("clamp", sumClamp(200, 3));
show("clampDouble", sumClamp(200, 1.5));

function sumAbs(n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = absv(i - 25) + s;
    return s;
}
for (var k = 0; k < N; k++) sumAbs(50);
show("abs", sumAbs(100));

function sumDist(n, m) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = dist(i, m) + s;
    return s;
}
for (var k = 0; k < N; k++) sumDist(50, 20);
show("dist", sumDist(100, 40));
show("distDouble", sumDist(100, 40.5));

function sumSign(n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = sign(i - 10) + sign(10 - i) + s;
    return s;
}
for (var k = 0; k < N; k++) sumSign(30);
show("sign", sumSign(100));

function sumLate(n, x) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = late(i * x, 7) + s;
    return s;
}
for (var k = 0; k < N; k++) sumLate(50, 3);
// The taken branch the baseline has never run: its feedback is empty, so the site stays a call or
// leaves the body at that instruction; either way the sum is the interpreter's.
show("late", sumLate(100, 3));
show("lateTaken", sumLate(100, 100000));
show("lateOverflow", sumLate(100, 1073741824));

function sumMaybe(n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = (maybe(i) | 0) + s;
    return s;
}
for (var k = 0; k < N; k++) sumMaybe(30);
show("maybe", sumMaybe(100));

function sumStep(n, x) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = step(i + x) + s;
    return s;
}
for (var k = 0; k < N; k++) sumStep(40, 3);
show("step", sumStep(100, 3));
show("stepDouble", sumStep(100, 0.25));

// An exit from inside a branch: an argument that is not an int32 where the body checks one, an
// overflow in the arithmetic of one arm, and a window value (a string) compared in the body.
function mix(n, x) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = dist(i, x) + clampHi(x) + s;
    return s;
}
for (var k = 0; k < N; k++) mix(50, 20);
show("mix", mix(60, 20));
show("mixDouble", mix(60, 20.75));
show("mixString", mix(60, "20"));
show("mixOverflow", mix(60, -2147483640));
show("mixBig", mix(60, 2147483640));
show("mixNull", mix(60, null));

// The same callee at two sites, one in each arm of the caller.
function two(n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) {
        if (i & 1) s = clampHi(i) + s; else s = clampHi(i * 7) + s;
    }
    return s;
}
for (var k = 0; k < N; k++) two(50);
show("two", two(100));

print(out.join("\n"));

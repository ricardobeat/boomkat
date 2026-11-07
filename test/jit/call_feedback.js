// Call feedback recorded by the baseline's direct call path: a site first reached after the
// function was compiled (a branch that only a hot loop takes) still names its callee, so the
// optimizing tier can inline it; a site that sees a second callee is polymorphic and must stay
// a call; results match the interpreter either way.
var out = [];
function show(label, v) { out.push(label + "=" + v); }

function add(a, b) { var c = a + b; return c; }
function mul(a, b) { var c = a * b; return c; }
function neg(a) { return -a; }

// The call is first reached long after the loop turned hot.
function lateCall(n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) {
        if (i > 700) s = add(s, i) + 0.25; else s += 0.5;
    }
    return s;
}
var t = 0;
for (var k = 0; k < 300; k++) t += lateCall(1000);
show("late", t);

// Monomorphic through a function value, then a second callee arrives.
function viaValue(f, n) {
    var s = 1.5;
    for (var i = 0; i < n; i++) s = f(s, 2) % 1000.5;
    return s;
}
t = 0;
for (var k = 0; k < 300; k++) t += viaValue(add, 100);
show("mono", t);
for (var k = 0; k < 300; k++) t += viaValue(k % 2 ? add : mul, 100);
show("poly", t);

// A method call site and a callee whose function number is the first one handed out.
var o = { base: 3, m: function (x) { return x + this.base; } };
function viaMethod(n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s += o.m(i);
    return s;
}
t = 0;
for (var k = 0; k < 300; k++) t += viaMethod(100);
show("method", t);
o.m = function (x) { return x - this.base; };
for (var k = 0; k < 300; k++) t += viaMethod(100);
show("swapped", t);

// An exit from the inlined body and a callee that throws.
function thrower(a) { if (a > 90) throw new Error("big " + a); return a + 1; }
function guarded(n) {
    var s = 0.5, caught = 0;
    for (var i = 0; i < n; i++) {
        try { s += thrower(i); } catch (e) { caught++; }
    }
    return s + caught;
}
t = 0;
for (var k = 0; k < 300; k++) t += guarded(100);
show("throw", t);
print(out.join("\n"));

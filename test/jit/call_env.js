// Native calls of functions that need a function scope (needs_env): closures over
// parameters and locals, recursion, exceptions through such frames, name bindings,
// fallbacks (arguments, eval, with, generators, async) and collection with live scopes.

// Mutually recursive closures, each creating a scope that inner closures capture.
function cluster(n) {
    var total = 0;
    function a(x) { var k = x; function g() { return k; } if (x <= 0) return g(); return b(x - 1) + g(); }
    function b(x) { var k = x * 2; function g() { return k; } if (x <= 0) return g(); return c(x - 1) + g(); }
    function c(x) { var k = x * 3; function g() { return k; } if (x <= 0) return g(); return a(x - 1) + g(); }
    for (var i = 0; i < n; i++) total += a(i % 30);
    return total;
}
print("cluster", cluster(3000));

// Closures capturing parameters escape the call; each call gets its own scope.
function makeAdder(base) { return function (v) { return base + v; }; }
var adders = [];
for (var i = 0; i < 2000; i++) adders.push(makeAdder(i));
var s = 0;
for (var i = 0; i < adders.length; i++) s += adders[i](1);
print("adders", s);

// Writes to captured variables through the scope.
function counter() {
    var n = 0;
    function inc() { n++; return n; }
    function run(k) { var last = 0; for (var j = 0; j < k; j++) last = inc(); return last; }
    return run;
}
var r = counter();
var acc = 0;
for (var i = 0; i < 500; i++) acc += r(3);
print("counter", acc);

// Deep recursion through env frames, past the native depth cap.
function deep(n) { var v = n; function get() { return v; } return n === 0 ? get() : deep(n - 1) + get() - n; }
for (var i = 0; i < 50; i++) deep(400);
print("deep", deep(2000));

// Exceptions thrown and caught across env frames.
function thrower(n) { var tag = "e" + n; function t() { throw new Error(tag); } if (n === 0) t(); return thrower(n - 1); }
var caught = 0;
for (var i = 0; i < 300; i++) {
    try { thrower(i % 20); } catch (e) { if (e.message === "e0") caught++; }
}
print("caught", caught);
function catchInside(n) {
    var local = n;
    function f() { if (local % 3 === 0) throw local; return local; }
    try { return f(); } catch (e) { return -e; }
}
var cs = 0;
for (var i = 0; i < 1000; i++) cs += catchInside(i);
print("catchInside", cs);

// Named function expressions bind their own name.
var fact = function self(n) { var m = n; function g() { return m; } return n <= 1 ? 1 : g() * self(n - 1); };
var fs = 0;
for (var i = 0; i < 500; i++) fs += fact(10);
print("named", fs);

// Fallbacks: arguments, eval, with, generators and async callees.
function usesArgs(a) { var x = a; function g() { return x; } return arguments.length + g(); }
function usesEval(a) { var x = a; return eval("x + 1"); }
function usesWith(o) { var y = 1; with (o) { return p + y; } }
function* gen(n) { var k = n; function g() { return k; } yield g(); yield g() + 1; }
async function asy(n) { var k = n; function g() { return k; } return g(); }
var fb = 0;
for (var i = 0; i < 400; i++) {
    fb += usesArgs(i, 1, 2) + usesEval(i) + usesWith({ p: i });
    for (var v of gen(i)) fb += v;
}
print("fallbacks", fb);
var asum = 0;
var pending = [];
for (var i = 0; i < 100; i++) pending.push(asy(i).then(function (v) { asum += v; }));
Promise.all(pending).then(function () { print("async", asum); });

// Sloppy callee reading `this` through a plain call sees the global object.
function sloppyThis() { var q = 1; function g() { return q; } return (this === globalThis) + g(); }
var st = 0;
for (var i = 0; i < 300; i++) st += sloppyThis();
print("sloppyThis", st);

// Collection while scopes are live on native frames.
function churn(n) {
    var keep = [];
    function alloc(k) { var o = { k: k, s: "x" + k }; function g() { return o; } keep.push(g); return g().k; }
    var t = 0;
    for (var j = 0; j < n; j++) t += alloc(j);
    var u = 0;
    for (var j = 0; j < keep.length; j++) u += keep[j]().k;
    return t + u;
}
var ch = 0;
for (var i = 0; i < 30; i++) ch += churn(2000);
print("churn", ch);

// Unbounded recursion through env frames raises RangeError.
function forever(n) { var z = n; function g() { return z; } return forever(n + 1) + g(); }
try { forever(0); print("no overflow"); } catch (e) { print("overflow", e instanceof RangeError); }

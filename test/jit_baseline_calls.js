// Calls and returns between functions that run as native code in the
// baseline tier, and every way a frame can leave one.
var out = [];
function log(x) { out.push(String(x)); }

function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
log(fib(20));

function isEven(n) { return n === 0 ? true : isOdd(n - 1); }
function isOdd(n) { return n === 0 ? false : isEven(n - 1); }
log(isEven(60) + " " + isOdd(61) + " " + isEven(7));

function three(a, b, c) { return [a, b, c].join(","); }
for (var i = 0; i < 3; i++) log(three(1) + "|" + three(1, 2) + "|" + three(1, 2, 3, 4, 5));

function count() { return arguments.length + ":" + Array.prototype.join.call(arguments, "-"); }
function sumArgs() { var s = 0; for (var k = 0; k < arguments.length; k++) s += arguments[k]; return s; }
for (var i = 0; i < 3; i++) log(count(1, 2, 3) + " " + sumArgs(1, 2, 3, 4) + " " + count());

function counter() { var n = 0; return function () { return ++n; }; }
var ctr = counter();
for (var i = 0; i < 5; i++) ctr();
log(ctr());

var obj = {
    base: 10,
    add: function (x) { return this.base + x; },
    twice: function (x) { return this.add(this.add(x)); },
    get doubled() { return this.base * 2; },
};
for (var i = 0; i < 3; i++) log(obj.twice(i) + " " + obj.doubled);

function readGetter(o) { return o.doubled + 1; }
for (var i = 0; i < 3; i++) log(readGetter(obj));

function thrower(n) { if (n === 0) throw new Error("deep"); return thrower(n - 1) + 1; }
function catcher() {
    try { return thrower(30); } catch (e) { return "caught " + e.message; }
}
for (var i = 0; i < 3; i++) log(catcher());

function sameFrame(x) {
    var r = 0;
    for (var k = 0; k < 5; k++) {
        try { if (k === x) throw k; r += k; } catch (e) { r += 100 * e; }
    }
    return r;
}
for (var i = 0; i < 3; i++) log(sameFrame(i));

function* gen(n) { for (var k = 0; k < n; k++) yield k * k; }
function useGen(n) { var s = 0; for (var v of gen(n)) s += v; return s; }
for (var i = 0; i < 3; i++) log(useGen(5 + i));

async function asyncAdd(a, b) { await null; return a + b; }
function useAsync() { return asyncAdd(2, 3).then(function (v) { log("async " + v); }); }
useAsync();

function finallyRet(x) {
    try { if (x) return "try"; } finally { if (x > 1) return "finally"; }
    return "after";
}
function useFinally() { return finallyRet(0) + " " + finallyRet(1) + " " + finallyRet(2); }
for (var i = 0; i < 3; i++) log(useFinally());

class Point {
    constructor(x, y) { this.x = x; this.y = y; }
    len() { return Math.sqrt(this.x * this.x + this.y * this.y); }
}
class Point3 extends Point {
    constructor(x, y, z) { super(x, y); this.z = z; }
    len() { return Math.sqrt(super.len() ** 2 + this.z * this.z); }
}
function makePoints() { return new Point(3, 4).len() + new Point3(2, 3, 6).len(); }
for (var i = 0; i < 3; i++) log(makePoints());

function scaled(k, x) { return k * x; }
var triple = scaled.bind(null, 3);
function useBound() { return triple(5) + triple(7); }
for (var i = 0; i < 3; i++) log(useBound());

function Ctor(v) { this.v = v; }
function useNew() { return new Ctor(4).v + new Ctor(5).v; }
for (var i = 0; i < 3; i++) log(useNew());

function evalCallee(x) { return eval("x * 2 + 1"); }
function useEval() { return evalCallee(4) + evalCallee(5); }
for (var i = 0; i < 3; i++) log(useEval());

function depth(n) { return n === 0 ? 0 : depth(n - 1) + 1; }
log(depth(500));
log(depth(2000));

function runaway(n) { return runaway(n + 1) + 1; }
function catchOverflow() {
    try { runaway(0); return "no overflow"; } catch (e) { return e instanceof RangeError ? "RangeError" : "other " + e; }
}
log(catchOverflow());
log(catchOverflow());
log(depth(100));

function allocate(n) {
    var a = [];
    for (var k = 0; k < n; k++) a.push({ k: k, s: "x" + k });
    return a.length;
}
function gcUnder(n) { return n === 0 ? allocate(20000) : gcUnder(n - 1) + allocate(10); }
for (var i = 0; i < 3; i++) log(gcUnder(20));

function cleanup() { log(out.length + " lines"); console.log(out.join("\n")); }
Promise.resolve().then(function () {}).then(cleanup);

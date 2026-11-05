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

// Direct calls through a callee's call entry: exact arity, method receivers
// of every kind, arity mismatches and callees that throw or recurse.
function Acc(x) { this.x = x; }
Acc.prototype.add = function (a) { return this.x + a; };
Acc.prototype.two = function (a, b) { return this.x + a * b; };
Acc.prototype.self = function () { return this; };
function directMethods(o) {
    var s = 0;
    for (var k = 0; k < 40; k++) s += o.add(k) + o.two(k, 2);
    return s;
}
log(directMethods(new Acc(3)));
log(directMethods(new Acc(-1.5)));
function arity(o) { return [o.add(), o.add(1, 2, 3), o.two(1), o.two(1, 2, 3)].join(); }
for (var i = 0; i < 40; i++) arity(new Acc(1));
log(arity(new Acc(1)));
function primReceiver(r) { return r.add(2); }
Number.prototype.add = function (a) { "use strict"; return typeof this + (this + a); };
String.prototype.add = function (a) { return typeof this + this + a; };
for (var i = 0; i < 40; i++) primReceiver(i);
log(primReceiver(5));
log(primReceiver("s"));
log(primReceiver(new Acc(7)));
function noThis(x, y) { return x - y; }
function plainCall(a) { return noThis(a, 1) + noThis(a, 2); }
for (var i = 0; i < 40; i++) plainCall(i);
log(plainCall(10));
function thrower(o) { if (o.x > 2) throw new Error("big " + o.x); return o.x; }
Acc.prototype.chk = function () { return thrower(this); };
function catching(v) {
    try { return new Acc(v).chk(); } catch (e) { return e.message; }
}
for (var i = 0; i < 40; i++) catching(1);
log(catching(1));
log(catching(5));
function viaFinally(v) {
    var n = 0;
    for (var k = 0; k < 5; k++) { try { n += new Acc(v + k).chk(); } catch (e) { n += 100; } finally { n += 1; } }
    return n;
}
for (var i = 0; i < 40; i++) viaFinally(0);
log(viaFinally(0));
function swapCallee(o, i) { return o.add(i); }
var kinds = [new Acc(1), { add: function (a) { return a * 2; } }, { add: function () { return "z"; } }, { add: Math.abs }];
for (var i = 0; i < 80; i++) swapCallee(kinds[i & 1], i);
log(kinds.map(function (o) { return swapCallee(o, -3); }).join());
Acc.prototype.rec = function (n) { return n === 0 ? this.x : this.rec(n - 1) + 1; };
log(new Acc(0).rec(50));
log(new Acc(0).rec(400));
log(new Acc(0).rec(3000));
var bound = new Acc(9).add.bind(new Acc(1));
function viaBound(o) { return o.f(4); }
log(viaBound({ f: bound }) + viaBound({ f: bound }));
function selfRet(o) { return o.self() === o; }
for (var i = 0; i < 40; i++) selfRet(new Acc(i));
log(selfRet(new Acc(1)));

function cleanup() { log(out.length + " lines"); console.log(out.join("\n")); }
Promise.resolve().then(function () {}).then(cleanup);

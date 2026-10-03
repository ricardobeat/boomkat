// A tail call from a plain frame to a lean function reuses the frame. Results,
// argument counts, `this` and exceptions must match an ordinary call.
function check(label, got, want) {
    if (got !== want) throw new Error(label + ": got " + String(got) + ", want " + String(want));
}

function sum(n, acc) { return n === 0 ? acc : sum(n - 1, acc + n); }
check("self recursion", sum(300000, 0), 300000 * 300001 / 2);

function isEven(n) { return n === 0 ? true : isOdd(n - 1); }
function isOdd(n) { return n === 0 ? false : isEven(n - 1); }
check("mutual recursion", isEven(200001), false);

function add(a, b) { return a + b; }
function wrap2(a, b) { return add(a, b); }
function wrap1(a) { return add(a); }
function wrap3(a, b, c) { return add(a, b, c); }
check("exact args", wrap2(1, 2), 3);
check("missing arg", String(wrap1(1)), "NaN");
check("extra arg", wrap3(1, 2, 3), 3);

// Locals of the replaced frame do not leak into the callee.
function leak(a, b, c) { return a + b + c; }
function fresh(x) { var t1 = 1, t2 = 2, t3 = 3, t4 = 4; return leak(x); }
check("callee locals start undefined", String(fresh(5)), "NaN");

// Heap-valued arguments and results.
function cat(a, b) { return a + b; }
function wrapStr(a) { return cat(a + "x", "y"); }
check("string args", wrapStr("s"), "sxy");
function pick(o, k) { return o[k]; }
function wrapObj(o) { return pick(o, "k"); }
check("object arg", wrapObj({ k: 7 }), 7);

// `this` of the replaced frame and of the callee.
var holder = { v: 3, m() { return thisOf(); } };
function thisOf() { return this === undefined || this === globalThis; }
check("method tail calls plain function", holder.m(), true);
function strictThis() { "use strict"; return this === undefined; }
function wrapStrict() { return strictThis(); }
check("strict callee this", wrapStrict(), true);

// Exceptions unwind past a replaced frame.
function thrower(x) { if (x > 0) throw new RangeError("t" + x); return x; }
function relay(x) { return thrower(x); }
var caught;
try { relay(2); } catch (e) { caught = e.message; }
check("throw through tail call", caught, "t2");
check("catch around tail call", (function () { try { return relay(1); } catch (e) { return e.message; } })(), "t1");
check("finally around tail call", (function () {
    var log = [];
    try { return relay(0); } finally { log.push("f"); }
})(), 0);

// The tail-called binding is reassigned during the call.
var swap = function (x) { swap = null; return x + 1; };
function callSwap(x) { return swap(x); }
check("reassigned binding", callSwap(1), 2);

// A caller that is itself tail-called, from native code and from a method.
function viaMap(x) { return add(x, 1); }
check("map", [1, 2, 3].map(viaMap).join(), "2,3,4");
check("call/apply", viaMap.call(null, 4) + viaMap.apply(null, [5]), 11);

// Frames with a closure cannot be replaced by the lean path; both agree.
function withClosure(n) { var f = () => n; return add(f(), 1); }
check("closure frame", withClosure(4), 5);

// Strings accumulate across a long chain without leaking or corrupting.
function build(n, s) { return n === 0 ? s : build(n - 1, s + "a"); }
check("string chain", build(2000, "").length, 2000);
// A callee held in a register: a parameter, a local, or a function only that
// register references.
function churn() { var a = []; for (var i = 0; i < 3000; i++) a.push({ i: i, s: "k" + i }); return a.length; }
function callParam(f, x) { return f(x); }
check("param callee", callParam((y) => y + 1, 1), 2);
function callLocal(x) { var f = (y) => y * 2; return f(x); }
check("local callee", callLocal(4), 8);
function callFresh(x) { return (function (y) { churn(); return y + 1; })(x); }
check("fresh callee", callFresh(1), 2);
function callMade(x) { var make = () => (y) => { churn(); return y - 1; }; return make()(x); }
check("made callee", callMade(5), 4);
function callStr(a, b) { var s = a + b; return callParam((t) => t + "!", s); }
check("string through param callee", callStr("ab", "cd"), "abcd!");
for (var i = 0; i < 2000; i++) callStr("x" + i, "y");
check("string after loop", callStr("p", "q"), "pq!");
function countdown(f, n) { return n === 0 ? "done" : f(f, n - 1); }
check("register recursion", countdown(countdown, 200000), "done");
print("ok");

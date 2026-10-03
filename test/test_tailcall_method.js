// A tail call through a method (`return o.m(x)`) reuses the caller's frame:
// the receiver becomes the callee's `this`, string arguments change hands, and
// the registers the caller owned are released.
function check(label, got, want) {
    if (got !== want) throw new Error(label + ": got " + String(got) + ", want " + String(want));
}
function churn() { var a = []; for (var i = 0; i < 3000; i++) a.push({ i: i, s: "k" + i }); return a.length; }

var o = { v: 10, add(x) { return this.v + x; }, id(x) { return x; }, noThis(x) { return x + 1; } };
var viaAdd = (x) => o.add(x);
var viaNoThis = (x) => o.noThis(x);
check("this", viaAdd(1), 11);
check("this repeated", viaAdd(2) + viaAdd(3), 25);
check("ignores this", viaNoThis(1), 2);

// String arguments built at run time are owned by the caller's registers.
function viaStr(a, b) { var t = a + b; return o.id(t + "!"); }
check("string arg", viaStr("ab", "cd"), "abcd!");
for (var i = 0; i < 2000; i++) viaStr("x" + i, "y");
check("string arg after loop", viaStr("p", "q"), "pq!");
function strs(n) { var parts = []; for (var i = 0; i < n; i++) parts.push("s" + i); return o.id(parts.join()); }
check("joined", strs(4), "s0,s1,s2,s3");
function manyArgs(a, b, c) { var x = a + "1", y = b + "2"; return o.sum3(x, y, c + "3"); }
o.sum3 = function (a, b, c) { return a + b + c; };
check("three string args", manyArgs("a", "b", "c"), "a1b2c3");
for (var i = 0; i < 2000; i++) manyArgs("m" + i, "n", "o");
churn();
check("three after churn", manyArgs("a", "b", "c"), "a1b2c3");

// The caller's own temporaries are released, not leaked into the callee.
function temps(n) {
    var s1 = "t" + n, s2 = "u" + n, s3 = "v" + n;
    return o.id(s1.length + s2.length + s3.length);
}
check("temps", temps(5), 6);
for (var i = 0; i < 3000; i++) temps(i);
check("temps after loop", temps(1), 6);

// A receiver only the caller's register held stays alive in the callee.
function fresh() { return ({ v: 5, get() { churn(); return this.v; } }).get(); }
check("fresh receiver", fresh(), 5);
function freshArg(x) { return { v: x, get(y) { churn(); return this.v + y; } }.get(1); }
check("fresh receiver with arg", freshArg(4), 5);

// The callee is a closure only the caller's register referenced.
function freshCallee(x) {
    var holder = { make() { return function (y) { churn(); return y + 1; }; } };
    return holder.make().call(null, x);
}
check("fresh callee", freshCallee(1), 2);
var holder = { f: null };
function makeAndCall(x) { holder.f = function (y) { churn(); return this === holder ? y * 2 : -1; }; return holder.f(x); }
check("rooted by frame", makeAndCall(4), 8);

// Receivers that are not objects.
check("number receiver", ((x) => (5).toString(x))(2), "101");
check("string receiver", ((x) => "abc".charAt(x))(1), "b");
check("undefined receiver", ((x) => { var u; return Array.prototype.slice.call(u === undefined ? [1, 2, 3] : u, x).length; })(1), 2);
var strict = { f(x) { "use strict"; return this === strictObj ? x : -1; } };
var strictObj = strict;
check("strict this", ((x) => strict.f(x))(3), 3);
var sloppyRecv = { f(x) { return typeof this; } };
check("sloppy this", ((x) => sloppyRecv.f(x))(1), "object");
check("primitive this boxed", ((x) => { var f = function () { return typeof this; }; f.call(1); return f.call.call(f, x); })(1), "object");

// Getters and accessors as the callee expression.
var acc = { get f() { return function (x) { return x * 3; }; } };
check("getter callee", ((x) => acc.f(x))(2), 6);

// Deep recursion through a method stays in constant stack.
var rec = { down(n) { return n === 0 ? "done" : this.down(n - 1); } };
check("deep method recursion", rec.down(200000), "done");
var mutual = { even(n) { return n === 0 ? true : this.odd(n - 1); }, odd(n) { return n === 0 ? false : this.even(n - 1); } };
check("mutual recursion", mutual.even(100001), false);

// Results, exceptions and callbacks through the reused frame.
check("returns undefined", ((x) => ({ f() {} }).f(x))(1), undefined);
var thrower = { f(x) { throw new Error("boom" + x); } };
var caught;
try { ((x) => thrower.f(x))(7); } catch (e) { caught = e.message; }
check("throw through tail call", caught, "boom7");
check("callback", [1, 2, 3].map((x) => o.add(x)).join(), "11,12,13");
function outer(x) { try { return o.add(x); } finally { churn(); } }
check("finally", outer(1), 11);
function withCatch(x) { try { return o.add(x); } catch (e) { return -1; } }
check("catch frame", withCatch(2), 12);
print("ok");

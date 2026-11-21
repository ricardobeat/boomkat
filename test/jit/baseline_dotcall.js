// f.call(t, args...) sites that baseline code enters as the method call of f on t
// (Asm.emit_dotcall), and the value of a trivial callee computed at the site. Each site is warmed
// up, then given what must leave that path: another callee, a replaced Function.prototype.call,
// receivers of every kind, fewer and more arguments, a throw. Then apply, whose argument list stays
// on the C stack up to 16 values and takes the heap past them.
var out = [];
function log(x) { out.push(String(x)); }
function err(f) { try { return "ok " + f(); } catch (e) { return e.constructor.name; } }

function g3(a, b, c) { return a + b * c; }
function gm(a) { return this.x + a; }
function first(a, b) { return a; }
function third(a, b, c) { return c; }
function nothing() {}
function sum2(a, b) { return a + b; }
function strictThis() { "use strict"; return this === undefined ? "undef" : typeof this; }
function sloppyThis() { return this === globalThis ? "global" : typeof this; }
function many(a, b, c, d, e, f, g, h, i, j) { return [a, b, c, d, e, f, g, h, i, j].join(","); }
function args() { return arguments.length + ":" + Array.prototype.join.call(arguments, "/"); }

var o = { x: 10 }, p = { x: 100 };
function dot(i) {
    return g3.call(null, i, 2, 3) + gm.call(o, i) + first.call(o, i, 7) + (third.call(null, i, i) === undefined ? 1 : 0)
        + (nothing.call(o, i) === undefined ? 1 : 0) + sum2.call(null, i, 1);
}
var s = 0;
for (var i = 0; i < 3000; i++) s += dot(i);
log(s);

// Receivers: primitives, null and undefined, for strict and sloppy callees.
function recv(t) { return strictThis.call(t) + "/" + sloppyThis.call(t); }
var rs = "";
for (var i = 0; i < 400; i++) rs = recv(o) + " " + recv(null) + " " + recv(undefined) + " " + recv(5) + " " + recv("s");
log(rs);
function method(t, a) { return gm.call(t, a); }
for (var i = 0; i < 400; i++) method(o, i);
log(method(p, 1) + " " + method({ x: "s" }, 2) + " " + err(() => method(null, 3)) + " " + method(5, 4));

// Fewer and more arguments, many arguments, an arguments object, no arguments at all.
function counts(i) { return many.call(null, i, 2, 3) + "|" + args.call(null, i, 2, 3, 4) + "|" + first.call(null) + "|" + third.call(null, 1, 2, 3, 4, 5); }
var cs;
for (var i = 0; i < 400; i++) cs = counts(i);
log(cs);
function zero(f) { return f.call(); }
for (var i = 0; i < 400; i++) zero(nothing);
log(zero(sloppyThis) + " " + zero(strictThis));

// The callee changes after warm-up: another compiled function, a builtin, a bound function, an
// arrow, a class, a function that throws, a non-function.
function site(f, i) { return f.call(o, i, 1); }
for (var i = 0; i < 400; i++) site(gm, i);
log(site(gm, 1) + " " + site(sum2, 1) + " " + site(Math.max, 5) + " " + site(gm.bind(p), 2) + " " + site((a) => a * 2, 4));
log(err(() => site(class K {}, 1)) + " | " + err(() => site(function () { throw new RangeError("inside"); }, 1)));
log(err(() => site({ call: Function.prototype.call }, 1)) + " | " + err(() => site(Object.create(gm), 1)));
function tsite(f, i) { return f.call(null, i); }
for (var i = 0; i < 400; i++) tsite(first, i);
log(tsite(first, 9) + " " + tsite(nothing, 9) + " " + tsite(third, 9) + " " + tsite(g3, 9) + " " + tsite(String, 9));

// Function.prototype.call replaced, then shadowed on the function, then restored.
var realCall = Function.prototype.call;
Function.prototype.call = function (t, a) { return "replaced " + a; };
log(dot(1) + " " + site(gm, 3));
Function.prototype.call = realCall;
gm.call = function () { return "own"; };
log(site(gm, 3));
delete gm.call;
log(site(gm, 3) + " " + dot(2));

// Recursion through call, and allocation while it runs.
function fact(n) { return n <= 1 ? 1 : n * fact.call(null, n - 1); }
function build(n) { var a = []; for (var k = 0; k < n; k++) a.push({ k: k }); return a.length; }
var r = 0;
for (var i = 0; i < 2000; i++) r += fact.call(null, 10) % 1000 + build.call(null, 8);
log(r);

// apply: arrays short and long, holes, array-likes with getters, an arguments object, a throw,
// null and undefined lists, Reflect.apply, a builtin target.
function ap(f, t, list) { return f.apply(t, list); }
var big = [];
for (var i = 0; i < 40; i++) big.push(i);
var holes = [1, , 3];
var like = { length: 3, get 0() { return "a"; }, 1: "b", get 2() { return "c"; } };
var throwing = { length: 2, get 1() { throw new TypeError("getter"); } };
function fwd() { return ap(args, null, arguments); }
var as = "";
for (var i = 0; i < 400; i++) {
    as = ap(g3, null, [i, 2, 3]) + " " + ap(gm, o, [i]) + " " + ap(args, null, big).length + " " + ap(args, null, holes)
        + " " + ap(args, null, like) + " " + fwd(1, 2) + " " + ap(args, null, null) + " " + ap(args, null, undefined)
        + " " + Math.max.apply(null, big) + " " + Reflect.apply(sum2, null, [i, 1]) + " " + String.fromCharCode.apply(null, [104, 105]);
}
log(as);
log(err(() => ap(args, null, throwing)) + " | " + err(() => ap(args, null, 5)));
Array.prototype[1] = "proto";
log(ap(args, null, holes));
delete Array.prototype[1];

print(out.join("\n"));

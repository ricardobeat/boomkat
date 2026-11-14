// Global bindings holding functions and objects, which optimized code folds under a watch: every
// way of rebinding one takes effect at the next use, including from a callee while the folded
// code is on the stack. Each case has a binding and a loop of its own: a watch that fired leaves
// its binding unfolded for good.
function one() { return 1; }
function two() { return 2; }
function three() { return 3; }
var log = [];
function check(name, got, want) { if (got !== want) log.push(name + ": " + got + " != " + want); }
function warm(fn) { for (var k = 0; k < 40; k++) fn(200, -1, null); }
var f_store = one;
function sum_store(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); s += f_store(i); } return s; }
var f_eval = one;
function sum_eval(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); s += f_eval(i); } return s; }
var f_ieval = one;
function sum_ieval(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); s += f_ieval(i); } return s; }
var f_globalthis = one;
function sum_globalthis(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); s += f_globalthis(i); } return s; }
var f_reflect = one;
function sum_reflect(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); s += f_reflect(i); } return s; }
var f_define = one;
function sum_define(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); s += f_define(i); } return s; }
var f_hot = one;
function sum_hot(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); s += f_hot(i); } return s; }
function rebindHot(fn) { f_hot = fn; }
for (var k = 0; k < 3000; k++) rebindHot(k & 1 ? three : one);
f_hot = one;
warm(sum_store);
check('store', sum_store(4000, 2000, function () { f_store = two; }), 2000 + 4000);
warm(sum_eval);
check('eval', sum_eval(4000, 2000, function () { eval("f_eval = two"); }), 2000 + 4000);
warm(sum_ieval);
check('ieval', sum_ieval(4000, 2000, function () { (0, eval)("f_ieval = two"); }), 2000 + 4000);
warm(sum_globalthis);
check('globalthis', sum_globalthis(4000, 2000, function () { globalThis.f_globalthis = two; }), 2000 + 4000);
warm(sum_reflect);
check('reflect', sum_reflect(4000, 2000, function () { Reflect.set(globalThis, "f_reflect", two); }), 2000 + 4000);
warm(sum_define);
check('define', sum_define(4000, 2000, function () { Object.defineProperty(globalThis, "f_define", { value: two }); }), 2000 + 4000);
warm(sum_hot);
check('hot', sum_hot(4000, 2000, function () { rebindHot(two); }), 2000 + 4000);

// f++ on a function makes NaN, which the next call throws on.
var f_inc = one;
function sum_inc(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); s += f_inc(i); } return s; }
warm(sum_inc);
var r;
try { r = sum_inc(4000, 2000, function () { f_inc++; }); } catch (e) { r = e.constructor.name; }
check("increment", r, "TypeError");

// An object-valued global, rebound, and a field of the object it holds stored to.
var obj = { v: 10 };
var obj2 = { v: 10 };
var other = { v: 20 };
function field(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); s += obj.v; } return s; }
function field2(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); s += obj2.v; } return s; }
warm(field);
check("object", field(4000, 2000, function () { obj = other; }), 2000 * 10 + 2000 * 20);
warm(field2);
check("object field", field2(4000, 2000, function () { obj2.v = 30; }), 2000 * 10 + 2000 * 30);

// Configurable globals, made by assignments that declare nothing: deleted, made an accessor,
// redefined, and one after a deleted one, whose slot moves.
function useG(name) {
  return function (n, at, act) {
    var s = 0;
    for (var i = 0; i < n; i++) {
      if (i === at) act();
      try { s += globalThis[name](); } catch (e) { s += 100; }
    }
    return s;
  };
}
globalThis.g_del = one;
function del(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); try { s += g_del(); } catch (e) { s += 100; } } return s; }
warm(del);
check("delete", del(4000, 2000, function () { delete globalThis.g_del; }), 2000 + 2000 * 100);
globalThis.g_acc = one;
function acc(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); s += g_acc(); } return s; }
warm(acc);
check("accessor", acc(4000, 2000, function () { Object.defineProperty(globalThis, "g_acc", { get: function () { return three; }, configurable: true }); }), 2000 + 2000 * 3);
globalThis.g_redef = one;
function redef(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); s += g_redef(); } return s; }
warm(redef);
check("redefine", redef(4000, 2000, function () { Object.defineProperty(globalThis, "g_redef", { value: two }); }), 2000 + 2000 * 2);
globalThis.g_before = 1;
globalThis.g_after = one;
function after(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); s += g_after(); } return s; }
warm(after);
check("delete before", after(4000, 2000, function () { delete globalThis.g_before; }), 4000);
check("store after delete", after(4000, 2000, function () { g_after = two; }), 2000 + 4000);

// let and const: the temporal dead zone, and a let rebound.
function lexical(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); try { s += lf(); } catch (e) { s += 100; } } return s; }
warm(lexical);
check("tdz", lexical(10, -1, null), 1000);
let lf = one;
warm(lexical);
check("let", lexical(4000, 2000, function () { lf = two; }), 2000 + 4000);
const cf = three;
function constant(n) { var s = 0; for (var i = 0; i < n; i++) s += cf(); return s; }
for (var k = 0; k < 40; k++) constant(200);
check("const", constant(4000), 12000);

print(log.length === 0 ? "global_watch ok" : "global_watch FAIL\n" + log.join("\n"));

// Regression test for two spread arguments in one call.
// The first spread writes real argument values into registers at/above
// first_arg at runtime, so a second spread's source expression must be
// compiled into the reserved below-first_arg evaluation region; evaluating
// it with the normal allocator landed on an already-written argument slot
// and destroyed it (src/compiler/regalloc.c3: compile_spread_source).
// Before the fix, `f(...a, ...a)` with a=[1,2] passed 4 args as
// [1, <array>, 1, 2] instead of [1, 2, 1, 2].

var pass = 0, fail = 0;

function assert(cond, msg) {
  if (cond) { pass++; }
  else { fail++; print("FAIL: " + msg); }
}

function eq(actual, expected, msg) {
  assert(actual === expected, msg + " (expected " + expected + ", got " + actual + ")");
}

function collect() {
  var r = "";
  for (var i = 0; i < arguments.length; i++) { r += arguments[i] + ","; }
  return r;
}

var a = [1, 2];
var b = [3, 4, 5];
var big = [];
for (var i = 0; i < 30; i++) { big.push(i); }

// ── Two spreads, same array ───────────────────────────────────────────────
eq(collect(...a, ...a), "1,2,1,2,", "double spread, same array");

// ── Different sizes ───────────────────────────────────────────────────────
eq(collect(...b, ...a), "3,4,5,1,2,", "double spread, big then small");
eq(collect(...a, ...b), "1,2,3,4,5,", "double spread, small then big");

// ── Big arrays: runtime window larger than the compile-time overlap band ──
eq(collect(...big, ...big), collect(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29), "double spread, 30-element arrays");

// ── Plain args around spreads ─────────────────────────────────────────────
eq(collect(9, 8, ...a), "9,8,1,2,", "plain args before first spread");
eq(collect(...a, 7, ...b), "1,2,7,3,4,5,", "plain arg between spreads");
eq(collect(...a, ...b, 6), "1,2,3,4,5,6,", "trailing arg after spreads");

// ── Spread of call results ────────────────────────────────────────────────
function mk() { return [9, 9]; }
eq(collect(...mk(), ...mk()), "9,9,9,9,", "spread of call results, twice");

// ── Three spreads ─────────────────────────────────────────────────────────
eq(collect(...a, ...a, ...b), "1,2,1,2,3,4,5,", "three spreads");

// ── Numeric result ────────────────────────────────────────────────────────
function sum() { var r = 0; for (var i = 0; i < arguments.length; i++) { r += arguments[i]; } return r; }
eq(sum(...a, ...a), 6, "double spread sum");
eq(sum(...big, ...big), 870, "double spread big sum");

// ── new with double spread ────────────────────────────────────────────────
function C() { this.vals = collect.apply(null, arguments); }
eq(new C(...a, ...a).vals, "1,2,1,2,", "new with double spread");

// ── Method call with double spread ────────────────────────────────────────
var obj = { m: function() { return collect.apply(null, arguments); } };
eq(obj.m(...a, ...a), "1,2,1,2,", "method call with double spread");

// ── Evaluation order: sources run left to right, before the call ──────────
var order = [];
function tagged(t) { return function() { order.push(t); return [1]; }; }
var g1 = tagged("g1"), g2 = tagged("g2");
collect(...g1(), ...g2());
eq(order.join(""), "g1g2", "spread sources evaluate in order");

// ── Spread of a complex expression ────────────────────────────────────────
eq(collect(...(a.concat(b)), ...a), "1,2,3,4,5,1,2,", "spread of concat result");
eq(collect(...a, ...(b.concat(a))), "1,2,3,4,5,1,2,", "spread of concat result, second");

// ── Function-local spread call: register window below the locals ──────────
function localCall() {
  var x = 100, y = 200;
  var r = collect(...a, ...b);
  return x + ":" + y + ":" + r;
}
eq(localCall(), "100:200:1,2,3,4,5,", "function-local double spread keeps locals");

print('codegen_double_spread: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }

// Regression coverage for two `var` hoisting bugs, both silent wrong answers
// in completely ordinary code.
//
// BUG 1 — an arrow's block ConciseBody never ran the hoisting pass at all.
// compile_arrow_inner (and compile_arrow_inner_reparse) went straight from the
// parameter list to statement compilation, so a `var` in an unreached branch
// produced NO binding rather than an `undefined` one:
//   (() => { if (false) { var x = 1; } return x; })()
//     → ReferenceError "x is not defined", not undefined
// A block ConciseBody is a FunctionBody, so its VarDeclaredNames hoist exactly
// like an ordinary function's. The equivalent `function` form was already
// correct, which is what makes this specific to the arrow forms.
//
// The same absence made an arrow-body `var` fail to SHADOW an outer binding of
// the same name: with no hoisted slot, the read resolved outward and returned
// the enclosing value instead of undefined. That direction is nastier than the
// throw, because it returns a plausible wrong answer silently.
//
// BUG 2 — the hoist re-initialized a name that is already a PARAMETER.
// hoist_one_var_name called declare_var unconditionally, which allocates a
// FRESH register and emits LDUNDEF into it, so the argument value was lost:
//   function f(p){ if (false) { var p = 1; } return p; }   →  undefined, not 1
// Per ES2015 §9.2.10 step 27 only var names ABSENT from parameterNames get the
// `undefined` initialization. This one predates the arrow work and affected
// ordinary functions too; it is covered here for both forms because fixing
// bug 1 is what first exposed it in arrows.
//
// WHAT MAKES THIS FRAGILE (read before simplifying anything below):
//
// Every case must read the `var` from inside the arrow/function that declares
// it. At global scope a `var` is env-resident and the read goes through
// GETVAR, which finds the binding whether or not the hoist ran — so a
// top-level version of any case below passes on a broken compiler.
//
// The unexecuted-branch shape is also load-bearing. If the declaration's
// statement actually runs, var_declaration declares the name as it parses and
// the missing hoist is masked entirely; only a branch that never executes (or
// a read that happens before it) can observe the absence.
//
// Runs unmodified under node with identical counts.

"use strict";

var pass = 0, fail = 0;

function assert(cond, msg) {
  if (cond) { pass++; }
  else { fail++; print("FAIL: " + msg); }
}

function eq(actual, expected, msg) {
  assert(actual === expected, msg + " (expected " + expected + ", got " + actual + ")");
}

// ── Bug 1: an unexecuted `var` in an arrow body reads undefined ──────────
eq((() => { if (false) { var x = 1; } return x; })(), undefined,
   "var in an unreached if");
eq((() => { for (var i = 0; i < 0; i++) { var x = 1; } return x; })(), undefined,
   "var in a zero-iteration for body");
eq((() => { while (false) { var x = 1; } return x; })(), undefined,
   "var in a never-entered while");
eq((() => { do { var x = 1; } while (false); return x; })(), 1,
   "var in a do-while that runs once");
eq((() => { switch (0) { case 1: var x = 1; } return x; })(), undefined,
   "var in an unmatched switch case");
eq((() => { L: { break L; var x = 1; } return x; })(), undefined,
   "var after a break out of a labelled block");
eq((() => { return x; var x = 1; })(), undefined,
   "var textually after the return that reads it");
eq((() => { try { throw 0; } catch (e) { var x = 4; } return x; })(), 4,
   "var in a catch block that runs");
eq((() => { for (var k in {}) { var x = 1; } return x; })(), undefined,
   "var in a zero-iteration for-in body");
eq((() => { for (var v of []) { var x = 1; } return x; })(), undefined,
   "var in a zero-iteration for-of body");
eq((() => { { { var x = 2; } } return x; })(), 2,
   "var in a nested block reaches the arrow's own scope");

// ── Bug 1: binding-pattern declarators hoist too ─────────────────────────
eq((() => { if (false) { var [x] = [1]; } return x; })(), undefined,
   "array-pattern var in an unreached branch");
eq((() => { if (false) { var { p: x } = { p: 1 }; } return x; })(), undefined,
   "object-pattern var in an unreached branch");
eq((() => { var [x] = [5]; return x; })(), 5,
   "array-pattern var that actually runs");
eq((() => { var { p: x } = { p: 6 }; return x; })(), 6,
   "object-pattern var that actually runs");
eq((() => { if (false) { var [a, [b]] = [1, [2]]; } return typeof a + typeof b; })(),
   "undefinedundefined", "nested array-pattern var hoists every leaf");

// ── Bug 1: the shadowing direction (a wrong VALUE, not a throw) ──────────
var outerName = "outer";
eq((() => { if (false) { var outerName = 1; } return outerName; })(), undefined,
   "arrow-body var shadows an outer var of the same name");
function shadowsEnclosingLocal() {
  var n = "enclosing";
  return (() => { if (false) { var n = 1; } return n; })() + "|" + n;
}
eq(shadowsEnclosingLocal(), "undefined|enclosing",
   "arrow-body var shadows an enclosing FUNCTION local and leaves it intact");

// ── Bug 1: the arrow's var must not LEAK outward ─────────────────────────
function noLeakFromArrow() {
  (() => { if (false) { var leaked = 1; } })();
  return typeof leaked;
}
eq(noLeakFromArrow(), "undefined", "arrow-body var does not leak to the enclosing function");
(() => { if (false) { var siblingLeak = 1; } })();
eq((() => typeof siblingLeak)(), "undefined", "arrow-body var does not leak to a sibling arrow");

// ── Bug 1: across every arrow form ──────────────────────────────────────
eq((p => { if (false) { var x = 1; } return x; })(1), undefined,
   "single-identifier-parameter arrow");
eq(((...r) => { if (false) { var x = 1; } return x; })(1), undefined,
   "rest-parameter arrow");
eq(((a = 1, b = 2) => { if (false) { var x = 1; } return x; })(), undefined,
   "arrow with parameter defaults (the separate body var scope)");
eq((({ q }) => { if (false) { var x = 1; } return x; })({ q: 1 }), undefined,
   "destructured-parameter arrow");
var asMethod = { m: () => { if (false) { var x = 1; } return x; } };
eq(asMethod.m(), undefined, "arrow used as a method value");
class WithField {
  f = () => { if (false) { var x = 1; } return x; };
}
eq(new WithField().f(), undefined, "arrow in a class field initializer");
function arrowInsideFunction() {
  return (() => { if (false) { var x = 1; } return x; })();
}
eq(arrowInsideFunction(), undefined, "arrow nested in an ordinary function");
eq((() => (() => { if (false) { var x = 1; } return x; })())(), undefined,
   "arrow nested in an arrow");
eq((() => ((() => { if (false) { var x = 1; } return x; })()))(), undefined,
   "expression-bodied arrow wrapping a block-bodied one");

// ── Bug 1: hoisted function declarations inside an arrow body ───────────
eq((() => { return h(); function h() { return "H"; } })(), "H",
   "function declaration hoists to the top of an arrow body");
eq((() => { if (false) { var x = 1; } function g() { var x = 9; return x; } return typeof x + ":" + g(); })(),
   "undefined:9", "a nested function's own var does not disturb the arrow's");
eq((() => { var inner = () => { var y = 1; return y; }; if (false) { var x = 2; } return typeof x + ":" + inner(); })(),
   "undefined:1", "a nested arrow's var does not disturb the enclosing arrow's");

// ── Bug 2: a `var` that renames a parameter keeps the ARGUMENT ──────────
eq((p => { if (false) { var p = 1; } return p; })(7), 7,
   "arrow: unexecuted var over a parameter name keeps the argument");
eq(((p, q) => { if (false) { var q = 1; } return p + ":" + q; })(1, 2), "1:2",
   "arrow: only the named parameter is considered, and it is untouched");
function fnParamShadow(p) { if (false) { var p = 1; } return p; }
eq(fnParamShadow(7), 7,
   "function: unexecuted var over a parameter name keeps the argument");
eq((p => { var p = 3; return p; })(7), 3,
   "arrow: a var over a parameter WITH an initializer still assigns");
function fnParamAssign(p) { var p = 3; return p; }
eq(fnParamAssign(7), 3,
   "function: a var over a parameter WITH an initializer still assigns");
eq(((p = 5) => { if (false) { var p = 1; } return p; })(), 5,
   "arrow: a defaulted parameter's value survives an unexecuted var");
eq((({ p }) => { if (false) { var p = 1; } return p; })({ p: 8 }), 8,
   "arrow: a destructured parameter's value survives an unexecuted var");

// ── `arguments` and `this` are unaffected by the new pass ───────────────
function argumentsFromArrow() {
  return (() => { if (false) { var x = 1; } return arguments[0]; })();
}
eq(argumentsFromArrow(42), 42,
   "`arguments` in an arrow still resolves to the enclosing function's");
function argumentsFromNestedArrow() {
  return (() => (() => { if (false) { var x = 1; } return arguments.length; })())();
}
eq(argumentsFromNestedArrow(1, 2, 3), 3,
   "`arguments` resolves through two arrow levels to the enclosing function's");
var thisHolder = {
  v: "V",
  m() { return (() => { if (false) { var x = 1; } return this.v; })(); }
};
eq(thisHolder.m(), "V", "`this` in an arrow is still lexical");

// ── async arrows take the same body path ────────────────────────────────
var asyncResults = [];
var asyncChecks = [
  [async () => { if (false) { var x = 1; } return x; }, undefined,
   "async arrow: var in an unreached branch"],
  [async (p) => { if (false) { var p = 1; } return p; }, 7,
   "async arrow: unexecuted var over a parameter keeps the argument"],
  [async () => { if (false) { var [x] = [1]; } return x; }, undefined,
   "async arrow: array-pattern var in an unreached branch"]
];

Promise.all(asyncChecks.map(function (c) {
  return c[0](7).then(function (v) { eq(v, c[1], c[2]); });
})).then(function () {
  print('codegen_arrow_var_hoisting: ' + pass + ' passed, ' + fail + ' failed');
  if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
}, function (e) {
  print('codegen_arrow_var_hoisting: async section threw: ' + e);
  print('SOME TESTS FAILED');
  throw new Error('FAIL');
});

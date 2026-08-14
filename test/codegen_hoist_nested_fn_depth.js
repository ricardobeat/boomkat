// Regression coverage for hoist_decls walking into a nested function body
// when that function sits deeper than the scan's own top level.
//
// hoist_decls skips a nested `function`'s body wholesale so its `var`s stay in
// their own VarDeclaredNames scope. That skip existed in two places: one for a
// function at the scan's own brace depth (own_depth), and one for a function
// deeper than that. The deeper one was gated on `is_global`, so it only ran
// for the Program's scan. A function-body scan hit no handler at all and let
// the loop wander into the inner body brace-by-brace, hoisting every `var` it
// found into the function being scanned.
//
// WHAT MAKES THIS OBSERVABLE (read before simplifying anything below):
//
// A bogus hoist only shows up when the mis-hoisted name collides with a name
// the enclosing function otherwise reads from an OUTER scope. The hoist emits
// LDUNDEF + DECLVAR_HOIST for it, creating a local binding initialised to
// undefined that shadows the outer one for the whole body. So each case needs
// three levels: an outer function owning the real binding (as a parameter or
// var), a middle function that reads it, and — nested inside the middle at
// brace depth > 1 — a function literal declaring `var <same name>`.
//
// Also load-bearing: the inner function literal must be at brace depth 2 or
// more relative to the middle function's body. At depth 1 the own_depth
// handler already skipped it correctly, which is why `f(function(){ var t })`
// passed while `f({ a: function(){ var t } })` did not — the object literal's
// brace is what pushed it out of reach.
//
// Real-world impact: babel 7.24.7 bundles the `regenerate` module as a UMD
// wrapper `!function(e,t){ ... }(vV, vV.exports)` whose body assigns
// `n.exports = W` through the captured `e`/`t` pair. An inner
// `!function(e,t){...}(G, { add: function(e){ var t = this; ... }, ... })`
// mis-hoisted `t` (and, via other properties, `e`) into the enclosing scope,
// so the export assignment ran against undefined and `vV.exports` stayed the
// empty object it was initialised to. `regenerate()` was then called as a
// plain object: "object is not a function".
//
// All expectations below were checked against node.

var pass = 0, fail = 0;

function assert(cond, msg) {
  if (cond) { pass++; }
  else { fail++; print("FAIL: " + msg); }
}

function eq(actual, expected, msg) {
  assert(actual === expected, msg + " (expected " + expected + ", got " + actual + ")");
}

function sink() { return 0; }

// ── Object literal in argument position ──────────────────────────────────
// The literal's `{` puts the function property at brace depth 2.
function objArgOuter(t) {
  function mid() {
    sink({ a: function () { var t; } });
    return t;
  }
  return mid();
}
eq(objArgOuter(5), 5, "object literal in an argument list does not leak its method's var");

// ── Function expression inside a nested block ────────────────────────────
function blockOuter(t) {
  function mid() {
    if (true) { sink(function () { var t; }); }
    return t;
  }
  return mid();
}
eq(blockOuter("v"), "v", "a block-nested function expression does not leak its var");

// ── Depth 1 kept working (the own_depth handler already covered it) ──────
function shallowOuter(t) {
  function mid() {
    sink(function () { var t; });
    return t;
  }
  return mid();
}
eq(shallowOuter(7), 7, "a function expression at the scan's own depth still does not leak");

// ── The outer binding may be a var rather than a parameter ───────────────
function varOuter() {
  var t = "outer";
  function mid() {
    sink({ m: function () { var t; } });
    return t;
  }
  return mid();
}
eq(varOuter(), "outer", "a mis-hoist shadows an outer var binding too");

// ── Two names at once, the babel shape ───────────────────────────────────
// Both `e` and `t` are read by the middle function and both are declared by
// nested properties, which is what made the whole module's export assignment
// silently write to the wrong object.
function umdOuter(e, t) {
  function mid() {
    sink({
      add: function (e) { var t = this; return t; },
      clone: function () { var e = 1; return e; }
    });
    return typeof e + "/" + typeof t;
  }
  return mid();
}
eq(umdOuter({}, {}), "object/object", "neither name of a two-name collision leaks");

// ── The inner function's own var still works ─────────────────────────────
function innerStillOwns(t) {
  function mid() {
    var got;
    sink({ a: function () { var t = "inner"; got = t; return t; } });
    return { outer: t, inner: got };
  }
  var r = mid();
  return r;
}
var r1 = innerStillOwns("outer");
eq(r1.outer, "outer", "the enclosing binding is untouched");
eq(r1.inner, undefined, "the inner function has not run yet");

function innerRuns(t) {
  function mid() {
    var box = { a: function () { var t = "inner"; return t; } };
    return box.a() + "/" + t;
  }
  return mid();
}
eq(innerRuns("outer"), "inner/outer", "the inner function's own var binding is its own");

// ── A block-scoped function declaration is still lexical, not hoisted ────
// The deeper-skip now also covers `function` DECLARATIONS below own_depth.
// In strict mode those are lexically bound to their block, so skipping them in
// the var pre-scan must not change what the enclosing scope sees.
function blockFnDecl() {
  var seen;
  if (true) {
    function g() { return "g"; }
    seen = typeof g;
  }
  return seen + "/" + typeof g;
}
eq(blockFnDecl(), "function/undefined", "a block-scoped function declaration stays lexical");

// ── A real var in the scanned body is still hoisted ──────────────────────
// The skip must not swallow the enclosing scope's own declarations.
function stillHoists() {
  var before = typeof own;
  sink({ a: function () { var own; } });
  var own = 1;
  return before + "/" + own;
}
eq(stillHoists(), "undefined/1", "the scanned function's own var is still hoisted");

// ── Nested deeper than two levels ────────────────────────────────────────
function deepOuter(t) {
  function mid() {
    if (true) { while (false) { sink([{ a: function () { var t; } }]); } }
    return t;
  }
  return mid();
}
eq(deepOuter(3), 3, "a function literal several braces deep does not leak");

print('codegen_hoist_nested_fn_depth: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }

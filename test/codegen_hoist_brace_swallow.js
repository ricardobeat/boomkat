// Direct regression coverage for the hoist brace-swallow bug fixed in
// b0fdc49c (commit 907921a5, bug 1).
//
// hoist_decls' `var` declarator loop consumed the token after a bare final
// declarator without pushing it back when it was not a comma. For an
// unterminated `var` after a return (`function f(){ return x; var t }`) that
// token IS the body's closing brace, so brace_depth never returned to 0 and
// the pre-scan ran on past the end of the function — hoisting the NEXT
// function declaration into this one as a local.
//
// Before this file the only coverage was incidental behaviour of the
// third-party minified bundle in test/modules/t11_colord. That bundle could be
// updated at any time, silently removing the coverage.
//
// WHAT MAKES THIS FRAGILE (read before simplifying anything below):
//
// The mis-hoist is usually INVISIBLE. The swallowed sibling is still declared
// as a global too, and the bogus local closure is created at the top of the
// body before any call, so `c()` calling the swallowed `h()` returns the right
// answer by accident. The nesting shows up in the disassembly (the sibling is
// compiled as "Inner function 0.0" instead of a flat "Inner function 1") but
// not in the result.
//
// To make it observable, the swallowed function's binding must be REASSIGNED
// after declaration. The caller then has a stale local shadowing the global:
// pre-fix it calls the original ("v1"), post-fix it sees the reassignment
// ("v2"), which is what node does. That reassignment is load-bearing — drop it
// and this test passes on a broken compiler.
//
// Equally load-bearing: the `var` must be the LAST thing in the body, bare
// (no initializer) and unterminated (no semicolon before `}`), and the
// function it swallows must be the very next declaration.
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

// ── Bare final `var` after a return ──────────────────────────────────────
// Pre-fix: `h` is hoisted into c as a local, so c calls the ORIGINAL h ("v1").
function c1() { return h(1); var t }
function h(x) { return "v1:" + x; }
h = function (x) { return "v2:" + x; };
eq(c1(), "v2:1", "bare final var after return does not swallow the next function");

// ── The same, with the return nested inside a block ──────────────────────
function c2() { if (1) { return k(2); } var q }
function k(x) { return "k1:" + x; }
k = function (x) { return "k2:" + x; };
eq(c2(), "k2:2", "bare final var after a nested return does not swallow");

// ── Multiple declarators, last one bare ──────────────────────────────────
function c3() { return m(3); var a = 1, b, cc }
function m(x) { return "m1:" + x; }
m = function (x) { return "m2:" + x; };
eq(c3(), "m2:3", "multiple declarators with a bare last one do not swallow");

// ── Bare final var after throw ───────────────────────────────────────────
function c4() {
  try { throw new Error("x"); } catch (e) { return p(4); }
  var z
}
function p(x) { return "p1:" + x; }
p = function (x) { return "p2:" + x; };
eq(c4(), "p2:4", "bare final var after throw/catch does not swallow");

// ── Bare final var after break, inside a loop ────────────────────────────
function c5() {
  for (var i = 0; i < 1; i++) { break; }
  return q(5);
  var y
}
function q(x) { return "q1:" + x; }
q = function (x) { return "q2:" + x; };
eq(c5(), "q2:5", "bare final var after break does not swallow");

// ── The swallowed sibling's own locals must not leak into the caller ─────
// Pre-fix the pre-scan hoisted the sibling's declarations too. `leaked` is
// declared only inside sib, so it must be undeclared (a ReferenceError on
// read) from inside caller.
function caller() {
  var sawError = false;
  try { void leaked; } catch (e) { sawError = e instanceof ReferenceError; }
  return sawError;
  var t2
}
function sib() { var leaked = 99; return leaked; }
eq(caller(), true, "sibling's locals are not hoisted into the preceding function");
eq(sib(), 99, "swallowed sibling still works on its own");

// ── The sibling must remain a real global, not a nested local ────────────
function c6() { return 6; var w }
function stillGlobal() { return "global"; }
eq(typeof stillGlobal, "function", "swallowed sibling is still globally visible");
eq(stillGlobal(), "global", "swallowed sibling is callable from outer scope");
eq(c6(), 6, "the swallowing function itself still returns correctly");

print('codegen_hoist_brace_swallow: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }

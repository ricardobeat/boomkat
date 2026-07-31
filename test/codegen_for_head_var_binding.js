// Regression coverage for two `var` binding-lifetime bugs in for-in/for-of
// heads, both silent wrong answers in completely ordinary code.
//
// BUG 1 — the head allocated a SECOND register for a `var` name.
// `declare_var` unconditionally allocates. A `var` head's name is already
// hoisted to the enclosing function scope, so the head wrote its value into a
// fresh register while every read outside the loop used the hoisted one; the
// head's own scope entry was then dropped at the loop epilogue's pop_scope_to.
//   function f(){ for (var v in {z:1}) {} return v; }   →  undefined, not 'z'
//
// BUG 2 — the for-in head pointed NEXTFOR straight at the binding register.
// The exhausting step reports has_next=false and writes undefined to its A
// operand, so the binding was clobbered with undefined on the way out even
// after bug 1 was fixed. NEXTFOR now targets a scratch and the key moves into
// the binding past the exhaustion branch (the shape emit_bare_forin_loop
// already used).
//
// BUG 3 — hoist_decls stopped at a non-IDENTIFIER declarator, so a binding
// PATTERN (`var [a]`, `var {p:b}`) hoisted nothing at all. For a plain
// statement that was masked (var_declaration declares as it parses), but a
// for-head is not: pop_scope_to drops the head's entries and the name is gone.
//   for (var [x] of []) {} x    →  "x is not defined", not undefined
//
// WHAT MAKES THIS FRAGILE (read before simplifying anything below):
//
// The bugs are INVISIBLE at global scope and for any captured local. Both are
// env-resident, so the head's DECLVAR keeps the env slot correct and the read
// goes through GETVAR. Only a register-resident function local diverges. So
// every case below must read the binding from inside a FUNCTION, and must not
// close over it — wrap a case in a closure and it passes on a broken compiler.
//
// Equally load-bearing: the zero-iteration cases. Bug 2 only shows up on the
// exhausting step, so a loop that runs at least once and is then read hides it
// unless the last real value is compared (hence the many-iteration cases check
// the LAST value, not just "not undefined").
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

// ── Bug 1+2: identifier `var` head survives the loop ─────────────────────
function f1() { for (var v in { z: 1 }) {} return v; }
eq(f1(), "z", "for-in var head holds the last key after the loop");

function f2() { var v; for (var v in { z: 1 }) {} return v; }
eq(f2(), "z", "for-in var head redeclaring an existing var writes that binding");

function f3() { for (var w of [7]) {} return w; }
eq(f3(), 7, "for-of var head holds the last value after the loop");

function f4() { for (var k in { a: 1, b: 2, c: 3 }) {} return k; }
eq(f4(), "c", "for-in var head holds the LAST key, not undefined from exhaustion");

function f5() { for (var n of [10, 20, 30]) {} return n; }
eq(f5(), 30, "for-of var head holds the LAST value, not undefined from exhaustion");

// Zero iterations must leave the binding undefined rather than throwing.
function f6() { for (var q in {}) {} return q; }
eq(f6(), undefined, "zero-iteration for-in var head leaves undefined");

function f7() { for (var r of []) {} return r; }
eq(f7(), undefined, "zero-iteration for-of var head leaves undefined");

// The binding is one binding: writes inside the body persist after the loop
// when the loop then ends.
function f8() { for (var s of [1]) { s = 99; } return s; }
eq(f8(), 99, "body assignment to the head binding is the same binding");

// ── Bug 3: pattern `var` heads are hoisted ───────────────────────────────
function p1() { for (var [a] of [[1], [2]]) {} return a; }
eq(p1(), 2, "array-pattern var head holds the last destructured value");

function p2() { for (var { v: b } of [{ v: 1 }, { v: 2 }]) {} return b; }
eq(p2(), 2, "object-pattern var head holds the last destructured value");

function p3() { for (var [c] of []) {} return c; }
eq(p3(), undefined, "zero-iteration array-pattern var head leaves undefined");

function p4() { for (var { v: d } of []) {} return d; }
eq(p4(), undefined, "zero-iteration object-pattern var head leaves undefined");

function p5() { for (var [e] in { ab: 1, cd: 2 }) {} return e; }
eq(p5(), "c", "for-in array-pattern var head destructures the last key string");

// Nested patterns, rest elements, defaults and computed keys must all hoist
// exactly their bound names — and nothing from a computed key or a default,
// whose identifiers are REFERENCES.
function p6() { for (var { a: { b: [g] } } of [{ a: { b: [5] } }]) {} return g; }
eq(p6(), 5, "nested pattern var head binds the innermost leaf");

function p7() { for (var [h, ...rest] of [[1, 2, 3]]) {} return h + ":" + rest.join(","); }
eq(p7(), "1:2,3", "array rest element in a var head");

function p8() { for (var { p, ...others } of [{ p: 1, q: 2 }]) {} return p + ":" + others.q; }
eq(p8(), "1:2", "object rest element in a var head");

var outerDefault = 42;
function p9() { for (var [i = outerDefault] of [[]]) {} return i; }
eq(p9(), 42, "default value in a var head pattern resolves the OUTER name");

var computedKey = "a";
function p10() { for (var { [computedKey]: j } of [{ a: 9 }]) {} return j; }
eq(p10(), 9, "computed key in a var head pattern is an expression, not a binding");

// A property KEY is not a bound name — including when the property carries a
// default. The pattern walk's default-skipper must stop at the token that ends
// the default and hand the pattern's own closing bracket back to the walk;
// using the general expression skipper here consumed that bracket, so the walk
// ran on into the INITIALIZER and hoisted names out of it (`w` below became a
// declared binding).
var keyNotBound = false;
try { void wkey; } catch (e) { keyNotBound = e instanceof ReferenceError; }
assert(keyNotBound, "sanity: wkey is undeclared before the pattern below");
var { wkey: [kx] = [4] } = { wkey: [7] };
eq(kx, 7, "a property with an array sub-pattern and a default still binds its leaf");
var keyStillNotBound = false;
try { void wkey; } catch (e) { keyStillNotBound = e instanceof ReferenceError; }
assert(keyStillNotBound, "a property key with a default value is not a binding");

var { wkey2: k2 = 4 } = { wkey2: 7 };
eq(k2, 7, "a shorthand-with-default property binds its value name");
var key2NotBound = false;
try { void wkey2; } catch (e) { key2NotBound = e instanceof ReferenceError; }
assert(key2NotBound, "a property key with a scalar default is not a binding");

// A repeated name in one pattern is ONE binding (`var` heads are exempt from
// the unique-BoundNames rule), so the later element wins.
function p11() { for (var [m, m] of [[1, 2]]) {} return m; }
eq(p11(), 2, "a repeated name in a var head pattern is a single binding");

// Array holes bind nothing.
function p12() { for (var [, second] of [[1, 2]]) {} return second; }
eq(p12(), 2, "an array hole in a var head pattern skips a position");

// ── Bug 3 also fixes plain pattern `var` statements in nested blocks ─────
// The hoisted binding is what makes the name readable after the block.
function b1() { { var [z] = [3]; } return z; }
eq(b1(), 3, "a pattern var in a nested block is function-scoped");

function b2() { if (false) { var [n1, { n2 }] = [1, { n2: 2 }]; } return typeof n1 + ":" + typeof n2; }
eq(b2(), "undefined:undefined", "an unexecuted pattern var is still declared");

// ── The head binding is function-scoped, not loop-scoped ─────────────────
// A `var` in a nested block after the loop refers to the SAME binding.
function s1() { for (var t of [1, 2]) {} { var t2 = t; } return t + ":" + t2; }
eq(s1(), "2:2", "the head binding is visible to a later nested block");

// A `var` declaration AFTER the loop is the same binding, not a reset.
function s2() { for (var u in { a: 1 }) {} var u; return u; }
eq(s2(), "a", "a later bare `var` of the same name does not reset the binding");

// ── let/const heads keep their block scoping and per-iteration semantics ──
// These share the head write path, so they must not have been disturbed.
var closures = [];
for (let li of [1, 2, 3]) { closures.push(function () { return li; }); }
eq(closures.map(function (fn) { return fn(); }).join(","), "1,2,3",
   "let head still gives each iteration its own binding");

var inClosures = [];
for (const ck in { a: 1, b: 2 }) { inClosures.push(function () { return ck; }); }
eq(inClosures.map(function (fn) { return fn(); }).join(","), "a,b",
   "const for-in head still gives each iteration its own binding");

var patClosures = [];
for (let [pl] of [[1], [2]]) { patClosures.push(function () { return pl; }); }
eq(patClosures.map(function (fn) { return fn(); }).join(","), "1,2",
   "let pattern head still gives each iteration its own binding");

// A const head is still immutable inside the body.
var constThrew = false;
try { for (const cc of [1]) { cc = 2; } } catch (e) { constThrew = e instanceof TypeError; }
assert(constThrew, "assigning a const head binding inside the body throws TypeError");

// A let head is still in TDZ while the RHS is evaluated.
var tdzThrew = false;
try { (function () { let tz = 1; for (let tz of [tz]) {} })(); }
catch (e) { tdzThrew = e instanceof ReferenceError; }
assert(tdzThrew, "a let head binding is in TDZ during RHS evaluation");

// ── The head binding works in every function form ────────────────────────
var method = { m: function () { for (var mv of [4]) {} return mv; } };
eq(method.m(), 4, "var head inside a method");

function outerFn() {
  function innerFn() { for (var iv in { y: 1 }) {} return iv; }
  return innerFn();
}
eq(outerFn(), "y", "var head inside a nested function");

function* genFn() { for (var gv of [8]) {} yield gv; }
eq(genFn().next().value, 8, "var head inside a generator");

print('codegen_for_head_var_binding: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }

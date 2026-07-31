// The for-of head's RHS is an AssignmentExpression, not an Expression.
//
// ES2024 §14.7.5:
//
//   for ( LeftHandSideExpression of AssignmentExpression ) Statement
//   for ( var ForBinding of AssignmentExpression ) Statement
//   for ( ForDeclaration of AssignmentExpression ) Statement
//
// A top-level comma therefore terminates nothing and is a SyntaxError:
// `for (let x of [], []) {}` cannot parse. Note the contrast with for-in,
// whose RHS *is* a full Expression, and with the C-style for's second and
// third clauses, which are Expressions too -- so this rule is specific to
// for-of and cannot be applied to the other heads.
//
// The RHS was being parsed with the full comma-expression parser, so the
// comma was silently swallowed and the loop ran over the LAST operand.
//
// Every non-comma expression form must keep working, which is the bulk of this
// file: narrowing an expression parser is exactly the change that
// over-rejects, and a for-of RHS legitimately contains assignments, ternaries,
// `??`, spread, calls and arrow functions.
//
// This file is written to run UNMODIFIED under node (with a `print` shim), so
// the expectations are V8-verified rather than self-asserted.

var pass = 0, fail = 0;

function assert(cond, msg) {
  if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); }
}

// Assert that `src` is an early SyntaxError.
function rejects(src) {
  var threw = null;
  try {
    eval('"use strict";\n' + src);
  } catch (e) {
    threw = e;
  }
  assert(threw !== null && threw instanceof SyntaxError,
         'expected SyntaxError for: ' + src +
         (threw === null ? ' (accepted)' : ' (got ' + threw.name + ')'));
}

// Assert that `src` parses AND runs cleanly. Over-rejection is the more
// damaging failure mode, so the valid shapes are asserted just as hard as the
// invalid ones.
function accepts(src) {
  var threw = null;
  try {
    eval('"use strict";\n' + src);
  } catch (e) {
    threw = e;
  }
  assert(threw === null,
         'expected clean parse+run for: ' + src +
         (threw === null ? '' : ' (got ' + threw.name + ': ' + threw.message + ')'));
}

// ---------------------------------------------------------------------------
// A top-level comma in the for-of RHS is a SyntaxError, in every head form
// ---------------------------------------------------------------------------

rejects('for (let x of [], []) {}');
rejects('for (const x of [], []) {}');
rejects('for (var x of [], []) {}');
rejects('var x; for (x of [], []) {}');
rejects('var x; for ([x] of [], []) {}');
rejects('var x; for ({ p: x } of [], []) {}');
rejects('for (var [a, b] of [], []) {}');
rejects('var o = {}; for (o.p of [], []) {}');
rejects('for (let x of [1], [2], [3]) {}');

// ---------------------------------------------------------------------------
// Accepts: every other RHS form is an AssignmentExpression and still parses
// ---------------------------------------------------------------------------

accepts('var n = 0; for (var x of [1, 2]) { n += x; } if (n !== 3) throw new Error("x");');
accepts('var n = 0; for (var x of [1].concat([2])) { n += x; } if (n !== 3) throw new Error("x");');
accepts('var n = 0, c = true; for (var x of c ? [1] : [2]) { n = x; } if (n !== 1) throw new Error("x");');
accepts('var n = 0, a = null; for (var x of a || [5]) { n = x; } if (n !== 5) throw new Error("x");');
accepts('var n = 0, a = null; for (var x of a ?? [6]) { n = x; } if (n !== 6) throw new Error("x");');
accepts('var n = 0; for (var x of new Set([7])) { n = x; } if (n !== 7) throw new Error("x");');
accepts('var n = 0; for (var x of (function () { return [8]; })()) { n = x; } if (n !== 8) throw new Error("x");');
accepts('var n = 0, o = { a: [9] }; for (var x of o.a) { n = x; } if (n !== 9) throw new Error("x");');
accepts('var n = 0; for (var x of "ab") { n++; } if (n !== 2) throw new Error("x");');
accepts('var n = 0; for (var x of [...[4]]) { n = x; } if (n !== 4) throw new Error("x");');
accepts('var n = 0; for (var x of [1, 2].map(function (v) { return v * 2; })) { n += x; } if (n !== 6) throw new Error("x");');

// An ASSIGNMENT is an AssignmentExpression, so it is legal unparenthesised.
accepts('var n = 0, y; for (var x of y = [3]) { n = x; } if (n !== 3) throw new Error("x");');

// A comma nested inside parens or brackets is not a top-level comma.
accepts('var n = 0; for (var x of [(1, 2)]) { n = x; } if (n !== 2) throw new Error("x");');
accepts('var n = 0; for (var x of [1, 2, 3]) { n += x; } if (n !== 6) throw new Error("x");');
accepts('var n = 0; for (var x of [].concat([1], [2])) { n += x; } if (n !== 3) throw new Error("x");');

// Every head form works with a legal RHS.
accepts('var n = 0; for (var [a, b] of [[1, 2]]) { n = a + b; } if (n !== 3) throw new Error("x");');
accepts('var n = 0; for (var { p } of [{ p: 5 }]) { n = p; } if (n !== 5) throw new Error("x");');
accepts('var o = {}; for (o.p of [8]) {} if (o.p !== 8) throw new Error("x");');
accepts('var t, n = 0; for (t of [9]) { n = t; } if (n !== 9) throw new Error("x");');
accepts('var n = 0; for (let x of [1]) { for (let y of [2]) { n = x + y; } } if (n !== 3) throw new Error("x");');

// ---------------------------------------------------------------------------
// The rule is for-of ONLY: for-in's RHS is a full Expression, and the C-style
// for's clauses are Expressions, so a comma is legal in all of those.
// ---------------------------------------------------------------------------

accepts('var n = 0; for (var k in { a: 1 }, { b: 1, c: 1 }) { n++; } if (n !== 2) throw new Error("x");');
accepts('var n = 0; for (var i = 0, j = 1; i < 1; i++) { n = j; } if (n !== 1) throw new Error("x");');
accepts('var n = 0; for (var i = 0; i < 1; i++, n++) {} if (n !== 1) throw new Error("x");');
accepts('var n = 0, i; for (i = 0, n = 5; i < 1; i++) {} if (n !== 5) throw new Error("x");');

print('forof_head_expr: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }

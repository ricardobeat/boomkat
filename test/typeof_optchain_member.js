// `typeof` on an identifier followed by a member/optional-chain/call/tagged-
// template continuation must keep the whole chain as the operand.
//
// The bare-identifier and parenthesized-identifier fast paths under TYPEOF
// short-circuit to TYPEOFIDENT (a name walk) once they see a plain name. Both
// only checked for `.` `[` `(` as a continuation, so `typeof a?.b` split into
// `typeof a` plus a dangling `?.b`, and `typeof (a).b` left the `.b` behind
// (a SyntaxError from the enclosing parse). The continuation set must match
// what the member chain accepts: `.` `[` `(` `?.` and a template literal.

var pass = 0, fail = 0;

function assert(cond, msg) {
  if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); }
}

function eq(actual, expected, msg) {
  assert(actual === expected, msg + ': expected ' + expected + ', got ' + actual);
}

var a = { b: 5, deep: { c: 6 } };
eq(typeof a?.b, 'number', 'typeof a?.b');
eq(typeof a.b?.c, 'undefined', 'typeof a.b?.c');
eq(typeof a.deep?.c, 'number', 'typeof a.deep?.c');
eq(typeof (a).b, 'number', 'typeof (a).b');
eq(typeof (a)?.b, 'number', 'typeof (a)?.b');
eq(typeof a.missing?.c, 'undefined', 'typeof a.missing?.c');
eq(typeof a['b'], 'number', "typeof a['b']");
eq(typeof (a)['b'], 'number', "typeof (a)['b']");
eq(typeof a['b']?.c, 'undefined', "typeof a['b']?.c");

var tag = function (s) { return s[0]; };
eq(typeof tag`x`, 'string', 'typeof tag`x`');
eq(typeof (tag)`x`, 'string', 'typeof (tag)`x`');

// Bare-identifier fast path still applies when nothing follows the name.
eq(typeof a, 'object', 'typeof a');
eq(typeof (a), 'object', 'typeof (a)');
eq(typeof missingName, 'undefined', 'typeof missingName');

if (fail) { print('FAILURES: ' + fail); }
print('PASS: ' + pass);

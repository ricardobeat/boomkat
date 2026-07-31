// `typeof arguments` inside a function body.
//
// The compiler has two bare-identifier fast paths under TYPEOF that emit
// TYPEOFIDENT (an env walk by name) directly, bypassing primary_expr. Only
// primary_expr set the function's `uses_arguments` flag, and the VM builds the
// arguments object at call entry solely from that flag — so a function whose
// *only* mention of `arguments` was under `typeof` never got one, the name walk
// found nothing, and TYPEOFIDENT's not-found branch returned "undefined".
//
// Silent and wrong-valued: no error, no throw, plausible-looking output. Every
// expectation below is node-verified.

var pass = 0, fail = 0;

function assert(cond, msg) {
  if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); }
}

function eq(actual, expected, msg) {
  assert(actual === expected, msg + ': expected ' + expected + ', got ' + actual);
}

// --- the shapes that were wrong -------------------------------------------

function plain() { return typeof arguments; }
eq(plain(), 'object', 'typeof arguments in an ordinary function');

function parenthesized() { return typeof (arguments); }
eq(parenthesized(), 'object', 'typeof (arguments) — CoverParenthesized');

var obj = { m() { return typeof arguments; } };
eq(obj.m(), 'object', 'typeof arguments in a method');

function viaArrow() { return (() => typeof arguments)(); }
eq(viaArrow(), 'object', 'arrow closing over the enclosing arguments');

// An arrow is not itself an arguments-bearing function, so the flag has to be
// propagated to the *enclosing* function, not consumed by the arrow.
function nestedArrow() { return (() => (() => typeof arguments)())(); }
eq(nestedArrow(), 'object', 'doubly nested arrow reaches the function');

// typeof must not be the thing that materializes it — the object it reports
// has to be the real one.
function alsoRead(a, b) { return typeof arguments === 'object' && arguments.length; }
eq(alsoRead(1, 2), 2, 'typeof and a real read agree on the same object');

// --- controls that were already correct -----------------------------------

// The whole reason TYPEOFIDENT exists: an unresolvable reference is
// "undefined", not a ReferenceError (ES5 §11.4.3).
eq(typeof nope123, 'undefined', 'undeclared identifier');
eq(typeof (nope456), 'undefined', 'undeclared identifier, parenthesized');
function undeclaredInFn() { return typeof alsoNope789; }
eq(undeclaredInFn(), 'undefined', 'undeclared identifier inside a function');

// A resolvable binding still reports its own type, not the arguments object.
function shadowCheck() { var arg = 1; return typeof arg; }
eq(shadowCheck(), 'number', 'ordinary local is unaffected');

function lengthOnly() { return arguments.length; }
eq(lengthOnly(1, 2, 3), 3, 'arguments.length');

function truthy() { return !!arguments; }
eq(truthy(), true, '!!arguments');

// --- the early error must survive -----------------------------------------

// ES2022 §15.7.1: a class field initializer may not mention `arguments`,
// including under `typeof`. Reusing the shared helper for the flag must not
// drop this.
function rejects(src, msg) {
  var threw = null;
  try { eval('"use strict";\n' + src); } catch (e) { threw = e; }
  assert(threw instanceof SyntaxError, msg + ': expected SyntaxError');
}
rejects('class C { x = typeof arguments; }', 'typeof arguments in a field init');
rejects('class C { x = typeof (arguments); }', 'typeof (arguments) in a field init');
rejects('class C { x = () => typeof arguments; }', 'arrow in a field init');

// ...but a method body is a normal function.
eq(new (class { m() { return typeof arguments; } })().m(), 'object',
   'typeof arguments in a class method');

print('typeof_arguments: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { throw new Error(fail + ' assertion(s) failed'); }

// Early (parse-time) SyntaxErrors for restricted BindingIdentifier names.
//
// Each case is compiled in isolation via eval() because these are *early*
// errors: they must be raised while parsing the binding, before any of it
// runs. A direct source-level copy of these shapes would fail to parse this
// whole file rather than exercise one rule at a time.
//
// ES2024 §13.1.1 makes `eval` and `arguments` (and the future reserved words)
// illegal as a BindingIdentifier in strict code. This engine is strict-only,
// so the restriction is unconditional. The positions covered here were each
// reading the name with a bare `expect(IDENTIFIER)` and so accepted them:
//
//   BI1  FunctionDeclaration / FunctionExpression / generator / async names.
//        A *top-level* declaration additionally has to be checked in the
//        hoisting pre-scan: once the name is recorded as hoisted, the
//        statement pass skips the declaration outright and never re-reads it.
//   BI2  The `for (var|let|const X in/of ...)` head binding.
//
// The complementary accepts() cases matter more than the rejects(): `eval` and
// `arguments` remain perfectly legal as property keys, method names and class
// element names, and over-rejecting those would break working code.
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
// BI1: function names
// ---------------------------------------------------------------------------

// Declarations. These are the ones that go through the hoisting pre-scan.
rejects('function eval() {}');
rejects('function arguments() {}');
rejects('function* eval() {}');
rejects('function* arguments() {}');
rejects('async function eval() {}');
rejects('async function* arguments() {}');

// A declaration nested in a function body takes the non-hoisted path.
rejects('function outer() { function eval() {} }');
rejects('function outer() { function arguments() {} }');

// Expressions.
rejects('(function eval() {});');
rejects('(function arguments() {});');
rejects('(function* eval() {});');
rejects('(async function arguments() {});');
rejects('var f = function eval() {};');

// Other §13.1.1 restricted names share the rule and the same code path.
rejects('function yield() {}');
rejects('function let() {}');
rejects('function static() {}');
rejects('function package() {}');
rejects('function implements() {}');
rejects('(function interface() {});');

// ---------------------------------------------------------------------------
// BI2: for-in / for-of head bindings
// ---------------------------------------------------------------------------

rejects('for (var eval in null) {}');
rejects('for (var arguments in null) {}');
rejects('for (let eval in {}) {}');
rejects('for (const eval of []) {}');
rejects('for (var eval of []) {}');
rejects('for (let arguments of []) {}');
rejects('for (var let in {}) {}');
rejects('for (const yield of []) {}');
rejects('for (let static of []) {}');

// Inside a function body too, not just at top level.
rejects('function f() { for (var arguments in null) {} }');
rejects('function f() { for (let eval of []) {} }');

// ---------------------------------------------------------------------------
// Accepts: the restriction is on BINDING position only
// ---------------------------------------------------------------------------

// `arguments` and `eval` are ordinary identifiers to READ.
accepts('function f() { return arguments.length; } if (f(1, 2) !== 2) throw new Error("x");');
accepts('if (typeof eval !== "function") throw new Error("x");');

// Property keys, shorthand method names and accessors are IdentifierNames, not
// BindingIdentifiers -- the restriction must not reach them.
accepts('var o = { eval: 1, arguments: 2 }; if (o.eval + o.arguments !== 3) throw new Error("x");');
accepts('var o = { eval() { return 1; }, arguments() { return 2; } }; if (o.eval() + o.arguments() !== 3) throw new Error("x");');
accepts('var o = { get eval() { return 4; }, set arguments(v) {} }; if (o.eval !== 4) throw new Error("x");');
accepts('var o = { let: 1, static: 2, yield: 3 }; if (o.let + o.static + o.yield !== 6) throw new Error("x");');
accepts('class C { eval() { return 1; } arguments() { return 2; } static eval() { return 3; } }; if (new C().eval() !== 1) throw new Error("x");');
accepts('var o = {}; o.eval = 5; o.arguments = 6; if (o.eval + o.arguments !== 11) throw new Error("x");');

// Names that merely CONTAIN a restricted name are unaffected.
accepts('function evaluate() { return 1; } if (evaluate() !== 1) throw new Error("x");');
accepts('function argumentsList() { return 2; } if (argumentsList() !== 2) throw new Error("x");');
accepts('var n = 0; for (var evaluate in { a: 1 }) { n++; } if (n !== 1) throw new Error("x");');
accepts('var n = 0; for (const argumentsx of [1, 2]) { n += argumentsx; } if (n !== 3) throw new Error("x");');

// Ordinary function names and for-head bindings still work.
accepts('function ok() { return 7; } if (ok() !== 7) throw new Error("x");');
accepts('var f = function named() { return 8; }; if (f() !== 8) throw new Error("x");');
accepts('function* g() { yield 1; } if (g().next().value !== 1) throw new Error("x");');
accepts('var n = 0; for (var k in { a: 1, b: 2 }) { n++; } if (n !== 2) throw new Error("x");');
accepts('var n = 0; for (let v of [1, 2, 3]) { n += v; } if (n !== 6) throw new Error("x");');
accepts('var n = 0; for (const [a, b] of [[1, 2]]) { n = a + b; } if (n !== 3) throw new Error("x");');

// A bare (non-declaring) for-in/for-of head is an AssignmentTarget, not a
// BindingIdentifier, so an existing `eval`-named variable is not in scope here
// but any ordinary variable must still work.
accepts('var t, n = 0; for (t in { a: 1 }) { n++; } if (n !== 1) throw new Error("x");');

print('binding_identifier_early_errors: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }

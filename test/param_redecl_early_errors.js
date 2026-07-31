// Early (parse-time) SyntaxErrors where a lexical declaration collides with a
// parameter, and where a pattern's BoundNames repeat.
//
// Each case is compiled in isolation via eval() because these are *early*
// errors: they must be raised while parsing, before any of it runs. A direct
// source-level copy of these shapes would fail to parse this whole file rather
// than exercise one rule at a time.
//
// The rules covered (all were previously under-enforced):
//
//   PR1  A function body's top-level LexicallyDeclaredNames must not contain
//        any BoundName of the parameter list.  ES2024 §14.1.2
//   PR2  The same rule for a catch block and its CatchParameter, including the
//        case where the lexical declaration is a block-level FunctionDeclaration
//        or a class (both lexical in strict code).  §14.15.1
//   PR3  A destructuring CatchParameter's BoundNames must be unique, as must a
//        `let`/`const` ForDeclaration's.  §14.15.1, §14.7.5.1
//
// The distinction that makes this subtle is that a body *var* of the same name
// stays legal in every one of these positions -- it denotes the very same
// binding -- so only the lexical forms may be rejected. Likewise a `var`
// for-head may legally repeat a name (`for (var [x, x] of ...)`), and a NESTED
// block's lexical names shadow the parameters freely. Those shapes are all
// asserted below, because over-rejecting them would break working code.
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
// PR1: function body lexical vs parameter
// ---------------------------------------------------------------------------

rejects('function f(param) { let param; }');
rejects('function f(param) { const param = 1; }');
rejects('function f(a, b) { let b; }');
rejects('function f(param) { class param {} }');
rejects('var f = function (param) { let param; };');
rejects('var f = (param) => { let param; };');
rejects('var obj = { method(param) { let param; } };');
rejects('var obj = { *gen(a) { let a = 3; } };');
rejects('var obj = { *gen(a) { const a = 3; } };');
rejects('var obj = { get p() { let q; } , set s(v) { let v; } };');
rejects('function f([a]) { let a; }');
rejects('function f({ a }) { let a; }');
rejects('function f(...rest) { let rest; }');
rejects('async function f(param) { let param; }');

// ---------------------------------------------------------------------------
// PR2: catch block lexical vs catch parameter
// ---------------------------------------------------------------------------

rejects('try { } catch (x) { let x; }');
rejects('try { } catch (x) { const x = 1; }');
rejects('try { } catch (e) { function e() {} }');
rejects('try { } catch (e) { class e {} }');
rejects('try { } catch ([e]) { function e() {} }');
rejects('try { } catch ({ e }) { let e; }');
rejects('function f() { try { } catch (e) { function e() {} } }');
rejects('function f() { try { } catch (e) { let e; } }');

// ---------------------------------------------------------------------------
// PR3: duplicate BoundNames in a pattern
// ---------------------------------------------------------------------------

rejects('try { } catch ([x, x]) {}');
rejects('try { } catch ({ a: x, b: x }) {}');
rejects('for (let [x, x] in {}) {}');
rejects('for (const [x, x] in {}) {}');
rejects('for (let [x, x] of []) {}');
rejects('for (const [x, x] of []) {}');
rejects('for (let { a: x, b: x } of []) {}');

// ---------------------------------------------------------------------------
// Accepts: a body `var` denotes the SAME binding and stays legal
// ---------------------------------------------------------------------------

accepts('function f(param) { var param; if (f.length !== 1) throw new Error("x"); }');
accepts('function f(param) { var param = 2; return param; } if (f(1) !== 2) throw new Error("x");');
accepts('var obj = { method(param) { var param; } }; obj.method(1);');
accepts('try { throw 1; } catch (x) { var x; }');
accepts('function f() { try { throw 1; } catch (e) { var e; } } f();');

// A `var` for-head may legally repeat a name: all occurrences are one binding.
accepts('var n = 0; for (var [x, x] of [[1, 2]]) { n = x; } if (n !== 2) throw new Error("x");');
accepts('var n = 0; for (var { a: x, b: x } of [{ a: 1, b: 2 }]) { n = x; } if (n !== 2) throw new Error("x");');

// ---------------------------------------------------------------------------
// Accepts: a NESTED block's lexical names shadow the parameters freely
// ---------------------------------------------------------------------------

accepts('function f(p) { { let p = 2; if (p !== 2) throw new Error("x"); } } f(1);');
accepts('function f(p) { { const p = 2; } } f(1);');
accepts('function f(p) { { class p {} } } f(1);');
accepts('try { } catch (e) { { function e() {} } }');
accepts('try { } catch (e) { { let e; } }');
accepts('function f(p) { if (true) { let p; } } f(1);');

// A nested FUNCTION's body is its own parameter scope: its lexical names
// shadow the enclosing function's parameters, not collide with them.
accepts('function outer(p) { function inner() { let p; } } outer(1);');
accepts('function outer(p) { var g = function () { let p; }; } outer(1);');
accepts('function outer(p) { var g = () => { let p; }; } outer(1);');
accepts('function outer(e) { try { } catch (x) { function e() {} } } outer(1);');
accepts('function outer(e) { try { } catch (x) { let e; } } outer(1);');
accepts('try { } catch (e) { function f(e) {} }');

// ---------------------------------------------------------------------------
// Accepts: distinct names, and lexical declarations with no parameter at all
// ---------------------------------------------------------------------------

accepts('function f(a, b) { let c, d; } f(1, 2);');
accepts('try { } catch (e) { let g; function h() {} }');
accepts('try { } catch ([x, y]) {}');
accepts('try { } catch ({ a: x, b: y }) {}');
accepts('var n = 0; for (let [x, y] of [[1, 2]]) { n = x + y; } if (n !== 3) throw new Error("x");');
accepts('var n = 0; for (const [x, y] in { ab: 1 }) { n = 1; } if (n !== 1) throw new Error("x");');
accepts('{ function q() {} }');
accepts('function f(p) { let q = p; return q; } if (f(5) !== 5) throw new Error("x");');

// A parameter and a lexical name in a SIBLING function do not interact.
accepts('function a(x) {} function b(x) { let y; } b(1);');

print('param_redecl_early_errors: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }

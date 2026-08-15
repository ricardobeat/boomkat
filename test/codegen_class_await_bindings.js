// Regression coverage for the `class await {}` body-hoist leak.
//
// `class` is its own TokenType, and `await` is its own TokenType (not
// IDENTIFIER) when the lexer sees it in an async/modal context. The raw-token
// pre-scans (hoist_decls in functions.c3, pre_scan_var_decls in statements.c3)
// gated `class` bodies on class_kw_starts_class(), which only recognized
// IDENTIFIER / EXTENDS / LBRACE after the `class` keyword. `class await { ... }`
// is a legal BindingIdentifier in non-async/non-module code, so missing the
// AWAIT arm meant the gate returned false, skip_class_body() never ran, and
// every `var` inside the class body leaked into the enclosing function's hoist
// list as a global-undefined binding.
//
// The repro is observable only because the leaked name shadows nothing in the
// enclosing scope: the enclosing function reads `leaked`, gets the bogus
// undefined, and returns it. With the fix the read throws ReferenceError.
//
// `class yield {}` and `class static {}` / `class let {}` / `class package {}`
// are rejected at parse time (yield is reserved in this strict-only engine;
// static/let/package/etc. are reserved in strict class bodies), so the gate
// never sees them and they are unaffected. `class await {}` inside an async
// function or module is rejected the same way (await is reserved there).
//
// WHAT MAKES THIS FRAGILE (read before simplifying anything below):
//
// Each `leaked` read must be from inside the enclosing function/Program of the
// class declaration. The leaked name must shadow nothing (no `var leaked`
// above it), so the bugged binding is what the read finds. The class body must
// declare `leaked` itself with `var` (not `let`/`const`), since the leak is a
// VarDeclaredNames hoist.
//
"use strict";

var pass = 0, fail = 0;

function assert(cond, msg) {
  if (cond) { pass++; }
  else { fail++; print("FAIL: " + msg); }
}

function eq(actual, expected, msg) {
  assert(actual === expected, msg + " (expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual) + ")");
}

function readsLeakedInFunctionBody() {
  class await { m() { var leaked = 1; } }
  try { return "" + leaked; } catch (e) { return e.name; }
}
eq(readsLeakedInFunctionBody(), "ReferenceError",
   "class await { } body var does not leak into the enclosing function");

function readsLeakedInFunctionBodyExtends() {
  class await extends (class {}) { m() { var leaked = 2; } }
  try { return "" + leaked; } catch (e) { return e.name; }
}
eq(readsLeakedInFunctionBodyExtends(), "ReferenceError",
   "class await extends ... { } body var does not leak either");

// Same shape but inside a block: the enclosing BlockStatement is the scope.
function readsLeakedInsideBlock() {
  {
    class await { m() { var leaked = 3; } }
  }
  try { return "" + leaked; } catch (e) { return e.name; }
}
eq(readsLeakedInsideBlock(), "ReferenceError",
   "class await inside a block: body's var stays in the block scope");

// Two leaked names from two sibling classes both raise.
function readsMultipleLeaked() {
  class await { m() { var a = 1; } }
  class await2 extends (class {}) { n() { var b = 2; } }
  try { return "" + a + ":" + b; } catch (e) { return e.name; }
}
eq(readsMultipleLeaked(), "ReferenceError",
   "two sibling class awaits both leak unless the gate runs");

// The class itself is callable as a constructor and its method works, so the
// fix does not over-reject the legal class.
function classWorks() {
  class await { m() { return "M"; } }
  return new await().m();
}
eq(classWorks(), "M", "class await { m() {} } still parses and runs");

// The class name binds to the constructor from the enclosing scope.
function classNameBinding() {
  class await { m() { return "N"; } }
  return typeof await;
}
eq(classNameBinding(), "function", "class await's name is visible as a binding");

// Two methods in the same class body each have their own function scope; a
// `var` declared inside one method does NOT carry to another method. (In ES
// terms, methods are separate FunctionEnvironmentRecords.) This test guards
// against an over-correction that would hoist method-locals into the body:
// the pre-scan skip must be tight enough to skip the body as a whole, and no
// tighter. The bug's direction here is "var in m() leaks out into the
// enclosing function", which the first cases above already cover.
function methodLocalVarStaysLocal() {
  class await {
    m() { var mLocal = 31; }
    n() {
      var sawError = false;
      try { void mLocal; } catch (e) { sawError = e instanceof ReferenceError; }
      return sawError;
    }
  }
  return new await().n();
}
eq(methodLocalVarStaysLocal(), true,
   "a method's own var is local to that method, not shared with sibling methods");

// ── Negative cases: reserved words stay rejected ──────────────────────────
// Each is wrapped in eval so the SyntaxError raises inside the catch rather
// than aborting this whole file's parse.
function rejects(src) {
  var threw = null;
  try { eval(src); } catch (e) { threw = e; }
  assert(threw !== null && threw instanceof SyntaxError,
         'expected SyntaxError for: ' + src +
         (threw === null ? ' (accepted)' : ' (got ' + threw.name + ')'));
}

rejects('class yield { m() { return 1; } }');
rejects('class static { m() { return 1; } }');
rejects('class let { m() { return 1; } }');
rejects('class package { m() { return 1; } }');
rejects('class implements { m() { return 1; } }');

// Inside an async function `await` is reserved, so `class await` must fail.
function rejectsAsync() {
  var threw = null;
  try {
    eval('async function f() { class await { m() { return 1; } } }');
  } catch (e) { threw = e; }
  assert(threw !== null && threw instanceof SyntaxError,
         'class await inside an async function is a SyntaxError' +
         (threw === null ? ' (accepted)' : ' (got ' + threw.name + ')'));
}
rejectsAsync();

print('codegen_class_await_bindings: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
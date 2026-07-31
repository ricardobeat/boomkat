// `new.target` is only legal in function code (ES2024 §16.1.1, §16.2.1.1).
//
//   "It is a Syntax Error if StatementList Contains NewTarget unless the source
//    code containing NewTarget is eval code that is being processed by a direct
//    eval that is contained in function code that is not the function code of
//    an ArrowFunction."
//
// So global and module top-level code may not contain it, and neither may an
// ArrowFunction written directly there: an arrow has no [[NewTarget]] of its
// own and inherits its enclosing function's, of which there is none.
//
// NOTE ON NODE: this file is NOT a node differential. `node file.js` accepts a
// bare top-level `new.target` because it evaluates a script as if wrapped in a
// function; the rule above is what test262's language/global-code/new.target.js
// asserts, and the spec text is quoted rather than deferring to V8 here. The
// eval-based cases below DO agree with node, because inside eval the harness is
// itself function code and the direct-eval exception applies.
//
// The top-level cases therefore cannot be expressed with eval() (that would
// make them legal), so they are asserted from a separate file the shell driver
// compiles; here we cover the eval-reachable half plus every accept case.

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
// Indirect eval has no [[NewTarget]] either, and unlike direct eval it gets no
// exception -- the source is not "contained in function code".
// ---------------------------------------------------------------------------

(function () {
  var indirect = eval;
  var threw = null;
  try {
    indirect('"use strict"; new.target;');
  } catch (e) {
    threw = e;
  }
  assert(threw !== null && threw instanceof SyntaxError,
         'expected SyntaxError for indirect eval of new.target' +
         (threw === null ? ' (accepted)' : ' (got ' + threw.name + ')'));
})();

// ---------------------------------------------------------------------------
// Accepts: every position that DOES have a [[NewTarget]]
// ---------------------------------------------------------------------------

accepts('function f() { return new.target; } if (f() !== undefined) throw new Error("x");');
accepts('function f() { return new.target; } if (new f() === undefined) throw new Error("x");');
accepts('function f() { return new.target; } if (new f() !== f) throw new Error("x");');
accepts('class C { constructor() { if (new.target !== C) throw new Error("x"); } } new C();');
accepts('class C { m() { return new.target; } } if (new C().m() !== undefined) throw new Error("x");');
accepts('var o = { m() { return new.target; } }; if (o.m() !== undefined) throw new Error("x");');
accepts('function* g() { yield new.target; } if (g().next().value !== undefined) throw new Error("x");');
accepts('async function a() { return new.target; } a();');
accepts('function f() { return new.target; } if (Reflect.construct(f, []) !== f) throw new Error("x");');

// An arrow INSIDE a function inherits that function's [[NewTarget]], so it is
// legal there and observes the enclosing function's value.
accepts('function f() { var g = () => new.target; return g(); } if (f() !== undefined) throw new Error("x");');
accepts('function f() { var g = () => new.target; return g(); } if (new f() !== f) throw new Error("x");');
accepts('class C { constructor() { var g = () => new.target; if (g() !== C) throw new Error("x"); } } new C();');
accepts('function f() { var g = () => () => new.target; return g()(); } if (new f() !== f) throw new Error("x");');

// `new.target` is a meta-property, not a property read: `target` remains an
// ordinary identifier and `new` an ordinary operator everywhere else.
accepts('var target = 1; if (target !== 1) throw new Error("x");');
accepts('var o = { target: 2 }; if (o.target !== 2) throw new Error("x");');
accepts('function F() {} if (typeof new F() !== "object") throw new Error("x");');

print('new_target_early_errors: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }

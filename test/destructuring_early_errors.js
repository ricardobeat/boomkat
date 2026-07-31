// Early (parse-time) SyntaxErrors in destructuring patterns.
//
// Each case is compiled in isolation via eval() because these are *early*
// errors: they must be raised while parsing the pattern, before any of it
// runs. A direct source-level copy of these shapes would fail to parse this
// whole file rather than exercise one rule at a time.
//
// The rules covered (all four were previously under-enforced, i.e. the engine
// accepted source the spec requires it to reject):
//
//   SR1  A reserved word may be a property *key* (`{extends: t}`) but not the
//        shorthand *target* (`{extends}`), where the key doubles as an
//        IdentifierReference / BindingIdentifier.  ES2015 §13.15.5.1, §13.3.3
//   SR2  `yield` is a reserved word in strict code regardless of generator
//        context, so it can never be a shorthand target here.
//   SR3  A rest element must be last: no trailing comma or elision may follow
//        it, in either an assignment or a binding pattern.  ES2022 §13.15.5
//   SR4  A pattern's leaf assignment target must be a valid simple assignment
//        target, so `eval` / `arguments` are rejected in strict code exactly
//        as the non-pattern `eval = v` already is.  ES2022 §13.15.1
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
// SR1: reserved word as a shorthand target
// ---------------------------------------------------------------------------

// Assignment patterns.
rejects('0, { extends } = {};');
rejects('0, { var } = {};');
rejects('0, { default } = {};');
rejects('0, { this } = {};');
rejects('0, { new } = {};');
rejects('0, { function } = {};');
rejects('0, { class } = {};');
rejects('0, { typeof } = {};');
rejects('0, { in } = {};');
rejects('0, { instanceof } = {};');
rejects('0, { import } = {};');
rejects('0, { super } = {};');
rejects('0, { enum } = {};');
rejects('0, { null } = {};');
rejects('0, { true } = {};');
rejects('0, { false } = {};');

// Escaped spellings denote the same reserved word (ES2024 §12.6.1) and are
// rejected identically -- this is the bulk of the test262 family.
rejects('0, { v\\u0061r } = {};');
rejects('0, { def\\u{61}ult } = {};');
rejects('0, { \\u0074his } = {};');
rejects('0, { ext\\u0065nds } = {};');

// Binding patterns (declarations) and parameter lists share the rule.
rejects('var { extends } = {};');
rejects('let { var } = {};');
rejects('const { default } = {};');
rejects('function f({ extends }) {}');
rejects('var f = ({ extends }) => {};');
rejects('var f = ({ v\\u0061r }) => {};');
rejects('try {} catch ({ extends }) {}');
rejects('for ({ extends } in [{}]) ;');

// With an initializer, and nested at depth.
rejects('0, { extends = 1 } = {};');
rejects('0, { a: { extends } } = { a: {} };');
rejects('0, [ { extends } ] = [ {} ];');

// ---------------------------------------------------------------------------
// SR2: `yield` is reserved in strict code, generator or not
// ---------------------------------------------------------------------------

rejects('0, { yield } = {};');
rejects('0, { yield = 1 } = {};');
rejects('var { yield } = {};');
rejects('for ({ yield } in [{}]) ;');
rejects('function f({ yield }) {}');
rejects('0, { a: { yield } } = { a: {} };');

// ---------------------------------------------------------------------------
// SR3: a rest element must be last
// ---------------------------------------------------------------------------

// Assignment patterns.
rejects('var x; 0, [...x,] = [];');
rejects('var x, y; 0, [...x, y] = [];');
rejects('var a, x; 0, [a, ...x,] = [];');

// Binding patterns.
rejects('var [...a,] = [];');
rejects('let [...a,] = [];');
rejects('const [...a,] = [];');
rejects('var {...a,} = {};');
rejects('function f([...a,]) {}');
rejects('var f = ([...a,]) => {};');
rejects('for ([...x,] in [[]]) ;');

// Nested.
rejects('var [[...a,]] = [[]];');

// ---------------------------------------------------------------------------
// SR4: eval / arguments are not valid assignment targets in strict code
// ---------------------------------------------------------------------------

rejects('0, [eval] = [];');
rejects('0, [arguments] = [];');
rejects('0, { a: eval } = {};');
rejects('0, { a: arguments } = {};');
rejects('0, [...eval] = [];');
rejects('0, [eval = 1] = [];');
rejects('0, [[eval]] = [[]];');
rejects('for ({ eval } in [{}]) ;');
rejects('for ({ eval = 0 } in [{}]) ;');

// ---------------------------------------------------------------------------
// ACCEPT side -- valid shapes that must keep working.
// Over-rejection breaks working programs, so these matter more than the
// rejections above.
// ---------------------------------------------------------------------------

// A reserved word is fine as a property KEY in the long form.
accepts('var a; 0, ({ extends: a } = { extends: 1 }); if (a !== 1) throw new Error("x");');
accepts('var a; 0, ({ var: a } = { var: 2 }); if (a !== 2) throw new Error("x");');
accepts('var a; 0, ({ default: a } = { default: 3 }); if (a !== 3) throw new Error("x");');
accepts('var a; 0, ({ this: a } = { this: 4 }); if (a !== 4) throw new Error("x");');
accepts('var a; 0, ({ yield: a } = { yield: 5 }); if (a !== 5) throw new Error("x");');
accepts('var a; 0, ({ default: a = 6 } = {}); if (a !== 6) throw new Error("x");');
accepts('var a; 0, ({ x: { default: a } } = { x: { default: 7 } }); if (a !== 7) throw new Error("x");');
accepts('var o = { extends: 1, var: 2, default: 3, this: 4, class: 5 };');
accepts('var f = ({ extends: a }) => a; if (f({ extends: 8 }) !== 8) throw new Error("x");');
accepts('var { extends: e } = { extends: 9 }; if (e !== 9) throw new Error("x");');

// Ordinary identifiers, including contextual keywords, remain legal shorthand.
accepts('var a; 0, ({ a } = { a: 1 }); if (a !== 1) throw new Error("x");');
accepts('var async; 0, ({ async } = { async: 2 }); if (async !== 2) throw new Error("x");');
accepts('var get, set; 0, ({ get, set } = { get: 3, set: 4 }); if (get !== 3) throw new Error("x");');
accepts('var of, target; 0, ({ of, target } = { of: 5, target: 6 }); if (of !== 5) throw new Error("x");');
accepts('var { a, b } = { a: 1, b: 2 }; if (a + b !== 3) throw new Error("x");');

// Rest in its legal final position, and trailing commas WITHOUT a rest.
accepts('var x; 0, ([...x] = [1, 2]); if (x.length !== 2) throw new Error("x");');
accepts('var a, x; 0, ([a, ...x] = [1, 2, 3]); if (x.length !== 2) throw new Error("x");');
accepts('var x; 0, ([, , ...x] = [1, 2, 3]); if (x[0] !== 3) throw new Error("x");');
accepts('var a, b; 0, ([a, b,] = [1, 2]); if (b !== 2) throw new Error("x");');
accepts('var a, b; 0, ([a, , b] = [1, 2, 3]); if (b !== 3) throw new Error("x");');
accepts('var x; 0, ({ ...x } = { a: 1 }); if (x.a !== 1) throw new Error("x");');
accepts('var [p, ...q] = [1, 2, 3]; if (q.length !== 2) throw new Error("x");');
accepts('var { a, ...r } = { a: 1, b: 2 }; if (r.b !== 2) throw new Error("x");');
accepts('function f(...rest) { return rest.length; } if (f(1, 2) !== 2) throw new Error("x");');
accepts('function f([...a]) { return a.length; } if (f([1, 2]) !== 2) throw new Error("x");');
accepts('var o = {}; 0, ([...o.p] = [1]); if (o.p[0] !== 1) throw new Error("x");');

// `eval` / `arguments` are fine as property keys and as member targets; only
// the bare-identifier target position is restricted.
accepts('var a; 0, ({ eval: a } = { eval: 1 }); if (a !== 1) throw new Error("x");');
accepts('var a; 0, ({ arguments: a } = { arguments: 2 }); if (a !== 2) throw new Error("x");');
accepts('var o = {}; 0, ([o.eval] = [3]); if (o.eval !== 3) throw new Error("x");');
accepts('function f() { var o = {}; 0, ([o.arguments] = [4]); return o.arguments; } if (f() !== 4) throw new Error("x");');

// Assorted valid destructuring that exercises the touched collectors.
accepts('var a, b; 0, ([[a], { x: b }] = [[1], { x: 2 }]); if (a + b !== 3) throw new Error("x");');
accepts('var a; 0, ([a = 5] = []); if (a !== 5) throw new Error("x");');
accepts('var o = {}, k = "p"; 0, ([o[k]] = [6]); if (o.p !== 6) throw new Error("x");');
accepts('var a; 0, ({ p: { q: a } } = { p: { q: 7 } }); if (a !== 7) throw new Error("x");');
accepts('function f({ a = 1, b: { c = 2 } = {} }) { return a + c; } if (f({}) !== 3) throw new Error("x");');
accepts('try { throw { message: "m" }; } catch ({ message }) { if (message !== "m") throw new Error("x"); }');
accepts('var n = 0; for (const [k, v] of [[1, 2]]) { n = k + v; } if (n !== 3) throw new Error("x");');
accepts('var seen = 0, t; for ({ a: t } in { foo: 1 }) { seen++; } if (seen !== 1) throw new Error("x");');
accepts('var g = function* () { var x; 0, ([x = yield] = []); }; g().next();');

print('destructuring_early_errors: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }

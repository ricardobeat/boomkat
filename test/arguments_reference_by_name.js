// A reference to `arguments` is a reference however it is written.
//
// A non-arrow function only builds its arguments object when the compiler saw
// a reference to the implicit binding, so every read of the name has to be
// counted. A read that resolves to a local binding does not count -- that name
// is bound, and the implicit object is not what it names.
//
// The same name is an early SyntaxError anywhere in a class field initializer
// (§15.7.1), including under `typeof`, so both checks travel together.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }
function eq(a, b, m) { ok(a === b, m + ' (got ' + a + ', want ' + b + ')'); }

// Property shorthand reads the binding named by the key.
eq((function () { return typeof ({ arguments }).arguments; })(), 'object',
   'object literal shorthand');
eq((function () { return ({ arguments }).arguments.length; })(1, 2), 2,
   'shorthand yields the real arguments object');
eq((function () { return ({ arguments: arguments }).arguments.length; })(1, 2), 2,
   'the longhand form still works');
eq((function () { return ({ a: 1, arguments, b: 2 }).arguments.length; })(7), 1,
   'shorthand among other properties');
eq((function () { return ({ arguments }).arguments === arguments; })(), true,
   'shorthand reads the same object');

// A nested shorthand inside an object that is itself a member target.
ok((function () { [{ arguments }.x] = []; return true; })(),
   'shorthand inside a destructuring member target');
ok((function () { [...{ arguments }.x] = []; return true; })(),
   'shorthand inside a rest member target');
ok((function () { ({ a: { arguments }.x } = {}); return true; })(),
   'shorthand inside an object-pattern member target');

// `eval` takes the same path and must keep working.
eq((function () { return typeof ({ eval }).eval; })(), 'function',
   'eval shorthand');
ok((function () { [{ eval }.x] = []; return true; })(),
   'eval shorthand in a member target');

// Other by-name reads.
eq((function () { var o = {}; o.a = arguments; return o.a.length; })(3, 4), 2,
   'assignment from arguments');
eq((function () { return [arguments][0].length; })(1), 1,
   'arguments in an array literal');
eq((function () { return `${arguments.length}`; })(1, 2, 3), '3',
   'arguments in a template');
eq((function () { return (function (a) { return a.length; })(arguments); })(5), 1,
   'arguments as a call argument');
eq((function () { return typeof arguments; })(), 'object', 'typeof arguments');
eq((function () { return arguments && arguments.length; })(9), 1,
   'arguments in a logical expression');

// The name is a reserved binding identifier in strict code, which this engine
// always is, so it cannot be shadowed by a declaration. It is still an ordinary
// property key.
eq((function () { var o = { arguments: 'x' }; return o.arguments; })(), 'x',
   'a property key named arguments is not a reference');
function bindingIsRejected(src) {
    try { eval(src); return false; }
    catch (e) { return e instanceof SyntaxError; }
}
ok(bindingIsRejected('(function () { var arguments = 1; })'),
   'a var named arguments is rejected');
ok(bindingIsRejected('(function (arguments) {})'),
   'a parameter named arguments is rejected');
ok(bindingIsRejected('(function () { let arguments = 1; })'),
   'a let named arguments is rejected');

// An arrow has no arguments object of its own and reads the enclosing one.
eq((function () { return (() => ({ arguments }).arguments.length)(); })(1, 2), 2,
   'an arrow shorthand reads the enclosing arguments');
eq((function () { return (() => arguments.length)(); })(1), 1,
   'an arrow reads the enclosing arguments');

// §15.7.1: `arguments` is an early SyntaxError in a class field initializer,
// in every spelling.
function isSyntaxError(src) {
    try { eval(src); return false; }
    catch (e) { return e instanceof SyntaxError; }
}
ok(isSyntaxError('class C { f = arguments; }'), 'plain reference in a field');
ok(isSyntaxError('class C { f = { arguments }; }'), 'shorthand in a field');
ok(isSyntaxError('class C { f = typeof arguments; }'), 'typeof in a field');
ok(isSyntaxError('class C { f = [arguments]; }'), 'array literal in a field');
ok(isSyntaxError('class C { f = { a: arguments }; }'), 'longhand in a field');
ok(isSyntaxError('class C { static f = { arguments }; }'), 'shorthand in a static field');

// A field may still use the name as a property key, or bind it inside a
// nested function, where the restriction does not reach.
ok(!isSyntaxError('class C { f = { arguments: 1 }; }'), 'a key named arguments is allowed');
ok(!isSyntaxError('class C { f = function () { return arguments; }; }'),
   'a nested function has its own arguments');

if (fail === 0) {
    print('PASS: arguments reference by name (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}

// Free identifiers inside functions.
//
// A name that no scope around a function binds, and that nothing can bind
// later, can only be a global: it is read and written through the global slot
// cache instead of a walk of the environment chain. These cases keep every way
// of binding the name from being skipped.

var pass = 0;
var fail = 0;

function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

var counter = 0;
function bump() { counter++; counter += 2; return counter; }
for (var i = 0; i < 100; i++) bump();
eq(counter, 300, 'global var updated from a function');

// An enclosing function's binding wins over the global of the same name.
var shade = 'global';
function outer() {
    var shade = 'outer';
    return function () { return shade; };
}
eq(outer()(), 'outer', 'closure sees the enclosing var');
function viaBlock() { { let shade = 'block'; return (function () { return shade; })(); } }
eq(viaBlock(), 'block', 'closure sees the enclosing block let');
eq((function () { return shade; })(), 'global', 'plain function sees the global');

// A parameter and a catch binding shadow it too.
eq((function (shade) { return (function () { return shade; })(); })('param'), 'param', 'parameter');
eq((function () { try { throw 'c'; } catch (shade) { return (function () { return shade; })(); } })(), 'c', 'catch binding');

// with and eval can bind a name the source never declares.
var viaWith = (function () {
    var o = { shade: 'with' };
    with (o) { return (function () { return shade; })(); }
})();
eq(viaWith, 'with', 'with object');
var viaEval = (function () {
    eval('var shade = "eval"');
    return (function () { return shade; })();
})();
eq(viaEval, 'eval', 'direct eval var');

// Writes: sloppy creates a global, strict throws, a deleted global stops resolving.
function implicit() { madeHere = 7; return madeHere; }
eq(implicit(), 7, 'sloppy implicit global');
eq(globalThis.madeHere, 7, 'implicit global lands on the global object');
function strictWrite() { 'use strict'; neverDeclared = 1; }
var threw = '';
try { strictWrite(); } catch (e) { threw = e.name; }
eq(threw, 'ReferenceError', 'strict write to an undeclared name');
function readMissing() { return typeof missingEntirely; }
eq(readMissing(), 'undefined', 'typeof of an undeclared name');
function readThrows() { return missingEntirely; }
threw = '';
try { readThrows(); } catch (e) { threw = e.name; }
eq(threw, 'ReferenceError', 'read of an undeclared name');
globalThis.gone = 1;
function readGone() { return gone; }
eq(readGone(), 1, 'before delete');
delete globalThis.gone;
threw = '';
try { readGone(); } catch (e) { threw = e.name; }
eq(threw, 'ReferenceError', 'after delete');

// A getter, and const.
var hits = 0;
Object.defineProperty(globalThis, 'acc', { get: function () { return ++hits; }, configurable: true });
function useAcc() { return acc; }
eq(useAcc() + ':' + useAcc(), '1:2', 'global accessor getter');
const frozen = 1;
function writeConst() { frozen = 2; }
threw = '';
try { writeConst(); } catch (e) { threw = e.name; }
eq(threw, 'TypeError', 'assignment to a global const');

// The same function body run in two activations, one with a shadowing closure.
function make(shadowed) {
    if (shadowed) { var counter = 'local'; }
    return function () { return typeof counter; };
}
eq(make(true)(), 'string', 'activation that binds the name');
eq(make(false)(), 'undefined', 'hoisted var without a value');

print('free_global_access: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }

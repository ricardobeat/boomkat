// arguments[i] reads in loops, so the threaded read path sees each state of
// the object: parameter-mapped, unmapped, written, deleted, redefined,
// frozen, extended, and holding more arguments than the shared shapes cover.
var pass = 0, fail = 0;
function eq(actual, expected, msg) {
    if (actual === expected) pass++;
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}
function loop(f, n) { var last; for (var i = 0; i < n; i++) last = f(i); return last; }
var N = 40;

function sum() { var s = 0; for (var i = 0; i < arguments.length; i++) s += arguments[i]; return s; }
eq(loop(function () { return sum(1, 2, 3); }, N), 6, 'plain sum');
eq(loop(function () { return sum(1, 2, 3, 4, 5, 6, 7, 8); }, N), 36, 'more arguments than the shared shapes');
eq(loop(function () { return sum(); }, N), 0, 'no arguments');

function strictSum(a) { 'use strict'; var s = 0; for (var i = 0; i < arguments.length; i++) s += arguments[i]; return s; }
eq(loop(function () { return strictSum(1, 2, 3); }, N), 6, 'strict sum');
function strictWrite(a) { 'use strict'; a = 100; return arguments[0] + arguments[1]; }
eq(loop(function () { return strictWrite(1, 2); }, N), 3, 'strict arguments do not alias a');

function aliasRead(a, b) { a = 10; var s = 0; for (var i = 0; i < 2; i++) s += arguments[i]; return s; }
eq(loop(function () { return aliasRead(1, 2); }, N), 12, 'sloppy parameter write is visible');
function aliasWrite(a, b) { arguments[1] = 20; return a + b + arguments[1]; }
eq(loop(function () { return aliasWrite(1, 2); }, N), 41, 'arguments write reaches the parameter');
function extra(a) { a = 9; return arguments[0] * 100 + arguments[1] * 10 + arguments[2]; }
eq(loop(function () { return extra(1, 2, 3); }, N), 923, 'mapped and unmapped indices together');

function afterDelete(a) { delete arguments[0]; a = 5; return arguments[0] === undefined && 0 in arguments === false; }
eq(loop(function () { return afterDelete(1); }, N), true, 'deleted index stops aliasing');
function afterFreeze(a, b) { Object.freeze(arguments); a = 7; return arguments[0] + arguments[1]; }
eq(loop(function () { return afterFreeze(1, 2); }, N), 3, 'frozen arguments keep their values');
function accessor() {
    Object.defineProperty(arguments, 1, { get: function () { return 42; }, configurable: true });
    return arguments[0] + arguments[1];
}
eq(loop(function () { return accessor(1, 2, 3); }, N), 43, 'accessor shadows the argument');
function extend() { arguments.extra = 1; arguments[5] = 6; return arguments[0] + arguments[1] + arguments[5]; }
eq(loop(function () { return extend(1, 2); }, N), 9, 'object that left its shared shape');
function hole() { return arguments[1]; }
eq(loop(function () { return hole(1, undefined, 3); }, N), undefined, 'explicit undefined argument');
eq(loop(function () { return hole(1); }, N), undefined, 'index past the arguments');
function neg() { return arguments[-1]; }
eq(loop(function () { return neg(1); }, N), undefined, 'negative index');
function nested() { var f = function () { return arguments[0]; }; return f(arguments[0] + 1) + arguments[0]; }
eq(loop(function () { return nested(5); }, N), 11, 'inner arguments are separate');
function pass1(o) { return peek(arguments); }
function peek(args) { return args[0] + args[1]; }
eq(loop(function () { return pass1(3, 4); }, N), 7, 'arguments read in another frame');
function swap(a, b) { var t = arguments[0]; arguments[0] = arguments[1]; arguments[1] = t; return a * 10 + b; }
eq(loop(function () { return swap(1, 2); }, N), 21, 'swap through arguments');

print('arguments_reads: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }

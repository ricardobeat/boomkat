// Lean frames that build an arguments object.
//
// A function whose `arguments` is a register and aliases no formal (it has no
// formals, or is strict) used to take the general entry on every call. The
// lean entries now build the object themselves: threaded calls, getters and
// host callbacks such as Array.prototype.map. A mapped object with formals
// still takes the general entry, which keeps it in step with the parameters.

var pass = 0;
var fail = 0;

function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

// The Prototype.js class idiom: a shared constructor forwards to initialize.
var Class = { create: function () { return function () { this.initialize.apply(this, arguments); }; } };
var Point = Class.create();
Point.prototype = { x: 0, y: 0, initialize: function (x, y) { this.x = x; this.y = y; } };
var sum = 0;
for (var i = 0; i < 300; i++) { var p = new Point(i, 2 * i); sum += p.x + p.y; }
eq(sum, 3 * 299 * 300 / 2, 'forwarded constructor arguments');

// Length, values, extra and missing arguments, and callee in sloppy code.
function count() { return arguments.length + ':' + Array.prototype.join.call(arguments, ','); }
function self() { return arguments.callee; }
for (var i = 0; i < 100; i++) {
    eq(count(), '0:', 'no arguments');
    eq(count(1, 'a', null), '3:1,a,', 'three arguments');
    eq(self(), self, 'sloppy callee');
}

// The object escapes and outlives its frame.
function capture() { return arguments; }
var kept = [];
for (var i = 0; i < 100; i++) kept.push(capture(i, i + 1));
eq(kept[99][0] + kept[99][1] + kept[42].length, 99 + 100 + 2, 'escaped arguments');
eq(Object.prototype.toString.call(kept[0]), '[object Arguments]', 'arguments class');

// Strict formals are unmapped: assigning a parameter leaves the object alone.
function strictArgs(a) { 'use strict'; a = 9; return arguments[0] + ':' + arguments.length; }
var calleeThrows = false;
function strictCallee() { 'use strict'; return arguments.callee; }
for (var i = 0; i < 100; i++) eq(strictArgs(1, 2), '1:2', 'strict unmapped');
try { strictCallee(); } catch (e) { calleeThrows = e instanceof TypeError; }
eq(calleeThrows, true, 'strict callee throws');

// Sloppy formals are mapped and stay in step.
function mapped(a) { arguments[0] = 'm'; return a; }
for (var i = 0; i < 100; i++) eq(mapped(1), 'm', 'mapped formal');

// A getter, a host callback and a tail call.
var obj = { get n() { return arguments.length; } };
var cb = [1, 2, 3].map(function () { return arguments.length; });
function tailee() { return arguments.length; }
function tailer(a, b) { return tailee(a, b, 3); }
for (var i = 0; i < 100; i++) {
    eq(obj.n, 0, 'getter arguments');
    eq(tailer(1, 2), 3, 'tail-called arguments');
}
eq(cb.join(), '3,3,3', 'callback arguments');

print('lean_arguments: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }

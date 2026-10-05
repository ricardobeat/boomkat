function equal(actual, expected, label) {
    if (actual !== expected) throw new Error(label + ': ' + actual + ' !== ' + expected);
}

// §13.16.1 and §13.15.4: GetValue precedes evaluation of the next operand.
function commaValues() {
    var a = 1;
    equal((0, a) + (a = 4), 5, 'comma value');
    a = 1;
    equal((0, (0, a)) + (a = 4), 5, 'nested comma value');
    a = 1;
    equal(((0, a) || 0) + (a = 4), 5, 'comma in logical expression');
    a = 1;
    equal((0, a) + ([a] = [4], a), 5, 'destructuring writes local');
    var original = { x: 1 }, object = original;
    (0, object).x = (object = { x: 9 }, 2);
    equal(original.x, 2, 'comma base preserved');
    equal(object.x, 9, 'replacement base');
    var receiver = { method: function () { 'use strict'; return this; } };
    equal((0, receiver.method)(), undefined, 'comma discards receiver');
    var hidden = 1;
    equal((0, eval)('typeof hidden'), 'undefined', 'comma makes eval indirect');
}
commaValues();

// §14.12.4: capture the discriminant before evaluating any case selector.
function switchValue(a) {
    switch (a) {
        case (a = 2): return 'wrong';
        case 1: return 'right';
        default: return 'default';
    }
}
equal(switchValue(1), 'right', 'switch keeps original value');
equal(switchValue(2), 'wrong', 'switch matches first case');
equal(switchValue(3), 'default', 'switch default');
function commaSwitch() {
    var a = 1;
    switch ((0, a)) {
        case (a = 2): return false;
        case 1: return true;
    }
}
equal(commaSwitch(), true, 'switch with comma discriminant');

// §14.3.2.1: a var declaration without an initializer performs no assignment.
function forVariables() {
    var a = 3;
    for (var a; a < 4; a++) {}
    equal(a, 4, 'for preserves initialized var');
    var b = 7;
    for (var a = 0, b; a < 1; a++) {}
    equal(b, 7, 'later uninitialized declarator');
    for (var fresh; false;) {}
    equal(fresh, undefined, 'fresh var is hoisted');
    for (let a; true;) {
        equal(a, undefined, 'let gets a fresh binding');
        break;
    }
    equal(a, 1, 'let leaves outer binding intact');
}
forVariables();
var globalLoopValue = 3;
for (var globalLoopValue; globalLoopValue < 4; globalLoopValue++) {}
equal(globalLoopValue, 4, 'global var preserved');
var touches = 0;
var bindings = {
    get untouchedLoopVar() { touches++; return 1; },
    set untouchedLoopVar(value) { touches++; }
};
with (bindings) { for (var untouchedLoopVar; false;) {} }
equal(touches, 0, 'uninitialized var does not access with binding');

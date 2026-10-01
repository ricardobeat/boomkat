// Calls to compiled functions that need no scope, arguments object or `this`
// coercion enter their frame from the threaded burst. Each case below checks a
// state the entry has to preserve once the callee runs.
function check(actual, expected, what) {
    if (actual !== expected) {
        throw new Error(what + ': expected ' + expected + ', got ' + actual);
    }
}

// Recursion through a captured binding (CALL_VAR) and a global (CALL_GLOBAL),
// long enough that the burst crosses many calls and hands control back.
function recursion() {
    function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
    return fib(24);
}
check(recursion(), 46368, 'captured recursion');

function globalFib(n) { return n < 2 ? n : globalFib(n - 1) + globalFib(n - 2); }
check(globalFib(24), 46368, 'global recursion');

// Missing and extra arguments.
function pick(a, b, c) { return (a === undefined ? 'u' : a) + (b === undefined ? 'u' : b) + (c === undefined ? 'u' : c); }
function callPick() {
    var out = '';
    for (var i = 0; i < 200; i++) out = pick(1) + pick(1, 2) + pick(1, 2, 3) + pick(1, 2, 3, 4);
    return out;
}
check(callPick(), '1uu3u66', 'missing and extra arguments');

// A binding reassigned while its function runs must not free or swap the
// running frame's function.
var rebound = function (n) {
    var before = rebound;
    rebound = function () { return -1; };
    return before === rebound ? 0 : n + 1;
};
function callRebound() {
    var total = 0;
    for (var i = 0; i < 3; i++) {
        total += rebound(i);
        rebound = function (n) {
            var before = rebound;
            rebound = function () { return -1; };
            return before === rebound ? 0 : n + 1;
        };
    }
    return total;
}
check(callRebound(), 6, 'reassigned callee binding');

// `this` of a plain call: a sloppy callee that reads it still sees the global
// object, a strict one sees undefined, and one that ignores it is unaffected.
function sloppyThis() { return this === globalThis; }
function strictThis() { 'use strict'; return this === undefined; }
function noThis(x) { return x + 1; }
function callThis() {
    var ok = 0;
    for (var i = 0; i < 100; i++) {
        if (sloppyThis() && strictThis() && noThis(i) === i + 1) ok++;
    }
    return ok;
}
check(callThis(), 100, 'this of plain calls');

// A throw out of a callee entered from the burst unwinds to the caller's catch.
function thrower(n) { if (n > 3) throw new Error('boom ' + n); return n; }
function callThrower() {
    var caught = 0;
    for (var i = 0; i < 200; i++) {
        try { thrower(i % 6); } catch (e) { caught++; }
    }
    return caught;
}
check(callThrower(), 66, 'throw through lean frames');

// Unbounded recursion reaches the activation limit and raises a RangeError the
// caller can catch, after which calls work again.
function runaway() { return runaway() + 1; }
function callRunaway() {
    try { runaway(); } catch (e) { return e instanceof RangeError; }
    return false;
}
check(callRunaway(), true, 'stack limit');
check(globalFib(10), 55, 'calls after the stack limit');

// Frames that allocate while a collection runs keep their callee and caller state.
function build(n) { return n === 0 ? { v: 0 } : { v: n, next: build(n - 1) }; }
function callBuild() {
    var sum = 0;
    for (var i = 0; i < 300; i++) {
        var o = build(40);
        while (o) { sum += o.v; o = o.next; }
    }
    return sum;
}
check(callBuild(), 300 * 820, 'allocating recursion');

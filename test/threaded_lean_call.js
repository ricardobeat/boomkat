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

// A method call whose callee ignores `this` keeps its receiver in the caller's
// register for the duration of the call, including across collections.
function makeReceiver(i) {
    var r = { id: i, pad: [i, i + 1, i + 2], tag: 'r' + i };
    r.run = function (n) {
        var junk = [];
        for (var k = 0; k < 8; k++) junk.push({ k: k, n: n });
        return junk.length + n;
    };
    return r;
}
function callMethods() {
    var sum = 0;
    for (var i = 0; i < 2000; i++) {
        sum += makeReceiver(i).run(i);
    }
    return sum;
}
check(callMethods(), 2000 * 8 + 1999 * 2000 / 2, 'method calls ignoring this');

// Receivers of other types, and callees that do read `this`.
var methodHolder = {
    plain: function (x) { return x * 2; },
    usesThis: function (x) { return this === methodHolder ? x : -1; },
    strictThis: function (x) { 'use strict'; return this === methodHolder ? x : -1; }
};
Number.prototype.twice = function (x) { 'use strict'; return typeof this === 'number' ? x * 2 : -1; };
function callMixed() {
    var ok = 0;
    for (var i = 0; i < 200; i++) {
        if (methodHolder.plain(i) === i * 2 && methodHolder.usesThis(i) === i
            && methodHolder.strictThis(i) === i && (5).twice(i) === i * 2) ok++;
    }
    return ok;
}
check(callMixed(), 200, 'mixed receivers');

// Methods that read `this` borrow an object receiver from the caller; primitive
// receivers still get the callee's own coercion.
var counter = {
    n: 0,
    bump: function (d) { this.n += d; return this; },
    sloppyType: function () { return typeof this; },
    strictType: function () { 'use strict'; return typeof this; }
};
String.prototype.sloppyType = counter.sloppyType;
String.prototype.strictType = counter.strictType;
function callBorrowed() {
    var ok = 0;
    for (var i = 0; i < 300; i++) {
        if (counter.bump(1).bump(2) === counter && counter.sloppyType() === 'object'
            && counter.strictType() === 'object' && 'x'.sloppyType() === 'object'
            && 'x'.strictType() === 'string') ok++;
    }
    return ok === 300 && counter.n === 900;
}
check(callBorrowed(), true, 'borrowed receivers');

// A receiver that exists only in the caller's temporary register survives a
// collection triggered inside the callee.
function callTemporaryReceiver() {
    var total = 0;
    for (var i = 0; i < 500; i++) {
        total += { v: i, m: function () { var junk = []; for (var k = 0; k < 20; k++) junk.push([k]); return this.v + junk.length; } }.m();
    }
    return total;
}
check(callTemporaryReceiver(), 500 * 499 / 2 + 500 * 20, 'temporary receiver');

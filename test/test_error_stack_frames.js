// error.stack carries one frame per live JS call, innermost first.
//
// Asserts on STRUCTURE only: the number of "    at <name>" frame lines and the
// order of the function names. Line/column numbers and the exact frame spelling
// are not spec-pinned, so they are deliberately not asserted.

var failures = 0;
function fail(msg) { failures++; print('FAIL: ' + msg); }

// Frame names in order, innermost first. The header line ("Name: message") and
// the outermost script frame are excluded by the caller via `expected`.
function frameNames(stack) {
    if (typeof stack !== 'string') { return null; }
    var lines = stack.split('\n');
    var names = [];
    for (var i = 0; i < lines.length; i++) {
        var m = /^\s+at\s+(\S+)/.exec(lines[i]);
        if (m) { names.push(m[1]); }
    }
    return names;
}

function check(label, stack, expected) {
    var names = frameNames(stack);
    if (names === null) { fail(label + ': stack is not a string'); return; }
    if (names.length < expected.length) {
        fail(label + ': expected at least ' + expected.length + ' frames, got ' +
             names.length + ' (' + JSON.stringify(stack) + ')');
        return;
    }
    // Substring rather than equality: some engines prefix a frame with its
    // receiver ("Object.method"), which is not spec-pinned.
    for (var i = 0; i < expected.length; i++) {
        if (names[i].indexOf(expected[i]) === -1) {
            fail(label + ': frame ' + i + ' expected ' + expected[i] + ', got ' +
                 names[i] + ' (' + JSON.stringify(stack) + ')');
            return;
        }
    }
}

// --- named function chain ---------------------------------------------------
function inner() { throw new Error('boom'); }
function middle() { inner(); }
function outer() { middle(); }

var caught = null;
try { outer(); } catch (e) { caught = e; }
if (caught === null) {
    fail('outer() did not throw');
} else {
    check('named chain', caught.stack, ['inner', 'middle', 'outer']);
    if (caught.stack.indexOf('Error: boom') !== 0) {
        fail('named chain: stack does not start with the "Name: message" header');
    }
}

// --- frame count grows with call depth --------------------------------------
// The recursive calls below are deliberately NOT in tail position: a proper
// tail call (ES2015 §14.8) reuses its caller's frame, so `return recurse(n-1)`
// would correctly leave a two-frame stack and prove nothing about depth. The
// array wrapper keeps each frame live across its callee without coercing the
// Error the recursion returns.
function recurse(n) {
    if (n === 0) { return new Error('depth'); }
    return [recurse(n - 1)][0];
}
var deep = frameNames(recurse(5).stack);
var shallow = frameNames(recurse(1).stack);
if (deep.length - shallow.length !== 4) {
    fail('frame count does not track call depth: depth-5 had ' + deep.length +
         ' frames, depth-1 had ' + shallow.length);
}

// --- a deep stack is not truncated ------------------------------------------
function deepRecurse(n) {
    if (n === 0) { return new Error('long'); }
    return [deepRecurse(n - 1)][0];
}
var longStack = deepRecurse(200).stack;
var longNames = frameNames(longStack);
if (longNames.length < 201) {
    fail('deep stack truncated: expected at least 201 frames, got ' + longNames.length);
}
if (longStack.length <= 512) {
    fail('deep stack fits in 512 bytes (' + longStack.length + '), so it proves nothing');
}

// --- methods and arrows carry their inferred names --------------------------
var obj = { method: function () { throw new TypeError('m'); } };
var viaArrow = function named() { obj.method(); };
var caught2 = null;
try { viaArrow(); } catch (e) { caught2 = e; }
if (caught2 === null) {
    fail('viaArrow() did not throw');
} else {
    check('method chain', caught2.stack, ['method', 'named']);
}

// --- every error constructor captures frames --------------------------------
function makeAggregate() { return new AggregateError([], 'agg'); }
check('AggregateError', makeAggregate().stack, ['makeAggregate']);

function makeRange() { return new RangeError('r'); }
check('RangeError', makeRange().stack, ['makeRange']);

// --- frames below a native callback boundary --------------------------------
// A builtin that calls back into JS runs the callback in a fresh activation
// segment; the callers below the builtin must still appear.
function viaMap() { [1].map(function mapped() { throw new Error('cb'); }); }
var caught3 = null;
try { viaMap(); } catch (e) { caught3 = e; }
check('native boundary', caught3 && caught3.stack, ['mapped', 'viaMap']);

// --- a proper tail call keeps its replaced caller ---------------------------
// Strict code reuses the caller's frame for `return f()`, and for an arrow's
// expression body. The trace still names the caller that made the call.
var tailStacks = (function () {
    'use strict';
    function thrower() { throw new Error('tail'); }
    function tailCaller() { return thrower(); }
    var arrowCaller = () => thrower();
    var out = [];
    try { tailCaller(); } catch (e) { out.push(e.stack); }
    try { arrowCaller(); } catch (e) { out.push(e.stack); }
    return out;
})();
check('tail call', tailStacks[0], ['thrower', 'tailCaller']);
check('arrow tail call', tailStacks[1], ['thrower', 'arrowCaller']);

if (failures === 0) {
    print('PASS: error.stack carries ordered call frames');
}

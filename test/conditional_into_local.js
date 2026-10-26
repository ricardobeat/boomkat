// A conditional expression stored to a local writes each arm's value straight
// into the variable. Reads of the variable inside the test and the arms must
// still see its previous value, and an arm that throws must leave it alone.
var pass = 0, fail = 0;
function eq(actual, expected, msg) {
    if (actual === expected) pass++;
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

function selfRead(c, s) { s = c ? s + '!' : s + '?'; return s; }
eq(selfRead(true, 'a'), 'a!', 'true arm reads the old value');
eq(selfRead(false, 'a'), 'a?', 'false arm reads the old value');

function testReads(s) { s = s ? s + 1 : 100; return s; }
eq(testReads(0), 100, 'test reads the old value (falsy)');
eq(testReads(4), 5, 'test reads the old value (truthy)');

function nested(a, b, n) { n = a ? (b ? 1 : 2) : (b ? n + 10 : n); return n; }
eq(nested(1, 1, 7), 1, 'nested true/true');
eq(nested(1, 0, 7), 2, 'nested true/false');
eq(nested(0, 1, 7), 17, 'nested false/true reads n');
eq(nested(0, 0, 7), 7, 'nested false/false keeps n');

function throwing(n) {
    try { n = n > 0 ? (function () { throw new Error('x'); })() : 5; } catch (e) { return n; }
    return -1;
}
eq(throwing(3), 3, 'a throwing arm leaves the variable alone');

function declared(a) { var s = a ? 'y' : 'z'; var s = a ? s + s : s; return s; }
eq(declared(1), 'yy', 'redeclared var keeps the first value');
eq(declared(0), 'z', 'redeclared var, false arm');

function sideEffects(a) {
    var log = [], n = 0;
    n = (log.push('t'), a) ? (log.push('y'), n + 1) : (log.push('n'), n - 1);
    return log.join('') + n;
}
eq(sideEffects(1), 'ty1', 'evaluation order, true');
eq(sideEffects(0), 'tn-1', 'evaluation order, false');

function inLoop(k) {
    var x = 0, y = 1;
    for (var i = 0; i < k; i++) { x = i % 2 ? x + y : y; y = i % 3 ? y + 1 : x; }
    return x * 1000 + y;
}
eq(inLoop(10), (function () {
    var x = 0, y = 1;
    for (var i = 0; i < 10; i++) { var nx; if (i % 2) nx = x + y; else nx = y; x = nx; var ny; if (i % 3) ny = y + 1; else ny = x; y = ny; }
    return x * 1000 + y;
})(), 'loop with two conditional stores');

function captured(a) { var s = 'o'; s = a ? 'p' : 'q'; return function () { return s; }; }
eq(captured(1)(), 'p', 'captured variable, true');
eq(captured(0)(), 'q', 'captured variable, false');

function usedAsValue(a) { var s; var t = (s = a ? 1 : 2) + 10; return s + ':' + t; }
eq(usedAsValue(1), '1:11', 'assignment used as a value');
eq(usedAsValue(0), '2:12', 'assignment used as a value, false');

print('conditional_into_local: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }

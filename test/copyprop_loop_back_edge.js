// Copy propagation: a loop back-edge must keep a loop-carried copy alive.
//
// Copy propagation (CompilerContext.finish in compiler/context.c3) NOPs
// `LDREG rT = rS` when its consumer can read rS instead and rT is dead after it.
// The liveness scan walked forward only: it stepped over the loop's back-edge
// and stopped at a later write of rT, missing that the loop head reads rT on
// the next iteration. In
//
//     do { s = s + x; x = a[i]; y = (y + x) | 0; ... } while (...)
//
// the copy into x was dropped, `s + x` kept reading the initial x, and s stayed
// 0. Octane's Mandreel (BenchmarkDemo::initPhysics) failed its checksum on
// this shape.

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; }
    else { fail++; print('FAIL: ' + msg); }
}

function eq(actual, expected, msg) {
    assert(actual === expected, msg + ' (got ' + actual + ', want ' + expected + ')');
}

var a = [3, 5, 7, 11, 13];

function do_while_carried(a) {
    var x = 0, y = 1, s = 0, i = 0;
    do { s = s + x; x = a[i]; y = (y + x) | 0; i++; } while (i < 5);
    return s + ':' + y;
}
eq(do_while_carried(a), '26:40', 'do-while reads the previous iteration\'s copy');

function for_carried(a) {
    var x = 0, s = 0;
    for (var i = 0; i < 5; i++) { s = (s + x) | 0; x = a[i]; s = (s - x) | 0; }
    return s + ':' + x;
}
eq(for_carried(a), '-13:13', 'for loop reads the previous iteration\'s copy');

function while_carried(a) {
    var prev = 0, cur = 0, n = 0, i = 0;
    while (i < a.length) { n = (n + prev * 2) | 0; prev = cur; cur = a[i]; n = (n + cur) | 0; i++; }
    return n;
}
eq(while_carried(a), 69, 'two-deep carried copies in a while loop');

print('copyprop_loop_back_edge: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }

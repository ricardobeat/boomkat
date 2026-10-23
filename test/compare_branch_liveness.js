// Compare results and computed keys without copies.
//
// A comparison whose left operand is a local used to copy it into a scratch
// register and compare in place, because compare-branch fusion proved the
// result dead with a block-local scan that only the aliasing let through. The
// fusion now reads whole-function liveness, which no longer counts a JUMP's
// offset as a register or a plain call's receiver slot as a read, and the
// compare writes a fresh register. A plain `o[k]` names a local key in place
// with GETPROP, which leaves the key alone; a store target still copies it.

var pass = 0;
var fail = 0;

function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

// A key coerces once per access, and a local key keeps its value.
var coerced = 0;
var key = { toString: function () { coerced++; return 'p'; } };
function readKey(o, k) { var v = o[k]; return v + ':' + (k === key); }
var obj = { p: 1 };
eq(readKey(obj, key) + ':' + coerced, '1:true:1', 'plain read coerces once');
function bump(o, k) { o[k] += 1; o[k]++; return o[k]; }
coerced = 0;
eq(bump(obj, key) + ':' + coerced, '3:3', 'compound updates coerce once each');
function storeAfter(a, i) { a[i] = (i = 5); return a.join() + ':' + i; }
eq(storeAfter([0, 0, 0], 1), '0,5,0:5', 'store keeps the key read before the value');
function sumKeys(a) { var s = 0; for (var i = 0; i < a.length; i++) s += a[i] * i; return s; }
eq(sumKeys([1, 2, 3, 4]), 20, 'loop reads by a local index');

// A compare result that is used as a value survives the branch.
function kept(n) {
    var out = [];
    for (var i = 0; i < n; i++) {
        var small = i < 2;
        if (small) out.push('s'); else out.push(small);
    }
    return out.join();
}
eq(kept(4), 's,s,false,false', 'compare result read after the branch');
function chained(a, b, c) { var r = a < b && b < c; return r ? 'in' : 'out:' + r; }
eq(chained(1, 2, 3) + ',' + chained(3, 2, 1), 'in,out:false', 'short-circuit keeps its value');
function grade(n) { return n > 90 ? 1 : n > 80 ? 2 : 3; }
eq(grade(95) + grade(85) + grade(10), 6, 'nested ternary on compares');

// Nested loops: each back-edge lands on its own body.
function grid(n) {
    var s = '';
    for (var i = 0; i < n; i++) for (var j = 0; j < n; j++) s += j ? 'a' : 'b';
    return s;
}
eq(grid(3), 'baabaabaa', 'nested loop back-edges');

// A plain call writes its receiver slot; a value parked there is dead.
function fib(n) { return n <= 1 ? n : fib(n - 1) + fib(n - 2); }
eq(fib(15), 610, 'compare before a plain call');

// Inside a try region the block-local scan decides, and a throw from a
// comparison is caught with the loop state intact.
function guarded(list) {
    var seen = 0;
    try {
        for (var i = 0; i < list.length; i++) { if (list[i] < 3) seen++; }
    } catch (e) { return 'caught:' + seen + ':' + i; }
    return 'done:' + seen;
}
var bad = { valueOf: function () { throw new Error('x'); } };
eq(guarded([1, 2, 5]), 'done:2', 'loop in a try');
eq(guarded([1, bad, 2]), 'caught:1:1', 'throwing compare in a try');

print('compare_branch_liveness: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }

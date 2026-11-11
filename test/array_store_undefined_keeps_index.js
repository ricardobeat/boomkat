// Assigning `undefined` to an existing element keeps the element: the index
// stays an own, enumerable property. The dense part marks holes with
// `undefined`, so such a store has to record presence in the named table.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }

var d = [1, 2, 3];
d[1] = undefined;
ok(1 in d && d.hasOwnProperty(1), 'global array: index kept');
ok(Object.keys(d).join() === '0,1,2' && d.length === 3, 'global array: keys ' + Object.keys(d).join());
var desc = Object.getOwnPropertyDescriptor(d, 1);
ok(desc && desc.value === undefined && desc.writable && desc.enumerable && desc.configurable,
   'global array: descriptor');

function local() { var e = ['p', 'q', 'r']; e[2] = void 0; return (2 in e) && Object.keys(e).length === 3; }
ok(local(), 'local array');

var n = [3, 1, 2];
n[0] = undefined;
n.sort();
ok(Object.keys(n).join() === '0,1,2' && n[2] === undefined && 2 in n, 'sort keeps the undefined element');

var count = 0;
[1, 2, 3].forEach(function () {});
var f = [1, 2, 3];
f[0] = undefined;
f.forEach(function () { count++; });
ok(count === 3, 'forEach visits the undefined element: ' + count);

// Written back to a value afterwards.
var w = [1, 2, 3];
w[1] = undefined;
w[1] = 'back';
ok(w[1] === 'back' && Object.keys(w).join() === '0,1,2', 'rewritten element');

function st(a, i, v) { a[i] = v; }
var kept = 0;
for (var k = 0; k < 2000; k++) {
    var a = [1, 2, 3];
    st(a, 1, k % 2 ? undefined : 7);
    if (1 in a) kept++;
}
ok(kept === 2000, 'hot store keeps the index: ' + kept);

function sloppy(x, y) { arguments[0] = undefined; return (0 in arguments) && x === undefined; }
ok(sloppy(1, 2), 'mapped arguments');
function strict(x, y) { 'use strict'; arguments[1] = undefined; return (1 in arguments) && y === 2; }
ok(strict(1, 2), 'unmapped arguments');

print(fail === 0 ? 'PASS ' + pass : 'FAIL ' + fail);

// A compiled caller/callee must hand the taken edge to an existing SSA loop
// without repeating stores, losing the caller frame, or retaining retired code.
function handoffCopy(a, b, n) {
    for (var i = 0; i < n; i++) b[i] = a[i] + 1;
    return b[n - 1];
}
function handoffCaller(a, b, n) { return handoffCopy(a, b, n) + 7; }
var a = [], b = [];
for (var i = 0; i < 128; i++) { a[i] = i; b[i] = 0; }
for (var warm = 0; warm < 2000; warm++) {
    if (handoffCaller(a, b, 128) !== 135) throw Error('native caller return');
}
var calls = 0;
a[63] = { valueOf: function () { calls++; return 200; } };
if (handoffCaller(a, b, 128) !== 135 || calls !== 1 || b[63] !== 201)
    throw Error('handoff recovery');
a[63] = '7';
handoffCaller(a, b, 128);
if (b[63] !== '71') throw Error('retired SSA fallback');
a[63] = 63;
for (var warm = 0; warm < 200; warm++) {
    if (handoffCaller(a, b, 128) !== 135) throw Error('repeated handoff');
}
var largeA = new Float64Array(10001), largeB = new Float64Array(10001);
largeA.fill(1.25);
if (handoffCaller(largeA, largeB, 10001) !== 9.25) throw Error('poll return');
for (var i = 0; i < largeB.length; i++) if (largeB[i] !== 2.25) throw Error('poll store');
print('SSA handoff: PASS');

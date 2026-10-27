// Alias, branch-state and representation checks for the optimizing loop tier.
function ssaCheck(actual, expected, message) {
    if (actual !== expected) throw new Error(message + ': ' + actual + ' != ' + expected);
}
function ssaAlias(a, b, n) {
    var sum = 0;
    for (var i = 0; i < n; i++) { var x = a[i]; b[i] = x + 1; sum += a[i]; }
    return sum;
}
function ssaArms(a, b, n) {
    var sum = 0, x = 0, y = 0;
    for (var i = 0; i < n; i++) {
        if (i & 1) { x = a[i] + 10; y = a[i] * 2; }
        else { x = a[i] - 3; y = a[i] * 4; }
        b[i] = x + y;
        sum += b[i];
    }
    return sum;
}
function ssaExact(a, factor, n) {
    var sum = 0;
    for (var i = 0; i < n; i++) {
        var at = i * factor;
        var truncated = at | 0;
        a[at] = truncated + 100;
        sum += truncated;
    }
    return sum;
}
function ssaFloatJoins(a, n) {
    var sum = 0, x = 0, y = 0;
    for (var i = 0; i < n; i++) {
        if (i & 1) { x = a[i] + 0.25; y = a[i] * 0.5; }
        else { x = a[i] | 0; y = a[i] + 3; }
        sum += x + y;
    }
    return sum;
}
for (var warm = 0; warm < 200; warm++) {
    var a = new Int32Array(32), b = new Int32Array(32);
    for (var i = 0; i < 32; i++) a[i] = i;
    ssaCheck(ssaAlias(a, b, 32), 496, 'disjoint load/store');
    ssaCheck(ssaAlias(a, a, 32), 528, 'aliased load/store');
    var expected = 0;
    for (var i = 0; i < 32; i++) expected += (i & 1) ? a[i] * 3 + 10 : a[i] * 5 - 3;
    ssaCheck(ssaArms(a, b, 32), expected, 'branch joins');
    var floatExpected = 0;
    for (var i = 0; i < 32; i++) floatExpected += (i & 1) ? a[i] * 1.5 + 0.25 : a[i] * 2 + 3;
    ssaCheck(ssaFloatJoins(a, 32), floatExpected, 'mixed representations at joins');
    for (var i = 0; i < 32; i++) ssaCheck(b[i], (i & 1) ? a[i] * 3 + 10 : a[i] * 5 - 3, 'branch values');
    ssaCheck(ssaExact(b, 1, 16), 120, 'integer indexes');
}
var exact = new Int32Array(64);
ssaCheck(ssaExact(exact, 1.5, 16), 176, 'fractional index conversion');
for (var i = 0; i < 64; i++) {
    var expected = (i % 3 === 0 && i <= 21) ? i + 100 : 0;
    ssaCheck(exact[i], expected, 'fractional typed store');
}
print('SSA CFG: PASS');

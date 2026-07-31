// Sum of a series
// Compute sum of f(i) for i = m..n.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function sumSeries(m, n, f) {
    var total = 0;
    for (var i = m; i <= n; i++) total += f(i);
    return total;
}

assert(sumSeries(1, 5, function (i) { return i; }) === 15, "1..5 = 15");
assert(sumSeries(1, 10, function (i) { return i * i; }) === 385, "sum squares 1..10 = 385");
assert(sumSeries(1, 100, function (i) { return 1 / (i * (i + 1)); }) - 0.99 < 0.01, "telescoping 1/(i(i+1)) ~ 1");

// Sum of cubes equals square of sum
function sumCubes(n) {
    return sumSeries(1, n, function (i) { return i * i * i; });
}
function sumN(n) { return n * (n + 1) / 2; }
var cubesOk = true;
for (var k = 1; k <= 20; k++) {
    if (sumCubes(k) !== sumN(k) * sumN(k)) {
        cubesOk = false;
        assert(false, "cubes identity k=" + k);
        break;
    }
}
assert(cubesOk, "sum cubes = (sum)^2 for k=1..20");

// Sum of evens in [a, b]
function sumEvens(a, b) {
    var total = 0;
    for (var i = a; i <= b; i++) if (i % 2 === 0) total += i;
    return total;
}
assert(sumEvens(1, 10) === 30, "sum evens 1..10 = 2+4+6+8+10 = 30");
assert(sumEvens(1, 11) === 30, "sum evens 1..11 = 30");

print("engine/sum_series: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
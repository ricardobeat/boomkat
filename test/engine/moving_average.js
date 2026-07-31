// Averages/Simple moving average
// SMA over a sliding window.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function approxEq(a, b, eps) {
    if (eps === undefined) eps = 1e-9;
    return Math.abs(a - b) < eps;
}

function sma(values, window) {
    var out = [];
    if (values.length < window) return out;
    var sum = 0;
    for (var i = 0; i < window; i++) sum += values[i];
    out.push(sum / window);
    for (var i = window; i < values.length; i++) {
        sum += values[i] - values[i - window];
        out.push(sum / window);
    }
    return out;
}

var r1 = sma([1, 3, 5, 7, 9], 3);
assert(r1.length === 3, "5 values, window 3 -> 3 outputs");
assert(approxEq(r1[0], 3, 1e-9), "[0]=3 (1+3+5)/3");
assert(approxEq(r1[1], 5, 1e-9), "[1]=5 (3+5+7)/3");
assert(approxEq(r1[2], 7, 1e-9), "[2]=7 (5+7+9)/3");

var r2 = sma([10, 20, 30, 40], 2);
assert(approxEq(r2[0], 15, 1e-9), "r2[0]=15");
assert(approxEq(r2[2], 35, 1e-9), "r2[2]=35");

// Cumulative moving average
function cma(values) {
    var out = [];
    var sum = 0;
    for (var i = 0; i < values.length; i++) {
        sum += values[i];
        out.push(sum / (i + 1));
    }
    return out;
}

var c = cma([1, 2, 3, 4, 5]);
assert(approxEq(c[0], 1, 1e-9), "cma[0]=1");
assert(approxEq(c[2], 2, 1e-9), "cma[2]=2");
assert(approxEq(c[4], 3, 1e-9), "cma[4]=3");

print("engine/moving_average: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
// Compound interest
// Compute accumulated amount given principal, rate, time, and compounding frequency.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function compoundInterest(P, r, t, n) {
    // A = P * (1 + r/n)^(n*t)
    return P * Math.pow(1 + r / n, n * t);
}

function approxEq(a, b, eps) {
    if (eps === undefined) eps = 1e-9;
    return Math.abs(a - b) < eps;
}

assert(approxEq(compoundInterest(1000, 0.05, 1, 1), 1050, 1e-6), "annually 1yr");
assert(approxEq(compoundInterest(1000, 0.05, 1, 4), 1050.945, 1e-3), "quarterly 1yr");
assert(approxEq(compoundInterest(1000, 0.05, 1, 12), 1051.162, 1e-3), "monthly 1yr");

// Continuous compounding: limit as n -> infinity
function continuousInterest(P, r, t) { return P * Math.exp(r * t); }
assert(approxEq(continuousInterest(1000, 0.05, 1), 1051.271, 1e-3), "continuous 1yr");

// Mortgage payment formula: M = P * r(1+r)^n / ((1+r)^n - 1)
function monthlyPayment(P, annualRate, years) {
    var r = annualRate / 12;
    var n = years * 12;
    if (r === 0) return P / n;
    var pow = Math.pow(1 + r, n);
    return P * r * pow / (pow - 1);
}

assert(approxEq(monthlyPayment(200000, 0.06, 30), 1199.10, 0.01), "mortgage 200k/30yr/6%");
assert(approxEq(monthlyPayment(100000, 0.04, 15), 739.69, 0.01), "mortgage 100k/15yr/4%");

// Present value
function presentValue(futureValue, r, t) { return futureValue / Math.pow(1 + r, t); }
assert(approxEq(presentValue(1100, 0.10, 1), 1000, 1e-6), "PV 1000");

print("engine/compound_interest: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
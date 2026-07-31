// Factorial
// Computes n! using iteration and recursion.

function factorialIter(n) {
    var r = 1;
    for (var i = 2; i <= n; i++) r *= i;
    return r;
}

function factorialRec(n) {
    if (n <= 1) return 1;
    return n * factorialRec(n - 1);
}

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

assert(factorialIter(0) === 1, "iter(0)=1");
assert(factorialIter(1) === 1, "iter(1)=1");
assert(factorialIter(5) === 120, "iter(5)=120, got " + factorialIter(5));
assert(factorialIter(10) === 3628800, "iter(10)=3628800, got " + factorialIter(10));
assert(factorialRec(0) === 1, "rec(0)=1");
assert(factorialRec(5) === 120, "rec(5)=120, got " + factorialRec(5));
assert(factorialRec(10) === 3628800, "rec(10)=3628800, got " + factorialRec(10));
assert(factorialIter(12) === factorialRec(12), "iter(12)==rec(12)");

print("engine/factorial: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

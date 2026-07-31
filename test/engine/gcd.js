// Greatest common divisor
// Euclidean algorithm for GCD.

function gcd(a, b) {
    a = a < 0 ? -a : a;
    b = b < 0 ? -b : b;
    while (b !== 0) {
        var t = b;
        b = a % b;
        a = t;
    }
    return a;
}

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

assert(gcd(8, 12) === 4, "gcd(8,12)=4, got " + gcd(8, 12));
assert(gcd(54, 24) === 6, "gcd(54,24)=6, got " + gcd(54, 24));
assert(gcd(7, 13) === 1, "gcd(7,13)=1, got " + gcd(7, 13));
assert(gcd(0, 5) === 5, "gcd(0,5)=5, got " + gcd(0, 5));
assert(gcd(5, 0) === 5, "gcd(5,0)=5, got " + gcd(5, 0));
assert(gcd(48, 18) === 6, "gcd(48,18)=6, got " + gcd(48, 18));
assert(gcd(-8, 12) === 4, "gcd(-8,12)=4, got " + gcd(-8, 12));

print("engine/gcd: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

// Greatest common divisor
// Euclidean algorithm (recursive + iterative).

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function gcdRec(a, b) {
    if (b === 0) return a;
    return gcdRec(b, a % b);
}

function gcdIter(a, b) {
    while (b !== 0) {
        var t = b;
        b = a % b;
        a = t;
    }
    return a;
}

assert(gcdRec(12, 8) === 4, "rec(12,8)=4");
assert(gcdRec(8, 12) === 4, "rec(8,12)=4");
assert(gcdRec(54, 24) === 6, "rec(54,24)=6");
assert(gcdRec(17, 13) === 1, "rec(17,13)=1");
assert(gcdRec(0, 5) === 5, "rec(0,5)=5");

assert(gcdIter(12, 8) === 4, "iter(12,8)=4");
assert(gcdIter(54, 24) === 6, "iter(54,24)=6");
assert(gcdIter(1000000, 250000) === 250000, "large gcd");

// LCM
function lcm(a, b) { return (a / gcdIter(a, b)) * b; }

assert(lcm(4, 6) === 12, "lcm(4,6)=12");
assert(lcm(3, 5) === 15, "lcm(3,5)=15");
assert(lcm(0, 5) === 0, "lcm(0,5)=0");

// Extended GCD: ax + by = gcd(a, b)
function extGcd(a, b) {
    if (b === 0) return { g: a, x: 1, y: 0 };
    var r = extGcd(b, a % b);
    return { g: r.g, x: r.y, y: r.x - Math.floor(a / b) * r.y };
}

var e = extGcd(35, 15);
assert(e.g === 5, "ext gcd g=5");
assert(35 * e.x + 15 * e.y === 5, "ext gcd identity");

print("engine/gcd_extended: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
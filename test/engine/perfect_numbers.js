// Perfect numbers
// Numbers equal to the sum of their proper divisors.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function properDivisors(n) {
    var divs = [1];
    if (n <= 1) return [];
    for (var i = 2; i * i <= n; i++) {
        if (n % i === 0) {
            divs.push(i);
            if (i !== n / i) divs.push(n / i);
        }
    }
    divs.sort(function (a, b) { return a - b; });
    return divs;
}

function sumOf(arr) {
    var s = 0;
    for (var i = 0; i < arr.length; i++) s += arr[i];
    return s;
}

function isPerfect(n) {
    if (n <= 1) return false;
    return sumOf(properDivisors(n)) === n;
}

assert(JSON.stringify(properDivisors(6)) === "[1,2,3]", "div 6");
assert(JSON.stringify(properDivisors(28)) === "[1,2,4,7,14]", "div 28");

assert(isPerfect(6), "6 perfect");
assert(isPerfect(28), "28 perfect");
assert(isPerfect(496), "496 perfect");
assert(isPerfect(8128), "8128 perfect");

assert(!isPerfect(1), "1 not perfect");
assert(!isPerfect(2), "2 not perfect");
assert(!isPerfect(12), "12 not perfect");

// First four perfect numbers
var perfects = [];
for (var n = 2; n < 10000; n++) if (isPerfect(n)) perfects.push(n);
assert(JSON.stringify(perfects) === "[6,28,496,8128]", "perfects <10000");

// Amicable pair: (a, b) where sum of proper divisors of a = b and vice versa
function isAmicablePair(a, b) {
    if (a === b) return false;
    return sumOf(properDivisors(a)) === b && sumOf(properDivisors(b)) === a;
}

assert(isAmicablePair(220, 284), "(220,284)");
assert(isAmicablePair(1184, 1210), "(1184,1210)");
assert(isAmicablePair(2620, 2924), "(2620,2924)");
assert(!isAmicablePair(6, 6), "perfects not amicable with self");

print("engine/perfect_numbers: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
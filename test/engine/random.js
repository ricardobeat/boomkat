// Random numbers
// Linear congruential generator and basic statistical checks.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function lcg(seed, a, c, m) {
    var state = seed;
    return function () {
        state = (a * state + c) % m;
        return state;
    };
}

var r = lcg(42, 1103515245, 12345, 2147483648);
assert(typeof r() === "number", "returns number");
assert(r() >= 0, "non-negative");
assert(r() < 2147483648, "below modulus");

// Normalize to [0, 1)
var v = r() / 2147483648;
assert(v >= 0 && v < 1, "normalized to [0,1)");

// Distribution check: 10000 random [0,1) should be roughly uniform
function uniform(n) {
    var gen = lcg(1, 1664525, 1013904223, 2147483648);
    var sum = 0;
    for (var i = 0; i < n; i++) sum += gen() / 2147483648;
    return sum / n;
}

var avg = uniform(10000);
assert(avg > 0.45 && avg < 0.55, "average near 0.5 (got " + avg.toFixed(3) + ")");

// Random integer in [a, b], from one persistent generator seeded once.
// Reseeding from Date.now() per call would return identical values for calls
// landing in the same millisecond, making the distribution check flaky.
var diceGen = lcg(Date.now() & 0x7FFFFFFF, 1664525, 1013904223, 2147483648);
function randInt(a, b) {
    return a + ((diceGen() / 2147483648) * (b - a + 1)) | 0;
}

var counts = [0, 0, 0, 0, 0, 0, 0];
for (var i = 0; i < 6000; i++) {
    var d = randInt(1, 6);
    if (d >= 1 && d <= 6) counts[d]++;
}
for (var k = 1; k <= 6; k++) {
    assert(counts[k] > 700 && counts[k] < 1300, "die[" + k + "] count = " + counts[k]);
}

print("engine/random: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
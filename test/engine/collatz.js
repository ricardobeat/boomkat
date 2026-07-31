// Collatz conjecture
// Computes the Collatz sequence length and verifies specific values.

function collatzLength(n) {
    var count = 1;
    while (n !== 1) {
        n = (n % 2 === 0) ? n / 2 : 3 * n + 1;
        count++;
    }
    return count;
}

function longestCollatz(limit) {
    var bestN = 1, bestLen = 1;
    for (var i = 2; i <= limit; i++) {
        var len = collatzLength(i);
        if (len > bestLen) { bestLen = len; bestN = i; }
    }
    return { n: bestN, length: bestLen };
}

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

assert(collatzLength(1) === 1, "length(1)=1");
assert(collatzLength(2) === 2, "length(2)=2");
assert(collatzLength(6) === 9, "length(6)=9, got " + collatzLength(6));
assert(collatzLength(10) === 7, "length(10)=7, got " + collatzLength(10));
assert(collatzLength(27) === 112, "length(27)=112, got " + collatzLength(27));

var r = longestCollatz(100);
assert(r.n === 97, "longest under 100 is n=97, got n=" + r.n);
assert(r.length === 119, "length=119, got " + r.length);

print("engine/collatz: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

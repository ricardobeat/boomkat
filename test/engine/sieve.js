// Sieve of Eratosthenes
// Finds all primes up to a given limit.

function sieve(limit) {
    var flags = [];
    for (var i = 0; i <= limit; i++) flags.push(true);
    flags[0] = false;
    if (limit >= 1) flags[1] = false;
    for (var i = 2; i * i <= limit; i++) {
        if (flags[i]) {
            for (var j = i * i; j <= limit; j += i) flags[j] = false;
        }
    }
    var primes = [];
    for (var i = 2; i <= limit; i++) {
        if (flags[i]) primes.push(i);
    }
    return primes;
}

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

var p10 = sieve(10);
assert(p10.length === 4, "primes <= 10: 4, got " + p10.length);
assert(p10[0] === 2, "first prime is 2");
assert(p10[3] === 7, "4th prime <= 10 is 7");

var p30 = sieve(30);
assert(p30.length === 10, "primes <= 30: 10, got " + p30.length);
assert(p30[9] === 29, "last prime <= 30 is 29");

var p100 = sieve(100);
assert(p100.length === 25, "primes <= 100: 25, got " + p100.length);
assert(p100[24] === 97, "last prime <= 100 is 97");

print("engine/sieve: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

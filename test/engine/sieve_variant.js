// Sieve of Eratosthenes (variant)
// Bit-array sieve for efficiency; alternative formulation.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

// Standard sieve
function sieve(n) {
    var composite = new Array(n + 1);
    var primes = [];
    for (var i = 2; i <= n; i++) {
        if (composite[i]) continue;
        primes.push(i);
        for (var j = i * i; j <= n; j += i) composite[j] = true;
    }
    return primes;
}

var p = sieve(30);
assert(p[0] === 2 && p[1] === 3, "first two primes");
assert(p[p.length - 1] === 29, "largest under 30");
assert(p.length === 10, "10 primes <=30");

var known30 = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29];
for (var i = 0; i < p.length; i++) assert(p[i] === known30[i], "prime[" + i + "]=" + p[i]);

// 100 primes
var p100 = sieve(100);
assert(p100.length === 25, "25 primes <=100");

// 1000 primes: pi(1000) = 168
var p1000 = sieve(1000);
assert(p1000.length === 168, "168 primes <=1000");

// Nth prime
function nthPrime(n) { return sieve(n * 15)[n - 1]; }
assert(nthPrime(1) === 2, "1st=2");
assert(nthPrime(6) === 13, "6th=13");
assert(nthPrime(25) === 97, "25th=97");

// Twin primes under 100: (3,5), (5,7), (11,13), (17,19), (29,31), (41,43), (59,61), (71,73)
var twins = [];
for (var i = 0; i < p100.length - 1; i++) {
    if (p100[i + 1] - p100[i] === 2) twins.push([p100[i], p100[i + 1]]);
}
assert(twins.length === 8, "8 twin primes <=100");

print("engine/sieve_variant: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
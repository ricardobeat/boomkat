// Primality by trial division
// Tests if a number is prime by checking divisibility up to sqrt(n).

function isPrime(n) {
    if (n < 2) return false;
    if (n < 4) return true;
    if (n % 2 === 0 || n % 3 === 0) return false;
    for (var i = 5; i * i <= n; i += 6) {
        if (n % i === 0 || n % (i + 2) === 0) return false;
    }
    return true;
}

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

assert(isPrime(0) === false, "0 not prime");
assert(isPrime(1) === false, "1 not prime");
assert(isPrime(2) === true, "2 is prime");
assert(isPrime(3) === true, "3 is prime");
assert(isPrime(4) === false, "4 not prime");
assert(isPrime(17) === true, "17 is prime");
assert(isPrime(25) === false, "25 not prime");
assert(isPrime(97) === true, "97 is prime");
assert(isPrime(100) === false, "100 not prime");
assert(isPrime(7919) === true, "7919 is prime");

print("engine/primality: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

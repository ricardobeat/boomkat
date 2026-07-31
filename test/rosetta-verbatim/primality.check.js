import { isPrime } from "./primality.js";
import { assert, assertImported, report } from "./_harness.js";
assertImported(isPrime, "isPrime");
var primes = [2, 3, 5, 7, 11, 13, 97, 7919];
for (var i = 0; i < primes.length; i++) assert(isPrime(primes[i]), primes[i] + " is prime");
var composites = [0, 1, 4, 9, 25, 91, 100];
for (var j = 0; j < composites.length; j++) assert(!isPrime(composites[j]), composites[j] + " is not prime");
assert(!isPrime(-7), "negative is not prime");
report("primality");

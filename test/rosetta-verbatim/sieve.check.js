import { eratosthenes } from "./sieve.js";
import { assertEq, assertImported, report } from "./_harness.js";

assertImported(eratosthenes, "eratosthenes");
assertEq(eratosthenes(1).length, 0, "no primes below 2");
// limit == 2 is the boundary of the sample's `limit >= 2` guard.
assertEq(eratosthenes(2).join(","), "2", "limit exactly 2 yields [2]");
assertEq(eratosthenes(10).join(","), "2,3,5,7", "primes to 10");
assertEq(eratosthenes(30).join(","), "2,3,5,7,11,13,17,19,23,29", "primes to 30");
assertEq(eratosthenes(100).length, 25, "25 primes below 100");
assertEq(eratosthenes(1000).length, 168, "168 primes below 1000");
report("sieve");

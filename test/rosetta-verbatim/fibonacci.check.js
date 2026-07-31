import { fib } from "./fibonacci.js";
import { assertEq, assertImported, report } from "./_harness.js";

assertImported(fib, "fib");
assertEq(fib(0), 0, "fib(0)");
assertEq(fib(1), 1, "fib(1)");
assertEq(fib(10), 55, "fib(10)");
assertEq(fib(20), 6765, "fib(20)");
// Naive exponential recursion; 25 is deep enough to exercise call overhead
// without making the suite slow.
assertEq(fib(25), 75025, "fib(25)");
report("fibonacci");

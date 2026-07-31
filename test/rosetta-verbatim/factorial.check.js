// Drives factorial.js -- uses: factorial

assertEq(factorial(0), 1, "0!");
assertEq(factorial(1), 1, "1!");
assertEq(factorial(5), 120, "5!");
assertEq(factorial(10), 3628800, "10!");

// The sample throws a bare string, not an Error.
var threw = false;
try { factorial(-1); } catch (e) { threw = (e === "Number must be non-negative"); }
assert(threw, "negative input throws the sample's string");
report("factorial");

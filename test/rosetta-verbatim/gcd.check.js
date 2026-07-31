// Drives gcd.js -- uses: gcd

assertEq(gcd(12, 8), 4, "gcd(12,8)");
assertEq(gcd(8, 12), 4, "gcd(8,12) argument order");
assertEq(gcd(-12, 8), 4, "negative input uses abs");
assertEq(gcd(37, 600), 1, "coprime");
assertEq(gcd(624129, 2061517), 18913, "large pair");

// The sample's loop has two exit branches. Coprime and general pairs above all
// return from `b === 0`; a pair where one argument divides the other is what
// reaches `a === 0`, so these cover the branch the rest miss.
assertEq(gcd(1, 5), 1, "gcd(1,5) exits via the a===0 branch");
assertEq(gcd(4, 8), 4, "gcd(4,8) divisor pair");
assertEq(gcd(9, 3), 3, "gcd(9,3) divisor pair, larger first");
report("gcd");

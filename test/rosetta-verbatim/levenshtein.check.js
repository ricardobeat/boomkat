// Drives levenshtein.js -- uses: levenshtein
// The sample runs its own 12-case table at import time and console.log()s only
// on mismatch, so a silent import is itself a pass. These assertions re-check
// the same values directly so the suite reports a count rather than silence.

assertEq(levenshtein("", ""), 0, "empty/empty");
assertEq(levenshtein("yo", ""), 2, "yo/empty");
assertEq(levenshtein("", "yo"), 2, "empty/yo");
assertEq(levenshtein("kitten", "sitting"), 3, "kitten/sitting");
assertEq(levenshtein("saturday", "sunday"), 3, "saturday/sunday");
assertEq(levenshtein("rosettacode", "raisethysword"), 8, "rosettacode/raisethysword");
assertEq(levenshtein("mississippi", "swiss miss"), 8, "mississippi/swiss miss");
report("levenshtein");

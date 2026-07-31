// Drives conditionals.js -- uses: takeWhile
function lt(n) { return function (x) { return x < n; }; }
assertEq(takeWhile([1, 2, 3, 9, 4], lt(5)).join(","), "1,2,3", "stops at first failure");
assertEq(takeWhile([9, 1], lt(5)).join(","), "", "head fails immediately");
assertEq(takeWhile([], lt(5)).join(","), "", "empty list");
assertEq(takeWhile([1, 2], lt(5)).join(","), "1,2", "all pass");
report("conditionals");

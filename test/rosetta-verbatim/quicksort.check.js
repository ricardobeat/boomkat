// Drives quicksort.js -- uses: sort

function asc(a, b) { return a < b; }

assertEq(sort([], asc).join(","), "", "empty array");
assertEq(sort([1], asc).join(","), "1", "single element");
assertEq(sort([3, 1, 2], asc).join(","), "1,2,3", "three elements");
assertEq(sort([5, 3, 7, 3, 5], asc).join(","), "3,3,5,5,7", "duplicates");
assertEq(sort([9, 8, 7, 6, 5, 4, 3, 2, 1], asc).join(","), "1,2,3,4,5,6,7,8,9", "reversed");

// The sample sorts in place and returns the same array object.
var orig = [2, 1];
assertEq(sort(orig, asc), orig, "sorts in place, returns same array");
report("quicksort");

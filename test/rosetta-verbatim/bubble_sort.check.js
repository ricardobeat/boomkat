// Drives bubble_sort.js
// The sample installs bubblesort on Array.prototype rather than defining a
// standalone function, so the assertions below go through the prototype.
assert(typeof [].bubblesort === "function", "bubblesort installed on Array.prototype");
assertEq([4, 65, 2, -31, 0, 99, 2, 83].bubblesort().join(","), "-31,0,2,2,4,65,83,99", "sorts with duplicates");
assertEq([].bubblesort().join(","), "", "empty array");
assertEq([1].bubblesort().join(","), "1", "single element");
var a = [2, 1];
assertEq(a.bubblesort(), a, "sorts in place, returns the same array");
report("bubble_sort");

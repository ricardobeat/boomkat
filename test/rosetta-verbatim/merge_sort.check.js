import { mergeSort } from "./merge_sort.js";
import { assertEq, assertImported, report } from "./_harness.js";
assertImported(mergeSort, "mergeSort");
// mergeSort sorts in place and returns undefined.
function sorted(a) { mergeSort(a); return a.join(","); }
assertEq(sorted([1]), "1", "single element");
assertEq(sorted([2, 1]), "1,2", "two elements");
assertEq(sorted([3, 1, 2]), "1,2,3", "odd length");
assertEq(sorted([5, 3, 7, 3, 5, 1]), "1,3,3,5,5,7", "duplicates");
assertEq(sorted([9, 8, 7, 6, 5, 4, 3, 2, 1]), "1,2,3,4,5,6,7,8,9", "reversed");
report("merge_sort");

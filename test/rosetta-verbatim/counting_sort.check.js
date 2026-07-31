import { countSort } from "./counting_sort.js";
import { assertEq, assertImported, report } from "./_harness.js";
assertImported(countSort, "countSort");
// countSort sorts in place and returns undefined; the caller supplies the range.
var a = [3, 1, 2, 3, 1];
countSort(a, 1, 3);
assertEq(a.join(","), "1,1,2,3,3", "sorts with duplicates");
var b = [5];
countSort(b, 5, 5);
assertEq(b.join(","), "5", "single element, degenerate range");
var c = [2, -1, 0];
countSort(c, -1, 2);
assertEq(c.join(","), "-1,0,2", "negative values");
report("counting_sort");

// Drives binary_search.js -- uses: binary_search_recursive

var a = [1, 3, 5, 7, 9, 11];
function find(v) { return binary_search_recursive(a, v, 0, a.length - 1); }

assertEq(find(1), 0, "first element");
assertEq(find(11), 5, "last element");
assertEq(find(7), 3, "middle element");
assertEq(find(4), null, "absent value returns null");
assertEq(find(99), null, "above range returns null");
report("binary_search");

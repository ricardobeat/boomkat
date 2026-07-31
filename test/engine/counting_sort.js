// Sorting algorithms / Counting sort
// Integer sort O(n+k) using a frequency array.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function countingSort(arr, min, max) {
    if (min === undefined) min = 0;
    if (max === undefined) max = 9;
    var counts = new Array(max - min + 1);
    for (var i = 0; i < counts.length; i++) counts[i] = 0;
    for (var i = 0; i < arr.length; i++) counts[arr[i] - min]++;
    var out = [];
    for (var v = min; v <= max; v++) {
        for (var k = 0; k < counts[v - min]; k++) out.push(v);
    }
    return out;
}

assert(JSON.stringify(countingSort([3, 1, 4, 1, 5, 9, 2, 6])) === "[1,1,2,3,4,5,6,9]", "basic");
assert(JSON.stringify(countingSort([])) === "[]", "empty");
assert(JSON.stringify(countingSort([5, 4, 3, 2, 1])) === "[1,2,3,4,5]", "reverse");
assert(JSON.stringify(countingSort([3, 3, 3])) === "[3,3,3]", "all same");

// Custom range
assert(JSON.stringify(countingSort([105, 102, 110, 101], 100, 110)) === "[101,102,105,110]", "custom range");

// Stability property: by index, then value
function stableCountingSort(arr) {
    var out = [];
    for (var v = 0; v <= 9; v++) {
        for (var i = 0; i < arr.length; i++) {
            if (arr[i] === v) out.push(v);
        }
    }
    return out;
}

assert(JSON.stringify(stableCountingSort([3, 1, 4, 1, 5, 9, 2, 6])) === "[1,1,2,3,4,5,6,9]", "stable");

print("engine/counting_sort: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
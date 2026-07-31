// Merge sort
// Recursive top-down merge sort.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function mergeSort(a) {
    if (a.length <= 1) return a;
    var mid = a.length >> 1;
    var left = mergeSort(a.slice(0, mid));
    var right = mergeSort(a.slice(mid));
    return merge(left, right);
}

function merge(a, b) {
    var out = [];
    var i = 0, j = 0;
    while (i < a.length && j < b.length) {
        if (a[i] <= b[j]) { out.push(a[i]); i++; }
        else { out.push(b[j]); j++; }
    }
    while (i < a.length) { out.push(a[i]); i++; }
    while (j < b.length) { out.push(b[j]); j++; }
    return out;
}

assert(JSON.stringify(mergeSort([5, 3, 8, 1, 4, 9, 2, 7, 6])) === "[1,2,3,4,5,6,7,8,9]", "basic");
assert(JSON.stringify(mergeSort([])) === "[]", "empty");
assert(JSON.stringify(mergeSort([42])) === "[42]", "single");
assert(JSON.stringify(mergeSort([2, 2, 1, 1, 3, 3])) === "[1,1,2,2,3,3]", "dups");

// Large random check vs Array.prototype.sort
function shuffled(n) {
    var a = [];
    for (var i = 0; i < n; i++) a.push(i);
    for (var i = n - 1; i > 0; i--) {
        var j = Math.floor(Math.random() * (i + 1));
        var t = a[i]; a[i] = a[j]; a[j] = t;
    }
    return a;
}

var arr = shuffled(50);
var sorted = mergeSort(arr);
var expected = arr.slice().sort(function (x, y) { return x - y; });
assert(JSON.stringify(sorted) === JSON.stringify(expected), "shuffled 50");

print("engine/merge_sort: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
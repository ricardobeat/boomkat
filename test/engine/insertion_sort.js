// Sorting algorithms / Insertion sort
// In-place sort: shifts elements down until each lands in its slot.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function insertionSort(input) {
    var a = input.slice();
    for (var i = 1; i < a.length; i++) {
        var key = a[i];
        var j = i - 1;
        for (; j >= 0; j--) {
            if (a[j] <= key) break;
            a[j + 1] = a[j];
        }
        a[j + 1] = key;
    }
    return a;
}

assert(JSON.stringify(insertionSort([5, 3, 1, 4, 2])) === "[1,2,3,4,5]", "basic");
assert(JSON.stringify(insertionSort([])) === "[]", "empty");
assert(JSON.stringify(insertionSort([1])) === "[1]", "single");
assert(JSON.stringify(insertionSort([2, 2, 2, 1])) === "[1,2,2,2]", "dups");
assert(JSON.stringify(insertionSort([9, 8, 7, 6, 5, 4, 3, 2, 1])) === "[1,2,3,4,5,6,7,8,9]", "reverse");

// Verify insertion sort produces the same ordering as Array.prototype.sort
function shuffled(n) {
    var a = [];
    for (var i = 0; i < n; i++) a.push(i);
    // Fisher-Yates
    for (var i = n - 1; i > 0; i--) {
        var j = Math.floor(Math.random() * (i + 1));
        var t = a[i]; a[i] = a[j]; a[j] = t;
    }
    return a;
}

var arr = shuffled(30);
var sorted = insertionSort(arr.slice());
var expected = arr.slice().sort(function (x, y) { return x - y; });
assert(JSON.stringify(sorted) === JSON.stringify(expected), "shuffled 30");

print("engine/insertion_sort: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
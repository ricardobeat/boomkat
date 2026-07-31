// Sorting algorithms / Heap sort
// In-place sort using a max-heap.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function siftDown(a, start, end) {
    var root = start;
    while (root * 2 + 1 <= end) {
        var child = root * 2 + 1;
        var swap = root;
        if (a[swap] < a[child]) swap = child;
        if (child + 1 <= end && a[swap] < a[child + 1]) swap = child + 1;
        if (swap === root) {
            return;
        } else {
            var tmp = a[root];
            a[root] = a[swap];
            a[swap] = tmp;
            root = swap;
        }
    }
}

function heapSort(arr) {
    var a = arr.slice();
    var n = a.length;
    var start = Math.floor((n - 2) / 2);
    while (start >= 0) {
        siftDown(a, start, n - 1);
        start--;
    }
    var end = n - 1;
    while (end > 0) {
        var tmp = a[end];
        a[end] = a[0];
        a[0] = tmp;
        end--;
        siftDown(a, 0, end);
    }
    return a;
}

var result = heapSort([5, 3, 8, 1, 9, 2]);
var expected = [1, 2, 3, 5, 8, 9];
assert(JSON.stringify(result) === JSON.stringify(expected),
    "heap_sort: expected " + JSON.stringify(expected) + ", got " + JSON.stringify(result));

print("engine/heap_sort: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

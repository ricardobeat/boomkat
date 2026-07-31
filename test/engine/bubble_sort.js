// Sorting algorithms/Bubble sort

function bubbleSort(arr) {
    var a = arr.slice();
    var n = a.length;
    for (var i = 0; i < n - 1; i++) {
        for (var j = 0; j < n - i - 1; j++) {
            if (a[j] > a[j + 1]) {
                var tmp = a[j];
                a[j] = a[j + 1];
                a[j + 1] = tmp;
            }
        }
    }
    return a;
}

function arrayEq(a, b) {
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) {
        if (a[i] !== b[i]) return false;
    }
    return true;
}

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

assert(arrayEq(bubbleSort([]), []), "empty");
assert(arrayEq(bubbleSort([1]), [1]), "single");
assert(arrayEq(bubbleSort([3,1,2]), [1,2,3]), "3,1,2");
assert(arrayEq(bubbleSort([5,4,3,2,1]), [1,2,3,4,5]), "reverse");
assert(arrayEq(bubbleSort([1,2,3,4,5]), [1,2,3,4,5]), "sorted");
assert(arrayEq(bubbleSort([3,3,1,1,2,2]), [1,1,2,2,3,3]), "duplicates");

print("engine/bubble_sort: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

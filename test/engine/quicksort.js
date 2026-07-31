// Sorting algorithms/Quicksort

function quickSort(arr) {
    var a = arr.slice();
    function qs(lo, hi) {
        if (lo >= hi) return;
        var pivot = a[Math.floor((lo + hi) / 2)];
        var i = lo, j = hi;
        while (i <= j) {
            while (a[i] < pivot) i++;
            while (a[j] > pivot) j--;
            if (i <= j) {
                var tmp = a[i]; a[i] = a[j]; a[j] = tmp;
                i++; j--;
            }
        }
        if (lo < j) qs(lo, j);
        if (i < hi) qs(i, hi);
    }
    qs(0, a.length - 1);
    return a;
}

function arrayEq(a, b) {
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) { if (a[i] !== b[i]) return false; }
    return true;
}

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

assert(arrayEq(quickSort([]), []), "empty");
assert(arrayEq(quickSort([42]), [42]), "single");
assert(arrayEq(quickSort([3,6,8,10,1,2,1]), [1,1,2,3,6,8,10]), "general");
assert(arrayEq(quickSort([5,4,3,2,1]), [1,2,3,4,5]), "reverse");
assert(arrayEq(quickSort([1,1,1,1]), [1,1,1,1]), "all same");
assert(arrayEq(quickSort([100,-5,0,3,-2]), [-5,-2,0,3,100]), "negatives");

print("engine/quicksort: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

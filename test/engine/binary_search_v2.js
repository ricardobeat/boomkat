// Binary search
// Classic iterative + recursive binary search.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function binarySearchIter(arr, target) {
    var lo = 0, hi = arr.length - 1;
    while (lo <= hi) {
        var mid = (lo + hi) >> 1;
        if (arr[mid] === target) return mid;
        if (arr[mid] < target) lo = mid + 1;
        else hi = mid - 1;
    }
    return -1;
}

function binarySearchRec(arr, target, lo, hi) {
    if (lo === undefined) lo = 0;
    if (hi === undefined) hi = arr.length - 1;
    if (lo > hi) return -1;
    var mid = (lo + hi) >> 1;
    if (arr[mid] === target) return mid;
    if (arr[mid] < target) return binarySearchRec(arr, target, mid + 1, hi);
    return binarySearchRec(arr, target, lo, mid - 1);
}

var data = [1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21];
assert(binarySearchIter(data, 7) === 3, "iter hit 7");
assert(binarySearchIter(data, 1) === 0, "iter first");
assert(binarySearchIter(data, 21) === 10, "iter last");
assert(binarySearchIter(data, 8) === -1, "iter miss");
assert(binarySearchIter([], 1) === -1, "iter empty");

assert(binarySearchRec(data, 7) === 3, "rec hit 7");
assert(binarySearchRec(data, 21) === 10, "rec last");
assert(binarySearchRec(data, 100) === -1, "rec miss");
assert(binarySearchRec([], 1) === -1, "rec empty");

// Lower bound: first index where arr[i] >= target
function lowerBound(arr, target) {
    var lo = 0, hi = arr.length;
    while (lo < hi) {
        var mid = (lo + hi) >> 1;
        if (arr[mid] < target) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}

assert(lowerBound([1, 2, 4, 4, 4, 7], 4) === 2, "lb 4");
assert(lowerBound([1, 2, 4, 4, 4, 7], 5) === 5, "lb 5");
assert(lowerBound([1, 2, 4, 4, 4, 7], 0) === 0, "lb 0");
assert(lowerBound([1, 2, 4, 4, 4, 7], 8) === 6, "lb 8");

print("engine/binary_search_v2: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
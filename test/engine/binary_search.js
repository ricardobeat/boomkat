// Binary search
// Returns index of target in sorted array, or -1.

function binarySearch(arr, target) {
    var lo = 0, hi = arr.length - 1;
    while (lo <= hi) {
        var mid = Math.floor((lo + hi) / 2);
        if (arr[mid] === target) return mid;
        else if (arr[mid] < target) lo = mid + 1;
        else hi = mid - 1;
    }
    return -1;
}

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

var a = [1, 3, 5, 7, 9, 11, 13, 15, 17, 19];
assert(binarySearch(a, 1) === 0, "find 1 at 0");
assert(binarySearch(a, 19) === 9, "find 19 at 9");
assert(binarySearch(a, 7) === 3, "find 7 at 3");
assert(binarySearch(a, 10) === -1, "10 not found");
assert(binarySearch([], 5) === -1, "empty array");
assert(binarySearch([42], 42) === 0, "single found");
assert(binarySearch([42], 0) === -1, "single not found");

print("engine/binary_search: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

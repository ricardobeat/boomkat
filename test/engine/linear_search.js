// Linear search

function linearSearch(arr, target) {
    for (var i = 0; i < arr.length; i++) {
        if (arr[i] === target) return i;
    }
    return -1;
}

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

var a = [10, 20, 30, 40, 50];
assert(linearSearch(a, 30) === 2, "find 30 at 2");
assert(linearSearch(a, 10) === 0, "find 10 at 0");
assert(linearSearch(a, 50) === 4, "find 50 at 4");
assert(linearSearch(a, 99) === -1, "99 not found");
assert(linearSearch([], 1) === -1, "empty");
assert(linearSearch([7], 7) === 0, "single found");
assert(linearSearch([7], 8) === -1, "single not found");

print("engine/linear_search: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

// Selection sort
// Repeatedly swap the smallest remaining element into position i.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function selectionSort(a) {
    for (var i = 0; i < a.length - 1; i++) {
        var minIdx = i;
        for (var j = i + 1; j < a.length; j++) {
            if (a[j] < a[minIdx]) minIdx = j;
        }
        if (minIdx !== i) {
            var t = a[i]; a[i] = a[minIdx]; a[minIdx] = t;
        }
    }
    return a;
}

assert(JSON.stringify(selectionSort([64, 25, 12, 22, 11])) === "[11,12,22,25,64]", "basic");
assert(JSON.stringify(selectionSort([])) === "[]", "empty");
assert(JSON.stringify(selectionSort([1, 2, 3])) === "[1,2,3]", "sorted");
assert(JSON.stringify(selectionSort([3, 2, 1])) === "[1,2,3]", "reverse");

// Verify property: identical element count
function isPermutation(a, b) {
    if (a.length !== b.length) return false;
    var ca = {}, cb = {};
    for (var i = 0; i < a.length; i++) {
        ca[a[i]] = (ca[a[i]] || 0) + 1;
        cb[b[i]] = (cb[b[i]] || 0) + 1;
    }
    for (var k in ca) if (ca[k] !== cb[k]) return false;
    return true;
}

var input = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5];
var s = selectionSort(input.slice());
assert(s.length === input.length, "length preserved");
assert(isPermutation(s, input), "permutation");
assert(s[0] <= s[s.length - 1], "monotonic non-decreasing");

print("engine/selection_sort: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
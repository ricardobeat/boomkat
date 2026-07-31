// Sorting algorithms / Shell sort
// Gapped insertion sort with diminishing gap sequence.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function shellSort(arr) {
    var a = arr.slice();
    var n = a.length;
    var gap = Math.floor(n / 2);
    while (gap > 0) {
        for (var i = gap; i < n; i++) {
            var temp = a[i];
            var j = i;
            while (j >= gap && a[j - gap] > temp) {
                a[j] = a[j - gap];
                j -= gap;
            }
            a[j] = temp;
        }
        gap = Math.floor(gap / 2);
    }
    return a;
}

var result = shellSort([5, 3, 8, 1, 9, 2]);
var expected = [1, 2, 3, 5, 8, 9];
assert(JSON.stringify(result) === JSON.stringify(expected),
    "shell_sort: expected " + JSON.stringify(expected) + ", got " + JSON.stringify(result));

print("engine/shell_sort: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

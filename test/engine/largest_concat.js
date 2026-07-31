// Largest int from concatenated ints
// Given a list of ints, permute them so the concatenation is maximal.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function largestConcatenation(nums) {
    // Compare as strings: (b+a) > (a+b) means b should come before a
    var strs = [];
    for (var i = 0; i < nums.length; i++) strs.push(String(nums[i]));
    strs.sort(function (a, b) {
        if (a + b > b + a) return -1;
        if (a + b < b + a) return 1;
        return 0;
    });
    // Edge: all zeros
    if (strs[0] === "0") return "0";
    return strs.join("");
}

assert(largestConcatenation([1, 2, 3]) === "321", "[1,2,3] -> 321");
assert(largestConcatenation([10, 2, 9, 39, 17]) === "93921710", "sample 1");
assert(largestConcatenation([1, 10, 100]) === "110100", "1,10,100 -> 110100");
assert(largestConcatenation([5, 50, 56]) === "56550", "5,50,56 -> 56550");
assert(largestConcatenation([0, 0, 0]) === "0", "all zeros -> 0");
assert(largestConcatenation([42]) === "42", "single");
assert(largestConcatenation([]) === "", "empty");

print("engine/largest_concat: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
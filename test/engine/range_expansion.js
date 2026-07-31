// Range expansion
// "1,3,5-9,12" -> [1,3,5,6,7,8,9,12]

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function expandRange(s) {
    var out = [];
    if (s === "") return out;
    var parts = s.split(",");
    for (var i = 0; i < parts.length; i++) {
        var p = parts[i];
        var dash = p.indexOf("-");
        if (dash === -1) {
            out.push(parseInt(p, 10));
        } else {
            var lo = parseInt(p.substring(0, dash), 10);
            var hi = parseInt(p.substring(dash + 1), 10);
            for (var n = lo; n <= hi; n++) out.push(n);
        }
    }
    return out;
}

function compressRange(nums) {
    if (nums.length === 0) return "";
    var out = [];
    var i = 0;
    while (i < nums.length) {
        var start = nums[i];
        var end = start;
        while (i + 1 < nums.length && nums[i + 1] === end + 1) {
            i++;
            end = nums[i];
        }
        var span = end - start;
        if (span >= 2) {
            out.push(start + "-" + end);
        } else if (span === 1) {
            out.push(String(start));
            out.push(String(end));
        } else {
            out.push(String(start));
        }
        i++;
    }
    return out.join(",");
}

function arrayEq(a, b) {
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
}

assert(arrayEq(expandRange("1,3,5-9,12"), [1, 3, 5, 6, 7, 8, 9, 12]), "1,3,5-9,12");
assert(arrayEq(expandRange("0-5"), [0, 1, 2, 3, 4, 5]), "0-5");
assert(arrayEq(expandRange("7"), [7]), "single 7");
assert(arrayEq(expandRange("3-3"), [3]), "single 3-3");
assert(arrayEq(expandRange(""), []), "empty -> empty");

assert(compressRange([]) === "", "compress empty");
assert(compressRange([7]) === "7", "compress single");
assert(compressRange([0, 1, 2, 3, 4, 5]) === "0-5", "compress 0-5");
assert(compressRange([1, 3, 5, 6, 7, 8, 9, 12]) === "1,3,5-9,12", "compress mixed");
assert(compressRange([0, 1, 2, 4, 6, 7, 8]) === "0-2,4,6-8", "compress gaps");
assert(compressRange([1, 2]) === "1,2", "compress two adjacent");

print("engine/range_expansion: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
// Levenshtein distance
// Edit distance with insert/delete/substitute operations.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function levenshtein(a, b) {
    if (a === b) return 0;
    if (a.length === 0) return b.length;
    if (b.length === 0) return a.length;

    var prev = new Array(b.length + 1);
    var curr = new Array(b.length + 1);
    for (var j = 0; j <= b.length; j++) prev[j] = j;

    for (var i = 1; i <= a.length; i++) {
        curr[0] = i;
        for (var j = 1; j <= b.length; j++) {
            var cost = a[i - 1] === b[j - 1] ? 0 : 1;
            curr[j] = Math.min(
                curr[j - 1] + 1,        // insert
                prev[j] + 1,            // delete
                prev[j - 1] + cost      // substitute
            );
        }
        for (var j2 = 0; j2 <= b.length; j2++) prev[j2] = curr[j2];
    }
    return prev[b.length];
}

assert(levenshtein("", "") === 0, "empty-empty=0");
assert(levenshtein("abc", "abc") === 0, "abc-abc=0");
assert(levenshtein("abc", "") === 3, "abc-empty=3");
assert(levenshtein("", "abc") === 3, "empty-abc=3");
assert(levenshtein("kitten", "sitting") === 3, "kitten-sitting=3");
assert(levenshtein("saturday", "sunday") === 3, "saturday-sunday=3");
assert(levenshtein("rosettacode", "raisethysword") === 8, "rosetta-raisethysword=8");

// Symmetry
assert(levenshtein("abcdef", "azced") === levenshtein("azced", "abcdef"), "symmetric");

// Triangle inequality: d(a,c) <= d(a,b) + d(b,c)
var d1 = levenshtein("abc", "abd");
var d2 = levenshtein("abd", "abe");
var d3 = levenshtein("abc", "abe");
assert(d3 <= d1 + d2, "triangle inequality");

print("engine/levenshtein: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
// Sequence of non-squares
// Sequence: a(n) = n + round(sqrt(n)).

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function nonSquares(n) {
    var out = [];
    for (var i = 1; i <= n; i++) out.push(i + Math.round(Math.sqrt(i)));
    return out;
}

// First 22 non-squares: 2,3,5,6,7,8,10,11,12,13,14,15,17,18,19,20,21,22,23,24,26,27
var expected = [2, 3, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 22, 23, 24, 26, 27];
var got = nonSquares(22);
for (var i = 0; i < 22; i++) assert(got[i] === expected[i], "[" + i + "]=" + got[i] + " (expected " + expected[i] + ")");

// Verify: no squares in the sequence
function isSquare(n) {
    var r = Math.sqrt(n) | 0;
    return r * r === n;
}

for (var i = 0; i < got.length; i++) assert(!isSquare(got[i]), "got[" + i + "]=" + got[i] + " is not a square");

print("engine/non_squares: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
// Pascal's triangle
// Generate rows of binomial coefficients.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function pascalRow(n) {
    if (n === 0) return [1];
    var prev = [1];
    for (var i = 1; i <= n; i++) {
        var row = [1];
        for (var j = 1; j < i; j++) row.push(prev[j - 1] + prev[j]);
        row.push(1);
        prev = row;
    }
    return prev;
}

function pascal(n) {
    var rows = [];
    for (var i = 0; i < n; i++) rows.push(pascalRow(i));
    return rows;
}

var tri = pascal(7);
assert(tri[0].length === 1 && tri[0][0] === 1, "row 0 = [1]");
assert(tri[1][0] === 1 && tri[1][1] === 1, "row 1 = [1,1]");
assert(tri[2][0] === 1 && tri[2][1] === 2 && tri[2][2] === 1, "row 2 = [1,2,1]");
assert(tri[3][0] === 1 && tri[3][3] === 1, "row 3 first and last");
assert(tri[4][1] === 4 && tri[4][2] === 6, "row 4 [1]=4 [2]=6");
assert(tri[6][3] === 20, "row 6 [3]=20");

// Sum of row n is 2^n
function rowSum(row) {
    var s = 0;
    for (var i = 0; i < row.length; i++) s += row[i];
    return s;
}

for (var k = 0; k <= 10; k++) {
    var rs = rowSum(tri[Math.min(k, 6)]);
    // Recompute since we only have 7 rows
    if (k < 7) {
        var expected = 1 << k;
        assert(rs === expected, "sum row " + k + " = " + expected);
    }
}

print("engine/pascal: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
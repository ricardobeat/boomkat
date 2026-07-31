// Matrix transposition

function transpose(m) {
    var rows = m.length, cols = m[0].length;
    var t = [];
    for (var j = 0; j < cols; j++) {
        t[j] = [];
        for (var i = 0; i < rows; i++) {
            t[j][i] = m[i][j];
        }
    }
    return t;
}

function matrixEq(a, b) {
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) {
        if (a[i].length !== b[i].length) return false;
        for (var j = 0; j < a[i].length; j++) {
            if (a[i][j] !== b[i][j]) return false;
        }
    }
    return true;
}

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

var m1 = [[1,2,3],[4,5,6]];
var t1 = transpose(m1);
assert(t1.length === 3, "3 rows");
assert(t1[0].length === 2, "2 cols");
assert(matrixEq(t1, [[1,4],[2,5],[3,6]]), "transpose 2x3");
assert(matrixEq(transpose(t1), m1), "double transpose = original");

var m2 = [[1]];
assert(matrixEq(transpose(m2), [[1]]), "1x1 transpose");

var m3 = [[1,2],[3,4]];
var t3 = transpose(m3);
assert(matrixEq(t3, [[1,3],[2,4]]), "2x2 transpose");

print("engine/matrix_transpose: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

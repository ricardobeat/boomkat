// Matrix multiplication

function matMul(a, b) {
    var rowsA = a.length, colsA = a[0].length, colsB = b[0].length;
    var c = [];
    for (var i = 0; i < rowsA; i++) {
        c[i] = [];
        for (var j = 0; j < colsB; j++) {
            var sum = 0;
            for (var k = 0; k < colsA; k++) sum += a[i][k] * b[k][j];
            c[i][j] = sum;
        }
    }
    return c;
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

// 2x3 * 3x2 = 2x2
var a = [[1,2,3],[4,5,6]];
var b = [[7,8],[9,10],[11,12]];
var r = matMul(a, b);
assert(r.length === 2, "result 2 rows");
assert(r[0].length === 2, "result 2 cols");
assert(matrixEq(r, [[58,64],[139,154]]), "2x3 * 3x2");

// Identity
var id = [[1,0],[0,1]];
var v = [[3,4],[5,6]];
assert(matrixEq(matMul(id, v), v), "identity * v = v");

// 1x1
assert(matrixEq(matMul([[3]], [[5]]), [[15]]), "3*5=15");

print("engine/matrix_multiply: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

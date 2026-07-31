// Matrix arithmetic
// Add, subtract, multiply, transpose 2D matrices.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function zeros(rows, cols) {
    var out = [];
    for (var i = 0; i < rows; i++) {
        var row = [];
        for (var j = 0; j < cols; j++) row.push(0);
        out.push(row);
    }
    return out;
}

function add(a, b) {
    var r = a.length, c = a[0].length;
    var out = zeros(r, c);
    for (var i = 0; i < r; i++) for (var j = 0; j < c; j++) out[i][j] = a[i][j] + b[i][j];
    return out;
}

function sub(a, b) {
    var r = a.length, c = a[0].length;
    var out = zeros(r, c);
    for (var i = 0; i < r; i++) for (var j = 0; j < c; j++) out[i][j] = a[i][j] - b[i][j];
    return out;
}

function transpose(a) {
    var r = a.length, c = a[0].length;
    var out = zeros(c, r);
    for (var i = 0; i < r; i++) for (var j = 0; j < c; j++) out[j][i] = a[i][j];
    return out;
}

function mul(a, b) {
    var ra = a.length, ca = a[0].length, cb = b[0].length;
    var out = zeros(ra, cb);
    for (var i = 0; i < ra; i++) {
        for (var k = 0; k < ca; k++) {
            for (var j = 0; j < cb; j++) {
                out[i][j] += a[i][k] * b[k][j];
            }
        }
    }
    return out;
}

function toStr(m) {
    var rows = [];
    for (var i = 0; i < m.length; i++) rows.push("[" + m[i].join(",") + "]");
    return "[" + rows.join(",") + "]";
}

// Basic add
var sum = add([[1, 2], [3, 4]], [[5, 6], [7, 8]]);
assert(toStr(sum) === "[[6,8],[10,12]]", "add basic");

// Sub
var diff = sub([[5, 6], [7, 8]], [[1, 2], [3, 4]]);
assert(toStr(diff) === "[[4,4],[4,4]]", "sub basic");

// Transpose
var t = transpose([[1, 2, 3], [4, 5, 6]]);
assert(toStr(t) === "[[1,4],[2,5],[3,6]]", "transpose");

// Multiply
var prod = mul([[1, 2], [3, 4]], [[5, 6], [7, 8]]);
assert(toStr(prod) === "[[19,22],[43,50]]", "mul 2x2");

// Identity
var I = [[1, 0], [0, 1]];
var prodI = mul(I, [[3, 4], [5, 6]]);
assert(toStr(prodI) === "[[3,4],[5,6]]", "I * A = A");

// Determinant (2x2)
function det2(a) { return a[0][0] * a[1][1] - a[0][1] * a[1][0]; }
assert(det2([[3, 8], [4, 6]]) === -14, "det 2x2");

print("engine/matrix_ops: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
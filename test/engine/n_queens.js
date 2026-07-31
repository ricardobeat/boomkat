// N-queens
// Place n non-attacking queens on an n×n board; backtracking solver.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function solveNQueens(n) {
    var solutions = [];
    var cols = new Array(n);
    var diag1 = {};
    var diag2 = {};

    function recurse(row, placement) {
        if (row === n) {
            solutions.push(placement.slice());
            return;
        }
        for (var c = 0; c < n; c++) {
            if (cols[c]) continue;
            var d1 = row - c;
            var d2 = row + c;
            if (diag1[d1] || diag2[d2]) continue;
            cols[c] = true;
            diag1[d1] = true;
            diag2[d2] = true;
            placement.push(c);
            recurse(row + 1, placement);
            placement.pop();
            cols[c] = false;
            delete diag1[d1];
            delete diag2[d2];
        }
    }

    recurse(0, []);
    return solutions;
}

function isValidSolution(sol) {
    var n = sol.length;
    for (var i = 0; i < n; i++) {
        for (var j = i + 1; j < n; j++) {
            if (sol[i] === sol[j]) return false;
            if (sol[i] - sol[j] === i - j) return false;
            if (sol[i] - sol[j] === j - i) return false;
        }
    }
    return true;
}

// Known answer counts: n=4 -> 2, n=5 -> 10, n=6 -> 4, n=7 -> 40, n=8 -> 92
var s4 = solveNQueens(4);
assert(s4.length === 2, "n=4 -> 2 solutions");
for (var i = 0; i < s4.length; i++) assert(isValidSolution(s4[i]), "valid s4[" + i + "]");

var s5 = solveNQueens(5);
assert(s5.length === 10, "n=5 -> 10 solutions");

var s6 = solveNQueens(6);
assert(s6.length === 4, "n=6 -> 4 solutions");

var s7 = solveNQueens(7);
assert(s7.length === 40, "n=7 -> 40 solutions");

var s8 = solveNQueens(8);
assert(s8.length === 92, "n=8 -> 92 solutions");

print("engine/n_queens: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
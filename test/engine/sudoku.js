// Sudoku (validator)
// Verify a 9x9 grid is a valid Sudoku solution.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function isValidSudoku(grid) {
    // Row check
    for (var r = 0; r < 9; r++) {
        var seen = {};
        for (var c = 0; c < 9; c++) {
            var v = grid[r][c];
            if (v < 1 || v > 9) return false;
            if (seen[v]) return false;
            seen[v] = true;
        }
    }
    // Column check
    for (var c = 0; c < 9; c++) {
        var seen = {};
        for (var r = 0; r < 9; r++) {
            var v = grid[r][c];
            if (seen[v]) return false;
            seen[v] = true;
        }
    }
    // 3x3 box check
    for (var br = 0; br < 3; br++) {
        for (var bc = 0; bc < 3; bc++) {
            var seen = {};
            for (var dr = 0; dr < 3; dr++) {
                for (var dc = 0; dc < 3; dc++) {
                    var v = grid[br * 3 + dr][bc * 3 + dc];
                    if (seen[v]) return false;
                    seen[v] = true;
                }
            }
        }
    }
    return true;
}

// A valid solved grid
var valid = [
    [5, 3, 4, 6, 7, 8, 9, 1, 2],
    [6, 7, 2, 1, 9, 5, 3, 4, 8],
    [1, 9, 8, 3, 4, 2, 5, 6, 7],
    [8, 5, 9, 7, 6, 1, 4, 2, 3],
    [4, 2, 6, 8, 5, 3, 7, 9, 1],
    [7, 1, 3, 9, 2, 4, 8, 5, 6],
    [9, 6, 1, 5, 3, 7, 2, 8, 4],
    [2, 8, 7, 4, 1, 9, 6, 3, 5],
    [3, 4, 5, 2, 8, 6, 1, 7, 9]
];
assert(isValidSudoku(valid), "valid solved grid");

// Invalid: duplicate 5 in first row
var dupRow = valid.slice();
dupRow[0] = valid[0].slice();
dupRow[0][0] = 5;
dupRow[0][1] = 5;
assert(!isValidSudoku(dupRow), "duplicate in row rejected");

// Invalid: duplicate in column
var dupCol = valid.slice();
dupCol[0] = valid[0].slice();
dupCol[0][0] = 9;
dupCol[5][0] = 9;
assert(!isValidSudoku(dupCol), "duplicate in column rejected");

// Invalid: out of range
var badRange = valid.slice();
badRange[0] = valid[0].slice();
badRange[0][0] = 0;
assert(!isValidSudoku(badRange), "out-of-range rejected");

print("engine/sudoku: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
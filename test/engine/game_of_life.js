// Conway's Game of Life
// Single-step iteration on a torus (wraparound edges).

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function makeGrid(rows, cols, val) {
    var g = [];
    for (var i = 0; i < rows; i++) {
        var row = [];
        for (var j = 0; j < cols; j++) row.push(val);
        g.push(row);
    }
    return g;
}

function countNeighbors(grid, r, c) {
    var rows = grid.length, cols = grid[0].length;
    var n = 0;
    for (var dr = -1; dr <= 1; dr++) {
        for (var dc = -1; dc <= 1; dc++) {
            if (dr === 0 && dc === 0) continue;
            var nr = (r + dr + rows) % rows;
            var nc = (c + dc + cols) % cols;
            n += grid[nr][nc];
        }
    }
    return n;
}

function step(grid) {
    var rows = grid.length, cols = grid[0].length;
    var next = makeGrid(rows, cols, 0);
    for (var r = 0; r < rows; r++) {
        for (var c = 0; c < cols; c++) {
            var n = countNeighbors(grid, r, c);
            if (grid[r][c] === 1) {
                next[r][c] = (n === 2 || n === 3) ? 1 : 0;
            } else {
                next[r][c] = (n === 3) ? 1 : 0;
            }
        }
    }
    return next;
}

function gridEqual(a, b) {
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) {
        for (var j = 0; j < a[i].length; j++) {
            if (a[i][j] !== b[i][j]) return false;
        }
    }
    return true;
}

// Blinker: 3 cells in a row -> oscillates between horizontal and vertical
var blinker = makeGrid(5, 5, 0);
blinker[2][1] = 1; blinker[2][2] = 1; blinker[2][3] = 1;
var blinkerV = makeGrid(5, 5, 0);
blinkerV[1][2] = 1; blinkerV[2][2] = 1; blinkerV[3][2] = 1;
var step1 = step(blinker);
assert(gridEqual(step1, blinkerV), "blinker rotates to vertical");

var step2 = step(step1);
assert(gridEqual(step2, blinker), "blinker rotates back to horizontal");

// Block: still life
var block = makeGrid(4, 4, 0);
block[1][1] = 1; block[1][2] = 1; block[2][1] = 1; block[2][2] = 1;
var stepB = step(block);
assert(gridEqual(stepB, block), "block is still life");

// Empty: stays empty
var empty = makeGrid(3, 3, 0);
assert(gridEqual(step(empty), empty), "empty grid stays empty");

// Population count
function popCount(g) {
    var n = 0;
    for (var i = 0; i < g.length; i++) for (var j = 0; j < g[i].length; j++) n += g[i][j];
    return n;
}

assert(popCount(blinker) === 3, "blinker population = 3");
assert(popCount(block) === 4, "block population = 4");

print("engine/game_of_life: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
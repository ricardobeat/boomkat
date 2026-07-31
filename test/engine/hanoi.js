// Tower of Hanoi
// Classic recursive puzzle.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function hanoi(n, from, to, via, moves) {
    if (moves === undefined) moves = [];
    if (n === 0) return moves;
    hanoi(n - 1, from, via, to, moves);
    moves.push([from, to]);
    hanoi(n - 1, via, to, from, moves);
    return moves;
}

function moveCount(n) { return (1 << n) - 1; }

assert(moveCount(1) === 1, "moves(1)=1");
assert(moveCount(2) === 3, "moves(2)=3");
assert(moveCount(3) === 7, "moves(3)=7");
assert(moveCount(10) === 1023, "moves(10)=1023");

var m3 = hanoi(3, "A", "C", "B");
assert(m3.length === 7, "hanoi(3) 7 moves");
assert(m3[0][0] === "A" && m3[0][1] === "C", "m3[0]");
assert(m3[3][0] === "A" && m3[3][1] === "C", "m3[3] (largest disc: A->C)");

// Verify hanoi solves correctly by simulating
function simulate(n, moves) {
    var pegs = { A: [], B: [], C: [] };
    for (var i = n; i >= 1; i--) pegs.A.push(i);
    for (var k = 0; k < moves.length; k++) {
        var m = moves[k];
        var from = m[0], to = m[1];
        var disk = pegs[from].pop();
        if (pegs[to].length > 0 && pegs[to][pegs[to].length - 1] < disk) {
            return "BAD: tried to place " + disk + " on " + pegs[to][pegs[to].length - 1];
        }
        pegs[to].push(disk);
    }
    if (pegs.C.length !== n) return "BAD: C has " + pegs.C.length + " disks";
    for (var i = 0; i < n; i++) {
        if (pegs.C[i] !== n - i) return "BAD: stack order";
    }
    return "OK";
}

assert(simulate(3, m3) === "OK", "simulate(3)");
assert(simulate(4, hanoi(4, "A", "C", "B")) === "OK", "simulate(4)");

print("engine/hanoi: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
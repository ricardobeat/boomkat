// Dragon curve
// Iteratively generate L-system sequence then render the turtle path.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

// Sequence rules:
//   X -> X+YF+
//   Y -> -FX-Y
//   F -> F (unchanged)
function nextGen(s) {
    var out = "";
    for (var i = 0; i < s.length; i++) {
        var c = s[i];
        if (c === "X") out += "X+YF+";
        else if (c === "Y") out += "-FX-Y";
        else out += c;
    }
    return out;
}

function dragonSeq(iterations) {
    var s = "FX";
    for (var i = 0; i < iterations; i++) s = nextGen(s);
    return s;
}

// After 0 iterations: "FX"
// After 1: "FX" -> F->F, X->X+YF+ -> "FX+YF+"
// After 2: F->F, X->X+YF+, Y->-FX-Y, F->F, +->+, +->+
//   so: F X + Y F + - F X - Y
//   which is "FX+YF+-FX-Y"
assert(dragonSeq(0) === "FX", "iter 0");
assert(dragonSeq(1) === "FX+YF+", "iter 1");
assert(dragonSeq(2) === "FX+YF++-FX-YF+", "iter 2");

// Length grows by 2^(n+1) - 2 each iteration
function dragonLen(n) {
    return dragonSeq(n).length;
}

assert(dragonLen(0) === 2, "len iter 0");
assert(dragonLen(1) === 6, "len iter 1");
assert(dragonLen(2) === 14, "len iter 2");
assert(dragonLen(5) === 126, "len iter 5");

// Render: walk the sequence as turtle commands (F=forward, +/-=turn, no X/Y)
function renderDragon(iterations, step, angle) {
    var seq = dragonSeq(iterations);
    var x = 0, y = 0, dir = 0; // dir 0=right, 1=down, 2=left, 3=up
    var dx = [1, 0, -1, 0];
    var dy = [0, 1, 0, -1];
    var minX = 0, maxX = 0, minY = 0, maxY = 0;
    var path = [[x, y]];
    for (var i = 0; i < seq.length; i++) {
        var c = seq[i];
        if (c === "F") {
            x += dx[dir] * step;
            y += dy[dir] * step;
            path.push([x, y]);
        } else if (c === "+") {
            dir = (dir + 1) % 4;
        } else if (c === "-") {
            dir = (dir + 3) % 4;
        }
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
    }
    return { path: path, width: maxX - minX, height: maxY - minY };
}

// Render 5 iterations: count F's to know path length
function countF(s) {
    var n = 0;
    for (var i = 0; i < s.length; i++) if (s[i] === "F") n++;
    return n;
}
var d = renderDragon(5, 1, 0);
assert(d.path.length === countF(dragonSeq(5)) + 1, "path = F count + 1");

// Bounds should be finite
assert(d.width >= 0 && d.height >= 0, "non-negative bounds");

// Bounds should be finite
assert(d.width >= 0 && d.height >= 0, "non-negative bounds");

print("engine/dragon_curve: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
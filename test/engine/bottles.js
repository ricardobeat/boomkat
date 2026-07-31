// 99 bottles of beer
// Generate the lyrics using a loop and conditional.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function bottle(n) {
    if (n === 0) return "No more bottles";
    if (n === 1) return "1 bottle";
    return n + " bottles";
}

function plural(n) { return n === 1 ? "bottle" : "bottles"; }

function lineA(n) {
    return bottle(n) + " of beer on the wall, " + bottle(n).toLowerCase() + " of beer.";
}

function lineB(n) {
    if (n === 0) {
        return "Go to the store and buy some more, 99 bottles of beer on the wall.";
    }
    var next = n - 1;
    var verb = n === 1 ? "it" : "one";
    var tail = next === 0 ? "no more bottles" : next + " " + plural(next);
    return "Take " + verb + " down and pass it around, " + tail + " of beer on the wall.";
}

assert(bottle(0) === "No more bottles", "bottle(0)");
assert(bottle(1) === "1 bottle", "bottle(1)");
assert(bottle(99) === "99 bottles", "bottle(99)");

assert(lineA(3) === "3 bottles of beer on the wall, 3 bottles of beer.", "lineA(3)");
assert(lineA(1) === "1 bottle of beer on the wall, 1 bottle of beer.", "lineA(1)");
assert(lineA(0) === "No more bottles of beer on the wall, no more bottles of beer.", "lineA(0)");

assert(lineB(99).indexOf("98 bottles") !== -1, "lineB(99) ends at 98");
assert(lineB(1).indexOf("no more bottles") !== -1, "lineB(1) wraps to 0");
assert(lineB(0).indexOf("99 bottles") !== -1, "lineB(0) restarts");

// Build the full song; verify length and key phrases
var song = "";
for (var n = 99; n >= 0; n--) {
    song += lineA(n) + "\n";
    song += lineB(n) + "\n";
}

assert(song.indexOf("99 bottles of beer on the wall") === 0, "starts with 99");
assert(song.indexOf("No more bottles") !== -1, "has 'No more bottles'");
// Wrap: lineB(0) ends with "99 bottles of beer on the wall."
var wrap = song.indexOf("99 bottles of beer on the wall.");
var start = song.indexOf("99 bottles of beer on the wall");
assert(wrap > start, "wraps back to 99 at end");

print("engine/bottles: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
// Loops/Increment loop index within loop body
// Demonstrates `i++` inside the loop body.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

// Simulate the rosetta task: print i, then skip the next if i is even
function printSkip(max) {
    var out = [];
    for (var i = 1; i <= max; i++) {
        out.push(i);
        if (i % 2 === 0) i++; // skip the next (but the for-loop will increment again)
    }
    return out;
}

var r = printSkip(11);
assert(r[0] === 1, "[0]=1");
assert(r[1] === 2, "[1]=2");
assert(r[2] === 4, "[2]=4");
assert(r[3] === 6, "[3]=6");
assert(r.indexOf(3) === -1, "3 was skipped (after 2, i++ => 3, for++ => 4)");
assert(r.indexOf(5) === -1, "5 was skipped");

// Verify the standard interpretation: i increments once per for-iter, plus the
// i++ inside when i is even. So:
var expectedPattern = [];
for (var ii = 1; ii <= 11; ii++) {
    expectedPattern.push(ii);
    if (ii % 2 === 0) ii++;
}
assert(JSON.stringify(r) === JSON.stringify(expectedPattern), "pattern matches expected");

print("engine/incr_in_loop: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
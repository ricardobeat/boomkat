// Do while / Labeled loops
// Tests do...while, labeled break/continue, nested loop control.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Basic do...while
var i = 0;
var sum = 0;
do {
    sum += i;
    i++;
} while (i <= 10);
assert(sum === 55, "do..while sum 1-10 = 55");

// do...while executes at least once
var executed = false;
do {
    executed = true;
} while (false);
assert(executed, "do..while runs once even if condition false");

// Labeled break
outer_loop:
for (var a = 0; a < 5; a++) {
    for (var b = 0; b < 5; b++) {
        if (a === 2 && b === 3) break outer_loop;
    }
}
assert(a === 2 && b === 3, "labeled break exits outer loop");

// Labeled continue
var count = 0;
skip:
for (var x = 0; x < 3; x++) {
    for (var y = 0; y < 3; y++) {
        if (y === 1) continue skip;
        count++;
    }
}
// Each outer iteration: y=0 runs, y=1 skips to next x, y=2 never reached
assert(count === 3, "labeled continue: count=" + count);

// Break in do...while
var k = 0;
do {
    k++;
    if (k === 5) break;
} while (k < 100);
assert(k === 5, "break in do..while at 5");

// Continue in for loop
var evens = 0;
for (var n = 0; n < 20; n++) {
    if (n % 2 !== 0) continue;
    evens++;
}
assert(evens === 10, "continue counts evens");

// Nested do...while with break
var r = 0, c = 0;
do {
    c = 0;
    do {
        r++;
        c++;
        if (r >= 10) break;
    } while (c < 5);
} while (r < 10);
assert(r === 10, "nested do..while with break: r=" + r);

// Labeled break from do...while
var found = false;
search:
do {
    for (var m = 0; m < 5; m++) {
        if (m === 3) { found = true; break search; }
    }
} while (false);
assert(found, "labeled break from do..while");

// do...while with update before condition
var vals = [];
var v = 1;
do {
    vals.push(v);
    v *= 2;
} while (v < 32);
assert(vals.length === 5, "powers of 2 count");
assert(vals.join(",") === "1,2,4,8,16", "powers of 2 values");

print("engine/do_while: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

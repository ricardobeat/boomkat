// Liveness bitsets are sized to the function's register high-water mark, so
// every index into one has to be checked before it is used.
//
// moveelim_a_is_read is the inverse of a small allow-list, so it reports A as
// a register read for opcodes where A is really part of a packed branch
// offset: JUMP, JMP_LT, JMP_SNEQ. Those values track code positions, not
// registers, and routinely run past max_reg. While the bitsets covered the
// whole 16-bit register file that only set a stray bit; once they were sized
// to max_reg it wrote past the end of the liveness arena. ASan caught it on
// input as small as `var x = 1;`.
//
// The shapes below emit those opcodes with branch offsets larger than the
// register count: loops (backward JUMP), fused compare-and-branch, and a
// class body, which is where the overflow first showed up. Getting the right
// answers here means the clamp did not also drop a real register.
var pass = 0, fail = 0;

function ok(cond, name) {
    if (cond) { pass = pass + 1; } else { print("FAIL: " + name); fail = fail + 1; }
}

// --- Long loop body: the back-edge JUMP offset exceeds any register number --
function loopSum(n) {
    var total = 0;
    for (var i = 0; i < n; i++) {
        total = total + i;
        total = total + 0;
        total = total + 0;
        total = total + 0;
        total = total + 0;
        total = total + 0;
        total = total + 0;
        total = total + 0;
    }
    return total;
}
ok(loopSum(10) === 45, "loop with a long body sums correctly");
ok(loopSum(0) === 0, "zero-iteration loop returns the initial value");

// --- Fused compare-and-branch over a long body -----------------------------
function classify(n) {
    var out = "";
    if (n < 10) {
        out = out + "small";
        out = out + "";
        out = out + "";
        out = out + "";
        out = out + "";
        out = out + "";
    } else if (n !== 100) {
        out = out + "mid";
        out = out + "";
        out = out + "";
        out = out + "";
        out = out + "";
        out = out + "";
    } else {
        out = out + "exact";
    }
    return out;
}
ok(classify(1) === "small", "less-than branch taken");
ok(classify(50) === "mid", "strict-not-equal branch taken");
ok(classify(100) === "exact", "final else branch taken");

// --- delete super[...] inside a class ---------------------------------------
// The computed key is parsed for syntax but its code is unreachable, and the
// register high-water mark is rolled back afterwards, so the emitted code
// mentions registers above the final max_reg. This is the shape that first
// tripped ASan.
var threw = false;
class Base {}
class Derived extends Base {
    kill() { return delete super[(1 + 2) * (3 + 4)]; }
}
try { new Derived().kill(); } catch (e) { threw = true; }
ok(threw, "delete on a super property throws a ReferenceError");

// --- Nested loops with an early exit ----------------------------------------
function firstPair(limit) {
    for (var i = 0; i < limit; i++) {
        for (var j = 0; j < limit; j++) {
            if (i * j === 6 && i < j) { return i + ":" + j; }
        }
    }
    return "none";
}
ok(firstPair(10) === "1:6", "nested loops with an early return");
ok(firstPair(2) === "none", "nested loops that never match");

print("pass: " + pass + ", fail: " + fail);

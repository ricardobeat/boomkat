// String.prototype.repeat must not truncate its count to 32 bits.
//
// ES2015 §21.1.3.13 requires a RangeError when the count is negative or
// infinite, and an implementation-limit error when the result cannot be
// allocated — never a shorter string. The count was narrowed to a 32-bit
// value before the limit check, so it wrapped: repeat(2**32) returned "" and
// repeat(1e10) returned a string of length 1410065408 (1e10 mod 2**32).
//
// test262's 16 repeat tests all pass; none uses a count anywhere near 2**32,
// so nothing upstream could catch this. See
// plans/070-real-world-battle-testing.md.
var failures = 0;
function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        print("FAIL: " + msg + " — expected " + expected + ", got " + actual);
        failures++;
    }
}
function assertThrows(ctor, fn, msg) {
    try {
        var r = fn();
        print("FAIL: " + msg + " — expected " + ctor.name +
              ", got a string of length " + (r && r.length));
        failures++;
    } catch (e) {
        if (!(e instanceof ctor)) {
            print("FAIL: " + msg + " — expected " + ctor.name + ", got " + e);
            failures++;
        }
    }
}

// Counts at or above the 32-bit boundary must not wrap.
assertThrows(RangeError, function () { return "x".repeat(4294967296); },
    "repeat(2**32)");
assertThrows(RangeError, function () { return "x".repeat(4294967297); },
    "repeat(2**32 + 1)");
assertThrows(RangeError, function () { return "x".repeat(2147483648); },
    "repeat(2**31)");
assertThrows(RangeError, function () { return "x".repeat(1e10); },
    "repeat(1e10)");
assertThrows(RangeError, function () { return "x".repeat(8589934592); },
    "repeat(2**33)");

// Already-correct cases, kept so a fix cannot regress them.
assertThrows(RangeError, function () { return "x".repeat(Infinity); },
    "repeat(Infinity)");
assertThrows(RangeError, function () { return "x".repeat(-1); },
    "repeat(-1)");
assertThrows(RangeError, function () { return "x".repeat(-Infinity); },
    "repeat(-Infinity)");

// A multi-character receiver makes the overflow reachable sooner.
assertThrows(RangeError, function () { return "abcd".repeat(2147483648); },
    "repeat(2**31) on a 4-character string");

// Ordinary counts must be unaffected.
assertEq("ab".repeat(3), "ababab", "repeat(3)");
assertEq("x".repeat(0), "", "repeat(0)");
// An empty receiver has a representable result for any count, so no limit is
// reached and no error is warranted. node agrees; QuickJS throws RangeError
// here, which is wrong — do not "fix" this assertion to match qjs.
assertEq("".repeat(4294967296), "", "empty receiver with a huge count is still empty");
assertEq("".repeat(1e10), "", "empty receiver with a 1e10 count is still empty");
assertEq("x".repeat(1), "x", "repeat(1)");
assertEq("ab".repeat(2.9), "abab", "fractional count truncates toward zero");
assertEq("x".repeat(NaN), "", "NaN count coerces to 0");
assertEq("x".repeat(null), "", "null count coerces to 0");
assertEq("xy".repeat(1000).length, 2000, "a large-but-legal count still works");

if (failures === 0) {
    print("PASS: String.prototype.repeat limits");
} else {
    print("FAILURES: " + failures);
}

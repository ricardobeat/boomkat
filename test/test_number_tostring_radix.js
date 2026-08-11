// Number.prototype.toString(radix) must handle the full double range.
//
// The integer part was converted with `ulong int_val = (ulong)(long)int_part`
// (src/builtins/number.c3), a cast through signed 64-bit that saturates at
// INT64_MAX. Every value at or above 2**63 therefore produced the digits of
// 9223372036854775807: 1e19, 1e20, 1e25, 1e30 and Number.MAX_VALUE all
// returned the same string.
//
// Doubles reach ~1.8e308, so no integer type can hold the integer part; the
// conversion has to be done in floating point by repeated division, as V8 and
// QuickJS do. The output buffer must grow with it — MAX_VALUE.toString(2) is
// 1024 digits, well past the fixed char[128] that was there.
//
// test262's 90 toString tests all pass. The radix-16 test asserts exactly
// four values — 0, 1, NaN, Infinity — so the largest number it tests is 1.
// Nothing upstream could detect a cliff at 2**63. See
// plans/070-real-world-battle-testing.md.
var failures = 0;
function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        print("FAIL: " + msg + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// Exact digit strings for values past 2**63 (cross-checked against node).
assertEq((1e19).toString(16), "8ac7230489e80000", "1e19 base 16");
assertEq((1e20).toString(16), "56bc75e2d63100000", "1e20 base 16");
assertEq((1e25).toString(16), "845951614014880000000", "1e25 base 16");
// Base 36 is asserted by magnitude rather than exact digits: the trailing
// digits of a float->radix conversion are not pinned by the spec, and node
// and QuickJS legitimately differ there (…0p800 vs …0q000).
assertEq((1e20).toString(36).length, 13, "1e20 base 36 digit count");
assertEq((1e20).toString(36).charAt(0), "l", "1e20 base 36 leading digit");
assertEq((1e30).toString(36).length, 20, "1e30 base 36 digit count");

// The saturation signature: distinct large values must not collapse onto one
// string, and none of them may be INT64_MAX's digits.
(function () {
    var a = (1e19).toString(16), b = (1e25).toString(16),
        c = (1e30).toString(16), d = Number.MAX_VALUE.toString(16);
    assertEq(a === b, false, "1e19 and 1e25 differ in base 16");
    assertEq(b === c, false, "1e25 and 1e30 differ in base 16");
    assertEq(c === d, false, "1e30 and MAX_VALUE differ in base 16");
    assertEq(a === "7fffffffffffffff", false, "1e19 is not INT64_MAX's digits");
    assertEq((1e20).toString(36) === "1y2p0ij32e8e7", false,
        "1e20 base 36 is not INT64_MAX's digits");
}());

// Precision must not be capped by a fixed output buffer.
assertEq(Number.MAX_VALUE.toString(2).length, 1024, "MAX_VALUE base 2 digit count");
assertEq((1e20).toString(2).length, 67, "1e20 base 2 digit count");
assertEq(Number.MAX_VALUE.toString(16).length, 256, "MAX_VALUE base 16 digit count");

// Round-tripping through parseInt, to within the precision parseInt itself
// can carry. Exact equality is not available: reparsing a 20-digit base-36
// string loses low bits even on node, so assert a small relative error. That
// is still far tighter than the saturation bug, which lands the value on
// 9223372036854775807 regardless of the input.
(function () {
    var vals = [1e19, 1e20, 1e25, 1e30, 12345678901234567890];
    for (var i = 0; i < vals.length; i++) {
        for (var radix = 2; radix <= 36; radix += 17) {
            var s = vals[i].toString(radix);
            var back = parseInt(s, radix);
            var relErr = Math.abs(back - vals[i]) / vals[i];
            assertEq(relErr < 1e-12, true,
                "round-trip " + vals[i] + " through base " + radix +
                " (got " + back + ")");
        }
    }
}());

// Just below and just above 2**63, where the cast used to clamp.
assertEq((9223372036854775808).toString(16), "8000000000000000", "2**63 base 16");
assertEq((4611686018427387904).toString(16), "4000000000000000", "2**62 base 16");

// Negative values past the boundary keep their sign and digits.
assertEq((-1e20).toString(16), "-56bc75e2d63100000", "-1e20 base 16");

// Small values, fractions and radix 10 must be untouched.
assertEq((255).toString(16), "ff", "255 base 16");
assertEq((255).toString(2), "11111111", "255 base 2");
assertEq((35).toString(36), "z", "35 base 36");
assertEq((255.5).toString(2), "11111111.1", "fractional part still emitted");
assertEq((0.5).toString(2), "0.1", "pure fraction in base 2");
assertEq((1e20).toString(10), "100000000000000000000", "1e20 base 10 unaffected");
assertEq((1e20).toString(), "100000000000000000000", "1e20 default radix unaffected");
assertEq((0).toString(16), "0", "zero");
assertEq((-0).toString(16), "0", "negative zero");
assertEq(NaN.toString(16), "NaN", "NaN");
assertEq(Infinity.toString(16), "Infinity", "Infinity");
assertEq((-Infinity).toString(2), "-Infinity", "-Infinity");

if (failures === 0) {
    print("PASS: Number.prototype.toString(radix) over the full double range");
} else {
    print("FAILURES: " + failures);
}

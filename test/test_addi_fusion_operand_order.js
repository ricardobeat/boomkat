// LDINT+ADD fusion must not reorder the operands of `+`.
//
// FUSION_ADDI_SUBI folds `LDINT rK, imm` + `ADD rD = rX, rY` into
// `ADDI rD = rS, imm`. ADDI has no field left to record which side the
// immediate came from, so it can only ever mean `rS + imm`. The rule used to
// fold `imm + rS` as well, on the grounds that addition is commutative — but
// `+` in JavaScript is string concatenation whenever either operand is a
// string after ToPrimitive (ES5 §11.6.1), and concatenation is not
// commutative. `function f(a){ return 1 + a; } f("A")` therefore evaluated to
// "A1".
//
// This is a SILENT wrong answer on entirely ordinary code, with no error and
// no crash. test262 never caught it because the fusion only fires on a
// specific register/opcode shape, and a constant-plus-parameter concatenation
// in that shape is not something the suite exercises.
//
// The fix restricts the fold to `rS + imm`, matching the constraint SUB
// already had; `imm + rS` stays as LDINT+ADD, which reads its operands in
// source order. See plans/070-real-world-battle-testing.md (B13).
var failures = 0;
function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        print("FAIL: " + msg + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// The exact reported shape: a small literal on the left of a parameter. The
// call must be through a function so the ADD sees a register whose runtime
// type the compiler cannot know.
function immLeft(a) { return 1 + a; }
function immRight(a) { return a + 1; }
assertEq(immLeft("A"), "1A", "1 + str concatenates with the literal first");
assertEq(immRight("A"), "A1", "str + 1 concatenates with the literal last");

// Both orders must still be numeric addition for numbers.
assertEq(immLeft(2), 3, "1 + num adds");
assertEq(immRight(2), 3, "num + 1 adds");

// Negative and boundary immediates, which sit at the edges of the signed
// 8-bit field the fusion is allowed to fold.
function negLeft(a) { return -128 + a; }
function negRight(a) { return a + -128; }
assertEq(negLeft("A"), "-128A", "-128 + str keeps order");
assertEq(negRight("A"), "A-128", "str + -128 keeps order");
assertEq(negLeft(0), -128, "-128 + 0 adds");

function maxLeft(a) { return 127 + a; }
assertEq(maxLeft("A"), "127A", "127 + str keeps order");
assertEq(maxLeft(1), 128, "127 + 1 adds");

// Just past the foldable range, so the fusion cannot fire at all — these
// guard the unfused path with the same assertions.
function bigLeft(a) { return 128 + a; }
assertEq(bigLeft("A"), "128A", "128 + str keeps order (immediate out of range)");
assertEq(bigLeft(1), 129, "128 + 1 adds");

// Zero is worth pinning separately: "0" + s and s + "0" differ, and 0 is the
// immediate most likely to appear in a fused loop.
function zeroLeft(a) { return 0 + a; }
assertEq(zeroLeft("A"), "0A", "0 + str keeps order");
assertEq(zeroLeft(5), 5, "0 + num adds");

// Inside a loop, where the fusion is most likely to fire and where a wrong
// order compounds visibly.
(function () {
    var out = "";
    for (var i = 0; i < 3; i++) { out = out + (1 + "x"); }
    assertEq(out, "1x1x1x", "1 + str inside a loop keeps order every iteration");
}());

(function () {
    var acc = "s";
    for (var i = 0; i < 3; i++) { acc = acc + 1; }
    assertEq(acc, "s111", "str + 1 accumulation still appends on the right");
}());

// SUB was always restricted to `rS - imm`; assert the asymmetry directly so a
// future change cannot "restore symmetry" by folding the other side.
function subLeft(a) { return 2 - a; }
function subRight(a) { return a - 2; }
assertEq(subLeft(5), -3, "2 - a is not rewritten as a - 2");
assertEq(subRight(5), 3, "a - 2 subtracts");

// Non-string, non-number operands go through ToPrimitive and must still see
// the operands in source order.
function objLeft(a) { return 1 + a; }
assertEq(objLeft({ toString: function () { return "O"; } }), "1O",
    "1 + object concatenates after ToPrimitive, in order");
assertEq(objLeft([]), "1", "1 + [] concatenates with an empty string");
assertEq(objLeft(true), 2, "1 + true adds after ToNumber");
assertEq(objLeft(null), 1, "1 + null adds after ToNumber");
assertEq(objLeft(undefined) !== objLeft(undefined) , true,
    "1 + undefined is NaN");

// A long accumulation on the left, which also exercises the in-place concat
// accumulator on a path the fusion no longer folds.
(function () {
    var s = "";
    for (var i = 0; i < 200; i++) { s = 7 + s; }
    assertEq(s.length, 200, "200 left-concatenations of a one-digit literal");
    assertEq(s.charAt(0), "7", "every left-concatenation prepended");
}());

if (failures === 0) {
    print("PASS: ADDI/SUBI fusion operand order");
} else {
    print("FAILURES: " + failures);
}

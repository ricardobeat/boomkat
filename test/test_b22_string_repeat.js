// Regression test for B22: String.prototype.repeat count handling
// (ES2015 §21.1.3.14 / ES2023 §22.1.3.16).
//
// The count is first put through ToIntegerOrInfinity, which truncates toward
// zero and maps NaN to 0. RangeError is thrown only when that RESULT is
// negative or +Infinity. So -0.5 and NaN both truncate to 0 and yield "";
// only genuinely negative results (-1, -Infinity) and +Infinity throw.

function expectThrow(name, fn, expectedName) {
    try {
        var r = fn();
        print("FAIL " + name + ": no throw, got", String(r));
        return false;
    } catch (e) {
        if (e.constructor.name === expectedName) {
            print("PASS " + name + ":", e.constructor.name, "thrown");
            return true;
        }
        print("FAIL " + name + ": got " + e.constructor.name + ", expected " + expectedName);
        return false;
    }
}

function expectValue(name, fn, expected) {
    try {
        var r = fn();
        if (r === expected) {
            print("PASS " + name + ":", JSON.stringify(r));
            return true;
        }
        print("FAIL " + name + ": got " + JSON.stringify(r) + ", expected " + JSON.stringify(expected));
        return false;
    } catch (e) {
        print("FAIL " + name + ": unexpected " + e.constructor.name + ": " + e.message);
        return false;
    }
}

// Negative or +Infinity after truncation -> RangeError.
expectThrow("repeat(-1)",  function () { return "a".repeat(-1);  }, "RangeError");
expectThrow("repeat(Infinity)", function () { return "a".repeat(Infinity); }, "RangeError");
expectThrow("repeat(-Infinity)", function () { return "a".repeat(-Infinity); }, "RangeError");

// Truncates to 0 -> empty string, no throw.
expectValue("repeat(-0.5)", function () { return "a".repeat(-0.5); }, "");
expectValue("repeat(NaN)", function () { return "a".repeat(NaN); }, "");
expectValue("repeat(0.9)", function () { return "a".repeat(0.9); }, "");
expectValue("repeat(-0)", function () { return "a".repeat(-0); }, "");
expectValue("repeat(undefined)", function () { return "a".repeat(undefined); }, "");
expectValue("repeat(null)", function () { return "a".repeat(null); }, "");

// Sanity: legitimate calls still work.
expectValue("repeat(0)", function () { return "a".repeat(0); }, "");
expectValue("repeat(3)", function () { return "a".repeat(3); }, "aaa");
expectValue("repeat('2')", function () { return "a".repeat("2"); }, "aa");
expectValue("xy.repeat(2)", function () { return "xy".repeat(2); }, "xyxy");
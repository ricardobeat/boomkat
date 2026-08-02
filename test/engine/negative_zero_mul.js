// A zero product with operands of opposite sign is -0 (ES2024 6.1.6.1.4).
// The fastint MUL path cannot represent -0, so it must hand off to a double.
function check(actual, expected, label) {
    if (!Object.is(actual, expected)) {
        print("FAIL: " + label + " -> " + actual + " (want " + expected + ")");
        return 0;
    }
    return 1;
}

var pass = 0, total = 0;
var cases = [
    [0 * -1, -0, "0 * -1"],
    [-1 * 0, -0, "-1 * 0"],
    [0 * -0, -0, "0 * -0"],
    [-0 * 0, -0, "-0 * 0"],
    [2 * -0, -0, "2 * -0"],
    [-0 * -0, 0, "-0 * -0"],
    [0 * 0, 0, "0 * 0"],
    [0 * 1, 0, "0 * 1"],
    [-3 * -0, 0, "-3 * -0"],
    [3 * 0, 0, "3 * 0"],
];
for (var i = 0; i < cases.length; i++) {
    total++; pass += check(cases[i][0], cases[i][1], cases[i][2]);
}

// Same through variables, so constant folding cannot mask the VM path.
var a = 0, b = -1, c = -3, d = 0, e = -0;
total++; pass += check(a * b, -0, "a * b");
total++; pass += check(c * d, -0, "c * d");
total++; pass += check(a * e, -0, "a * e");
total++; pass += check(e * e, 0, "e * e");

// A nonzero product must keep its sign and stay exact.
total++; pass += check(6 * -7, -42, "6 * -7");
total++; pass += check(-6 * -7, 42, "-6 * -7");

print("engine/negative_zero_mul: " + pass + " passed, " + (total - pass) + " failed");

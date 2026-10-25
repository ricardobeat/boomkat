// A loop whose body has an arm: the register state at the join depends on
// which arm ran, so the native tier has to merge the two.
var failures = 0;
function check(label, actual, expected) {
    if (actual !== expected) {
        print("FAIL " + label + ": got " + actual + ", expected " + expected);
        failures++;
    }
}

function countAbove(n, limit) {
    var hits = 0;
    for (var i = 0; i < n; i++) {
        if (i > limit) hits = hits + 1;
    }
    return hits;
}

function sumEven(values, n) {
    var total = 0;
    for (var i = 0; i < n; i++) {
        if (values[i] % 2 == 0) total += values[i]; else total -= values[i];
    }
    return total;
}

function pickBranch(n, flag) {
    var out = 0;
    for (var i = 0; i < n; i++) {
        if (flag) out = out + i; else out = out - i;
    }
    return out;
}

function nestedArms(n) {
    var out = 0;
    for (var i = 0; i < n; i++) {
        if (i % 3 == 0) out = out + 1;
        if (i % 5 == 0) out = out + 10;
    }
    return out;
}

var values = [1, 2, 3, 4, 5, 6, 7, 8];

for (var round = 0; round < 500; round++) {
    check("count above", countAbove(10, 3), 6);
    check("count none", countAbove(4, 10), 0);
    check("sum even", sumEven(values, 8), 4);
    check("branch true", pickBranch(5, true), 10);
    check("branch false", pickBranch(5, false), -10);
    check("nested arms", nestedArms(15), 35);
}

if (failures == 0) print("ok");

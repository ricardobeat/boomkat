// Native loose equality: null/undefined and object reference comparisons.
var failures = 0;
function check(label, actual, expected) {
    if (actual !== expected) {
        print("FAIL " + label + ": got " + actual + ", expected " + expected);
        failures++;
    }
}

function countEqNull(value, rounds) {
    var count = 0;
    for (var i = 0; i < rounds; i++) if (value == null) count++;
    return count;
}
function countNeNull(value, rounds) {
    var count = 0;
    for (var i = 0; i < rounds; i++) if (value != null) count++;
    return count;
}

var a = { name: "a" };
var b = { name: "b" };

for (var round = 0; round < 300; round++) {
    check("undefined == null", countEqNull(undefined, 100), 100);
    check("null == null", countEqNull(null, 100), 100);
    check("0 == null", countEqNull(0, 100), 0);
    check("object == null", countEqNull(a, 100), 0);
    check("undefined != null", countNeNull(undefined, 100), 0);
    check("null != null", countNeNull(null, 100), 0);
    check("0 != null", countNeNull(0, 100), 100);
    check("object != null", countNeNull(a, 100), 100);

    var same = 0;
    var different = 0;
    for (var i = 0; i < 100; i++) {
        if (a == a) same++;
        if (a != b) different++;
    }
    check("same reference ==", same, 100);
    check("different reference !=", different, 100);
}

if (failures == 0) print("ok");

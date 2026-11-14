// `.length` in optimized code reads a string's and an array's length inline;
// any other receiver takes the generic read.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

function total(items) {
    var t = 0;
    for (var i = 0; i < items.length; i++) t += items[i].length;
    return t;
}

var strings = ["ab", "cde", "", "€€"];
var arrays = [[1], [1, 2, 3], []];
for (var round = 0; round < 2000; round++) {
    check("strings", total(strings), 7);
    check("arrays", total(arrays), 4);
}
check("mixed", total(["xy", [1, 2], { length: 5 }, "z"]), 10);
check("function", total([function (a, b) {}]), 2);
if (failures === 0) print("OK");

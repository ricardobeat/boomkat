// Numeric homes must refuse uninitialized entries and recover mixed values.
function sum(n, seed, change) {
    var value = seed;
    for (var i = 0; i < n; i++) {
        if (i === change) value = "x";
        value = value + 1;
    }
    return value;
}
function nested(n) {
    var total = 0;
    for (var i = 0; i < n; i++) total += sum(20, i, -1);
    return total;
}
function conditional(n, initialize) {
    var value;
    if (initialize) value = 0;
    for (var i = 0; i < n; i++) value = value + 1;
    return value;
}
for (var k = 0; k < 200; k++) {
    if (sum(100, 3, -1) !== 103) throw Error("numeric local");
    if (nested(10) !== 245) throw Error("nested local");
    if (conditional(20, true) !== 20) throw Error("initialized local");
    if (!isNaN(conditional(20, false))) throw Error("undefined local");
}
if (sum(5, 0, 3) !== "x11") throw Error("string recovery");
var calls = 0;
if (sum(3, { valueOf: function () { calls++; return 4; } }, -1) !== 7 || calls !== 1)
    throw Error("coercion recovery");
print("numeric locals ok");

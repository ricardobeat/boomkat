// parseInt on an exact integer folds in native code; other inputs must keep
// the ordinary call and its coercion behavior.
function check(actual, expected, label) {
    if (actual !== expected) throw new Error(label + ": " + actual + " != " + expected);
}
function numeric(points, n) {
    var sum = 0;
    for (var i = 0; i < n; i++) {
        sum += parseInt(points);
        sum += points;
    }
    return sum;
}
check(numeric(32, 64), 4096, "numeric");
for (var warm = 0; warm < 100; warm++) check(numeric(32, 64), 4096, "warm numeric");
check(numeric(31, 5), 310, "other integer");
var calls = 0;
function parseOnly(value, n) {
    var sum = 0;
    for (var i = 0; i < n; i++) sum += parseInt(value);
    return sum;
}
for (var warm = 0; warm < 100; warm++) check(parseOnly(7, 2), 14, "warm parse");
check(parseOnly("41", 3), 123, "string");
var exotic = { toString: function () { calls++; return "17"; } };
check(parseOnly(exotic, 3), 51, "object");
check(calls, 3, "toString calls");
print("sljit parseInt: PASS");

// A Math function's ToNumber of its arguments throws a TypeError for a BigInt or a Symbol, directly
// or as an object's valueOf result, instead of reading NaN.
var fails = 0;
function throws(name, f) {
    try {
        var v = f();
        print("FAIL " + name + ": returned " + String(v));
        fails++;
    } catch (e) {
        if (!(e instanceof TypeError)) { print("FAIL " + name + ": " + e); fails++; }
    }
}
var names = ["abs", "floor", "ceil", "round", "sqrt", "sin", "cos", "tan", "exp", "log", "atan", "trunc",
             "sign", "cbrt", "log2", "log10", "fround", "clz32", "expm1", "log1p", "sinh", "cosh", "tanh",
             "asin", "acos", "asinh", "acosh", "atanh"];
var big = { valueOf: function () { return 3n; } };
for (var n of names) {
    throws(n + "(1n)", function () { return Math[n](1n); });
    throws(n + "(symbol)", function () { return Math[n](Symbol("s")); });
    throws(n + "(valueOf bigint)", function () { return Math[n](big); });
}
throws("min", function () { return Math.min(1, 2n); });
throws("max", function () { return Math.max(2n, 1); });
throws("pow", function () { return Math.pow(2, 1n); });
throws("atan2", function () { return Math.atan2(1n, 2); });
throws("imul", function () { return Math.imul(3n, 2); });
throws("hypot", function () { return Math.hypot(1, 2n); });
// A later argument's conversion still runs after an earlier NaN.
var seen = 0;
var counted = { valueOf: function () { seen++; return 1; } };
if (!isNaN(Math.max(NaN, counted)) || seen !== 1) { print("FAIL max conversion order " + seen); fails++; }
if (Math.sqrt("16") !== 4 || Math.floor(true) !== 1 || !isNaN(Math.abs(undefined)) || Math.abs(null) !== 0) {
    print("FAIL primitive conversions"); fails++;
}
print(fails === 0 ? "done" : "failed " + fails);

// A namespace-property numeric helper with conditional returns is inlined
// with a live callee check; non-numeric inputs keep the ordinary call.
function check(actual, expected, label) {
    if (actual !== expected) throw new Error(label + ": " + actual + " != " + expected);
}
var R = {};
R.Clamp = function (p, B, Q) {
    if (p === undefined) p = 0;
    if (B === undefined) B = 0;
    if (Q === undefined) Q = 0;
    return p < B ? B : p > Q ? Q : p;
};
var total = 0;
for (var i = 0; i < 1000; i++) total += R.Clamp(i, 0, 100);
check(total, 94950, "clamp loop");
check(R.Clamp(-5, 0, 10), 0, "low");
check(R.Clamp(50, 0, 10), 10, "high");
check(R.Clamp(5, 0, 10), 5, "inside");
check(R.Clamp("7", 0, 10), "7", "numeric string");
check(R.Clamp(undefined, 1, 2), 1, "undefined default");
var local = { Clamp: R.Clamp };
check(local.Clamp(5, 0, 10), 5, "non-global namespace");
R.Clamp = function (p, B, Q) { return p + B + Q; };
check(R.Clamp(1, 2, 3), 6, "replaced callee");
print("sljit inline clamp: PASS");

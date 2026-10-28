// Branch preservation around expanded callees: a callee holding null and
// equality branches, and a caller holding them around an expanded callee.
var failures = 0;
function check(label, actual, expected) {
    if (actual !== expected) {
        print("FAIL " + label + ": got " + actual + ", expected " + expected);
        failures++;
    }
}

function measure(o, x, y) {
    var v = o.base;
    if (x == null) v = v + 1;
    if (x == y) v = v + 2;
    return v;
}

function run(o, x, y) {
    var v = measure(o, x, y);
    if (x == null) v = v + 10;
    if (x == y) v = v + 20;
    return v;
}

function leaf(a, b) {
    return a + b;
}

function runLeaf(o, x, y) {
    var v = leaf(o.base, 1);
    if (x == null) v = v + 10;
    if (x == y) v = v + 20;
    return v;
}

var o = { base: 100 };
var p = { base: 100 };

for (var round = 0; round < 300; round++) {
    check("both null", run(o, null, null), 133);
    check("null and undefined", run(o, null, undefined), 133);
    check("undefined vs object", run(o, undefined, o), 111);
    check("same object", run(o, o, o), 122);
    check("different objects", run(o, o, p), 100);
    check("same number", run(o, 7, 7), 122);
    check("different numbers", run(o, 7, 8), 100);

    check("leaf both null", runLeaf(o, null, null), 131);
    check("leaf same number", runLeaf(o, 7, 7), 121);
    check("leaf different numbers", runLeaf(o, 7, 8), 101);
}

if (failures == 0) print("ok");

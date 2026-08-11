// JSON.stringify must detect a cycle however the self-reference was installed.
//
// SerializeJSONArray (ES2015 §24.3.2) throws a TypeError when the value being
// serialised is already on the stack. The check was present but not reached
// for elements installed by direct index assignment, so `var a = []; a[0] = a`
// serialised to "[]" — silent data loss, worse than an error.
//
// test262 covers cyclic arrays (built-ins/JSON/stringify/value-array-circular.js)
// and that test passes, because it builds both of its cases with
// `direct.push(direct)` — the path that already worked. Only the indexed form
// was broken, so the suite never saw it. See
// plans/070-real-world-battle-testing.md.
var failures = 0;
function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        print("FAIL: " + msg + " — expected " + expected + ", got " + actual);
        failures++;
    }
}
function assertThrows(ctor, fn, msg) {
    try {
        fn();
    } catch (e) {
        if (e instanceof ctor) return;
        print("FAIL: " + msg + " — expected " + ctor.name + ", got " + e);
        failures++;
        return;
    }
    print("FAIL: " + msg + " — expected " + ctor.name + ", nothing thrown");
    failures++;
}

// The broken path: a cycle installed by indexed assignment.
assertThrows(TypeError, function () {
    var a = [];
    a[0] = a;
    return JSON.stringify(a);
}, "cyclic array via a[0] = a");

// The same cycle built with push — this always worked, and must keep working.
assertThrows(TypeError, function () {
    var d = [];
    d.push(d);
    return JSON.stringify(d);
}, "cyclic array via push");

// Objects were never affected.
assertThrows(TypeError, function () {
    var o = {};
    o.self = o;
    return JSON.stringify(o);
}, "cyclic object via property assignment");

// A sparse index, past any dense region.
assertThrows(TypeError, function () {
    var a = [];
    a[3] = a;
    return JSON.stringify(a);
}, "cyclic array at a sparse index");

// Indirect cycles through indexed assignment.
assertThrows(TypeError, function () {
    var outer = [], inner = [];
    outer[0] = inner;
    inner[0] = outer;
    return JSON.stringify(outer);
}, "indirect cycle, array -> array");

assertThrows(TypeError, function () {
    var arr = [], obj = {};
    arr[0] = obj;
    obj.back = arr;
    return JSON.stringify(arr);
}, "indirect cycle, array -> object -> array");

// A cycle reached only through a nested array literal.
assertThrows(TypeError, function () {
    var a = [];
    a[0] = [[a]];
    return JSON.stringify(a);
}, "cycle nested two levels deep");

// A cycle that only a toJSON hook exposes.
assertThrows(TypeError, function () {
    var a = [];
    a[0] = { toJSON: function () { return a; } };
    return JSON.stringify(a);
}, "cycle introduced by toJSON");

// Acyclic structures must still serialise — the check must not over-fire on a
// repeated but non-cyclic reference.
(function () {
    var shared = [1];
    assertEq(JSON.stringify([shared, shared]), "[[1],[1]]",
        "repeated non-cyclic array reference serialises");
    var o = { a: 1 };
    assertEq(JSON.stringify({ x: o, y: o }), '{"x":{"a":1},"y":{"a":1}}',
        "repeated non-cyclic object reference serialises");
}());

(function () {
    var a = [];
    a[0] = 1;
    a[2] = 3;                       // sparse, but acyclic
    assertEq(JSON.stringify(a), "[1,null,3]", "sparse acyclic array serialises");
}());

// A self-reference that is removed again must not leave the stack poisoned.
(function () {
    var a = [];
    a[0] = a;
    try { JSON.stringify(a); } catch (e) { /* expected */ }
    a[0] = 42;
    assertEq(JSON.stringify(a), "[42]",
        "array serialises normally after the cycle is broken");
}());

if (failures === 0) {
    print("PASS: JSON.stringify cycle detection");
} else {
    print("FAILURES: " + failures);
}

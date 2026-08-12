// Array.prototype.pop must consult the prototype chain for a hole.
//
// pop reads index length-1 with [[Get]], which continues up the prototype
// chain when the own element is absent. Array.prototype can itself carry an
// indexed property, so `Array.prototype[1] = 1; var x = [0]; x.length = 2;
// x.pop()` yields 1, not undefined.
//
// The dense fast path answered a HOLE as undefined, treating "no own dense
// slot" as "the value is undefined". The generic-object path (Array.prototype
// .pop applied to a plain object) was always correct; only the array fast
// path short-cut the lookup. Fixed by requiring the element to be present in
// the dense part before the fast path may claim the operation.
//
// test262: built-ins/Array/prototype/pop/S15.4.4.6_A4_T1.js.
//
// NOTE: this file mutates Array.prototype, so it must stay self-contained —
// the indexed properties are deleted at the end.
var failures = 0;
function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        print("FAIL: " + msg + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// The test262 shape: a hole at length-1 shadowed by Array.prototype.
Array.prototype[1] = 1;
(function () {
    var x = [0];
    x.length = 2;
    assertEq(x.pop(), 1, "pop reads a hole through Array.prototype");
    // pop does [[Delete]] on the own property; the inherited one survives.
    assertEq(x[1], 1, "the inherited property is untouched by pop");
    assertEq(x.length, 1, "length still drops to idx");
}());

// An OWN element at length-1 must shadow the prototype's.
(function () {
    var x = [0, "own"];
    assertEq(x.pop(), "own", "an own element shadows the inherited one");
    assertEq(x.length, 1, "length drops after popping an own element");
}());

// An own element explicitly set to undefined is PRESENT, not a hole. It must
// still be returned as undefined rather than falling through to the
// prototype — this is the case the fix must not over-correct.
(function () {
    var x = [0, undefined];
    assertEq(x.pop(), undefined, "an own undefined shadows the inherited value");
    assertEq(x.length, 1, "length drops after popping an own undefined");
}());

// Repeated pops walk down through both holes and inherited values.
(function () {
    Array.prototype[0] = "p0";
    var x = [];
    x.length = 2;
    assertEq(x.pop(), 1, "first pop reads inherited index 1");
    assertEq(x.pop(), "p0", "second pop reads inherited index 0");
    assertEq(x.length, 0, "length reaches 0");
    assertEq(x.pop(), undefined, "popping an empty array is undefined");
    assertEq(x.length, 0, "length stays 0");
    delete Array.prototype[0];
}());

// A getter on the prototype must actually be invoked.
(function () {
    var calls = 0;
    Object.defineProperty(Array.prototype, 2, {
        get: function () { calls++; return "getter"; },
        configurable: true
    });
    var x = [0, 1];
    x.length = 3;
    assertEq(x.pop(), "getter", "pop invokes an inherited getter");
    assertEq(calls, 1, "the inherited getter ran exactly once");
    delete Array.prototype[2];
}());

// The ordinary dense case must be unaffected, including element identity for
// heap values (the fast path increfs the popped element before clearing).
(function () {
    var o = {};
    var x = [o, "a", "b"];
    assertEq(x.pop(), "b", "dense pop returns the last element");
    assertEq(x.pop(), "a", "dense pop again");
    assertEq(x.pop(), o, "dense pop returns the same object reference");
    assertEq(x.length, 0, "dense pops empty the array");
}());

// Longer arrays, past a single dense chunk, still pop normally.
(function () {
    var x = [];
    for (var i = 0; i < 300; i++) { x[i] = i; }
    assertEq(x.pop(), 299, "pop from a 300-element array");
    assertEq(x.length, 299, "length after popping a long array");
}());

// A hole NOT at length-1 is irrelevant to pop.
(function () {
    var x = [0, , 2];
    assertEq(x.pop(), 2, "a hole elsewhere does not affect pop");
    assertEq(x.length, 2, "length drops normally");
}());

delete Array.prototype[1];

// With the prototype property gone, a hole is genuinely undefined again.
(function () {
    var x = [0];
    x.length = 2;
    assertEq(x.pop(), undefined, "a hole with nothing inherited is undefined");
}());

if (failures === 0) {
    print("PASS: Array.prototype.pop hole/prototype lookup");
} else {
    print("FAILURES: " + failures);
}

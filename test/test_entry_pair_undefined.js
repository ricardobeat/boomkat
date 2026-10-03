// entries() steps produce a real two-element array even when an element is
// undefined: both indices are own properties and nothing leaks in from the
// prototype.
function assertEq(a, b, msg) { if (a !== b) throw new Error(msg + ": " + a + " !== " + b); }
function check(pair, first, label) {
    assertEq(pair.length, 2, label + " length");
    assertEq(pair.hasOwnProperty(0), true, label + " own 0");
    assertEq(pair.hasOwnProperty(1), true, label + " own 1");
    assertEq(pair[0], first, label + " first");
    assertEq(pair[1], undefined, label + " second");
    assertEq(Object.keys(pair).join(), "0,1", label + " keys");
}

check(new Map([[1, undefined]]).entries().next().value, 1, "map entries");
for (var e of new Map([["k", undefined]])) check(e, "k", "map for-of");
check(new Set([undefined]).entries().next().value, undefined, "set entries");
check([undefined].entries().next().value, 0, "array entries");

var pair = new Map([[1, 2]]).entries().next().value;
assertEq(pair.hasOwnProperty(0) && pair.hasOwnProperty(1), true, "defined pair");
assertEq(pair[0] + pair[1], 3, "defined pair values");
assertEq(Array.isArray(pair), true, "pair is an array");
assertEq(Object.getPrototypeOf(pair), Array.prototype, "pair prototype");

// Destructuring and spread over entries.
var total = 0;
for (var [k, v] of new Map([[1, 10], [2, 20], [3, undefined]])) total += k + (v === undefined ? 0 : v);
assertEq(total, 36, "destructured total");
assertEq([...new Map([[1, undefined]])][0].hasOwnProperty(1), true, "spread keeps own element");

Array.prototype[1] = "leak";
assertEq(new Map([[1, undefined]]).entries().next().value[1], undefined, "no prototype leak");
delete Array.prototype[1];
print("ok");

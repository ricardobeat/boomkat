// for-of over Set and Map values and keys: deletions, additions during
// iteration, and non-number elements must behave like the generic protocol.
function assertEq(a, b, msg) { if (a !== b) throw new Error(msg + ": " + a + " !== " + b); }

function sumSet(s) { var t = 0; for (var x of s) t += x; return t; }
function sumMapValues(m) { var t = 0; for (var v of m.values()) t += v; return t; }
function sumMapKeys(m) { var t = 0; for (var k of m.keys()) t += k; return t; }

var s = new Set(), m = new Map();
for (var i = 1; i <= 100; i++) { s.add(i); m.set(i, i * 2); }
for (var round = 0; round < 3; round++) {
    assertEq(sumSet(s), 5050, "set sum " + round);
    assertEq(sumMapValues(m), 10100, "map values " + round);
    assertEq(sumMapKeys(m), 5050, "map keys " + round);
}

// Deleted entries are skipped.
for (var i = 2; i <= 100; i += 2) { s.delete(i); m.delete(i); }
assertEq(sumSet(s), 2500, "set odd sum");
assertEq(sumMapValues(m), 5000, "map odd values");
assertEq(sumMapKeys(m), 2500, "map odd keys");

// Entries added while iterating are visited; deleting the current one is safe.
var seen = [];
var grow = new Set([1, 2, 3]);
for (var x of grow) { seen.push(x); if (x < 6) grow.add(x + 3); grow.delete(x); }
assertEq(seen.join(), "1,2,3,4,5,6,7,8", "grow while iterating");
seen = [];
var gm = new Map([[1, 10], [2, 20]]);
for (var v of gm.values()) { seen.push(v); if (v === 10) gm.set(3, 30); }
assertEq(seen.join(), "10,20,30", "map grows while iterating");

// Mixed element types: strings and objects take the generic path in the same loop.
var mixed = new Set([1, "two", 3, { four: 4 }, 5.5, null, undefined, true]);
var kinds = [];
for (var x of mixed) kinds.push(typeof x);
assertEq(kinds.join(), "number,string,number,object,number,object,undefined,boolean", "mixed kinds");
var tot = 0;
for (var x of mixed) if (typeof x === "number") tot += x;
assertEq(tot, 9.5, "mixed number total");

// A patched next is still called.
var calls = 0;
var proto = Object.getPrototypeOf(new Set()[Symbol.iterator]());
var realNext = proto.next;
proto.next = function () { calls++; return realNext.call(this); };
assertEq(sumSet(new Set([1, 2, 3])), 6, "patched next sum");
assertEq(calls, 4, "patched next called");
proto.next = realNext;

// Entries kind still pairs up.
var pairs = 0;
for (var [k, v] of m) pairs += k + v;
assertEq(pairs, 7500, "map entries");
for (var [a, b] of new Set([7]).entries()) assertEq(a + b, 14, "set entries destructure");

// Exhausted iterators stay exhausted.
var it = new Set([1])[Symbol.iterator]();
for (var x of it) {}
assertEq(it.next().done, true, "exhausted");
print("ok");

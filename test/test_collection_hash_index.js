// Map/Set/WeakMap/WeakSet keep entries in array_part and used to scan it with
// SameValueZero on every add, has, get and delete. Building a collection was
// therefore quadratic -- a 100k Set took 24s against QuickJS's 9ms -- so a hash
// index over array_part was added.
//
// The index stores 1-based indices rather than copies of the keys, which keeps
// array_part authoritative for iteration order, tombstones and GC tracing. That
// only works if the hash agrees exactly with SameValueZero: any pair of EQUAL
// keys that hash differently silently becomes two entries.
//
// Every case here therefore pushes past COLL_HASH_MIN_ENTRIES (8), since below
// that the collection still uses the linear scan and would pass regardless.
//
// Runs unmodified under QuickJS and node.
var pass = 0, fail = 0;
function eq(label, got, want) {
    if (got === want) { pass++; }
    else { fail++; print("FAIL " + label + ": got " + got + " want " + want); }
}
function fill(c, n, add) { for (var i = 0; i < n; i++) { add(c, i); } return c; }

// --- SameValueZero cases the hash has to respect -------------------------

// Every NaN is one key, however produced.
var nanMap = new Map();
fill(nanMap, 20, function (m, i) { m.set("pad" + i, i); });
nanMap.set(NaN, "nan");
eq("NaN key retrievable", nanMap.get(NaN), "nan");
eq("NaN from 0/0", nanMap.get(0 / 0), "nan");
eq("NaN not duplicated", (nanMap.set(NaN, "again"), nanMap.get(NaN)), "again");

// -0 and +0 are the same key, and the stored key canonicalises to +0.
var zeroMap = new Map();
fill(zeroMap, 20, function (m, i) { m.set("z" + i, i); });
zeroMap.set(-0, "neg");
zeroMap.set(0, "pos");
eq("-0 and +0 one key", zeroMap.get(-0), "pos");
eq("zero key is +0", (function () { var k; zeroMap.forEach(function (v, kk) { if (v === "pos") k = kk; }); return 1 / k; })(), Infinity);

// A fastint and a double holding the same value are the same key.
var numMap = new Map();
fill(numMap, 20, function (m, i) { m.set("n" + i, i); });
numMap.set(1, "one");
eq("fastint matches double", numMap.get(1.0), "one");
numMap.set(2.0, "two");
eq("double matches fastint", numMap.get(2), "two");
eq("large double key", (numMap.set(1e300, "big"), numMap.get(1e300)), "big");

// A literal like `7.0` is normalised to a fastint at parse time, so it does NOT
// exercise the fastint/double split. These do: the key arrives as a genuine
// double, from arithmetic or from a magnitude outside the fastint range, and
// must still match the fastint form.
numMap.set(3.5 * 2, "seven");
eq("double from arithmetic", numMap.get(7), "seven");
numMap.set(7, "seven again");
eq("no duplicate for 7", numMap.get(3.5 * 2), "seven again");
eq("2^53 key", (numMap.set(9007199254740992, "p53"), numMap.get(9007199254740992)), "p53");
eq("fraction stays distinct", (numMap.set(7.5, "half"), numMap.get(7)), "seven again");

// Strings compare by content. Over MAX_INTERN_BYTES they are not interned, so
// two equal strings are distinct objects and a pointer hash would split them.
var longA = "", longB = "";
for (var i = 0; i < 40; i++) { longA += "abcde"; longB += "abcde"; }
var strSet = new Set();
fill(strSet, 20, function (s, i) { s.add("s" + i); });
strSet.add(longA);
eq("long string by content", strSet.has(longB), true);
eq("long string not duplicated", (strSet.add(longB), strSet.size), 21);

// Objects are keyed by identity.
var o1 = {}, o2 = {};
var objSet = new Set();
fill(objSet, 20, function (s, i) { s.add(i); });
objSet.add(o1);
eq("object identity hit", objSet.has(o1), true);
eq("object identity miss", objSet.has(o2), false);

// --- Tombstones ----------------------------------------------------------

// A deleted entry keeps its array slot so live iterators still work; probing
// must step over the tombstone rather than stop, or a key inserted afterwards
// becomes unreachable.
var tomb = new Set();
fill(tomb, 50, function (s, i) { s.add(i); });
tomb.delete(25);
eq("deleted key gone", tomb.has(25), false);
tomb.add(25);
eq("re-added key found", tomb.has(25), true);
eq("re-add keeps size", tomb.size, 50);

// Heavy delete/re-add churn: the index must rebuild rather than degrade into
// one long probe chain of tombstones.
var churn = new Set();
fill(churn, 200, function (s, i) { s.add(i); });
for (var i = 0; i < 100; i++) { churn.delete(i); }
eq("after deletes", churn.size, 100);
for (var i = 0; i < 100; i++) { churn.add(i); }
eq("after re-adds", churn.size, 200);
eq("re-added lookups", churn.has(0) && churn.has(50) && churn.has(99), true);

// --- Iteration order -----------------------------------------------------

// array_part stays authoritative, so insertion order is unchanged.
var ordered = new Set();
fill(ordered, 50, function (s, i) { s.add(i); });
var seen = [];
ordered.forEach(function (v) { seen.push(v); });
eq("insertion order kept", seen[0] + ".." + seen[49] + " n=" + seen.length, "0..49 n=50");

// Deleting mid-iteration must not disturb the entries already queued.
var midDelete = new Set();
fill(midDelete, 30, function (s, i) { s.add(i); });
var collected = [];
midDelete.forEach(function (v) { collected.push(v); if (v === 5) { midDelete.delete(20); } });
eq("delete during iteration", collected.indexOf(20), -1);

// --- Map-specific --------------------------------------------------------

// Overwriting a value must not add a second entry for the key.
var over = new Map();
fill(over, 50, function (m, i) { m.set(i, i); });
over.set(25, "replaced");
eq("overwrite keeps size", over.size, 50);
eq("overwrite new value", over.get(25), "replaced");

// --- Crossing the index threshold ----------------------------------------

// The index appears partway through, so every size on the way must be right.
var growing = new Set();
var growOk = true;
for (var i = 0; i < 40; i++) {
    growing.add(i);
    if (growing.size !== i + 1 || !growing.has(i) || !growing.has(0)) { growOk = false; break; }
}
eq("consistent while growing", growOk, true);

// Mixed key types share one index and must not collide destructively.
var mixed = new Set();
mixed.add(1); mixed.add("1"); mixed.add(true); mixed.add(null);
mixed.add(undefined); mixed.add(NaN);
for (var i = 0; i < 20; i++) { mixed.add("k" + i); }
eq("mixed types size", mixed.size, 26);
eq("number vs string key", mixed.has(1) && mixed.has("1"), true);
eq("null vs undefined key", mixed.has(null) && mixed.has(undefined), true);

// WeakMap/WeakSet share the same lookup path.
var wsKeys = [];
var ws = new WeakSet();
for (var i = 0; i < 20; i++) { var k = {}; wsKeys.push(k); ws.add(k); }
eq("WeakSet lookup", ws.has(wsKeys[0]) && ws.has(wsKeys[19]), true);

var wmKeys = [];
var wm = new WeakMap();
for (var i = 0; i < 20; i++) { var k = {}; wmKeys.push(k); wm.set(k, i); }
eq("WeakMap lookup", wm.get(wmKeys[7]), 7);
wm.delete(wmKeys[7]);
eq("WeakMap delete", wm.has(wmKeys[7]), false);

print(fail === 0 ? "test_collection_hash_index: all passed"
                 : "test_collection_hash_index: " + fail + " FAILED");

// Set operations
// Demonstrates union / intersection / difference on a plain-object set.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function setOf(arr) {
    var s = {};
    for (var i = 0; i < arr.length; i++) s[arr[i]] = true;
    return s;
}

function toArray(s) {
    var out = [];
    for (var k in s) if (s.hasOwnProperty(k)) out.push(k);
    return out.sort();
}

function union(a, b) {
    var r = {};
    for (var k in a) if (a.hasOwnProperty(k)) r[k] = true;
    for (var k in b) if (b.hasOwnProperty(k)) r[k] = true;
    return r;
}

function intersection(a, b) {
    var r = {};
    for (var k in a) if (a.hasOwnProperty(k) && b.hasOwnProperty(k)) r[k] = true;
    return r;
}

function difference(a, b) {
    var r = {};
    for (var k in a) if (a.hasOwnProperty(k) && !b.hasOwnProperty(k)) r[k] = true;
    return r;
}

var a = setOf([1, 2, 3, 4]);
var b = setOf([3, 4, 5, 6]);

assert(toArray(union(a, b)).join(",") === "1,2,3,4,5,6", "union");
assert(toArray(intersection(a, b)).join(",") === "3,4", "intersection");
assert(toArray(difference(a, b)).join(",") === "1,2", "diff a-b");
assert(toArray(difference(b, a)).join(",") === "5,6", "diff b-a");

// Cardinality
function cardinality(s) {
    var n = 0;
    for (var k in s) if (s.hasOwnProperty(k)) n++;
    return n;
}

assert(cardinality(a) === 4, "card a=4");
assert(cardinality(intersection(a, b)) === 2, "card inter=2");

// Subset
function isSubset(a, b) {
    for (var k in a) if (a.hasOwnProperty(k) && !b.hasOwnProperty(k)) return false;
    return true;
}

assert(isSubset(setOf([3, 4]), a), "{3,4} subset of a");
assert(!isSubset(setOf([7]), a), "{7} not subset of a");

print("engine/set_ops: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
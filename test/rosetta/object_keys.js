// Rosetta Code: Object keys and enumeration
// https://rosettacode.org/wiki/Object_keys
// Tests Object.keys, for...in over own properties. TinyDuck has no prototype
// chain, so every key walk is own-property-only.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Object.keys on simple object
var obj = { a: 1, b: 2, c: 3 };
var keys = Object.keys(obj);
assert(keys.length === 3, "3 keys");
assert(keys.indexOf("a") >= 0, "has key a");
assert(keys.indexOf("b") >= 0, "has key b");
assert(keys.indexOf("c") >= 0, "has key c");

// Object.keys on empty
assert(Object.keys({}).length === 0, "empty object keys");
assert(Object.keys([]).length === 0, "empty array keys");

// Object.keys on array (indices as strings)
assert(Object.keys([10, 20, 30]).join(",") === "0,1,2", "array keys are indices");

// Delete property removes from Object.keys
var d = { a: 1, b: 2, c: 3 };
delete d.b;
var dk = Object.keys(d);
assert(dk.length === 2, "after delete, 2 keys");
assert(dk.indexOf("b") === -1, "b is gone");

// Object.keys with numeric-looking keys
var numKeys = { "0": "a", "1": "b", "10": "c" };
var nk = Object.keys(numKeys);
assert(nk.length === 3, "3 numeric keys");
assert(nk.indexOf("0") >= 0, "has key 0");
assert(nk.indexOf("10") >= 0, "has key 10");

// for...in counts own props only
var counted = 0;
var multi = { a: 1, b: 2, c: 3, d: 4, e: 5 };
for (var k in multi) { counted++; }
assert(counted === 5, "for..in counts 5");

// for...in walks own props only — no prototype chain
var own = [];
var instance = { x: 1, y: 2 };
for (var k in instance) { own.push(k); }
assert(own.length === 2, "for..in only own props");
assert(own.indexOf("x") >= 0 && own.indexOf("y") >= 0, "for..in sees x and y");
assert(own.indexOf("toString") === -1, "for..in does not see toString (no proto)");

// Object.keys agrees with for...in (own only)
assert(Object.keys(instance).length === 2, "Object.keys own only");

print("rosetta/object_keys: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

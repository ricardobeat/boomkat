// Object keys and enumeration
// Tests Object.keys, for...in, hasOwnProperty, enumeration order.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Object.keys on simple object
var obj = { a: 1, b: 2, c: 3 };
var keys = Object.keys(obj);
assert(keys.length === 3, "3 keys");
assert(keys.indexOf("a") >= 0, "has key a");
assert(keys.indexOf("b") >= 0, "has key b");
assert(keys.indexOf("c") >= 0, "has key c");

// Object.keys does not include inherited
function Parent() { this.x = 1; }
Parent.prototype.y = 2;
var child = new Parent();
var childKeys = Object.keys(child);
assert(childKeys.length === 1, "only own enumerable");
assert(childKeys[0] === "x", "own key x");
assert(childKeys.indexOf("y") === -1, "inherited y not in keys");

// for...in includes inherited
var allKeys = [];
for (var k in child) { allKeys.push(k); }
assert(allKeys.indexOf("x") >= 0, "for..in sees x");
assert(allKeys.indexOf("y") >= 0, "for..in sees inherited y");

// hasOwnProperty filtering in for...in
var ownOnly = [];
for (var k in child) {
    if (child.hasOwnProperty(k)) ownOnly.push(k);
}
assert(ownOnly.length === 1 && ownOnly[0] === "x", "hasOwnProperty filter");

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

// Adding non-enumerable (should not appear in Object.keys)
Object.defineProperty(d, "hidden", { value: 42, enumerable: false });
assert(Object.keys(d).indexOf("hidden") === -1, "non-enumerable not in keys");
assert(d.hidden === 42, "non-enumerable still accessible");

// Object.keys with numeric-looking keys
var numKeys = { "0": "a", "1": "b", "10": "c" };
var nk = Object.keys(numKeys);
// Numeric string keys are sorted numerically first in V8; Duktape may differ
assert(nk.length === 3, "3 numeric keys");
assert(nk.indexOf("0") >= 0, "has key 0");
assert(nk.indexOf("10") >= 0, "has key 10");

// Property count via loop
var counted = 0;
var multi = { a: 1, b: 2, c: 3, d: 4, e: 5 };
for (var k in multi) { counted++; }
assert(counted === 5, "for..in counts 5");

print("engine/object_keys: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

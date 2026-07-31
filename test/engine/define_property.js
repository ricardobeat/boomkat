// Property descriptors
// Tests hasOwnProperty, property enumeration, delete, 'in' operator.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Basic property access and 'in'
var obj = { a: 1, b: 2, c: 3 };
assert(obj.a === 1, "property access");
assert("a" in obj, "'in' sees own property");
assert(!("d" in obj), "'in' rejects missing property");

// hasOwnProperty
assert(obj.hasOwnProperty("a"), "hasOwnProperty own");
assert(!obj.hasOwnProperty("toString"), "hasOwnProperty not inherited");
assert("toString" in obj, "'in' sees inherited");

// Property enumeration with for-in
var keys = [];
for (var k in obj) keys.push(k);
assert(keys.length === 3, "for-in enumerates 3 keys");
assert(keys.indexOf("a") !== -1, "for-in includes a");

// Object.keys
var ownKeys = Object.keys(obj);
assert(ownKeys.length === 3, "Object.keys length");
assert(ownKeys.indexOf("b") !== -1, "Object.keys includes b");

// Delete
obj.d = 4;
assert("d" in obj, "d added");
delete obj.d;
assert(!("d" in obj), "d deleted");
assert(obj.d === undefined, "d is undefined after delete");

// Property enumeration after deletion
obj = { x: 10, y: 20 };
delete obj.x;
keys = [];
for (var k2 in obj) keys.push(k2);
assert(keys.length === 1, "only one key after delete");
assert(keys[0] === "y", "remaining key is y");

// Prototype chain and 'in'
function Animal(name) { this.name = name; }
Animal.prototype.speak = function() { return this.name + " speaks"; };
var cat = new Animal("cat");
assert(cat.hasOwnProperty("name"), "own property name");
assert(!cat.hasOwnProperty("speak"), "speak is on prototype");
assert("speak" in cat, "'in' sees prototype method");
assert(cat.speak() === "cat speaks", "prototype method works");

// Nested objects
var nested = { level1: { level2: 42 } };
assert("level1" in nested, "top level in");
assert("level2" in nested.level1, "nested level in");
assert(nested.level1.level2 === 42, "nested access");

// Property with different value types
var types = {
    num: 42,
    str: "hello",
    bool: true,
    nil: null,
    arr: [1, 2, 3],
    obj: { nested: true }
};
assert(types.num === 42, "number value");
assert(types.str === "hello", "string value");
assert(types.bool === true, "boolean value");
assert(types.nil === null, "null value");
assert(types.arr.length === 3, "array value");
assert(types.obj.nested === true, "nested object value");

// Overwriting properties
var mutable = { x: 1 };
mutable.x = 2;
assert(mutable.x === 2, "overwrite primitive");
mutable.x = "string";
assert(mutable.x === "string", "change type");

print("engine/define_property: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

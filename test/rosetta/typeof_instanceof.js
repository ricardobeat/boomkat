// Rosetta Code: typeof and instanceof
// https://rosettacode.org/wiki/Type_of
// Tests typeof operator, instanceof, null/undefined edge cases.
// TinyDuck has no prototype reassignment via `.prototype =`, so that case
// is dropped; instanceof is a class-id check.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// typeof for primitives
assert(typeof 42 === "number", "typeof number");
assert(typeof 3.14 === "number", "typeof float");
assert(typeof NaN === "number", "typeof NaN is number");
assert(typeof Infinity === "number", "typeof Infinity is number");
assert(typeof "hello" === "string", "typeof string");
assert(typeof "" === "string", "typeof empty string");
assert(typeof true === "boolean", "typeof true");
assert(typeof false === "boolean", "typeof false");
assert(typeof undefined === "undefined", "typeof undefined");

// typeof null is "object" (JS quirk)
assert(typeof null === "object", "typeof null is 'object'");

// typeof for non-primitives
assert(typeof {} === "object", "typeof object");
assert(typeof [] === "object", "typeof array is object");
assert(typeof function(){} === "function", "typeof function");
assert(typeof /regex/ === "object", "typeof regex is object");
assert(typeof new Date() === "object", "typeof date is object");
assert(typeof new RegExp("a") === "object", "typeof RegExp is object");

// typeof for undeclared variable
assert(typeof undeclaredVar === "undefined", "typeof undeclared is undefined");

// Array.isArray
assert(Array.isArray([]) === true, "isArray empty");
assert(Array.isArray([1,2,3]) === true, "isArray non-empty");
assert(Array.isArray({}) === false, "isArray object");
assert(Array.isArray("string") === false, "isArray string");
assert(Array.isArray(null) === false, "isArray null");
assert(Array.isArray(undefined) === false, "isArray undefined");

print("rosetta/typeof_instanceof: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

// typeof and instanceof
// Tests typeof operator, instanceof, null/undefined edge cases.

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

// instanceof
function Foo() {}
var f = new Foo();
assert(f instanceof Foo, "instanceof Foo");
assert(f instanceof Object, "instanceof Object");
assert([] instanceof Array, "array instanceof Array");
assert([] instanceof Object, "array instanceof Object");
assert(/x/ instanceof RegExp, "regex instanceof RegExp");
assert(new Date() instanceof Date, "date instanceof Date");

// Negated instanceof
assert(!("hello" instanceof String), "string literal not instanceof String");
assert(!(42 instanceof Number), "number literal not instanceof Number");
assert(!({} instanceof Array), "object not instanceof Array");

// instanceof with prototype reassignment
function Bar() {}
var b = new Bar();
assert(b instanceof Bar, "b instanceof Bar before");
Bar.prototype = {};
assert(!(b instanceof Bar), "b not instanceof Bar after proto change");

// Constructor check
assert(new String("hi").constructor === String, "String constructor");
assert(new Number(42).constructor === Number, "Number constructor");
assert(new Array(3).constructor === Array, "Array constructor");

// Array.isArray
assert(Array.isArray([]) === true, "isArray empty");
assert(Array.isArray([1,2,3]) === true, "isArray non-empty");
assert(Array.isArray({}) === false, "isArray object");
assert(Array.isArray("string") === false, "isArray string");
assert(Array.isArray(null) === false, "isArray null");
assert(Array.isArray(undefined) === false, "isArray undefined");

print("engine/typeof_instanceof: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

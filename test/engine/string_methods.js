// String methods
// Tests charAt, indexOf, substring, slice, toUpperCase, toLowerCase, trim, replace.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

var s = "Hello, World!";

// charAt
assert(s.charAt(0) === "H", "charAt(0)");
assert(s.charAt(7) === "W", "charAt(7)");
assert(s.charAt(99) === "", "charAt out of bounds");
assert(s[0] === "H", "bracket access [0]");
assert(s[7] === "W", "bracket access [7]");

// indexOf
assert(s.indexOf("World") === 7, "indexOf substring");
assert(s.indexOf("xyz") === -1, "indexOf not found");
assert(s.indexOf("l") === 2, "indexOf first occurrence");
assert(s.indexOf("l", 3) === 3, "indexOf from position");
assert(s.lastIndexOf("l") === 10, "lastIndexOf");
assert(s.lastIndexOf("l", 9) === 3, "lastIndexOf with fromIndex");

// substring
assert(s.substring(0, 5) === "Hello", "substring(0,5)");
assert(s.substring(7) === "World!", "substring(7)");
assert(s.substring(7, 12) === "World", "substring(7,12)");
// substring swaps args if start > end
assert(s.substring(5, 0) === "Hello", "substring swaps args");

// slice
assert(s.slice(0, 5) === "Hello", "slice(0,5)");
assert(s.slice(-6) === "World!", "slice negative");
assert(s.slice(-6, -1) === "World", "slice negative both");
assert(s.slice(7, 12) === "World", "slice(7,12)");

// toUpperCase / toLowerCase
assert(s.toUpperCase() === "HELLO, WORLD!", "toUpperCase");
assert(s.toLowerCase() === "hello, world!", "toLowerCase");
assert("abc".toUpperCase() === "ABC", "abc to upper");

// trim
assert("  hello  ".trim() === "hello", "trim spaces");
assert("\t\nhello\t\n".trim() === "hello", "trim tabs/newlines");
assert("no trim".trim() === "no trim", "no trim needed");

// split and join
assert("a,b,c".split(",").length === 3, "split length");
assert("a,b,c".split(",").join("-") === "a-b-c", "split then join");
assert("abc".split("").join("-") === "a-b-c", "split chars");

// concat
assert("foo".concat("bar") === "foobar", "concat");
assert("".concat("a", "b", "c") === "abc", "concat multi");

// charCodeAt
assert(s.charCodeAt(0) === 72, "charCodeAt(0) = H");
assert("A".charCodeAt(0) === 65, "charCodeAt A");

// String.fromCharCode
assert(String.fromCharCode(65) === "A", "fromCharCode 65");
assert(String.fromCharCode(72, 105) === "Hi", "fromCharCode multi");

// replace (first occurrence)
assert("aabbaa".replace("aa", "xx") === "xxbbaa", "replace first");
assert("aabbaa".replace(/aa/g, "xx") === "xxbbxx", "replace all regex");

print("engine/string_methods: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

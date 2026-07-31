// Regular expressions
// Tests RegExp matching, replacing, and extracting.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Basic match
assert(/hello/.test("hello world") === true, "basic match");
assert(/xyz/.test("hello world") === false, "basic no match");

// Test with exec
var m = /(\d+)-(\d+)/.exec("phone: 123-456");
assert(m !== null, "exec finds match");
assert(m[0] === "123-456", "full match");
assert(m[1] === "123", "group 1");
assert(m[2] === "456", "group 2");

// Replace
var r = "hello world".replace(/world/, "JS");
assert(r === "hello JS", "replace: " + r);

// Replace with function
var r2 = "abc 123 def 456".replace(/\d+/, function(match) { return "[" + match + "]"; });
assert(r2 === "abc [123] def 456", "replace fn: " + r2);

// Global replace
var r3 = "aabbaa".replace(/aa/g, "xx");
assert(r3 === "xxbbxx", "global replace: " + r3);

// String.match with global
var gm = "12 34 56".match(/\d+/g);
assert(gm !== null && gm.length === 3, "global match 3 results");
assert(gm[2] === "56", "third match is 56");

// Split
var parts = "one::two::three".split(/::+/);
assert(parts.length === 3, "split into 3");
assert(parts[1] === "two", "middle part");

// Anchors and special chars
assert(/^start/.test("start end") === true, "anchored start");
assert(/end$/.test("start end") === true, "anchored end");
assert(/^\d{3}-\d{4}$/.test("555-1234") === true, "exact pattern");
assert(/^\d{3}-\d{4}$/.test("55-1234") === false, "pattern no match");

print("engine/regexp: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

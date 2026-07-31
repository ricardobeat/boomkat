// String comparison
// Compare two strings: equal / less / greater / startsWith / endsWith / contains.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function compareStrings(a, b) {
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
}

assert(compareStrings("apple", "banana") === -1, "apple < banana");
assert(compareStrings("banana", "apple") === 1, "banana > apple");
assert(compareStrings("apple", "apple") === 0, "apple = apple");

// Case-insensitive compare
function ciCompare(a, b) {
    var la = a.toLowerCase(), lb = b.toLowerCase();
    if (la < lb) return -1;
    if (la > lb) return 1;
    return 0;
}

assert(ciCompare("Apple", "apple") === 0, "ci apple=apple");
assert(ciCompare("apple", "Banana") === -1, "ci apple < banana");

// Lexicographic: shorter prefix is less
assert(compareStrings("abc", "abcd") === -1, "abc < abcd");

// Startswith / endsWith
function startsWith(s, prefix) {
    return s.indexOf(prefix) === 0;
}
function endsWith(s, suffix) {
    var i = s.lastIndexOf(suffix);
    return i !== -1 && i === s.length - suffix.length;
}
function contains(s, sub) { return s.indexOf(sub) !== -1; }

assert(startsWith("hello world", "hello"), "startsWith hello");
assert(!startsWith("hello world", "world"), "not startsWith world");
assert(endsWith("hello world", "world"), "endsWith world");
assert(endsWith("test.js", ".js"), "endsWith .js");
assert(contains("hello world", "lo w"), "contains");
assert(!contains("hello", "xyz"), "not contains");

print("engine/string_compare: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
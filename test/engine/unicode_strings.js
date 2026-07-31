// Unicode and string escapes
// Tests string escape sequences, character encoding, special chars.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Escape sequences
assert("\n".length === 1, "newline length 1");
assert("\t".length === 1, "tab length 1");
assert("\r".length === 1, "carriage return length 1");
assert("\\".length === 1, "backslash length 1");
assert("\"".length === 1, "double quote length 1");
assert("\'".length === 1, "single quote length 1");
assert("\0".length === 1, "null char length 1");

// Hex escape
assert("\x41" === "A", "\\x41 = A");
assert("\x48\x69" === "Hi", "\\x48\\x69 = Hi");
assert("\x61\x62\x63" === "abc", "\\x61\\x62\\x63 = abc");

// Unicode escape
assert("\u0041" === "A", "\\u0041 = A");
assert("\u00E9" === "\u00E9", "\\u00E9 = e-acute");
assert("\u00FC" === "\u00FC", "\\u00FC = u-umlaut");
assert("\u4F60\u597D" === "\u4F60\u597D", "Chinese chars");
assert("\u03B1\u03B2\u03B3" === "\u03B1\u03B2\u03B3", "Greek alpha beta gamma");

// String length with special chars
assert("cafe\u0301".length === 5, "cafe + combining accent = 5 chars");
assert("\uD83D\uDE00".length === 2, "emoji surrogate pair = 2 code units");

// Quote styles
var dq = "same string";
var sq = 'same string';
assert(dq === sq, "double and single quotes equal");

// Multi-line via string concat or escape
var ml = "line one\nline two\nline three";
var lines = ml.split("\n");
assert(lines.length === 3, "3 lines");
assert(lines[0] === "line one", "first line");
assert(lines[2] === "line three", "third line");

// Tab-separated values
var tsv = "a\tb\tc";
var cols = tsv.split("\t");
assert(cols.length === 3, "3 columns");
assert(cols.join(",") === "a,b,c", "tab split values");

// Backslash in strings
var path = "C:\\Users\\test";
assert(path.indexOf("Users") === 3, "backslash path");
assert(path.length === 13, "backslash path length");

// Empty string operations
assert("".length === 0, "empty length 0");
assert("".charAt(0) === "", "charAt(0) of empty");
assert("" + "" === "", "empty concat");
assert("".indexOf("a") === -1, "indexOf in empty");

// String comparison (lexicographic)
assert("a" < "b", "a < b");
assert("abc" < "abd", "abc < abd");
assert("z" > "a", "z > a");
assert("10" < "9", "'10' < '9' (string comparison)");
assert("abc" === "abc", "same strings equal");

// Repeated string via pattern
var rep = new Array(4).join("ab");
assert(rep === "ababab", "repeat via join");

// String constructor edge case
assert(String(42) === "42", "String(42)");
assert(new String("hi").valueOf() === "hi", "new String valueOf");
assert(typeof new String("hi") === "object", "new String is object");

print("engine/unicode_strings: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

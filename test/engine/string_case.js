// String case folding
// Tests toUpperCase / toLowerCase / case-insensitive compare.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

var s = "Hello, World!";

assert(s.toUpperCase() === "HELLO, WORLD!", "toUpperCase basic");
assert("FoO".toLowerCase() === "foo", "toLowerCase basic");

// Case-insensitive equality
function ciEquals(a, b) {
    return a.length === b.length && a.toUpperCase() === b.toUpperCase();
}

assert(ciEquals("JavaScript", "javascript"), "ciEquals JS/js");
assert(!ciEquals("Java", "JavaScript"), "ciEquals mismatch");
assert(ciEquals("ABC", "abc"), "ciEquals simple");

// Title case (simple)
function titleCase(s) {
    return s.split(" ").map(function (w) {
        if (w.length === 0) return "";
        return w[0].toUpperCase() + w.slice(1).toLowerCase();
    }).join(" ");
}

assert(titleCase("hello world") === "Hello World", "titleCase basic");
assert(titleCase("the QUICK brown FOX") === "The Quick Brown Fox", "titleCase mixed");

print("engine/string_case: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
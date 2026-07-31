// Towers of Hanoi (visualization)
// ASCII art of the towers after each move.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

// Reverse string
function reverse(s) {
    var out = "";
    for (var i = s.length - 1; i >= 0; i--) out += s[i];
    return out;
}

assert(reverse("hello") === "olleh", "reverse hello");
assert(reverse("") === "", "reverse empty");
assert(reverse("a") === "a", "reverse a");

// Center-align a string in a width
function center(s, w) {
    if (s.length >= w) return s;
    var pad = w - s.length;
    var left = (pad / 2) | 0;
    var right = pad - left;
    var out = "";
    for (var i = 0; i < left; i++) out += " ";
    out += s;
    for (var i = 0; i < right; i++) out += " ";
    return out;
}

assert(center("ab", 6) === "  ab  ", "center even pad");
assert(center("abc", 7) === "  abc  ", "center odd pad");

// Pad-left to width
function padLeft(s, w, ch) {
    if (ch === undefined) ch = " ";
    while (s.length < w) s = ch + s;
    return s;
}

assert(padLeft("5", 3, "0") === "005", "pad-left zeros");
assert(padLeft("hello", 3) === "hello", "pad-left no-op");

// Pad-right
function padRight(s, w, ch) {
    if (ch === undefined) ch = " ";
    while (s.length < w) s = s + ch;
    return s;
}

assert(padRight("hi", 5) === "hi   ", "pad-right");
assert(padRight("hi", 5, ".") === "hi...", "pad-right dots");

// Repeat
function repeat(s, n) {
    var out = "";
    for (var i = 0; i < n; i++) out += s;
    return out;
}

assert(repeat("ab", 3) === "ababab", "repeat");
assert(repeat("", 5) === "", "repeat empty");

print("engine/string_helpers: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
// Generate lower case ASCII alphabet
// Generate 'a'..'z' in several ways.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function alphaFromCharCode() {
    var s = "";
    for (var i = 0; i < 26; i++) s += String.fromCharCode(97 + i);
    return s;
}

function alphaAsArray() {
    var a = [];
    for (var i = 0; i < 26; i++) a.push(String.fromCharCode(97 + i));
    return a.join("");
}

function alphaFromMap() {
    return "abcdefghijklmnopqrstuvwxyz";
}

var expected = "abcdefghijklmnopqrstuvwxyz";
assert(alphaFromCharCode() === expected, "from charCode");
assert(alphaAsArray() === expected, "from array");
assert(alphaFromMap() === expected, "literal");

// Uppercase
function upperAlpha() {
    var s = "";
    for (var i = 0; i < 26; i++) s += String.fromCharCode(65 + i);
    return s;
}

assert(upperAlpha() === "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "uppercase alphabet");

// Digits
function digits() {
    var s = "";
    for (var i = 0; i < 10; i++) s += String.fromCharCode(48 + i);
    return s;
}

assert(digits() === "0123456789", "digits 0..9");

// Index a letter by its position
function charAt(pos) { return String.fromCharCode(97 + pos); }
assert(charAt(0) === "a", "charAt(0)='a'");
assert(charAt(25) === "z", "charAt(25)='z'");
assert(charAt(13) === "n", "charAt(13)='n'");

// Reverse the alphabet
function reverseAlpha() {
    var s = "";
    for (var i = 25; i >= 0; i--) s += String.fromCharCode(97 + i);
    return s;
}
assert(reverseAlpha() === "zyxwvutsrqponmlkjihgfedcba", "reverse alphabet");

print("engine/alphabet: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
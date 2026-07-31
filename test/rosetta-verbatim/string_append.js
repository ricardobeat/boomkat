// Verbatim from https://rosettacode.org/wiki/String_append (JavaScript block 0)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
var s1 = "Hello";
s1 += ", World!";
print(s1);

var s2 = "Goodbye";
// concat() returns the strings together, but doesn't edit existing string
// concat can also have multiple parameters
print(s2.concat(", World!"));

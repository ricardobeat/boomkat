// Verbatim from https://rosettacode.org/wiki/Stack (JavaScript block 0)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
var stack = [];
stack.push(1)
stack.push(2,3);
print(stack.pop());   // 3
print(stack.length);   // 2, stack empty if 0

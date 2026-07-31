// Verbatim from https://rosettacode.org/wiki/Partial_function_application (JavaScript block 0)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
const fs = (f, s) => s.map(f);
const f1 = x => x * 2;
const f2 = x => x * x;

const fsf1 = fs.bind(null, f1);
const fsf2 = fs.bind(null, f2);

console.log(fsf1([0, 1, 2, 3])); // [0, 2, 4, 6]
console.log(fsf2([0, 1, 2, 3])); // [0, 1, 4, 9]

console.log(fsf1([2, 4, 6, 8])); // [4, 8, 12, 16]
console.log(fsf2([2, 4, 6, 8])); // [4, 16, 36, 64]

// Verbatim from https://rosettacode.org/wiki/Sequence_of_non-squares (JavaScript block 0)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
var a = [];
for (var i = 1; i < 23; i++) a[i] = i + Math.floor(1/2 + Math.sqrt(i));
console.log(a);

for (i = 1; i < 1000000; i++) if (Number.isInteger(i + Math.floor(1/2 + Math.sqrt(i))) === false) {
    console.log("The ",i,"th element of the sequence is a square");
}

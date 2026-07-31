// Verbatim from https://rosettacode.org/wiki/Towers_of_Hanoi (JavaScript block 0)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
function move(n, a, b, c) {
  if (n > 0) {
    move(n-1, a, c, b);
    console.log("Move disk from " + a + " to " + c);
    move(n-1, b, a, c);
  }
}
move(4, "A", "B", "C");

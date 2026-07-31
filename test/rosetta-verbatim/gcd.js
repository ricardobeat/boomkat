// Verbatim from https://rosettacode.org/wiki/Greatest_common_divisor (JavaScript block 0)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
function gcd(a,b) {
  a = Math.abs(a);
  b = Math.abs(b);

  if (b > a) {
    var temp = a;
    a = b;
    b = temp; 
  }

  while (true) {
    a %= b;
    if (a === 0) { return b; }
    b %= a;
    if (b === 0) { return a; }
  }
}

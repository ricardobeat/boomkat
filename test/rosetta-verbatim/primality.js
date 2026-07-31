// Verbatim from https://rosettacode.org/wiki/Primality_by_trial_division (JavaScript block 0)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
function isPrime(n) {
  if (n == 2 || n == 3 || n == 5 || n == 7) {
    return true;
  } else if ((n < 2) || (n % 2 == 0)) {
    return false;
  } else {
    for (var i = 3; i <= Math.sqrt(n); i += 2) {
      if (n % i == 0)
        return false;
    }
    return true;
  }
}

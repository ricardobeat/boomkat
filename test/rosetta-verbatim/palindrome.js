// Verbatim from https://rosettacode.org/wiki/Palindrome_detection (JavaScript block 0)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
function isPalindrome(str) {
  return str === str.split("").reverse().join("");
}

console.log(isPalindrome("ingirumimusnocteetconsumimurigni"));

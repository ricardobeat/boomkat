// Verbatim from https://rosettacode.org/wiki/Fibonacci_sequence (JavaScript block 0)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
function fib(n) {
  return n<2?n:fib(n-1)+fib(n-2);
}

// Drives fizzbuzz.js -- uses: fizzBuzz
// The sample defines fizzBuzz and prints via console.log rather than returning,
// so capture what it actually prints instead of restating its rules here.


var lines = [];
var realLog = console.log;
console.log = function (v) { lines.push(String(v)); };
try { fizzBuzz(); } finally { console.log = realLog; }

assertEq(lines.length, 100, "prints one line for 1..100");
assertEq(lines[0], "1", "1 prints itself");
assertEq(lines[2], "Fizz", "3 is Fizz");
assertEq(lines[4], "Buzz", "5 is Buzz");
assertEq(lines[14], "FizzBuzz", "15 is FizzBuzz");
assertEq(lines[99], "Buzz", "100 is Buzz");
var fizzes = lines.filter(function (l) { return l === "Fizz"; }).length;
var buzzes = lines.filter(function (l) { return l === "Buzz"; }).length;
var both = lines.filter(function (l) { return l === "FizzBuzz"; }).length;
assertEq(both, 6, "six multiples of 15");
assertEq(fizzes, 27, "27 Fizz-only lines");
assertEq(buzzes, 14, "14 Buzz-only lines");
report("fizzbuzz");

// FizzBuzz
// Prints numbers 1-100, replacing multiples of 3 with "Fizz",
// multiples of 5 with "Buzz", multiples of both with "FizzBuzz".
// Self-check: validate first 20 entries of expected output.

function fizzBuzz(n) {
    var results = [];
    for (var i = 1; i <= n; i++) {
        if (i % 15 === 0) results.push("FizzBuzz");
        else if (i % 3 === 0) results.push("Fizz");
        else if (i % 5 === 0) results.push("Buzz");
        else results.push(String(i));
    }
    return results;
}

var pass = 0;
var fail = 0;

function assert(condition, msg) {
    if (condition) { pass++; }
    else { fail++; print("FAIL: " + msg); }
}

var r = fizzBuzz(20);

assert(r[0] === "1", "fizzBuzz[0] = '1', got '" + r[0] + "'");
assert(r[2] === "Fizz", "fizzBuzz[2] = 'Fizz', got '" + r[2] + "'");
assert(r[4] === "Buzz", "fizzBuzz[4] = 'Buzz', got '" + r[4] + "'");
assert(r[14] === "FizzBuzz", "fizzBuzz[14] = 'FizzBuzz', got '" + r[14] + "'");
assert(r[19] === "Buzz", "fizzBuzz[19] = 'Buzz', got '" + r[19] + "'");

var r100 = fizzBuzz(100);
assert(r100.length === 100, "fizzBuzz(100) length 100, got " + r100.length);
assert(r100[99] === "Buzz", "fizzBuzz[99] = 'Buzz', got '" + r100[99] + "'");

print("engine/fizzbuzz: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

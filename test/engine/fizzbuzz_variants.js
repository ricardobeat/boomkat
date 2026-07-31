// FizzBuzz (variants)
// Several rule variations on the classic problem.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

// Classic: 3=Fizz, 5=Buzz, both=FizzBuzz
function classic(n) {
    var r = [];
    for (var i = 1; i <= n; i++) {
        if (i % 15 === 0) r.push("FizzBuzz");
        else if (i % 3 === 0) r.push("Fizz");
        else if (i % 5 === 0) r.push("Buzz");
        else r.push(String(i));
    }
    return r;
}

assert(classic(15)[2] === "Fizz", "classic[2]=Fizz");
assert(classic(15)[4] === "Buzz", "classic[4]=Buzz");
assert(classic(15)[14] === "FizzBuzz", "classic[14]=FizzBuzz");

// Variant: 3=Fizz, 7=Bazz
function fizzBazz(n) {
    var r = [];
    for (var i = 1; i <= n; i++) {
        var s = "";
        if (i % 3 === 0) s += "Fizz";
        if (i % 7 === 0) s += "Bazz";
        r.push(s === "" ? String(i) : s);
    }
    return r;
}

assert(fizzBazz(21)[2] === "Fizz", "fizzBazz[2]=Fizz (i=3)");
assert(fizzBazz(21)[6] === "Bazz", "fizzBazz[6]=Bazz (i=7)");
assert(fizzBazz(21)[20] === "FizzBazz", "fizzBazz[20]=FizzBazz (i=21)");

// Digit-replacement: numbers containing '3' => "Fizz", containing '5' => "Buzz"
function digitFizz(n) {
    var r = [];
    for (var i = 1; i <= n; i++) {
        var s = String(i);
        var out = "";
        var replaced = false;
        for (var j = 0; j < s.length; j++) {
            if (s[j] === "3") { out += "Fizz"; replaced = true; }
            else if (s[j] === "5") { out += "Buzz"; replaced = true; }
        }
        r.push(replaced ? out : String(i));
    }
    return r;
}

assert(digitFizz(15)[2] === "Fizz", "digitFizz[2]=Fizz (contains 3)");
assert(digitFizz(15)[4] === "Buzz", "digitFizz[4]=Buzz (contains 5)");
assert(digitFizz(15)[5] === "6", "digitFizz[5]=6 (no 3 or 5)");
assert(digitFizz(15)[0] === "1", "digitFizz[0]=1 (no 3 or 5)");
assert(digitFizz(15)[9] === "10", "digitFizz[9]=10 (no 3 or 5)");

// i=35 contains both 3 and 5 -> FizzBuzz
var big = digitFizz(53);
assert(big[34] === "FizzBuzz", "digitFizz(53)[34]=FizzBuzz (i=35)");

print("engine/fizzbuzz_variants: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
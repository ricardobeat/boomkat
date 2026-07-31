// Fibonacci word
// Strings whose concatenation follows the Fibonacci recurrence.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function fibWord(n) {
    var seq = ["0", "01"];
    if (n === 0) return seq[0];
    if (n === 1) return seq[1];
    for (var i = 2; i <= n; i++) {
        seq.push(seq[i - 1] + seq[i - 2]);
    }
    return seq[n];
}

assert(fibWord(0) === "0", "F(0)=0");
assert(fibWord(1) === "01", "F(1)=01");
assert(fibWord(2) === "010", "F(2)=010");
assert(fibWord(3) === "01001", "F(3)=01001");
assert(fibWord(4) === "01001010", "F(4)=01001010");

// Length of F(n) follows Fibonacci numbers (with F(0)=1, F(1)=2)
function fibLen(n) {
    var seq = fibWord(n);
    return seq.length;
}

assert(fibLen(5) === 13, "len F(5)=13");
assert(fibLen(6) === 21, "len F(6)=21");
assert(fibLen(7) === 34, "len F(7)=34");

// Fraction of '0's in F(n) is > 1/2 (since F(0) is all zeros and concat keeps skew)
function zeroFraction(s) {
    var n = 0;
    for (var i = 0; i < s.length; i++) if (s[i] === "0") n++;
    return n / s.length;
}

var f7 = fibWord(7);
assert(f7.length === 34, "F(7) length 34");
var z = zeroFraction(f7);
assert(z > 0.5, "F(7) zero fraction > 0.5 (got " + z + ")");

print("engine/fibonacci_word: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
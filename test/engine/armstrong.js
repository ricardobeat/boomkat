// Narcissistic / Armstrong numbers
// Numbers equal to the sum of their digits raised to the digit-count.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function digits(n) {
    var out = [];
    if (n === 0) return [0];
    var neg = n < 0;
    if (neg) n = -n;
    while (n > 0) { out.unshift(n % 10); n = (n - (n % 10)) / 10; }
    return out;
}

assert(digits(0).length === 1 && digits(0)[0] === 0, "digits(0)");
assert(digits(7).length === 1 && digits(7)[0] === 7, "digits(7)");
assert(digits(123).length === 3 && digits(123)[0] === 1 && digits(123)[2] === 3, "digits(123)");
assert(digits(1000).length === 4 && digits(1000)[0] === 1 && digits(1000)[3] === 0, "digits(1000)");

function isArmstrong(n) {
    var d = digits(n);
    var k = d.length;
    var sum = 0;
    for (var i = 0; i < d.length; i++) sum += Math.pow(d[i], k);
    return sum === n;
}

assert(isArmstrong(0), "0 is Armstrong");
assert(isArmstrong(1), "1 is Armstrong");
assert(isArmstrong(2), "2 is Armstrong");
assert(isArmstrong(153), "153 is Armstrong");
assert(isArmstrong(370), "370 is Armstrong");
assert(isArmstrong(371), "371 is Armstrong");
assert(isArmstrong(407), "407 is Armstrong");
assert(!isArmstrong(100), "100 not Armstrong");
assert(!isArmstrong(200), "200 not Armstrong");

// All Armstrong numbers in [0, 9999]
var armstrongs = [];
for (var n = 0; n < 10000; n++) if (isArmstrong(n)) armstrongs.push(n);
assert(JSON.stringify(armstrongs) === "[0,1,2,3,4,5,6,7,8,9,153,370,371,407,1634,8208,9474]", "all <10000");

print("engine/armstrong: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
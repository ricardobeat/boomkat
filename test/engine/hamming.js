// Hamming numbers
// Numbers with only 2, 3, 5 as prime factors.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function isHamming(n) {
    if (n === 1) return true;
    while (n % 2 === 0) n = n / 2;
    while (n % 3 === 0) n = n / 3;
    while (n % 5 === 0) n = n / 5;
    return n === 1;
}

assert(isHamming(1), "1 is hamming");
assert(isHamming(2), "2 is hamming");
assert(isHamming(3), "3 is hamming");
assert(isHamming(4), "4 is hamming");
assert(isHamming(5), "5 is hamming");
assert(isHamming(6), "6 is hamming");
assert(isHamming(8), "8 is hamming");
assert(isHamming(9), "9 is hamming");
assert(isHamming(10), "10 is hamming");
assert(!isHamming(7), "7 not hamming");
assert(!isHamming(11), "11 not hamming");
assert(!isHamming(14), "14 not hamming (has 7)");

// Generate first n hamming numbers
function firstHamming(n) {
    var out = [1];
    var i2 = 0, i3 = 0, i5 = 0;
    for (var k = 1; k < n; k++) {
        var next = Math.min(out[i2] * 2, out[i3] * 3, out[i5] * 5);
        out.push(next);
        if (next === out[i2] * 2) i2++;
        if (next === out[i3] * 3) i3++;
        if (next === out[i5] * 5) i5++;
    }
    return out;
}

var h20 = firstHamming(20);
// First 20: 1,2,3,4,5,6,8,9,10,12,15,16,18,20,24,25,27,30,32,36
assert(h20.length === 20, "length 20");
assert(h20[0] === 1, "[0]=1");
assert(h20[10] === 15, "[10]=15");
assert(h20[19] === 36, "[19]=36");

// All generated are hamming
for (var i = 0; i < h20.length; i++) assert(isHamming(h20[i]), "hamming[" + i + "]=" + h20[i]);

// Sorted
for (var i = 1; i < h20.length; i++) assert(h20[i] >= h20[i - 1], "sorted");

print("engine/hamming: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
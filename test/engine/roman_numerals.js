// Roman numerals
// Encode/decode integers using standard roman numeral rules.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

var PAIRS = [
    [1000, "M"], [900, "CM"], [500, "D"], [400, "CD"],
    [100, "C"], [90, "XC"], [50, "L"], [40, "XL"],
    [10, "X"], [9, "IX"], [5, "V"], [4, "IV"], [1, "I"]
];

function toRoman(n) {
    if (n <= 0 || n >= 4000) throw new Error("out of range");
    var out = "";
    for (var i = 0; i < PAIRS.length; i++) {
        var v = PAIRS[i][0], s = PAIRS[i][1];
        while (n >= v) { out += s; n -= v; }
    }
    return out;
}

function fromRoman(s) {
    var n = 0;
    for (var i = 0; i < PAIRS.length; i++) {
        var v = PAIRS[i][0], sym = PAIRS[i][1];
        while (s.indexOf(sym) === 0) { n += v; s = s.slice(sym.length); }
    }
    return n;
}

assert(toRoman(1) === "I", "1=I");
assert(toRoman(4) === "IV", "4=IV");
assert(toRoman(9) === "IX", "9=IX");
assert(toRoman(40) === "XL", "40=XL");
assert(toRoman(58) === "LVIII", "58=LVIII");
assert(toRoman(1994) === "MCMXCIV", "1994=MCMXCIV");
assert(toRoman(3999) === "MMMCMXCIX", "3999=MMMCMXCIX");

assert(fromRoman("I") === 1, "from I=1");
assert(fromRoman("IV") === 4, "from IV=4");
assert(fromRoman("LVIII") === 58, "from LVIII=58");
assert(fromRoman("MCMXCIV") === 1994, "from MCMXCIV=1994");

// Round trip
var roundTripOk = true;
for (var k = 1; k <= 100; k++) {
    if (fromRoman(toRoman(k)) !== k) {
        roundTripOk = false;
        assert(false, "round trip " + k);
        break;
    }
}
assert(roundTripOk, "round trip 1..100");

print("engine/roman_numerals: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
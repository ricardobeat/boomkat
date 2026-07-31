// Drives narcissistic.js -- uses: isNarc
// Single digits are all narcissistic; 153 = 1^3+5^3+3^3.
var narc = [0, 1, 9, 153, 370, 371, 407, 1634];
for (var i = 0; i < narc.length; i++) assert(isNarc(narc[i]), narc[i] + " is narcissistic");
var not = [10, 100, 154, 1635];
for (var j = 0; j < not.length; j++) assert(!isNarc(not[j]), not[j] + " is not narcissistic");
assert(!isNarc(-153), "negative returns false");
report("narcissistic");

function rangeCheck(ok, name) { if (!ok) throw new Error(name); }
function maskedArithmetic(output, seed, count) {
    var i = 0;
    do {
        var masked = seed & 255;
        output[i] = (masked + 1) * 2;
        seed = seed + 17;
        i++;
    } while (i < count);
    return output[count - 1];
}
var output = new Float64Array(16);
for (var warm = 0; warm < 160; warm++) {
    rangeCheck(maskedArithmetic(output, warm, 8) === (((warm + 119) & 255) + 1) * 2,
        'bounded arithmetic');
}
var seeds = [-2147483648, 2147483647, -1, -0, 0.5, NaN, Infinity, -Infinity, '7'];
for (var s = 0; s < seeds.length; s++) {
    var seed = seeds[s];
    var expected = [];
    var value = seed;
    for (var i = 0; i < 8; i++) { expected[i] = ((value & 255) + 1) * 2; value = value + 17; }
    maskedArithmetic(output, seed, 8);
    for (var i = 0; i < 8; i++) rangeCheck(output[i] === expected[i], 'range corners');
}
function guardedArithmetic(output, seed, count) {
    var i = 0;
    do {
        output[i] = i + 1;
        var integer = seed | 0;
        output[i + 8] = integer + 1;
        seed = (integer + 1) | 0;
        i++;
    } while (i < count);
    return output[8];
}
for (var warm = 0; warm < 128; warm++) rangeCheck(guardedArithmetic(output, warm, 4) === warm + 1, 'guard warm');
rangeCheck(guardedArithmetic(output, 2147483647, 4) === 2147483648, 'overflow replay');
rangeCheck(output[0] === 1 && output[1] === 2 && output[9] === -2147483647, 'overflow exact effects');
function signedAndUnsigned(output, seed) {
    var i = 0;
    do {
        var bounded = (seed & 255) - 128;
        output[i] = bounded * 0;
        output[i + 8] = seed >>> 0;
        i++;
    } while (i < 4);
    return output[0];
}
for (var warm = 0; warm < 128; warm++) signedAndUnsigned(output, 200);
rangeCheck(1 / signedAndUnsigned(output, 0) === -Infinity, 'negative zero multiply');
rangeCheck(1 / signedAndUnsigned(output, 200) === Infinity, 'positive zero multiply');
signedAndUnsigned(output, -1);
rangeCheck(output[8] === 4294967295, 'unsigned wrap');
console.log('SSA scalar ranges: PASS');

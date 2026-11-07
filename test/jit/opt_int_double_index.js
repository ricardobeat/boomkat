// Integers held as doubles (results of double arithmetic, Math.floor, division) used where the
// optimizing tier reads int32: element indices, bitwise operands, loop counters. The guard
// converts an integral double instead of exiting; -0, NaN, fractions and out-of-range values
// still leave. Compared by value against the interpreter.
var fails = 0;
function eq(a, b, msg) {
    if (Object.is(a, b) || (a !== a && b !== b)) return;
    fails++;
    print('FAIL: ' + msg + ' (got ' + a + ', want ' + b + ')');
}

// am3-like: the index arrives as a double and is incremented in the loop.
function mac(src, i, dst, j, c, n) {
    while (--n >= 0) {
        var l = src[i++] & 0x3fff;
        l = l * 3 + dst[j] + c;
        c = l >> 14;
        dst[j++] = l & 0xfffffff;
    }
    return c;
}

function idx(a, k) { return a[k] + (k | 0); }
function band(x) { return (x & 0xff) + (x >> 4); }

var src = [], dst = [];
for (var k = 0; k < 64; k++) { src.push(k * 37); dst.push(k); }
var total = 0;
for (var r = 0; r < 4000; r++) {
    var i0 = Math.floor(r % 8 / 1.0) + 0.0;
    var j0 = (r % 5) * 1.5 * 2 / 3;            // an integer computed in doubles
    total = (total + mac(src, i0, dst, j0, r & 7, 32)) | 0;
    total = (total + idx(src, Math.floor(r % 60))) | 0;
    total = (total + band(r * 0.5 * 2)) | 0;
}
eq(total, total | 0, 'total int');
print(total);

// The values the guard must not convert.
for (var r = 0; r < 3; r++) {
    eq(idx(src, -0), src[0], '-0 index');
    eq(idx(src, 1.5), undefined + 1, 'fractional index');
    eq(band(-0), 0, '-0 band');
    eq(band(NaN), 0, 'NaN band');
    eq(band(4294967296.5), (4294967296.5 & 0xff) + (4294967296.5 >> 4), 'large band');
    eq(mac(src, 0.5, dst.slice(), 0, 0, 2), mac(src, 0.5, dst.slice(), 0, 0, 2), 'fraction in loop');
}
print(fails === 0 ? 'ok' : 'FAILED ' + fails);

// A callee whose body is just past the old inliner size limit: straight-line arithmetic and
// bitwise work on two numeric parameters, accumulated into a local and bounded by a final `%`.
// The callee is called in a hot loop, so the inliner sees it at a call site; the results are
// checked against a second run of the same arithmetic through a differently shaped loop, so the
// check holds in the interpreter and in every JIT mode.
function mix(a, b) {
    var r = a;
    r = r + b;
    r = r - 3;
    r = r * 5;
    r = r | 7;
    r = r & 255;
    r = r ^ 11;
    r = r << 2;
    r = r >>> 1;
    r = r + (a * b);
    r = r - (b - a);
    r = r * 2;
    r = r | 1;
    r = r & 4095;
    r = r ^ 13;
    r = r << 1;
    r = r >>> 2;
    r = r + 17;
    r = r - 5;
    r = r * 3;
    r = r + (a - b);
    r = r * 2;
    r = r | 3;
    r = r & 2047;
    r = r ^ 21;
    r = r << 3;
    r = r >>> 3;
    r = r + 29;
    r = r - 11;
    r = r * 5;
    r = r + (b * 3);
    r = r * 2;
    r = r | 5;
    r = r & 8191;
    r = r ^ 27;
    r = r << 2;
    r = r >>> 1;
    r = r + 31;
    r = r * 3;
    r = r + (a * 2);
    r = r * 2;
    r = r | 7;
    r = r & 4095;
    r = r ^ 19;
    r = r << 4;
    r = r >>> 4;
    r = r + 37;
    r = r % 1000003;
    return r;
}

// The same calls in a counting loop, summed.
function sumForwards(n) {
    var s = 0;
    for (var i = 0; i < n; i++) s = s + mix(i & 1023, (i * 7) & 255);
    return s;
}

// The same calls with the same arguments, in a countdown loop with the addition on the other
// side, so the two sums agree only if the arithmetic is the same.
function sumBackwards(n) {
    var s = 0;
    var i = n;
    while (i > 0) {
        i = i - 1;
        s = mix(i & 1023, (i * 7) & 255) + s;
    }
    return s;
}

var sumA = sumForwards(30000);
var sumB = sumBackwards(30000);

if (sumA !== sumB) throw new Error("opt_inline_sizes: sums differ: " + sumA + " vs " + sumB);
if (sumA === 0) throw new Error("opt_inline_sizes: sum is zero");
if (!Number.isInteger(sumA)) throw new Error("opt_inline_sizes: sum is not an integer: " + sumA);

print("opt_inline_sizes: ok");

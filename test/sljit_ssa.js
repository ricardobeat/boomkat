// Differential checks for loops that the SSA path can lower, also run
// against the interpreter and the straight-line fallback.
function check(actual, expected, label) {
    if (actual !== expected) throw new Error(label + ": " + actual + " != " + expected);
}
function fields(o, n) {
    var a = o.array;
    var sum = 0;
    for (var i = 0; i < n; i++) sum += a[i];
    return sum;
}
function counters(n) {
    var sum = 0;
    while (--n >= 0) sum += n;
    return sum;
}
function copy(o, w, n) {
    var a = o.array, b = w.array;
    var i = 0, j = 0;
    while (--n >= 0) b[j++] = a[i++];
    return j;
}
function mixed(o, w) {
    var a = o.array, b = w.array;
    var xl = 8191 & 0x3fff, xh = 8191 >> 14;
    var i = 0, j = 0, c = 0, n = 32;
    while (--n >= 0) {
        var l = a[i] & 0x3fff;
        var h = a[i++] >> 14;
        var m = xh * l + h * xl;
        l = xl * l + ((m & 0x3fff) << 14) + b[j] + c;
        c = (l >> 28) + (m >> 14) + xh * h;
        b[j++] = l & 0xfffffff;
    }
    return c;
}
function am3(o, w) {
    var a = o.array, b = w.array;
    var xl = 8191 & 0x3fff, xh = 8191 >> 14;
    var i = 0, j = 0, c = 0, n = 32;
    while (--n >= 0) {
        var l = a[i] & 0x3fff;
        var h = a[i++] >> 14;
        var m = xh * l + h * xl;
        l = xl * l + ((m & 0x3fff) << 14) + b[j] + c;
        c = (l >> 28) + (m >> 14) + xh * h;
        b[j++] = l & 0xfffffff;
    }
    return c;
}
var a = [], b = [];
for (var k = 0; k < 32; k++) {
    a.push(((k + 1) * 7919) & 0xfffffff);
    b.push(((k + 1) * 3571) & 0xfffffff);
}
var o = { array: a }, w = { array: b };
check(fields(o, 8), 285084, "fields");
check(counters(8), 28, "counters");
check(copy(o, w, 8), 8, "copy");
check(w.array.slice(0, 8).join(','), a.slice(0, 8).join(','), "copy values");
w = { array: b.slice() };
check(mixed(o, w), 7, "mixed");
// Reuse the same objects across calls so the loop-carried values are not
// recreated by a fresh interpreter frame. Guards may exit to the interpreter.
var shared = { r: { array: a.slice() }, w: { array: b.slice() } };
var rolling = 0;
for (var round = 0; round < 40; round++) rolling = (rolling * 31 + am3(shared.r, shared.w)) | 0;
check(rolling, -1551793185, "am3 reuse");
print("sljit SSA: PASS");

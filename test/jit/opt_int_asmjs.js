// asm.js-style integer code (Mandreel, zlib): heap views read through globals and captured
// variables, more loop-carried values than machine registers, a guarded assignment to a global,
// and functions whose operands never leave int32 (no operand feedback at all).
var heap8 = new Int8Array(4096), heapU16 = new Uint16Array(heap8.buffer), heap32 = new Int32Array(heap8.buffer);
var r_g0 = 0;

function fill(sp) {
    var fp = sp >> 2, r0 = heap32[fp + 2], r1 = heap32[fp], r2 = heap32[fp + 1], r3 = r1;
    if (!(r0 == 0)) {
        lp: while (true) {
            r0 = (r0 + -1) | 0;
            heap8[r3] = r2;
            r3 = (r3 + 1) | 0;
            if (r0 != 0) continue lp; else break lp;
        }
    }
    r_g0 = r1;
}

// Twenty values live around the loop.
function wide(n) {
    var a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8, i = 9, j = 10;
    var k = 11, l = 12, m = 13, o = 14, p = 15, q = 16, r = 17, s = 18, t = 19, u = 20;
    for (var x = 0; x < n; x++) {
        a = (a + b) | 0; b = (b ^ c) | 0; c = (c + d) | 0; d = (d ^ e) | 0; e = (e + f) | 0;
        f = (f ^ g) | 0; g = (g + h) | 0; h = (h ^ i) | 0; i = (i + j) | 0; j = (j ^ k) | 0;
        k = (k + l) | 0; l = (l ^ m) | 0; m = (m + o) | 0; o = (o ^ p) | 0; p = (p + q) | 0;
        q = (q ^ r) | 0; r = (r + s) | 0; s = (s ^ t) | 0; t = (t + u) | 0; u = (u ^ a) | 0;
        heapU16[(x & 255) + 512] = (a + u) & 0xffff;
    }
    return (a ^ b ^ c ^ d ^ e ^ f ^ g ^ h ^ i ^ j ^ k ^ l ^ m ^ o ^ p ^ q ^ r ^ s ^ t ^ u) | 0;
}

// A module closure: the views are captured, as asm.js compiles them.
var mod = (function (buf) {
    var a = new Int8Array(buf), c = new Int32Array(buf);
    function sum(p, n) {
        p = p | 0; n = n | 0;
        var s = 0, k = 0;
        for (k = 0; (k | 0) < (n | 0); k = (k + 1) | 0) s = (s + (a[(p + k) | 0] | 0) + (c[((p + (k << 2)) >> 2) & 1023] >> 3)) | 0;
        return s | 0;
    }
    return { sum: sum };
})(heap8.buffer);

var acc = 0;
heap32[0] = 64; heap32[1] = 5; heap32[2] = 300;
for (var it = 0; it < 4000; it++) {
    heap32[1] = it & 63;
    fill(0);
    acc = (acc + r_g0 + heap8[100 + (it & 127)]) | 0;
    acc = (acc + wide(40)) | 0;
    acc = (acc + mod.sum(it & 511, 64)) | 0;
}
print(acc, heapU16[600], heap8[200]);

// The guarded assignment throws once the global is gone (strict code, ECMA-262 PutValue).
var gone = (function () {
    "use strict";
    return function (v) { var t = (v * 3) | 0; t = (t ^ 5) | 0; t = (t + 7) | 0; t = (t << 1) | 0; zz_gone = t; return t; };
})();
globalThis.zz_gone = 0;
var gs = 0;
for (var it = 0; it < 3000; it++) gs = (gs + gone(it)) | 0;
delete globalThis.zz_gone;
try { gone(1); print("no throw"); } catch (e) { print(e instanceof ReferenceError, gs); }

// Sums only ToInt32 reads wrap instead of overflowing: single, chained, subtract, unsigned shift,
// a shift count, and a sum whose register stays live (that one must not wrap).
function wrap1(a, b) { return (a + b) | 0; }
function wrap3(a, b, c) { return (a + b - c + 7) | 0; }
function wrapu(a, b) { return (a - b) >>> 0; }
function wrapsh(a, b) { return 1 << (a + b); }
function keep(a, b) { var s = a + b; var t = s | 0; return t + s; }
function hash(s) { var h = 0; for (var k = 0; k < s.length; k++) h = (((h << 5) - h) + s.charCodeAt(k)) | 0; return h; }
var w = 0, big = 0x7fffffff;
for (var it = 0; it < 4000; it++) {
    var a = (it * 2654435761) | 0, b = (it * 40503) | 0;
    w = (w + wrap1(a, b) + wrap3(a, b, -a) + wrapu(a, b) + wrapsh(a, b) + keep(it, it)) | 0;
}
print(w, wrap1(big, big), wrap3(big, big, -big), wrapu(-big, big), wrapsh(big, 2), keep(big, big), hash("the quick brown fox jumps over the lazy dog"));

// Captured variables read in a hot function: one compiled function with closures over different
// cells, a captured variable another closure reassigns mid-loop, and a `let` read before and after
// its initialization.
function maker(seed) {
    var view = new Int32Array(64), bump = seed;
    for (var k = 0; k < 64; k++) view[k] = k * seed;
    return {
        run: function (n) { var s = 0; for (var k = 0; k < n; k++) s = (s + view[k & 63] + bump) | 0; return s; },
        swap: function () { view = new Int32Array(64).fill(bump); bump = (bump + 1) | 0; }
    };
}
var m1 = maker(3), m2 = maker(5), cs = 0;
for (var it = 0; it < 3000; it++) {
    cs = (cs + m1.run(64) + m2.run(64)) | 0;
    if ((it & 255) == 0) m1.swap();
}
print(cs);
var tdz = (function () {
    function f(n) { var s = 0; for (var k = 0; k < n; k++) s = (s + late) | 0; return s; }
    var r = [];
    try { f(1); } catch (e) { r.push(e instanceof ReferenceError); }
    let late = 7;
    for (var it = 0; it < 2000; it++) r[1] = f(10);
    return r;
})();
print(tdz);

// Unsigned shifts: results of 2^31 and above (as doubles after the exit), and ones only ToInt32 reads.
function ush(a, b) { return a >>> b; }
function ushmix(a) { var u = a >>> 0; return (u >>> 1) + (u >>> 28) + ((a >>> 3) & 255) + ((a >>> 0) | 0); }
var us = 0;
for (var it = 0; it < 4000; it++) us += ush(it * 2654435761 | 0, it & 7) + ushmix((it * 40503) ^ -it);
print(us, ush(-1, 0), ush(-8, 1), ushmix(-1), ushmix(-2147483648));

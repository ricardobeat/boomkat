// Element reads and writes the optimizing tier specializes for the typed array kind a site has met:
// every kind, int32 and double values and uses, out-of-bounds and negative indices, a site that
// later meets another kind or a plain array, NaN, -0, Uint32 values above 2^31, and stores of
// doubles into integer kinds (modular) and of integers into float kinds.
var kinds = [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array];
var out = [];

function sumi(a, n) { var s = 0; for (var k = 0; k < n; k++) s = (s + (a[k] | 0)) | 0; return s; }
function sumd(a, n) { var s = 0; for (var k = 0; k < n; k++) s += a[k] * 0.5; return s; }
function puti(a, n, v) { for (var k = 0; k < n; k++) a[k] = (v + k * 37) | 0; }
function putd(a, n, v) { for (var k = 0; k < n; k++) a[k] = v + k * 0.25; }
function at(a, k) { return a[k]; }

kinds.forEach(function (K) {
    // A fresh copy of each function per kind keeps every site monomorphic.
    var si = new Function("a", "n", "var s = 0; for (var k = 0; k < n; k++) s = (s + (a[k] | 0)) | 0; return s;");
    var sd = new Function("a", "n", "var s = 0; for (var k = 0; k < n; k++) s += a[k] * 0.5; return s;");
    var pi = new Function("a", "n", "v", "for (var k = 0; k < n; k++) a[k] = (v + k * 37) | 0;");
    var pd = new Function("a", "n", "v", "for (var k = 0; k < n; k++) a[k] = v + k * 0.25;");
    var ga = new Function("a", "k", "return a[k];");
    var a = new K(64), acc = 0;
    for (var r = 0; r < 300; r++) {
        pi(a, 64, r * 1000003);
        acc = (acc + si(a, 64)) | 0;
        pd(a, 64, r * 1.5 - 200);
        acc = (acc + (sd(a, 64) | 0)) | 0;
        acc = (acc + (ga(a, r & 63) | 0)) | 0;
    }
    a[3] = NaN; a[4] = -0; a[5] = 4294967295; a[6] = 1e10;
    out.push(K.name + " " + acc + " " + [ga(a, 3), ga(a, 4), ga(a, 5), ga(a, 6), ga(a, 64), ga(a, -1), ga(a, 1.5)].map(String).join(","));
    pi(a, 64, 1);
    out.push(si(a, 70) + " " + sd(a, 64));
});

// One site meeting several kinds, then a plain array.
var a8 = new Int8Array(32), a32 = new Int32Array(32), af = new Float64Array(32), arr = [];
for (var k = 0; k < 32; k++) { a8[k] = k; a32[k] = k * 100000; af[k] = k / 3; arr.push(k * 2); }
var m = 0;
for (var r = 0; r < 3000; r++) m = (m + sumi(a8, 32)) | 0;
out.push(m, sumi(a32, 32), sumd(af, 32), sumi(arr, 32), sumd(a8, 32));
puti(a8, 32, 1000); putd(a32, 32, 1.75); puti(arr, 32, 3);
out.push(Array.prototype.join.call(a8, ","), Array.prototype.join.call(a32, ","), arr.join(","));
print(out.join("\n"));

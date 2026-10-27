function check(ok, message) { if (!ok) throw new Error(message); }
function identity(x) { return x; }
function same(a, b, message) { check(Object.is(a, b), message + ': ' + a + ' / ' + b); }
function sum(a, n) { var x = 0; for (var i = 0; i < n; i++) x += a[i]; return x; }
function transform(dst, src, n) { for (var i = 0; i < n; i++) dst[i] = (src[i] * 3 + 17) ^ 91; }
function blend(dst, src, n) { for (var i = 0; i < n; i++) dst[i] = src[i] * .75 + dst[i] * .25; }
function ascii(s) { var x = 0; for (var i = 0; i < s.length; i++) x = (x * 31 + s.charCodeAt(i)) | 0; return x; }
function asciiBinding() { var x = 0; for (var i = 0; i < text.length; i++) x = (x * 31 + text.charCodeAt(i)) | 0; return x; }
function hash(a) { var x = 1; for (var i = 0; i < a.length; i++) x = Math.imul(x, 31) + a[i] | 0; return x; }
function reference(a, n) { var x = 0; for (var i = 0; i < n; i++) x += identity(a[i]); return x; }

var constructors = [Int8Array, Uint8Array, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array];
for (var k = 0; k < constructors.length; k++) {
    // A fresh function admits each element representation independently.
    var add = Function('a', 'n', 'var x=0;for(var i=0;i<n;i++)x+=a[i];return x;');
    var src = new constructors[k](512), dst = new constructors[k](512);
    for (var i = 0; i < src.length; i++) src[i] = i * 13 - 1701;
    same(add(src, src.length), reference(src, src.length), 'typed sum ' + k);
    var map = Function('dst', 'src', 'n', 'for(var i=0;i<n;i++)dst[i]=(src[i]*3+17)^91;');
    map(dst, src, src.length);
    var expected = new constructors[k](512);
    for (var i = 0; i < src.length; i++) expected[i] = (identity(src[i]) * 3 + 17) ^ 91;
    for (var i = 0; i < dst.length; i++) same(dst[i], expected[i], 'typed store ' + k);
}
var buffer = new ArrayBuffer(4096), view = new Int16Array(buffer, 128, 512);
for (var i = 0; i < view.length; i++) view[i] = i - 400;
same(sum(view, view.length), reference(view, view.length), 'view offset');

var a = [], b = [];
for (var i = 0; i < 512; i++) { a[i] = i * .25; b[i] = -i * .5; }
blend(b, a, a.length);
for (var i = 0; i < a.length; i++) same(b[i], i * .0625, 'dense float');
same(sum(a, a.length), reference(a, a.length), 'change argument shape');
Object.freeze(b); blend(b, a, a.length);
same(b[511], 511 * .0625, 'frozen native destination');
var sparse = []; sparse[0] = 1; sparse.length = 512;
check(Number.isNaN(sum(sparse, sparse.length)), 'sparse length');
var f = new Float64Array(512), g = new Float64Array(512);
for (var i = 0; i < f.length; i++) { f[i] = i * .25; g[i] = -i * .5; }
var floatBlend = Function('dst', 'src', 'n', 'for(var i=0;i<n;i++)dst[i]=src[i]*.75+dst[i]*.25;');
floatBlend(g, f, f.length);
for (var i = 0; i < f.length; i++) same(g[i], i * .0625, 'typed float');

// Aliasing preserves the order of individual loads and stores.
var alias = new Uint8Array(513), mirror = new Uint8Array(513);
for (var i = 0; i < alias.length; i++) alias[i] = mirror[i] = i;
transform(alias.subarray(1), alias.subarray(0, 512), 512);
for (var i = 0; i < 512; i++) mirror[i + 1] = (identity(mirror[i]) * 3 + 17) ^ 91;
for (var i = 0; i < alias.length; i++) same(alias[i], mirror[i], 'alias');

var text = 'abc0123456789'.repeat(128), h = 0;
for (var i = 0; i < text.length; i++) h = (h * 31 + identity(text.charCodeAt(i))) | 0;
same(ascii(text), h, 'ASCII');
// Intrinsic receivers loaded from bindings are not VM register indices.
same(asciiBinding(), h, 'ASCII binding');
text += '\u00e9\ud83d\ude00'; h = 0;
for (var i = 0; i < text.length; i++) h = (h * 31 + identity(text.charCodeAt(i))) | 0;
same(ascii(text), h, 'Unicode fallback');
same(asciiBinding(), h, 'Unicode binding fallback');
var oldChar = String.prototype.charCodeAt;
String.prototype.charCodeAt = function () { return 7; };
h = 0; for (var i = 0; i < 512; i++) h = (h * 31 + identity(7)) | 0;
same(ascii('a'.repeat(512)), h, 'method replacement');
String.prototype.charCodeAt = oldChar;
var bytes = new Uint8Array(512), expectedHash = 1;
for (var i = 0; i < bytes.length; i++) { bytes[i] = i; expectedHash = Math.imul(expectedHash, 31) + identity(bytes[i]) | 0; }
same(hash(bytes), expectedHash, 'imul');
var oldImul = Math.imul;
Math.imul = function () { return 9; };
same(hash(bytes), 9 + bytes[511], 'imul replacement');
Math.imul = oldImul;

// A guard exit publishes completed iterations before invoking user code.
var values = [], calls = 0;
for (var i = 0; i < 512; i++) values[i] = 1;
values[200] = {valueOf: function () { calls++; return 5; }};
same(sum(values, values.length), 516, 'coercion exit');
same(calls, 1, 'coercion executes once');
var holes = []; for (var i = 0; i < 512; i++) holes[i] = 1;
delete holes[200];
Object.defineProperty(Array.prototype, '200', {configurable: true, get: function () { calls++; return 5; }});
try { same(sum(holes, holes.length), 516, 'prototype getter'); }
finally { delete Array.prototype[200]; }
same(calls, 2, 'getter executes once');
var frozen = []; for (var i = 0; i < 512; i++) frozen[i] = 1;
Object.freeze(frozen);
transform(frozen, bytes, 512);
same(frozen[200], 1, 'frozen array');
var special = new Float64Array(512);
special.fill(1); special[400] = NaN;
check(Number.isNaN(sum(special, special.length)), 'NaN');
special[400] = Infinity;
same(sum(special, special.length), Infinity, 'Infinity');
var zeros = new Float64Array(512), negatives = new Float64Array(512);
var negate = Function('d', 's', 'for(var i=0;i<s.length;i++)d[i]=-s[i];');
negate(negatives, zeros);
same(1 / negatives[511], -Infinity, 'negative zero');

function numeric(dst, src) {
    for (var i = 0; i < src.length; i++) {
        var x = src[i]; dst[i] = ((x >>> 5) ^ ~(x << 3)) | ((x + 17) >>> 0);
    }
}
var edges = new Float64Array(512), actual = new Int32Array(512);
edges.fill(.5);
var exceptional = [NaN, Infinity, -Infinity, -0, 2147483648, -2147483649, 4294967296, 140737488355328];
for (var i = 0; i < exceptional.length; i++) edges[500 + i] = exceptional[i];
numeric(actual, edges);
for (var i = 0; i < edges.length; i++) {
    var x = identity(edges[i]);
    same(actual[i], ((x >>> 5) ^ ~(x << 3)) | ((x + 17) >>> 0), 'ToInt32 edges');
}
var denseOut = a.slice(), typedOut = new Float64Array(f);
for (var j = 0; j < 8; j++) { blend(denseOut, a, a.length); blend(typedOut, f, f.length); }
for (var i = 0; i < a.length; i++) same(denseOut[i], typedOut[i], 'alternating representations');

var lengthReads = 0;
Object.defineProperty(bytes, 'length', {configurable: true, get: function () { lengthReads++; return 5; }});
var shadowHash = 1;
for (var i = 0; i < 5; i++) shadowHash = Math.imul(shadowHash, 31) + identity(bytes[i]) | 0;
same(hash(bytes), shadowHash, 'shadowed typed length');
same(lengthReads, 6, 'length getter executes once per test');
delete bytes.length;
function classify(dst, src) {
    for (var i = 0; i < src.length; i++) {
        if (src[i] < 0) dst[i] = 1;
        else if (src[i] >= 0) dst[i] = 2;
        else dst[i] = 3;
    }
}
var classes = new Uint8Array(512);
classify(classes, edges);
for (var i = 0; i < edges.length; i++) {
    var value = identity(edges[i]);
    same(classes[i], value < 0 ? 1 : value >= 0 ? 2 : 3, 'numeric branches');
}

console.log('SLJIT loops: PASS');

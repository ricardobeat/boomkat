function ssaUnsigned(a, b, shift, n) {
    for (var i = 0; i < n; i++) b[i] = a[i] >>> shift;
}
function ssaMultiply(a, b, factor, n) {
    for (var i = 0; i < n; i++) b[i] = a[i] * factor;
}
function ssaFractional(a, index, n) {
    var sum = 0;
    for (var i = 0; i < n; i++) sum += a[index];
    return sum;
}
var numericInput = new Int32Array(64), numericOutput = new Float64Array(64);
numericInput.fill(-1);
numericInput[31] = -1;
ssaUnsigned(numericInput, numericOutput, 0, 64);
for (var i = 0; i < 64; i++) if (numericOutput[i] !== 4294967295) throw Error('unsigned result narrowed at ' + i + ': ' + numericOutput[i]);
numericInput.fill(0);
ssaMultiply(numericInput, numericOutput, -1, 64);
for (var i = 0; i < 64; i++) if (!Object.is(numericOutput[i], -0)) throw Error('negative zero product at ' + i);
for (var i = 0; i < 64; i++) numericInput[i] = i;
ssaMultiply(numericInput, numericOutput, 2147483647, 64);
if (numericOutput[63] !== 63 * 2147483647) throw Error('multiply overflow recovery');
var fractionalArray = new Float64Array([4, 8, 12, 16]);
for (var warm = 0; warm < 100; warm++) {
    if (ssaFractional(fractionalArray, 1, 64) !== 512) throw Error('index warmup');
}
if (!Number.isNaN(ssaFractional(fractionalArray, 1.5, 64))) throw Error('fractional index truncated');
if (!Number.isNaN(ssaFractional(fractionalArray, NaN, 64))) throw Error('NaN index');
if (ssaFractional(fractionalArray, -0, 64) !== 256) throw Error('negative zero index');
// Typed-array NaN payloads must not escape as tagged heap-pointer bits.
function ssaNaNPayload(source, dest, n) {
    for (var i = 0; i < n; i++) dest[i] = source[i];
}
var nanStorage = new ArrayBuffer(64 * 8), nanView = new DataView(nanStorage);
for (var i = 0; i < 64; i++) {
    nanView.setUint32(i * 8, 123, true);
    nanView.setUint32(i * 8 + 4, 0xfff50000, true);
}
var nanSource = new Float64Array(nanStorage), nanDest = new Array(64).fill(0);
ssaNaNPayload(nanSource, nanDest, 64);
for (var i = 0; i < 64; i++) if (!Number.isNaN(nanDest[i])) throw Error('NaN payload boxing');
print('SSA numeric guards: PASS');

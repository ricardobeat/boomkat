// A sampled double array can contain tagged integers elsewhere. Numeric reads
// stay valid, while a string destination still needs normal reference release.
function mixedNumbers(input, output, n) {
  for (var i = 0; i < n; i++) output[i] = input[i] * 1.5;
}
var input = [], output = [];
for (var i = 0; i < 256; i++) { input[i] = i + 0.25; output[i] = 0.5; }
for (var pass = 0; pass < 100; pass++) {
  input[37] = pass % 2 ? 12 : 12.5;
  output[91] = 'replace-' + pass;
  mixedNumbers(input, output, 256);
  for (var i = 0; i < 256; i++) {
    if (output[i] !== input[i] * 1.5) throw new Error('mixed number ' + i);
  }
}
input[37] = '8';
mixedNumbers(input, output, 256);
if (output[37] !== 12) throw new Error('string input fallback');
print('SSA mixed numbers: PASS');

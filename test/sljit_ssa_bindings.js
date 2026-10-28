// Binding snapshots must follow the current closure and refresh after fallback.
function makeLoop(scale) {
  return {
    set: function (value) { scale = value; },
    run: function bindingLoop(input, output) {
      for (var i = 0; i < input.length; i++) output[i] = input[i] * scale;
      return output[input.length - 1];
    }
  };
}
var left = makeLoop(2), right = makeLoop(7);
var input = [], output = [];
for (var i = 0; i < 256; i++) { input[i] = i; output[i] = 0; }
for (var pass = 0; pass < 100; pass++) {
  if (left.run(input, output) !== 510) throw new Error('left closure');
  if (right.run(input, output) !== 1785) throw new Error('right closure');
}
left.set(3.5);
if (left.run(input, output) !== 892.5) throw new Error('rebound number');
left.set('4');
if (left.run(input, output) !== 1020) throw new Error('string fallback');
left.set(2);
var reads = 0;
Object.defineProperty(input, '128', {get: function () {
  reads++; left.set(5); return 128;
}, configurable: true});
if (left.run(input, output) !== 1275 || reads !== 1) throw new Error('getter rebind');
if (output[127] !== 254 || output[128] !== 640) throw new Error('fallback position');
print('SSA bindings: PASS');

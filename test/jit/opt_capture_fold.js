// Captured bindings folded in optimized code (OptBuild.fold_capture): an asm.js-style module whose
// inner functions read typed arrays and numbers from the module scope. The guards must notice a
// written number, a rebound array, a second closure of the same code and a detached buffer.

function makeModule(buffer, scale) {
  var HEAP32 = new Int32Array(buffer);
  var HEAPF64 = new Float64Array(buffer);
  var K = scale;
  const C = 7;
  function sum(n) {
    var s = 0;
    for (var i = 0; i < n; i++) s = ((s ^ (i & 3)) + ((HEAP32[i] * K) | 0) + (C << 1) - (i >> 2)) | 0;
    return s;
  }
  function fsum(n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += HEAPF64[i] * 0.5;
    return s;
  }
  function fill(n) { for (var i = 0; i < n; i++) HEAP32[i] = i * 3; }
  function rebind(b) { HEAP32 = new Int32Array(b); }
  function setK(k) { K = k; }
  return { sum, fsum, fill, rebind, setK };
}
var buf = new ArrayBuffer(1 << 12);
var m = makeModule(buf, 2);
m.fill(256);
var r = 0;
for (var j = 0; j < 20000; j++) r = (r + m.sum(64) + m.fsum(8)) | 0;
print("sum", r, m.fsum(64));
m.setK(5);
print("setK", m.sum(256));
var buf2 = new ArrayBuffer(1 << 12);
m.rebind(buf2);
print("rebind", m.sum(256), m.sum(1100));
var m2 = makeModule(buf, 3);
for (var j = 0; j < 100; j++) r = (r + m2.sum(256) + m.sum(256)) | 0;
print("two", r, m2.sum(256), m.sum(256));
if (typeof buf2.transfer === "function") {
  buf2.transfer();
  print("detached", m.sum(4));
}

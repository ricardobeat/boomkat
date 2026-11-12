// Folded global bindings (OptBuild.fold_global): numbers and typed arrays read as constants under
// GUARD_GLOBAL. The guards must notice a rebinding, a written number, and a detached buffer; element
// accesses on a constant view must leave for the baseline past the end.
var heap32 = new Int32Array(1024);
var heapU16 = new Uint16Array(heap32.buffer);
var heapU8 = new Uint8Array(heap32.buffer);
var heapF64 = new Float64Array(256);
var heapF32 = new Float32Array(256);
var heapU32 = new Uint32Array(64);
var K = 7, D = 2.5, U, N = null, B = true;
function work(n) {
  var s = 0;
  for (var i = 0; i < n; i++) {
    heap32[i & 255] = i * K;
    heapU16[(i & 255) + 600] = i;
    heapU8[(i & 127) + 3000] = i;
    heapF64[i & 63] = i * D;
    heapF32[i & 63] = i / 3;
    heapU32[i & 31] = 0xFFFFFFF0 + (i & 7);
    s = (s + heap32[(i * 3) & 255] + heapU16[(i & 255) + 600] + heapU8[(i & 127) + 3000]) | 0;
    s = s + heapF64[i & 63] + heapF32[i & 63] + heapU32[i & 31];
    if (U !== undefined || N !== null || B !== true) s = -1;
  }
  return s;
}
var r1 = 0;
for (var j = 0; j < 300; j++) r1 = work(500);
print("r1", r1);
// Rebind: the guard must notice.
heap32 = new Int32Array(1024);
heap32[3] = 99;
K = 3;
for (var j = 0; j < 50; j++) r1 = work(500);
print("r2", r1, heap32[3]);
// Out of bounds read and write through the constant view.
function oob(i) { return heap32[i]; }
function oobw(i, v) { heap32[i] = v; return heap32[i]; }
var t = 0;
for (var j = 0; j < 2000; j++) t += oob(j & 1023);
print("oob", oob(5000), oobw(5000, 1), t);
// Detach the buffer under the folded view.
var g8 = new Uint8Array(new ArrayBuffer(64));
function rd(i) { return g8[i]; }
for (var j = 0; j < 3000; j++) rd(j & 63);
g8.buffer.transfer();
print("detached", rd(1), g8.length);
// A number the program keeps writing: its readers fold it once, then read it.
var counter = 0;
function bump() { counter++; }
function readc(n) { var s = 0; for (var i = 0; i < n; i++) { s += counter; bump(); } return s; }
for (var j = 0; j < 40; j++) readc(100);
print("counter", counter, readc(10));

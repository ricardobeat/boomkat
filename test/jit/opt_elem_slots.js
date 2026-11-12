// Element reads and writes of optimized code by an int32 index: arrays whose dense part follows
// named properties, literals whose elements sit in the header, growth that moves the storage,
// and indexes that leave (negative, out of range, holes, typed arrays). An access proves its
// receiver an array for the ones after it: the register is reassigned, joins an object, or
// is written after only a read proved it.
function sum(a, n) {
  var t = 0;
  for (var i = 0; i < n; i++) t += a[i] | 0;
  return t;
}
function fill(a, n, k) {
  for (var i = 0; i < n; i++) a[i] = i * k;
  return a;
}
function pick(a, i) { return a[i]; }
function pickAll(a, idx) {
  var out = [];
  for (var k = 0; k < idx.length; k++) out.push(pick(a, idx[k]));
  return out.join(",");
}
var plain = fill(new Array(32), 32, 3);
var named = fill([], 32, 5);
named.tag = "t"; named.other = 7; named.more = { x: 1 };
var lit = [1, 2, 3, 4, 5, 6, 7, 8];
var out = [];
for (var r = 0; r < 4000; r++) {
  out[0] = sum(plain, 32);
  out[1] = sum(named, 32);
  out[2] = sum(lit, 8);
  fill(named, 32, r & 3);
}
out.push(sum(named, 40));
named.push(99);
named.extra = 1;
out.push(sum(named, 33));
var holes = [1, , 3, , 5];
var typed = new Int32Array([10, 20, 30, 40]);
for (var q = 0; q < 3000; q++) pickAll(plain, [1, 2, 3]);
out.push(pickAll(plain, [0, 31, 32, -1, 5]));
out.push(pickAll(holes, [0, 1, 2, 3, 4, 5]));
out.push(pickAll(typed, [0, 3, 4, -1]));
out.push(pickAll(named, [0, 32, 33]));

function swap(a, b, n) {
  var t = 0;
  for (var i = 0; i < n; i++) {
    t += a[i & 3];
    var x = a;
    if (i % 5 === 4) x = b;
    t += x[1] | 0;
    a = i % 7 === 6 ? b : a;
    t += a[2] | 0;
    a[3] = t & 15;
  }
  return t;
}
var arr = [1, 2, 3, 4], ta = new Int32Array([5, 6, 7, 8]), ob = { 1: 9, 2: 10, 3: 11 };
for (var q = 0; q < 2000; q++) swap([1, 2, 3, 4], [4, 3, 2, 1], 20);
out.push(swap([1, 2, 3, 4], ta, 30), swap([1, 2, 3, 4], ob, 30), swap([1, 2, 3, 4], "abcd", 30));
function readThenWrite(a, n) {
  var t = 0;
  for (var i = 0; i < n; i++) { t += a[i & 1]; a[2] = t; }
  return t;
}
var frozen = Object.freeze([1, 2, 3]);
var named = [1, 2, 3];
Object.defineProperty(named, 2, { get: function () { return 7; }, set: function (v) {} });
for (var q = 0; q < 2000; q++) readThenWrite([1, 2, 3], 10);
out.push(readThenWrite([1, 2, 3], 10), readThenWrite(frozen, 10), readThenWrite(named, 10), frozen.join(), named.join());
print(out.join(" "));

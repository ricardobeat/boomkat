// Frameless SSA leaf coverage: captures, globals and field writes.
//
// A whole-body leaf is replayed from its argument window when a guard refuses,
// so it may only write memory it never reads. These fixtures exercise the
// admitted shapes and the refusals around them, with independent reference
// loops so a wrong value cannot pass by matching itself.

function makeScaler(scale, addend) {
  var base = addend;
  return function (x) {
    var step = 3;
    return x * scale + base + step;
  };
}

function makeCounter(inc) {
  var count = 0;
  return function (n) {
    var s = 0;
    while (s < n) { s = s + inc; }
    return s + count;
  };
}

function refScaler(scale, addend, x) { return x * scale + addend + 3; }
function refCounter(inc, n) { var s = 0; while (s < n) { s = s + inc; } return s; }

var scalers = [makeScaler(2, 5), makeScaler(-3, 11), makeScaler(0.5, 1.25)];
var counters = [makeCounter(4), makeCounter(7)];

var checksum = 0;
for (var round = 0; round < 4000; round++) {
  for (var s = 0; s < scalers.length; s++) {
    var x = round % 37;
    var scale = s === 0 ? 2 : s === 1 ? -3 : 0.5;
    var addend = s === 0 ? 5 : s === 1 ? 11 : 1.25;
    var got = scalers[s](x);
    var want = refScaler(scale, addend, x);
    if (got !== want) throw new Error("scaler mismatch " + s + ": " + got + " !== " + want);
    checksum += got;
  }
  for (var c = 0; c < counters.length; c++) {
    var n = round % 23;
    var gotCount = counters[c](n);
    var wantCount = refCounter(c === 0 ? 4 : 7, n);
    if (gotCount !== wantCount) throw new Error("counter mismatch " + c);
    checksum += gotCount;
  }
}

// A capture holding an object or an uninitialized binding must fall back
// without corrupting the caller's frame.
function makeObjectReader(target) {
  return function (k) { return target.value + k; };
}
var targetA = { value: 10 }, targetB = { value: -4 };
var readerA = makeObjectReader(targetA), readerB = makeObjectReader(targetB);
for (var i = 0; i < 2000; i++) {
  if (readerA(i) !== 10 + i) throw new Error("object capture A");
  if (readerB(i) !== -4 + i) throw new Error("object capture B");
}

// Field writes: several slots, a write inside a cycle, and a body that reads
// the slot it writes (which must stay in the interpreter).
function Pair(a, b) { this.a = a; this.b = b; }
Pair.prototype.set = function (a, b) { this.a = a; this.b = b; };
Pair.prototype.sum = function () { return this.a + this.b; };
Pair.prototype.spin = function (n) { for (var i = 0; i < n; i++) { this.a = i; } };
Pair.prototype.incA = function () { this.a = this.a + 1; return this.a; };

var pair = new Pair(0, 0);
var pairSum = 0;
for (var j = 0; j < 20000; j++) {
  pair.set(j, j * 3);
  pair.spin(j % 7);
  pairSum += pair.sum() + pair.incA();
}var expectSum = 0;
for (var k = 0; k < 20000; k++) {
  var a = k, b = k * 3;
  for (var m = 0; m < k % 7; m++) { a = m; }
  expectSum += (a + b) + (a + 1);
}
if (pairSum !== expectSum) throw new Error("pair mismatch " + pairSum + " !== " + expectSum);

// A setter that receives a reference refuses the compiled store and lets the
// interpreter do the counted one; the earlier numeric write must still hold.
function Tagged() { this.value = 0; this.label = 0; }
Tagged.prototype.assign = function (v, label) { this.value = v; this.label = label; };
var tagged = new Tagged();
var words = ["a", "bb", "ccc"];
var tagSum = 0;
var expectTag = 0;
for (var r = 0; r < 4000; r++) {
  tagged.assign(r, words[r % 3]);
  tagSum += tagged.value + tagged.label.length;
  expectTag += r + words[r % 3].length;
}
if (tagSum !== expectTag) throw new Error("tagged mismatch " + tagSum + " !== " + expectTag);

// A global read inside a cyclic leaf body.
var globalBias = 17;
function biasSum(n) { var s = 0, i = 0; while (i < n) { s = s + globalBias; i = i + 1; } return s; }
var biased = 0;
for (var g = 0; g < 3000; g++) biased += biasSum(g % 19);
var expectBias = 0;
for (var h = 0; h < 3000; h++) expectBias += 17 * (h % 19);
if (biased !== expectBias) throw new Error("global bias mismatch");
globalBias = 5;
if (biasSum(10) !== 50) throw new Error("global rebind mismatch");

// Null, undefined and boolean constants, including a body that returns one.
function classify(n) {
  var missing = true;
  if (n < 0) return null;
  if (n === 0) return missing ? undefined : false;
  return n * 2;
}
var classified = 0;
var expectClassified = 0;
for (var c = 0; c < 6000; c++) {
  var v = classify(c % 7 - 3);
  classified += v === null ? 1 : v === undefined ? 2 : (v === false ? 3 : v);
  var n = c % 7 - 3;
  expectClassified += n < 0 ? 1 : n === 0 ? 2 : n * 2;
}
if (classified !== expectClassified) throw new Error("classify mismatch");

// A straight-line helper expanded into a cyclic body: both are effect-free.
function scaleValue(x, k) { return x * k + 1; }
function accumulate(n) {
  var total = 0, i = 0;
  while (i < n) { total = total + scaleValue(i, 3); i = i + 1; }
  return total;
}
var accumulated = 0;
for (var a = 0; a < 400; a++) accumulated += accumulate(a % 11);
var expectAccumulated = 0;
for (var b = 0; b < 400; b++) {
  var m = b % 11, sum = 0;
  for (var k = 0; k < m; k++) sum += k * 3 + 1;
  expectAccumulated += sum;
}
if (accumulated !== expectAccumulated) throw new Error("accumulate mismatch");

print("sljit leaf coverage ok " + checksum + " " + pairSum);

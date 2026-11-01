// Named property reads across layouts in compiled bodies.
//
// Polymorphic receivers, a site whose receiver shape changes for good, reads
// into loop-carried accumulators, and several reads per block. Every checksum
// has an interpreted reference so the differential run compares both tiers.

function Pair(a, b) { this.a = a; this.b = b; }
Pair.prototype.sum = function () { return this.a + this.b; };

var ok = 0;
function check(name, got, want) {
  if (got !== want) throw new Error(name + " got " + got + " want " + want);
  ok++;
}

function reads(o, n) {
  var s = 0;
  for (var i = 0; i < n; i++) s = s + o.a + o.b + i;
  return s;
}
var pair = new Pair(3, 5);
var total = 0;
for (var k = 0; k < 20000; k++) total += reads(pair, 8);
check("reads", total, 1840000);

function readsSeparate(o, n) {
  var s = 0;
  for (var i = 0; i < n; i++) { s = s + o.a; s = s + o.b; i = i + 1; }
  return s;
}
var separate = 0;
for (var k = 0; k < 20000; k++) separate += readsSeparate(pair, 8);
check("separate", separate, 640000);

// Two shapes at one call site: the callee's cache sees both receivers.
function polymorphic(n) {
  var s = 0;
  for (var i = 0; i < n; i++) {
    var p = (i & 1) ? new Pair(i, 2) : new Pair(i, 5);
    s += p.sum();
  }
  return s;
}
var poly = 0;
for (var k = 0; k < 20000; k++) poly = polymorphic(8);
check("polymorphic", poly, 56);

// The receiver keeps being replaced, so the site's cached shape never settles.
function replaced(n) {
  var o = { value: 3 };
  var t = 0;
  for (var i = 0; i < n; i++) {
    if ((i & 63) === 0) { o = { value: i, extra: 1 }; }
    t += o.value;
  }
  return t;
}
check("replaced", replaced(40000), 798720000);

// Reads on values the loop also keeps in canonical numeric lanes.
function laneReads(o, n) {
  var s = 0;
  var acc = 0.5;
  for (var i = 0; i < n; i++) { acc = acc + i * 0.25; s = s + o.a + o.b; }
  return s + acc;
}
var lanes = 0;
for (var k = 0; k < 20000; k++) lanes += laneReads(pair, 6) % 1000003;
check("lanes", lanes, 1045000);

print("sljit property read ok", ok);

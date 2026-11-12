// Young objects stored into an old array and an old object's field (STORE_ELEM and STORE_FIELD of
// an OBJECT node), where only an old owner that is not yet remembered takes the barrier's call:
// every stored object must survive the minor collections that follow, while the owner is
// remembered, after the collector has cleared that, and while it marks. An object stored into a
// typed array converts through its valueOf.
function Box(v) { this.v = v; this.w = v * 2; }
var ring = new Array(256).fill(null);
var holder = { last: null, count: 0 };
// Age the containers past a few collections.
var junk = [];
for (var g = 0; g < 200000; g++) junk = [g, { g: g }];

function fill(n, base) {
  for (var i = 0; i < n; i++) {
    var b = new Box(base + i);
    ring[i & 255] = b;
    holder.last = b;
    var tmp = { t: i };
    if (tmp.t !== i) throw new Error("tmp");
  }
}
function check(base, n) {
  var s = 0;
  for (var k = 0; k < 256; k++) {
    var b = ring[k];
    if (b === null) continue;
    if (b.w !== b.v * 2) throw new Error("lost " + k + " " + b.v + " " + b.w);
    s += b.v & 1;
  }
  if (holder.last.v !== base + n - 1) throw new Error("holder " + holder.last.v);
  return s;
}
var total = 0;
for (var round = 0; round < 60; round++) {
  fill(5000, round * 5000);
  for (var g = 0; g < 3000; g++) junk = [g, { g: g }, "s" + g];
  total += check(round * 5000, 5000);
}

var f64 = new Float64Array(16), u8 = new Uint8Array(16), boxes = new Array(16).fill(null).map(function () { return { x: 0 }; });
var hits = 0;
var conv = { valueOf: function () { hits++; return 7; } };
function typed(n) {
  var s = 0;
  for (var i = 0; i < n; i++) {
    f64[i & 15] = i & 1 ? conv : 1.5;
    u8[i & 15] = i & 2 ? conv : 3;
    boxes[i & 15] = { x: i };
    s += f64[3] + u8[5] + boxes[7].x;
  }
  return s;
}
for (var r = 0; r < 40; r++) total += typed(2000);
print(total, holder.last.v, hits);

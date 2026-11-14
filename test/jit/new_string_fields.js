// A constructor inlined into optimized code that stores strings into the object it builds: each
// string is counted and outlives the code's own references, through collections and string churn.
function P(a, b) { this.car = a; this.cdr = b; }
function mk(i, tail) { return new P("s" + (i % 97), new P(i & 1 ? "odd" : "even", tail)); }
var keep = [];
var total = 0;
for (var r = 0; r < 60; r++) {
  var l = null;
  for (var i = 0; i < 300; i++) l = mk(i, l);
  keep[r % 7] = l;
  var junk = [];
  for (var j = 0; j < 200; j++) junk.push("x" + j + r);
}
for (var k = 0; k < 7; k++) {
  for (var c = keep[k]; c !== null; c = c.cdr.cdr) total += c.car.length + c.cdr.car.length;
}
print(total);

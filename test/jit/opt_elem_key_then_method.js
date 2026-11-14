// An element read that met only int32 keys meets string keys once optimized; a method call made
// while its function's other sites are no longer speculated on is replaced on the prototype, then
// shadowed by an own property, mid-loop.
var table = [];
for (var k = 0; k < 64; k++) table[k] = k * 3;
table.x = 1000;
table.y = 2000;
function C(v) { this.v = v; }
C.prototype.get = function () { return this.v; };
function run(n, keys, o, flip) {
  var s = 0;
  for (var i = 0; i < n; i++) {
    var key = keys[i % keys.length];
    s += table[key] | 0;
    if (flip && i == (n >> 1)) C.prototype.get = function () { return -this.v; };
    if (flip && i == (n >> 1) + 7) o.get = function () { return 7; };
    s += o.get();
  }
  return s;
}
var ints = [], mixed = [];
for (var j = 0; j < 64; j++) { ints.push(j); mixed.push(j % 5 == 0 ? (j % 2 ? "x" : "y") : j); }
var out = [];
for (var r = 0; r < 30; r++) out.push(run(2000, ints, new C(r), false));
for (var r = 0; r < 30; r++) out.push(run(2000, mixed, new C(r), false));
out.push(run(4000, mixed, new C(5), true));
out.push(run(4000, ints, new C(9), false));
print(out.join(","));

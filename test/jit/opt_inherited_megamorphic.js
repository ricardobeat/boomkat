// An inherited method read from more receiver kinds than the read's cache keeps: the optimized
// read answers the misses without leaving, and a method replaced on a prototype, an own property
// shadowing it, a swapped prototype, an accessor and a deleted method all take effect at the next
// read, mid-loop included.
function Base() {}
Base.prototype.step = function () { return 1; };
var kinds = [];
for (var k = 0; k < 7; k++) {
  var F = new Function("return function K" + k + "() { this.k" + k + " = " + k + "; };")();
  F.prototype = Object.create(Base.prototype);
  if (k & 1) F.prototype.step = new Function("return " + (k + 10) + ";");
  kinds.push(F);
}
var objs = kinds.map(function (F) { return new F(); });
function run(n, mutate) {
  var s = 0;
  for (var i = 0; i < n; i++) {
    var o = objs[i % objs.length];
    s += o.step();
    if (mutate && i == 500) Base.prototype.step = function () { return 100; };
    if (mutate && i == 900) objs[2].step = function () { return 1000; };
    if (mutate && i == 1300) Object.setPrototypeOf(objs[4], { step: function () { return 7; } });
    if (mutate && i == 1700) Object.defineProperty(kinds[1].prototype, "step", { get: function () { return function () { return -1; }; }, configurable: true });
    if (mutate && i == 2100) delete kinds[3].prototype.step;
  }
  return s;
}
var out = [];
for (var r = 0; r < 40; r++) out.push(run(700, false));
out.push(run(3000, true));
out.push(run(700, false));
print(out.join(","));

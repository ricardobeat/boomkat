// Global reads and `this` loads of an inlined body whose registers lie inside the caller frame,
// so that the value read into the window is published there.
var gObj = { k: 4 };
function Gm(v) { this.v = v; }
Gm.prototype.objRead = function (a) { if (a > 5) return gObj.k + a; return a; };
Gm.prototype.selfRet = function (a) { if (a > 5) return this; return a; };
function drive(o, n) {
  var s = 0.5, a = 1, b = 2, c = 3, d = 4;
  for (var i = 0; i < n; i++) {
    var r = o.objRead(i & 15) + ((a * b + c * d) * ((a + b) * (c + d)) * ((a - b) * (c - d)));
    var q = o.selfRet(i & 15);
    s = r + s + (typeof q === 'object' ? 1 : q);
  }
  return s;
}
var g = new Gm(1);
for (var k = 0; k < 2000; k++) drive(g, 50);
print(drive(g, 1000));

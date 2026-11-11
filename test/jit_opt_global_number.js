// A global read as a number from optimized code: a binding still in its TDZ, then an int, a
// double, a string, an integer beyond int32 and -0 in the same binding.
function K() { return LIM & 7; }
function loop(n) { var s = 0; for (var i = 0; i < n; i++) s += K(); return s; }
var r = [];
try { r.push(loop(10)); } catch (e) { r.push(e.name); }
let LIM = 13;
for (var k = 0; k < 50; k++) r.push(loop(3000));
LIM = 2.5; r.push(loop(3000));
LIM = "9"; r.push(loop(3000));
LIM = 1e12; r.push(loop(3000));
LIM = 2147483648; r.push(loop(3000));
LIM = -0; r.push(loop(3000), 1 / (function () { var z = 0; for (var i = 0; i < 3000; i++) z = LIM * 1; return z; })());
print(r.length, r[0], r[1], r[50], r[51], r[52], r[53], r[54], r[55], r[56]);

// Register calls into optimized functions whose body starts with a loop: the call enters the loop
// header's values from the window. The callee meets other argument types midway and throws.
function member(x, l) {
  while (true) {
    if (l === null) return false;
    if (l.car === x) return true;
    l = l.cdr;
  }
}
function count(l) { var n = 0; for (; l !== null; l = l.cdr) n++; return n; }
function list(n) { var l = null; for (var i = 0; i < n; i++) l = { car: i, cdr: l }; return l; }
function caller(xs, l) {
  var hits = 0;
  for (var i = 0; i < xs.length; i++) if (member(xs[i], l)) hits += count(l);
  return hits;
}
var l = list(8), total = 0;
for (var r = 0; r < 20000; r++) {
  var xs = r < 15000 ? [r % 10, 3, 9] : ["3", 3.5, r % 10];
  total += caller(xs, l);
}
try { member(1, { car: 2, cdr: undefined }); } catch (e) { total += e instanceof TypeError ? 1 : 0; }
print(total);

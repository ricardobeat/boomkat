// Calls whose callee returns a string to optimized and baseline call sites: fresh strings, interned
// ones and strings only the returning frame held, through collections.
function leaf(i) { return i % 3 === 0 ? "k" + (i % 50) : i % 3 === 1 ? "const" : String.fromCharCode(65 + (i % 26)); }
function walk(n, acc) { if (n === 0) return acc; var s = leaf(n); return walk(n - 1, s.length > acc.length ? s : acc); }
function sym(t) { return typeof t === "string" ? t : sym(t.car); }
function P(a, b) { this.car = a; this.cdr = b; }
var total = 0, junk = [];
for (var r = 0; r < 3000; r++) {
  var s = walk(20, "");
  var p = new P(new P("x" + (r % 13), null), null);
  total += s.length + sym(p).length;
  if (r % 50 === 0) junk = [];
  junk.push(s + r);
}
print(total, junk.length);

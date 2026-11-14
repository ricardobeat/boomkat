// Inlined bodies that load string constants: returned, compared, stored into fresh and old
// objects and arrays, and kept across allocation, with the callee replaced mid-loop.
function kind(n) { return n & 1 ? "odd" : "even"; }
function tag(o, n) { o.label = n > 5 ? "big" : "small"; return o; }
function Box(n) { this.name = "box"; this.n = n; }
var keep = [];
function run(n, swap) {
  var odd = 0, s = "";
  for (var i = 0; i < n; i++) {
    if (kind(i) == "odd") odd++;
    var b = tag(new Box(i), i & 7);
    if (i % 97 == 0) keep.push(b, kind(i));
    if ((i & 1023) == 0) s += b.label + b.name;
    if (swap && i == (n >> 1)) kind = function (n) { return n % 3 ? "odd" : "three"; };
  }
  return odd + ":" + s.length;
}
var out = [];
for (var r = 0; r < 30; r++) out.push(run(3000, false));
out.push(run(6000, true));
out.push(run(3000, false));
var garbage = [];
for (var g = 0; g < 20000; g++) garbage.push({ g: g, s: "x" + g });
print(out.join(","), keep.length, keep.slice(0, 6).map(function (x) { return typeof x == "string" ? x : x.label + x.name + x.n; }).join(","), keep[keep.length - 1]);

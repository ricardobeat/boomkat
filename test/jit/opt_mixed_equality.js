// Equality of a number with a string, a boolean, null or an object, in a function the optimizer
// compiles: the inline test's rare cases are answered without leaving, an object's coercion still
// runs its valueOf (counted), and a nested function declaration does not stop the build.
var calls = 0;
var obj = { valueOf: function () { calls++; return 3; } };
function scan(values, n) {
  function tally(x) { return x; }
  var hits = 0, misses = 0, strict = 0;
  for (var i = 0; i < n; i++) {
    var v = values[i % values.length];
    var k = i & 7;
    if (v == k) hits = tally(hits) + 1; else misses++;
    if (k == v) hits++;
    if (v === k) strict++;
    if (v != "3") misses++;
  }
  return hits + ":" + misses + ":" + strict;
}
var nums = [0, 1, 2, 3, 4, 5, 6, 7];
var mixed = [0, "1", 2.0, "3", true, null, undefined, "7", "x", 1.5, "", "0x3", 10n, obj];
var out = [];
for (var r = 0; r < 20; r++) out.push(scan(nums, 3000));
for (var r = 0; r < 20; r++) out.push(scan(mixed, 3000 + r));
print(out.join(","), calls);

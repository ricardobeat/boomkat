// An element read that meets strings as well as arrays once optimized: a string's unit is read
// without leaving, the read proves nothing of its receiver for the reads after it, and indices past
// the end, wide units and an array again all still read right.
function scan(x, n) {
  var hits = 0, last = "";
  for (var i = 0; i < n; i++) {
    var c = x[i % (x.length + 2)];
    if (c == "a" || c == 97) hits++;
    var d = x[(i + 1) % x.length];
    if (d !== undefined) last = "" + d;
  }
  return hits + last;
}
function header(str, index) {
  var start = index;
  while (str[index++] != "[") start++;
  var count = 0;
  while (str[index++] != "]") count++;
  return str.substr(start + 1, count);
}
var arr = [];
for (var k = 0; k < 40; k++) arr.push(k & 1 ? 97 : 98);
var out = [];
for (var r = 0; r < 30; r++) out.push(scan(arr, 500));
for (var r = 0; r < 30; r++) out.push(scan("abcabcab", 500 + r));
out.push(scan("aāb€", 300));
out.push(scan(arr, 500));
out.push(scan(["a", "b", "a"], 300));
for (var r = 0; r < 2000; r++) out.length < 70 && r % 100 == 0 ? out.push(header("/FontMatrix [0.001 0 0 0.001 0 " + r + "] readonly", r % 3)) : header("x [1] y", 0);
print(out.join(","));

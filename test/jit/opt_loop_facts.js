// A loop's code assumes what its forward edges proved of an object, an array or a folded binding
// at its start, and an entry from the baseline code into the loop proves it again: here each entry
// meets a register whose object changed shape or class, or a binding that was rebound, since the
// code was built.
var scale = 2;
function sum(o, a, n) {
  var t = o.x;
  for (var i = 0; i < n; i++) t += a[i & 3] * scale + o.x;
  return t;
}
var out = [];
for (var q = 0; q < 3000; q++) sum({ x: 1 }, [1, 2, 3, 4], 50);
out.push(sum({ x: 1 }, [1, 2, 3, 4], 200000));
out.push(sum({ y: 0, x: 2 }, [1, 2, 3, 4], 200000));
out.push(sum({ x: 1 }, new Int32Array([4, 3, 2, 1]), 200000));
out.push(sum({ x: 1 }, { 0: 1, 1: 1, 2: 1, 3: 1 }, 200000));
scale = 0.5;
out.push(sum({ x: 1 }, [1, 2, 3, 4], 200000));
function fill(a, n) {
  for (var i = 0; i < n; i++) a[i & 7] = a[(i + 1) & 7] + 1;
  return a.join();
}
for (var q = 0; q < 3000; q++) fill([0, 0, 0, 0, 0, 0, 0, 0], 20);
var named = [0, 0, 0, 0, 0, 0, 0, 0];
Object.defineProperty(named, 3, { get: function () { return 9; }, set: function (v) {} });
out.push(fill([0, 0, 0, 0, 0, 0, 0, 0], 100000), fill(named, 100000), fill(Object.freeze([1, 2, 3, 4, 5, 6, 7, 8]), 100000));
print(out.join(" "));

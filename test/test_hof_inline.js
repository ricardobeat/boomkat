// Array.prototype callbacks inlined at the call site (src/compiler/hof_inline.c3).
function check(got, want) { if (got !== want) throw new Error("got " + got + ", want " + want); }
function main() {
  var a = [1, 2, 3, 4];
  let s = 0;
  a.forEach((x, i, arr) => { s += x * i; check(arr, a); });
  check(s, 20);
  check(a.map(x => x * 2).join(), "2,4,6,8");
  check(a.filter(x => x & 1).join(), "1,3");
  check(a.reduce((acc, x) => acc + x, 10), 20);
  check(a.some(x => x > 3), true);
  check(a.every(x => x > 3), false);
  check(a.every(x => x > 0), true);
  check(a.find(x => x > 2), 3);
  check(a.find(x => x > 9), undefined);
  check(a.findIndex(x => x > 2), 2);
  check(a.findIndex(x => x > 9), -1);
  // Holes: skipped by forEach/map/filter/some, visited by find; map keeps them.
  var h = [1, , 3];
  let visits = 0;
  h.forEach(() => { visits++; });
  check(visits, 2);
  var m = h.map(x => x + 1);
  check(m.length, 3);
  check(1 in m, false);
  check(h.findIndex(x => x === undefined), 1);
  // An index inherited from Array.prototype fills a hole.
  Array.prototype[1] = 7;
  check(h.map(x => x).join(), "1,7,3");
  delete Array.prototype[1];
  // Length is read once; presence is checked per index.
  var g = [1, 2, 3];
  let seen = [];
  g.forEach(x => { seen.push(x); g.push(9); if (x === 1) g.length = 2; });
  check(seen.join(), "1,2,9");
  // undefined results are real elements.
  var u = [1, 2].map(() => undefined);
  check(u.length, 2);
  check(0 in u, true);
  // A subclass's species constructor is honoured.
  class MyArr extends Array {}
  var sub = MyArr.from([1, 2, 3]);
  check(sub.map(x => x) instanceof MyArr, true);
  check(sub.filter(x => x) instanceof MyArr, true);
  // Non-arrays and replaced methods take the ordinary call.
  var like = { length: 2, 0: "a", 1: "b", map: Array.prototype.map };
  check(like.map(x => x + x).join(), "aa,bb");
  var swapped = [1, 2];
  swapped.map = function (f) { return "own"; };
  check(swapped.map(x => x), "own");
  // Exceptions propagate out of the inlined body.
  let caught = false;
  try { a.forEach(x => { if (x === 2) throw new Error("x"); }); } catch (e) { caught = e.message === "x"; }
  check(caught, true);
  // Arrow parameters shadow and do not leak.
  let x = "outer";
  a.forEach(x => x);
  check(x, "outer");
  check([[1, 2], [3]].map(r => r.reduce((p, q) => p + q, 0)).join(), "3,3");
}
main();

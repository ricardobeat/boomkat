// RETURN_SUB's single sweep of the tracked registers: a string held in a
// register above the returned one makes it take the helper after the lower
// registers were cleared, and the result must still come back intact.
function retObj(o) { var r = o; var s = "k" + o.n; return r.n + s.length > 0 ? r : null; }
function retNum(n) { var a = n; var s = "v" + n; return a + s.length * 0; }
function retUndef(o) { var s = "u" + o.n; if (s.length > 100) return s; }
function retStr(o) { var t = o; var s = "s" + t.n; return s; }
function retObjHigh(o) { var s = "h" + o.n; var r = o; return r; }
function retNoStr(o) { var a = o; var b = a.n; return a; }
function run(n) {
  var o = { n: 0 }, sum = 0, ids = 0, und = 0, len = 0;
  for (var i = 0; i < n; i++) {
    o.n = i;
    if (retObj(o) === o) ids++;
    sum += retNum(i);
    if (retUndef(o) === undefined) und++;
    len += retStr(o).length;
    if (retObjHigh(o) === o) ids++;
    if (retNoStr(o).n === i) ids++;
    if (i % 512 === 0) { var junk = []; for (var j = 0; j < 200; j++) junk.push("j" + j + i); }
  }
  return [sum, ids, und, len].join(",");
}
var n = 20000, len = 0;
for (var i = 0; i < n; i++) len += ("s" + i).length;
var expect = [n * (n - 1) / 2, n * 3, n, len].join(",");
var got = run(n);
print(got === expect ? "return_tracked ok" : "return_tracked FAIL " + got + " != " + expect);

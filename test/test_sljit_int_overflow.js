// Integer arithmetic keeps its JavaScript semantics at the int32 boundary: an
// operation that overflows leaves native code and the interpreter produces the
// exact double result, which `|0` then truncates. The expected strings were
// taken from a conforming engine.
function addOverflow(n) {
  var s = 2147483000;
  for (var i = 0; i < n; i++) s = (s + 2147483000) | 0;
  return s;
}

function subOverflow(n) {
  var s = -2147483000;
  for (var i = 0; i < n; i++) s = (s - 2147483000) | 0;
  return s;
}

function mulOverflow(n) {
  var s = 70000;
  for (var i = 0; i < n; i++) s = (s * 70000) | 0;
  return s;
}

function mulNegativeOverflow(n) {
  var s = -70000;
  for (var i = 0; i < n; i++) s = (s * 70000 * 3) | 0;
  return s;
}

function stayInt32(n) {
  var s = 0;
  for (var i = 0; i < n; i++) s = (s + i) | 0;
  return s;
}

var result = [addOverflow(100000), subOverflow(100000), mulOverflow(1000),
  mulNegativeOverflow(1000), stayInt32(200000)].join(",");
var expected = "2082683000,-2082683000,0,0,-1474936480";
if (result !== expected) {
  print("FAIL: int32 overflow=" + result + " expected=" + expected);
} else {
  print("PASS");
}

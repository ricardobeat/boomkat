// ToInt32 accepts booleans, so bitwise combinations of comparisons stay in
// native code. The reference computes the same totals from 0/1 numbers, and
// the wide values exercise the interpreter path a conversion guard still owns.
function hotBooleans(n) {
  var s = 0, t = 0;
  for (var i = 0; i < n; i++) {
    var even = (i & 1) === 0;
    var small = i < 500;
    s = (s + (even & small) + (even | small) + (eitherOf(even, small)) + (small & 3)) | 0;
    t = (t ^ (even & 1)) | 0;
  }
  return s + t;
}

function eitherOf(a, b) {
  return a ^ b;
}

function refBooleans(n) {
  var s = 0, t = 0;
  for (var i = 0; i < n; i++) {
    var even = (i & 1) === 0 ? 1 : 0;
    var small = i < 500 ? 1 : 0;
    s = (s + (even & small) + (even | small) + (even ^ small) + (small & 3)) | 0;
    t = (t ^ (even & 1)) | 0;
  }
  return s + t;
}

// A double outside int32 leaves the native conversion and must still agree.
function wideToInt() {
  return (4294967297 & 3) + (4294967296 & 3) + (-4294967297 | 0) + (true & 7) + (false | 5) + (~true);
}

var expected = 0, total = 0;
for (var k = 0; k < 200; k++) {
  expected += refBooleans(1000);
  total += hotBooleans(1000);
}
if (total !== expected) {
  print("FAIL: boolean bitwise total=" + total + " expected=" + expected);
} else if (wideToInt() !== 1 + 0 + -1 + 1 + 5 + -2) {
  print("FAIL: wide boolean bitwise=" + wideToInt());
} else {
  print("PASS");
}

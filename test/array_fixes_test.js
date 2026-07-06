// Test 1: concat hole preservation
var a = [1, , 3];
var b = [4, , 6];
var c = a.concat(b);
var expected = [1, , 3, 4, , 6];
if (c.length !== 6) throw "concat length wrong: " + c.length;
if (0 in c === false) throw "index 0 missing";
if (c[0] !== 1) throw "c[0] wrong: " + c[0];
if (1 in c !== false) throw "index 1 should be hole";
if (c[2] !== 3) throw "c[2] wrong: " + c[2];
if (3 in c === false) throw "index 3 missing";
if (c[3] !== 4) throw "c[3] wrong: " + c[3];
if (4 in c !== false) throw "index 4 should be hole";
if (c[5] !== 6) throw "c[5] wrong: " + c[5];
console.log("PASS: concat hole preservation");

// Test 2: map hole preservation
var arr = [1, , 3];
var mapped = arr.map(function(x) { return x * 2; });
if (mapped.length !== 3) throw "map length wrong: " + mapped.length;
if (mapped[0] !== 2) throw "mapped[0] wrong: " + mapped[0];
if (1 in mapped !== false) throw "map index 1 should be hole";
if (mapped[2] !== 6) throw "mapped[2] wrong: " + mapped[2];
console.log("PASS: map hole preservation");

// Test 3: map doesn't call callback for holes
var callCount = 0;
var arr2 = [10, , 20, , 30];
arr2.map(function(x) { callCount++; return x; });
if (callCount !== 3) throw "callback called " + callCount + " times, expected 3";
console.log("PASS: map skips callback for holes");

// Test 4: copyWithin with valueOf that throws
var obj = { valueOf: function() { throw 42; } };
var arr3 = [1, 2, 3, 4, 5];
try {
  arr3.copyWithin(obj, 1);
  throw "should have thrown";
} catch(e) {
  if (e === "should have thrown") throw e;
  if (e !== 42) throw "wrong error: " + e;
}
console.log("PASS: copyWithin coercion error propagation");

console.log("ALL TESTS PASSED");

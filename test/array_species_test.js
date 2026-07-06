// Test: plain slice still works (sanity)
var arr4 = [10, 20, 30];
var sliced4 = arr4.slice(0, 2);
if (sliced4.length !== 2) throw "length wrong: " + sliced4.length;
if (sliced4[0] !== 10 || sliced4[1] !== 20) throw "values wrong";
console.log("PASS: plain slice still works");

// Test: plain splice still works
var arr5 = [1, 2, 3, 4, 5];
var spliced5 = arr5.splice(1, 2);
if (spliced5.length !== 2) throw "splice length wrong: " + spliced5.length;
if (spliced5[0] !== 2 || spliced5[1] !== 3) throw "splice values wrong";
if (arr5.length !== 3) throw "original length wrong";
console.log("PASS: plain splice still works");

// Test: slice hole preservation
var arr6 = [1, , 3, , 5];
var sliced6 = arr6.slice(1, 4);
if (sliced6.length !== 3) throw "slice hole length wrong: " + sliced6.length;
if (0 in sliced6 !== false) throw "index 0 should be hole";
if (sliced6[1] !== 3) throw "index 1 wrong";
if (2 in sliced6 !== false) throw "index 2 should be hole";
console.log("PASS: slice hole preservation");

console.log("ALL SANITY TESTS PASSED");

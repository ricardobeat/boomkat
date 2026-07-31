import { sum } from "./sum_series.js";
import { assert, assertEq, assertImported, report } from "./_harness.js";
assertImported(sum, "sum");
assertEq(sum(1, 5, function (x) { return x; }), 15, "1..5 identity");
assertEq(sum(1, 3, function (x) { return x * x; }), 14, "1..3 squares");
assertEq(sum(2, 1, function (x) { return x; }), 0, "empty range sums to 0");
// The Basel series; the sample's own comment cites 1.64393456668156.
var basel = sum(1, 1000, function (x) { return 1 / (x * x); });
assert(Math.abs(basel - 1.64393456668156) < 1e-12, "1/x^2 to 1000 (got " + basel + ")");
report("sum_series");

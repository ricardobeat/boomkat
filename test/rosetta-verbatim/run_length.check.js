import { encode } from "./run_length.js";
import { assertEq, assertImported, report } from "./_harness.js";
assertImported(encode, "encode");
// encode returns [[count, char], ...].
function flat(s) { return encode(s).map(function (p) { return p[0] + p[1]; }).join(""); }
assertEq(flat("aaabbc"), "3a2b1c", "runs of decreasing length");
assertEq(flat("a"), "1a", "single character");
assertEq(flat("abc"), "1a1b1c", "no repeats");
assertEq(flat("WWWWWWWWWWWWBWWWWWWWWWWWWBBB"), "12W1B12W3B", "the task's example");
report("run_length");

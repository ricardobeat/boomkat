import { a, b, c } from "./array_concat.js";
import { assertEq, report } from "./_harness.js";
assertEq(c.join(","), "1,2,3,4,5,6", "concat result");
assertEq(a.join(","), "1,2,3", "concat does not modify the receiver");
assertEq(b.join(","), "4,5,6", "concat does not modify the argument");
report("array_concat");

import { compose } from "./function_composition.js";
import { assertEq, assertImported, report } from "./_harness.js";
assertImported(compose, "compose");
function inc(x) { return x + 1; }
function dbl(x) { return x * 2; }
assertEq(compose(inc, dbl)(5), 11, "inc after dbl");
assertEq(compose(dbl, inc)(5), 12, "dbl after inc (order matters)");
assertEq(compose(inc, inc)(0), 2, "same function twice");
report("function_composition");

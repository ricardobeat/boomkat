import { string, uppercase, lowercase } from "./string_case.js";
import { assertEq, report } from "./_harness.js";
assertEq(string, "alphaBETA", "original is unchanged");
assertEq(uppercase, "ALPHABETA", "toUpperCase");
assertEq(lowercase, "alphabeta", "toLowerCase");
report("string_case");

import { original, little, replaced } from "./string_interp.js";
import { assertEq, report } from "./_harness.js";
assertEq(replaced, "Mary had a little lamb", "X is replaced");
assertEq(original, "Mary had a X lamb", "the original string is not modified");
assertEq(little, "little", "interpolated value");
report("string_interp");

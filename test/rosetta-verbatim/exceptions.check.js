import { doStuff } from "./exceptions.js";
import { assert, assertEq, assertImported, report } from "./_harness.js";
assertImported(doStuff, "doStuff");
var caught = null;
try { doStuff(); } catch (e) { caught = e; }
assert(caught !== null, "doStuff throws");
assert(caught instanceof Error, "throws an Error");
assertEq(caught.message, "Not implemented!", "message");
report("exceptions");

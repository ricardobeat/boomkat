// The sample matches /Hello (World)/i against "Hello world!", so the capture
// group picks up the lowercase "world".
import { subject, isMatch, matches } from "./regexp.js";
import { assert, assertEq, report } from "./_harness.js";
assertEq(subject, "Hello world!", "subject");
assert(isMatch === true, "case-insensitive literal matches");
assert(matches !== null, "exec returned a match");
assertEq(matches[0], "Hello world", "whole match");
assertEq(matches[1], "world", "capture group");
report("regexp");

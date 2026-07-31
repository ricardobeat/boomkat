// Drives regexp.js -- uses: subject isMatch matches
// The sample matches /Hello (World)/i against "Hello world!", so the capture
// group picks up the lowercase "world".
assertEq(subject, "Hello world!", "subject");
assert(isMatch === true, "case-insensitive literal matches");
assert(matches !== null, "exec returned a match");
assertEq(matches[0], "Hello world", "whole match");
assertEq(matches[1], "world", "capture group");
report("regexp");

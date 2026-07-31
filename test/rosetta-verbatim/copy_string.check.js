// Drives copy_string.js -- uses: container containerCopy
// The task's point is that assigning an object copies the reference, not the
// object: mutating through one name is visible through the other.
assertEq(container.myString, "Goodbye", "mutation is visible through the original name");
assertEq(containerCopy.myString, "Goodbye", "and through the copy");
assert(container === containerCopy, "both names refer to the same object");
report("copy_string");

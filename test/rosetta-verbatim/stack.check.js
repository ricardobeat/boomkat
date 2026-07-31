// Drives stack.js -- uses: stack
// The sample prints only the popped value and the remaining length, so its
// stdout cannot reveal which values were pushed. Import the array and assert
// on the contents that survive the pop.
assert(Array.isArray(stack), "stack is an array");
assertEq(stack.length, 2, "two items remain after the pop");
assertEq(stack.join(","), "1,2", "the remaining items are the first two pushed");
stack.push(4);
assertEq(stack.pop(), 4, "push/pop round trip");
assertEq(stack.length, 2, "length restored after pop");
report("stack");

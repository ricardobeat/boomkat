// Drives ackermann.js -- uses: ack

assertEq(ack(0, 0), 1, "ack(0,0)");
assertEq(ack(0, 5), 6, "ack(0,5)");
assertEq(ack(1, 1), 3, "ack(1,1)");
assertEq(ack(2, 1), 5, "ack(2,1)");
assertEq(ack(2, 5), 13, "ack(2,5)");
assertEq(ack(3, 3), 61, "ack(3,3)");
assertEq(ack(3, 5), 253, "ack(3,5)");
report("ackermann");

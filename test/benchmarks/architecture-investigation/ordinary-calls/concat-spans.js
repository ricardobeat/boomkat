var checksum = 0;
var last = "";

var shortPrefix = "node_";
var shortStart = Date.now();
for (var i = 0; i < 200000; i++) {
    last = shortPrefix + i;
    checksum += last.length;
}
print("PHASE short_label " + (Date.now() - shortStart));

var longPrefix = "x".repeat(600);
var longStart = Date.now();
for (var j = 0; j < 8000; j++) {
    last = longPrefix + j;
    checksum += last.length;
}
print("PHASE long_label " + (Date.now() - longStart));

var left = "L".repeat(300);
var right = "R".repeat(300);
var pairStart = Date.now();
for (var k = 0; k < 10000; k++) {
    last = left + right;
    checksum += last.length;
}
print("PHASE independent_pair_600 " + (Date.now() - pairStart));

var shortLeft = "left-";
var shortRight = "-right";
var shortPairStart = Date.now();
for (var m = 0; m < 200000; m++) {
    last = shortLeft + (m % 10) + shortRight;
    checksum += last.length;
}
print("PHASE independent_pair_short " + (Date.now() - shortPairStart));
print("CHECK " + checksum + " " + last.length);

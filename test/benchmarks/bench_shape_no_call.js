// Memory test: unique properties on one object (no function calls)
var map = {};
for (var i = 0; i < 150000; i++) {
    map["key_" + i] = i;
}
// Force materialization
var sum = 0;
sum += map["key_0"];
sum += map["key_149999"];

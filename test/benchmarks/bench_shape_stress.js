// Minimal test: measure memory impact of N unique properties on one object
var map = {};
var N = 150000;
for (var i = 0; i < N; i++) {
    map["key_" + i] = i;
}
// Force materialization
print("map.key_0=" + map["key_0"] + " map.key_" + (N - 1) + "=" + map["key_" + (N - 1)]);

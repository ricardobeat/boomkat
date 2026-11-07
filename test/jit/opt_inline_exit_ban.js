// A captured variable the inlined callee reads held numbers while the body was built and then
// alternates with other values: the typed read exits from the inlined body at every change. After
// repeated exits at that instruction the next build leaves the call a call, and every phase keeps
// its result.
function make() {
    var k = 1;
    function get() { return k; }
    function set(v) { k = v; }
    return { get: get, set: set };
}
var m = make();
function sum(n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        var v = m.get();
        s += typeof v === "number" ? v : v.length;
    }
    return s;
}
var vals = [3, "abcd", 5.5, [1, 2], 7, "xy", {length: 9}, 11];
var total = 0;
for (var round = 0; round < 40; round++) {
    for (var j = 0; j < vals.length; j++) {
        m.set(vals[j]);
        for (var r = 0; r < 60; r++) total += sum(50);
    }
}
print(total);

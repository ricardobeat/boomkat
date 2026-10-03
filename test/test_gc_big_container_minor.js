// A heap of a few huge containers (few objects, many values) collects with minor
// cycles. Young objects stored into the old containers while the churn runs must
// survive, and so must entries reached only through them.
function assertEq(a, b, msg) { if (a !== b) throw new Error(msg + ": " + a + " !== " + b); }

var N = 300000;
var big = [];
for (var i = 0; i < N; i++) big.push(i);
var set = new Set();
var map = new Map();
for (var i = 0; i < 50000; i++) { set.add(i); map.set(i, i); }

// Churn with the iterator protocol, then store fresh objects into the old holders.
function* range(n) { for (var i = 0; i < n; i++) yield i; }
var sum = 0;
for (var round = 0; round < 6; round++) {
    for (var x of range(60000)) sum += x;
    big[round * 1000] = { round: round, tag: "r" + round, list: [round, round + 1] };
    map.set("obj" + round, { n: round, s: "s" + round });
    set.add({ round: round });
    for (var k = 0; k < 20000; k++) { var junk = { a: k, b: [k] }; }
}
assertEq(sum, 6 * (60000 * 59999 / 2), "sum");

for (var round = 0; round < 6; round++) {
    var o = big[round * 1000];
    assertEq(o.round, round, "big object " + round);
    assertEq(o.tag, "r" + round, "big tag " + round);
    assertEq(o.list[1], round + 1, "big list " + round);
    var m = map.get("obj" + round);
    assertEq(m.n, round, "map object " + round);
    assertEq(m.s, "s" + round, "map string " + round);
}
var rounds = 0;
set.forEach(function (v) { if (typeof v === "object") rounds += v.round + 1; });
assertEq(rounds, 21, "set objects");
assertEq(big[N - 1], N - 1, "tail untouched");
assertEq(map.get(49999), 49999, "map number key");
print("ok");

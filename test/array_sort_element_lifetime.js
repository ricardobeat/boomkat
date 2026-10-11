// Array.prototype.sort must keep every element alive until it is written
// back: overwriting slot 0 dropped the last reference to a concatenated string
// still waiting to be stored, and a comparefn may collect mid-sort.

function check(got, want, label) {
    if (got.join("|") !== want.join("|")) {
        throw new Error("FAIL " + label + ": got " + got + ", want " + want);
    }
}

var l = [{ k: "f", n: "x" }, { k: "d", n: "b" }];
check(l.map(function (e) { return e.k + ":" + e.n; }).sort(), ["d:b", "f:x"], "default");

var objs = [{ v: 3 }, { v: 1 }, { v: 2 }];
var sorted = objs.map(function (o) { return { v: o.v }; }).sort(function (a, b) { return a.v - b.v; });
check(sorted.map(function (o) { return o.v; }), [1, 2, 3], "objects");

var big = [];
for (var i = 99; i >= 0; i--) big.push("s" + (1000 + i));
var expected = big.slice().reverse();
check(big.sort(function (a, b) {
    var junk = [];
    for (var j = 0; j < 50; j++) junk.push({ j: j, s: "t" + j });
    return a < b ? -1 : a > b ? 1 : 0;
}), expected, "comparefn allocates");

var arr = ["b" + 1, "a" + 1];
check(arr.sort(function (a, b) { arr.length = 0; return a < b ? -1 : 1; }), ["a1", "b1"], "comparefn truncates");

// toSorted retains collected elements while comparefn shrinks the source.

function check(got, want, label) {
    if (got.join("|") !== want.join("|")) {
        throw new Error("FAIL " + label + ": got " + got + ", want " + want);
    }
}

var a = ["b" + 1, "a" + 1];
check(a.toSorted(function (x, y) { a.length = 0; return x < y ? -1 : 1; }), ["a1", "b1"], "small");

var big = [];
for (var i = 299; i >= 0; i--) big.push("s" + (1000 + i));
var want = big.slice().reverse();
check(big.toSorted(function (x, y) { big.length = 0; return x < y ? -1 : x > y ? 1 : 0; }), want, "large");

var holes = [3, , undefined, 1];
var r = holes.toSorted();
check(r, [1, 3, undefined, undefined], "holes");
if (!(3 in r)) throw new Error("FAIL holes: index 3 missing");

var stable = [{ k: 1, i: 0 }, { k: 0, i: 1 }, { k: 1, i: 2 }, { k: 0, i: 3 }];
check(stable.toSorted(function (x, y) { return x.k - y.k; }).map(function (o) { return o.i; }), [1, 3, 0, 2], "stable");

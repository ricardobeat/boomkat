// Array element reads and writes that the native tier may answer from the
// dense part. The rounds make the sites hot enough to compile, so the
// guarded element path really runs.
var failures = 0;

function check(label, actual, expected) {
    if (actual !== expected) {
        print("FAIL " + label + ": got " + actual + ", expected " + expected);
        failures++;
    }
}

function Bag() { this.items = []; }
Bag.prototype.get = function (index) { return this.items[index]; };
Bag.prototype.set = function (index, value) { this.items[index] = value; return value; };
Bag.prototype.len = function () { return this.items.length; };

var bag = new Bag();
for (var i = 0; i < 8; i++) bag.set(i, i * 10);

var holed = new Bag();
holed.set(0, "a");
holed.set(2, "c");

var named = new Bag();
named.set(0, "dense");
named.items[0] = "named";

var keyed = new Bag();
keyed.set(0, "zero");

var frozen = new Bag();
frozen.set(0, "x");
Object.freeze(frozen.items);

var plain = { 0: "p0", 1: "p1" };
var typed = new Int32Array(4);
typed[2] = 7;

for (var round = 0; round < 200; round++) {
    check("first element", bag.get(0), 0);
    check("last element", bag.get(7), 70);
    check("past the end", bag.get(8), undefined);
    check("negative index", bag.get(-1), undefined);
    check("fractional index", bag.get(1.5), undefined);
    check("numeric string key", bag.get("1"), 10);
    check("no key", bag.get(), undefined);
    check("length", bag.len(), 8);
    check("middle element", bag.get(3), 30);

    check("hole before", holed.get(0), "a");
    check("the hole", holed.get(1), undefined);
    check("hole after", holed.get(2), "c");

    check("named index", named.get(0), "named");
    check("string key", keyed.get("0"), "zero");
    check("length by name", keyed.get("length"), 1);
    check("missing name", keyed.get("nope"), undefined);

    check("plain index", plain[0], "p0");
    check("plain index two", plain[1], "p1");
    check("plain missing", plain[2], undefined);

    check("typed element", typed[2], 7);
    check("typed length", typed.length, 4);
}

// A hot loop makes the sites compile, so the guarded element path runs.
function fill(b, n) {
    for (var i = 0; i < n; i++) { b.set(i, i + 1); }
    return b.get(n - 1);
}
var hot = new Bag();
for (var round = 0; round < 400; round++) {
    check("hot element", fill(hot, 8), 8);
}
check("hot store", hot.get(3), 4);

// A write past the dense part grows the array, which the interpreter owns.
bag.set(20, "grown");
check("grown element", bag.get(20), "grown");
check("grown length", bag.len(), 21);

// A frozen array rejects the write.
frozen.set(0, "y");
check("frozen element", frozen.get(0), "x");

if (failures == 0) print("ok");
